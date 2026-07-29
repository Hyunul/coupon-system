"""EventBridge TTL safety net for the managed benchmark.

This intentionally stops, rather than deletes, only EC2 and Seoul RDS resources whose
Project, Owner, and ExpiresAt tags match the deployment. Terraform destroy is still
required for resources AWS cannot stop, including ALB and ElastiCache.
"""

import os
import json
from datetime import datetime, timezone

import boto3


def _parse_expiry(value: str) -> datetime:
    """Parse Terraform's RFC3339 timestamp as a timezone-aware UTC datetime."""
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _parse_enable_rds(value: str) -> bool:
    """Accept only Terraform's explicit boolean environment encoding."""
    if value == "true":
        return True
    if value == "false":
        return False
    raise ValueError("ENABLE_RDS must be exactly 'true' or 'false'")


def lambda_handler(event, context):
    del event, context
    project = os.environ["PROJECT"]
    owner = os.environ["OWNER"]
    expires_text = os.environ["EXPIRES_AT"]
    expires_at = _parse_expiry(expires_text)
    now = datetime.now(timezone.utc)
    enable_rds = _parse_enable_rds(os.environ["ENABLE_RDS"])

    if now < expires_at:
        return {"status": "not-expired", "expires_at": expires_at.isoformat()}

    failures = []
    stopped_instances = []
    stopped_databases = []
    filters = [
        {"Name": "tag:Project", "Values": [project]},
        {"Name": "tag:ExpiresAt", "Values": [expires_text]},
        {"Name": "tag:Owner", "Values": [owner]},
        {"Name": "instance-state-name", "Values": ["pending", "running"]},
    ]
    ec2 = None
    try:
        ec2 = boto3.client("ec2")
    except Exception as exc:
        failures.append({"scope": "ec2-client", "error": repr(exc)})

    if ec2 is not None:
        try:
            pages = ec2.get_paginator("describe_instances").paginate(Filters=filters)
            instance_ids = [
                instance["InstanceId"]
                for page in pages
                for reservation in page["Reservations"]
                for instance in reservation["Instances"]
            ]
        except Exception as exc:  # Lambda must still attempt independent RDS cleanup.
            instance_ids = []
            failures.append({"scope": "ec2-discovery", "error": repr(exc)})

        for instance_id in instance_ids:
            try:
                ec2.stop_instances(InstanceIds=[instance_id])
                stopped_instances.append(instance_id)
            except Exception as exc:
                failures.append({"scope": "ec2-stop", "resource": instance_id, "error": repr(exc)})

    if enable_rds:
        rds = None
        try:
            rds = boto3.client("rds")
        except Exception as exc:
            failures.append({"scope": "rds-client", "error": repr(exc)})

        if rds is not None:
            try:
                database_pages = rds.get_paginator("describe_db_instances").paginate()
                databases = [database for page in database_pages for database in page["DBInstances"]]
            except Exception as exc:
                databases = []
                failures.append({"scope": "rds-discovery", "error": repr(exc)})

            for database in databases:
                identifier = database["DBInstanceIdentifier"]
                try:
                    tags = rds.list_tags_for_resource(ResourceName=database["DBInstanceArn"])["TagList"]
                    tag_values = {tag["Key"]: tag["Value"] for tag in tags}
                    if (
                        tag_values.get("Project") == project
                        and tag_values.get("Owner") == owner
                        and tag_values.get("ExpiresAt") == expires_text
                        and database["DBInstanceStatus"] == "available"
                    ):
                        rds.stop_db_instance(DBInstanceIdentifier=identifier)
                        stopped_databases.append(identifier)
                except Exception as exc:
                    failures.append({"scope": "rds-stop", "resource": identifier, "error": repr(exc)})

    result = {
        "status": "expired",
        "stopped_instance_ids": stopped_instances,
        "stopped_databases": stopped_databases,
        "failures": failures,
    }
    print(json.dumps(result, sort_keys=True))
    if failures:
        raise RuntimeError(f"TTL cleanup completed with failures: {json.dumps(failures, sort_keys=True)}")
    return result
