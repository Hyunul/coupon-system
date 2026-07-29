#!/usr/bin/env python3
"""Build a fail-closed, offline recovery/fault evidence manifest."""

import argparse
import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
INPUT_SCHEMAS = {
    "stop_receipt": {
        "run_id",
        "event_id",
        "target_instance_id",
        "action",
        "command_id",
        "status",
        "submitted_at",
        "completed_at",
        "service",
    },
    "start_receipt": {
        "run_id",
        "event_id",
        "target_instance_id",
        "action",
        "command_id",
        "status",
        "submitted_at",
        "completed_at",
        "service",
    },
    "timeline": {
        "run_id",
        "event_id",
        "load_started_at",
        "stop_submitted_at",
        "stop_completed_at",
        "start_submitted_at",
        "start_completed_at",
        "recovery_completed_at",
    },
    "redis": {
        "run_id",
        "event_id",
        "status",
        "captured_at",
        "pending_before_stop",
        "pending_after_stop",
        "reclaimed",
        "pending_after_drain",
        "drained_at",
    },
    "mysql": {
        "run_id",
        "event_id",
        "status",
        "captured_at",
        "over_issued",
        "duplicate_issues",
    },
    "api": {
        "run_id",
        "event_id",
        "status",
        "captured_at",
        "successful_requests",
        "transport_failures",
        "unexpected_responses",
        "duplicate_issues",
        "over_issued",
    },
    "notification": {
        "run_id",
        "event_id",
        "status",
        "captured_at",
        "completed",
        "pending",
        "failed",
    },
}
APPROVED_WORKER_SERVICES = {"coupon-worker-stream"}


class EvidenceError(ValueError):
    """An input cannot support a recovery/fault claim."""


def utc_timestamp(value, field):
    if not isinstance(value, str) or not value:
        raise EvidenceError("%s must be a non-empty UTC timestamp" % field)
    if not value.endswith("Z"):
        raise EvidenceError("%s must use a UTC Z timestamp" % field)
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise EvidenceError("%s must be an ISO-8601 UTC timestamp" % field) from error
    if parsed.tzinfo != timezone.utc:
        raise EvidenceError("%s must use UTC" % field)
    return parsed


def nonempty_string(value, field):
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError("%s must be a non-empty string" % field)
    return value


def nonnegative_integer(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise EvidenceError("%s must be a non-negative integer" % field)
    return value

def positive_integer(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise EvidenceError("%s must be a positive integer" % field)
    return value





def require_exact_keys(payload, name):
    if not isinstance(payload, dict):
        raise EvidenceError("%s must be a JSON object" % name)
    expected = INPUT_SCHEMAS[name]
    actual = set(payload)
    missing = expected - actual
    extra = actual - expected
    if missing or extra:
        parts = []
        if missing:
            parts.append("missing " + ", ".join(sorted(missing)))
        if extra:
            parts.append("extra " + ", ".join(sorted(extra)))
        raise EvidenceError("%s has %s" % (name, "; ".join(parts)))

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("JSON object has duplicate key: %s" % key)
        result[key] = value
    return result





def read_input(name, raw_path, seen_identities):
    path = Path(raw_path)
    if path.is_symlink():
        raise EvidenceError("%s input must not be a symlink: %s" % (name, path))
    if not path.exists() or not path.is_file():
        raise EvidenceError("%s input must be a regular file: %s" % (name, path))
    identity = (path.stat().st_dev, path.stat().st_ino)
    if identity in seen_identities:
        raise EvidenceError("duplicate input file: %s" % path)
    seen_identities.add(identity)
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError("%s input must be UTF-8 JSON: %s" % (name, path)) from error
    require_exact_keys(payload, name)
    return payload, {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def validate_receipt(receipt, name):
    command_id = nonempty_string(receipt["command_id"], name + ".command_id")
    service = nonempty_string(receipt["service"], name + ".service")
    target_instance_id = nonempty_string(receipt["target_instance_id"], name + ".target_instance_id")
    if receipt["status"] != "Success":
        raise EvidenceError("%s.status must be Success" % name)
    submitted = utc_timestamp(receipt["submitted_at"], name + ".submitted_at")
    completed = utc_timestamp(receipt["completed_at"], name + ".completed_at")
    if completed < submitted:
        raise EvidenceError("%s.completed_at precedes submitted_at" % name)
    return command_id, service, target_instance_id, submitted, completed


def validate_snapshot(snapshot, name):
    if snapshot["status"] != "PASS":
        raise EvidenceError("%s.status must be PASS" % name)
    return utc_timestamp(snapshot["captured_at"], name + ".captured_at")


def validate_inputs(inputs):
    run_id = nonempty_string(inputs["timeline"]["run_id"], "timeline.run_id")
    event_id = positive_integer(inputs["timeline"]["event_id"], "timeline.event_id")
    for name, payload in inputs.items():
        if nonempty_string(payload["run_id"], name + ".run_id") != run_id:
            raise EvidenceError("%s.run_id does not match timeline.run_id" % name)
        if positive_integer(payload["event_id"], name + ".event_id") != event_id:
            raise EvidenceError("%s.event_id does not match timeline.event_id" % name)

    stop_id, stop_service, stop_target, stop_submitted, stop_completed = validate_receipt(
        inputs["stop_receipt"], "stop_receipt"
    )
    start_id, start_service, start_target, start_submitted, start_completed = validate_receipt(
        inputs["start_receipt"], "start_receipt"
    )
    if inputs["stop_receipt"]["action"] != "stop" or inputs["start_receipt"]["action"] != "start":
        raise EvidenceError("receipt actions must be exact stop and start")
    if stop_id == start_id:
        raise EvidenceError("stop and start command IDs must differ")
    if stop_service != start_service:
        raise EvidenceError("stop and start receipts must identify the same worker service")
    if stop_service not in APPROVED_WORKER_SERVICES:
        raise EvidenceError("receipt service must be an approved worker service identity")
    if stop_target != start_target:
        raise EvidenceError("receipt target instance IDs must match")

    timeline = inputs["timeline"]
    ordered = (
        "load_started_at",
        "stop_submitted_at",
        "stop_completed_at",
        "start_submitted_at",
        "start_completed_at",
        "recovery_completed_at",
    )
    moments = {field: utc_timestamp(timeline[field], "timeline." + field) for field in ordered}
    if any(moments[earlier] > moments[later] for earlier, later in zip(ordered, ordered[1:])):
        raise EvidenceError("timeline timestamps are not ordered")
    if moments["stop_submitted_at"] != stop_submitted or moments["stop_completed_at"] != stop_completed:
        raise EvidenceError("timeline stop timestamps do not match stop receipt")
    if moments["start_submitted_at"] != start_submitted or moments["start_completed_at"] != start_completed:
        raise EvidenceError("timeline start timestamps do not match start receipt")

    redis = inputs["redis"]
    redis_captured = validate_snapshot(redis, "redis")
    for field in ("pending_before_stop", "pending_after_stop", "reclaimed", "pending_after_drain"):
        nonnegative_integer(redis[field], "redis." + field)
    drained = utc_timestamp(redis["drained_at"], "redis.drained_at")
    if redis["pending_after_stop"] <= redis["pending_before_stop"]:
        raise EvidenceError("redis.pending_after_stop must exceed pending_before_stop")
    if redis["reclaimed"] == 0 or redis["pending_after_drain"] != 0:
        raise EvidenceError("redis reclaim/drain reconciliation failed")
    if drained > redis_captured:
        raise EvidenceError("redis.drained_at follows redis.captured_at")
    if drained < moments["start_completed_at"] or drained > moments["recovery_completed_at"]:
        raise EvidenceError("redis drain timestamp is outside the recovery window")

    mysql = inputs["mysql"]
    mysql_captured = validate_snapshot(mysql, "mysql")
    if mysql_captured < moments["recovery_completed_at"]:
        raise EvidenceError("mysql.captured_at precedes recovery completion")
    for field in ("over_issued", "duplicate_issues"):
        if nonnegative_integer(mysql[field], "mysql." + field) != 0:
            raise EvidenceError("mysql.%s must be zero" % field)

    api = inputs["api"]
    api_captured = validate_snapshot(api, "api")
    if api_captured < moments["recovery_completed_at"]:
        raise EvidenceError("api.captured_at precedes recovery completion")
    if nonnegative_integer(api["successful_requests"], "api.successful_requests") == 0:
        raise EvidenceError("api.successful_requests must be positive")
    for field in ("transport_failures", "unexpected_responses", "duplicate_issues", "over_issued"):
        nonnegative_integer(api[field], "api." + field)
    if api["transport_failures"] != 0 or api["unexpected_responses"] != 0:
        raise EvidenceError("api transport/unexpected counters must be zero")
    if api["duplicate_issues"] != 0 or api["over_issued"] != 0:
        raise EvidenceError("api reconciliation failed")

    notification = inputs["notification"]
    notification_captured = validate_snapshot(notification, "notification")
    if notification_captured < moments["recovery_completed_at"]:
        raise EvidenceError("notification.captured_at precedes recovery completion")
    if notification["completed"] is not True:
        raise EvidenceError("notification.completed must be true")
    for field in ("pending", "failed"):
        if nonnegative_integer(notification[field], "notification." + field) != 0:
            raise EvidenceError("notification.%s must be zero" % field)


def canonical_manifest(inputs, digests):
    return {
        "inputs": {name: digests[name] for name in sorted(digests)},
        "recovery": {
            "bindings": {
                "event_id": inputs["timeline"]["event_id"],
                "run_id": inputs["timeline"]["run_id"],
                "target_instance_id": inputs["stop_receipt"]["target_instance_id"],
                "service": inputs["stop_receipt"]["service"],
            },
            "start": {
                "action": inputs["start_receipt"]["action"],
                "command_id": inputs["start_receipt"]["command_id"],
            },
            "stop": {
                "action": inputs["stop_receipt"]["action"],
                "command_id": inputs["stop_receipt"]["command_id"],
            },
            "timeline": inputs["timeline"],
        },
        "schema_version": SCHEMA_VERSION,
    }


def write_manifest(path_text, manifest, input_identities):
    output = Path(path_text)
    if output.is_symlink():
        raise EvidenceError("output must not be a symlink: %s" % output)
    if output.exists() and (output.stat().st_dev, output.stat().st_ino) in input_identities:
        raise EvidenceError("output must not overwrite an input")
    if output.exists():
        raise EvidenceError("output already exists: %s" % output)
    if not output.parent.exists() or not output.parent.is_dir() or output.parent.is_symlink():
        raise EvidenceError("output parent must be an existing non-symlink directory")
    serialized = json.dumps(manifest, sort_keys=True, indent=2) + "\n"
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(output.parent), delete=False) as temporary:
            temporary.write(serialized)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_name = temporary.name
        try:
            os.link(temporary_name, output)
        except FileExistsError as error:
            raise EvidenceError("output already exists: %s" % output) from error
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in INPUT_SCHEMAS:
        parser.add_argument("--" + name.replace("_", "-"), required=True, dest=name, metavar="JSON")
    parser.add_argument("--output", required=True, metavar="MANIFEST")
    args = parser.parse_args(argv)
    try:
        inputs, digests, seen_paths = {}, {}, set()
        for name in INPUT_SCHEMAS:
            inputs[name], digests[name] = read_input(name, getattr(args, name), seen_paths)
        validate_inputs(inputs)
        write_manifest(args.output, canonical_manifest(inputs, digests), seen_paths)
    except EvidenceError as error:
        parser.exit(1, "build-recovery-evidence: %s\n" % error)


if __name__ == "__main__":
    main()
