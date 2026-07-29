#!/usr/bin/env python3
"""Fail-closed, offline aggregation of manifest-bound k6 sold-out summaries."""

import math
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


REQUIRED_OBJECTS = (
    "plan-manifest.json",
    "runtime-manifest.json",
    "execution-result.json",
    "package-manifest.json",
    "k6-summary.json",
    "k6-console.txt",
)
REQUIRED_THRESHOLD_METRICS = (
    "coupon_decision_duration",
    "coupon_duplicate",
    "coupon_issued",
    "coupon_request_failure",
    "coupon_transport_failure",
    "coupon_unexpected",
    "dropped_iterations",
    "iterations",
)
REQUIRED_COUNT_METRICS = (
    "coupon_issued",
    "coupon_sold_out",
    "coupon_duplicate",
    "dropped_iterations",
)
BUCKET_RE = re.compile(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\Z")
KEY_RE = re.compile(r"[A-Za-z0-9._/-]+\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z", re.IGNORECASE)


class EvidenceError(ValueError):
    """A collected summary cannot support an aggregate claim."""


def positive_integer(value):
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if str(parsed) != value or parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def parse_manifest_bindings(values):
    bindings = {}
    for value in values:
        parts = value.split("=", 6)
        if len(parts) != 7 or not all(parts):
            raise EvidenceError("--publication-manifest must use SUMMARY=MANIFEST=PLAN=RUNTIME=RESULT=PACKAGE=CONSOLE")
        summary, manifest, plan, runtime, result, package, console = parts
        key = str(Path(summary).resolve())
        if key in bindings:
            raise EvidenceError("duplicate publication manifest binding for %s" % summary)
        bindings[key] = tuple(Path(item) for item in (manifest, plan, runtime, result, package, console))
    return bindings

def reject_duplicate_keys(pairs):
    document = {}
    for key, value in pairs:
        if key in document:
            raise EvidenceError("JSON object contains a duplicate key: %s" % key)
        document[key] = value
    return document


def load_json(path, label):
    try:
        with Path(path).open("r", encoding="utf-8") as source:
            return json.load(source, object_pairs_hook=reject_duplicate_keys)
    except FileNotFoundError as error:
        raise EvidenceError("%s file does not exist: %s" % (label, path)) from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError("%s is not valid UTF-8 JSON: %s (%s)" % (label, path, error)) from error


def file_sha256(path, label):
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except FileNotFoundError as error:
        raise EvidenceError("%s file does not exist: %s" % (label, path)) from error
    except OSError as error:
        raise EvidenceError("%s cannot be read: %s (%s)" % (label, path, error)) from error


def manifest_identity(manifest, summary_path):
    if not isinstance(manifest, dict) or set(manifest) != {"schema_version", "objects"}:
        raise EvidenceError("publication manifest has an invalid schema: %s" % summary_path)
    if isinstance(manifest["schema_version"], bool) or not isinstance(manifest["schema_version"], int) or manifest["schema_version"] != 1:
        raise EvidenceError("publication manifest schema_version must be JSON integer 1: %s" % summary_path)
    objects = manifest["objects"]
    if not isinstance(objects, list) or len(objects) != len(REQUIRED_OBJECTS):
        raise EvidenceError("publication manifest must contain exactly six objects: %s" % summary_path)

    parsed = {}
    for entry in objects:
        if not isinstance(entry, dict) or set(entry) != {"name", "bucket", "key", "sha256", "version_id"}:
            raise EvidenceError("publication manifest object has an invalid schema: %s" % summary_path)
        if not all(isinstance(entry[field], str) for field in entry):
            raise EvidenceError("publication manifest object fields must be strings: %s" % summary_path)
        name, bucket, key, digest, version = (entry[field] for field in ("name", "bucket", "key", "sha256", "version_id"))
        if name not in REQUIRED_OBJECTS or name in parsed:
            raise EvidenceError("publication manifest object names must be the six unique required names: %s" % summary_path)
        if not BUCKET_RE.fullmatch(bucket) or not KEY_RE.fullmatch(key) or not SHA256_RE.fullmatch(digest) or not version:
            raise EvidenceError("publication manifest contains malformed object identity: %s" % summary_path)
        parsed[name] = (bucket, key, digest.lower(), version)
    if set(parsed) != set(REQUIRED_OBJECTS):
        raise EvidenceError("publication manifest is missing a required object: %s" % summary_path)

    directories = set()
    buckets = set()
    for name, (bucket, key, _, _) in parsed.items():
        suffix = "/" + name
        if not key.endswith(suffix):
            raise EvidenceError("publication manifest object key does not match its name: %s" % summary_path)
        buckets.add(bucket)
        directories.add(key[:-len(name)])
    if len(buckets) != 1 or len(directories) != 1:
        raise EvidenceError("publication manifest objects must share one bucket and directory: %s" % summary_path)

    bucket, key, _, version = parsed["k6-summary.json"]
    return "%s/%s?version_id=%s" % (bucket, key, version), "%s/%s" % (bucket, key), parsed


def verify_manifest_hash(path, object_identity, label):
    if file_sha256(path, label) != object_identity[2]:
        raise EvidenceError("local %s SHA-256 does not match its publication manifest: %s" % (label, path))


PLAN_FIELDS = {
    "run_id", "run_type", "created_at_utc", "commit", "git_dirty", "git_status",
    "application_profile", "aws_cli_profile", "record_mode", "regions",
    "instance_types", "jvm", "pool", "mock_notify", "event_id", "users", "stock",
    "rate", "duration", "duration_seconds", "base_url", "user_offset",
    "payload_descriptor", "request_payload_bytes", "claim_mode", "result_policy",
    "dry_run", "preallocated_vus", "max_vus", "scenario", "scenario_sha256",
    "package_manifest_sha256", "expected_attempts",
}
PLAN_STRING_FIELDS = PLAN_FIELDS - {
    "git_dirty", "git_status", "regions", "event_id", "users", "stock", "rate",
    "duration_seconds", "user_offset", "request_payload_bytes", "claim_mode",
    "dry_run", "preallocated_vus", "max_vus", "expected_attempts",
}


def positive_json_integer(value, field, path):
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise EvidenceError("plan-manifest %s must be a positive JSON integer: %s" % (field, path))
    return value


def plan_identity(plan, path):
    if not isinstance(plan, dict) or set(plan) != PLAN_FIELDS:
        raise EvidenceError("plan-manifest has an invalid schema: %s" % path)
    for field in PLAN_STRING_FIELDS:
        if not isinstance(plan[field], str) or not plan[field]:
            raise EvidenceError("plan-manifest %s must be a non-empty string: %s" % (field, path))
    if not isinstance(plan["git_dirty"], bool) or not isinstance(plan["claim_mode"], bool) or not isinstance(plan["dry_run"], bool):
        raise EvidenceError("plan-manifest boolean field has an invalid type: %s" % path)
    if not isinstance(plan["git_status"], list) or not all(isinstance(value, str) for value in plan["git_status"]):
        raise EvidenceError("plan-manifest git_status has an invalid schema: %s" % path)
    regions = plan["regions"]
    if (not isinstance(regions, list) or not regions or
            not all(isinstance(value, str) and re.fullmatch(r"[a-z]{2}-[a-z]+-\d+", value) for value in regions) or
            regions != sorted(set(regions))):
        raise EvidenceError("plan-manifest regions must be a non-empty canonical JSON region list: %s" % path)
    for field in ("event_id", "users", "stock", "rate", "preallocated_vus", "max_vus"):
        positive_json_integer(plan[field], field, path)
    for field in ("user_offset", "request_payload_bytes"):
        if isinstance(plan[field], bool) or not isinstance(plan[field], int) or plan[field] < 0:
            raise EvidenceError("plan-manifest %s must be a non-negative JSON integer: %s" % (field, path))
    for field in ("duration_seconds", "expected_attempts"):
        if (isinstance(plan[field], bool) or not isinstance(plan[field], (int, float)) or
                not math.isfinite(plan[field]) or plan[field] <= 0):
            raise EvidenceError("plan-manifest %s must be a finite positive JSON number: %s" % (field, path))
    if not SHA256_RE.fullmatch(plan["scenario_sha256"]) or not SHA256_RE.fullmatch(plan["package_manifest_sha256"]):
        raise EvidenceError("plan-manifest SHA-256 field is malformed: %s" % path)
    if plan["result_policy"] != "sold-out":
        raise EvidenceError("plan-manifest result_policy must be sold-out: %s" % path)
    return json.dumps(plan, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def execution_run_id(result, path):
    if not isinstance(result, dict) or set(result) != {"run_id", "k6_exit_code", "status", "summary_present"}:
        raise EvidenceError("execution-result has an invalid schema: %s" % path)
    if not isinstance(result["run_id"], str) or not result["run_id"]:
        raise EvidenceError("execution-result run_id must be a non-empty string: %s" % path)
    if isinstance(result["k6_exit_code"], bool) or not isinstance(result["k6_exit_code"], int):
        raise EvidenceError("execution-result k6_exit_code must be a JSON integer: %s" % path)
    if result["status"] != "completed" or result["k6_exit_code"] != 0 or result["summary_present"] is not True:
        raise EvidenceError("execution-result does not prove completed successful summary: %s" % path)
    return result["run_id"]


RUNTIME_FIELDS = {
    "schema_version", "run_id", "plan_sha256", "package_manifest_sha256", "region",
    "instance_id", "user_offset", "users", "started_at_utc", "ami_id", "kernel",
    "k6_version", "python_version", "aws_cli_version", "package_nevra",
}

def runtime_identity(runtime, path, plan_document, objects):
    if not isinstance(runtime, dict) or set(runtime) != RUNTIME_FIELDS:
        raise EvidenceError("runtime-manifest has an invalid schema: %s" % path)
    if runtime["schema_version"] != 1 or isinstance(runtime["schema_version"], bool):
        raise EvidenceError("runtime-manifest schema_version must be JSON integer 1: %s" % path)
    for field in ("run_id", "plan_sha256", "package_manifest_sha256", "region", "instance_id",
                  "started_at_utc", "ami_id", "kernel", "k6_version", "python_version", "aws_cli_version"):
        if not isinstance(runtime[field], str) or not runtime[field]:
            raise EvidenceError("runtime-manifest %s must be a non-empty string: %s" % (field, path))
    if (not SHA256_RE.fullmatch(runtime["plan_sha256"]) or
            not SHA256_RE.fullmatch(runtime["package_manifest_sha256"])):
        raise EvidenceError("runtime-manifest digest is malformed: %s" % path)
    if isinstance(runtime["user_offset"], bool) or not isinstance(runtime["user_offset"], int) or runtime["user_offset"] < 0:
        raise EvidenceError("runtime-manifest user_offset must be a non-negative JSON integer: %s" % path)
    positive_json_integer(runtime["users"], "users", path)
    if not isinstance(runtime["package_nevra"], list) or not all(isinstance(item, str) for item in runtime["package_nevra"]):
        raise EvidenceError("runtime-manifest package_nevra has an invalid schema: %s" % path)
    if runtime["run_id"] != plan_document["run_id"]:
        raise EvidenceError("runtime-manifest run_id does not match plan-manifest: %s" % path)
    if runtime["plan_sha256"].lower() != objects["plan-manifest.json"][2]:
        raise EvidenceError("runtime-manifest plan digest does not match published plan-manifest: %s" % path)
    if runtime["package_manifest_sha256"].lower() != objects["package-manifest.json"][2]:
        raise EvidenceError("runtime-manifest package digest does not match published package-manifest: %s" % path)
    if runtime["region"] not in plan_document["regions"] or not re.fullmatch(r"i-[a-f0-9]{8,17}", runtime["instance_id"]):
        raise EvidenceError("runtime-manifest has an invalid effective generator identity: %s" % path)
    start = runtime["user_offset"]
    users = runtime["users"]
    if start < plan_document["user_offset"] or (start - plan_document["user_offset"]) % plan_document["users"] or users != plan_document["users"]:
        raise EvidenceError("runtime-manifest user range does not match the plan allocation: %s" % path)
    if start > (2 ** 63 - 1) - (users - 1):
        raise EvidenceError("runtime-manifest user range overflows: %s" % path)
    return runtime["region"], runtime["instance_id"], start, start + users - 1

def load_summary(path, binding):
    manifest_path, plan_path, runtime_path, result_path, package_path, console_path = binding
    manifest = load_json(manifest_path, "publication manifest")
    identity, _, objects = manifest_identity(manifest, path)
    for local_path, name, label in (
            (path, "k6-summary.json", "summary"), (plan_path, "plan-manifest.json", "plan-manifest"),
            (runtime_path, "runtime-manifest.json", "runtime-manifest"), (result_path, "execution-result.json", "execution-result"),
            (package_path, "package-manifest.json", "package-manifest"), (console_path, "k6-console.txt", "k6-console")):
        verify_manifest_hash(local_path, objects[name], label)
    summary = load_json(path, "summary")
    if not isinstance(summary, dict):
        raise EvidenceError("summary root must be an object: %s" % path)
    plan_document = load_json(plan_path, "plan-manifest")
    plan = plan_identity(plan_document, plan_path)
    if plan_document["package_manifest_sha256"].lower() != objects["package-manifest.json"][2]:
        raise EvidenceError("plan-manifest package digest does not match the published package-manifest object: %s" % plan_path)
    slot = runtime_identity(load_json(runtime_path, "runtime-manifest"), runtime_path, plan_document, objects)
    expected_prefix = "%s/%s/%s/" % (plan_document["run_id"], slot[0], slot[1])
    for name, (_, key, _, _) in objects.items():
        if key != expected_prefix + name:
            raise EvidenceError("publication manifest object key is not the canonical run/region/instance path: %s" % manifest_path)
    result_run_id = execution_run_id(load_json(result_path, "execution-result"), result_path)
    if result_run_id != plan_document["run_id"]:
        raise EvidenceError("execution-result run_id does not match plan-manifest: %s" % result_path)
    metrics = summary.get("metrics")
    if not isinstance(metrics, dict):
        raise EvidenceError("summary has no metrics object: %s" % path)
    iterations = nonnegative_count(metrics.get("iterations"), "iterations", path)
    expected_attempts = plan_document["expected_attempts"]
    if iterations > math.ceil(expected_attempts) or iterations < math.ceil(expected_attempts * 0.999):
        raise EvidenceError("summary iterations do not reconcile with plan expected_attempts: %s" % path)
    observed_outcomes = sum(nonnegative_count(metrics.get(name), name, path) for name in ("coupon_issued", "coupon_sold_out", "coupon_duplicate"))
    if observed_outcomes > iterations:
        raise EvidenceError("summary outcomes exceed observed iterations: %s" % path)
    return identity, slot, plan, plan_document["stock"], metrics


def nonnegative_count(metric, name, path):
    values = metric.get("values") if isinstance(metric, dict) else None
    value = values.get("count") if isinstance(values, dict) else None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise EvidenceError("summary is missing non-negative integer %s.values.count: %s" % (name, path))
    return value


def validate_thresholds(metrics, path):
    for name in REQUIRED_THRESHOLD_METRICS:
        metric = metrics.get(name)
        if not isinstance(metric, dict):
            raise EvidenceError("summary is missing required threshold metric %s: %s" % (name, path))
        thresholds = metric.get("thresholds")
        if not isinstance(thresholds, dict) or not thresholds:
            raise EvidenceError("summary is missing threshold results for %s: %s" % (name, path))
        if any(passed is not True for passed in thresholds.values()):
            raise EvidenceError("summary has failed threshold(s) for %s in %s: %s" % (name, path, ", ".join(sorted(thresholds))))


def collect(paths, bindings):
    seen_slots = set()
    ranges = []
    plans = set()
    stocks = set()
    totals = {name: 0 for name in REQUIRED_COUNT_METRICS}
    identities = []
    for path in paths:
        identity, slot, plan, stock, metrics = load_summary(path, bindings[str(Path(path).resolve())])
        if slot[:2] in seen_slots:
            raise EvidenceError("duplicate runtime generator identity %r" % (slot[:2],))
        if any(slot[2] <= end and start <= slot[3] for start, end in ranges):
            raise EvidenceError("effective generator user ranges overlap")
        seen_slots.add(slot[:2])
        ranges.append((slot[2], slot[3]))
        plans.add(plan)
        stocks.add(stock)
        validate_thresholds(metrics, path)
        for name in REQUIRED_COUNT_METRICS:
            totals[name] += nonnegative_count(metrics.get(name), name, path)
        identities.append(identity)
    if len(plans) != 1 or len(stocks) != 1:
        raise EvidenceError("publication manifests have mixed canonical plan identities")
    return sorted(identities), totals, stocks.pop()


def report(stock, identities, totals):
    failures = []
    if totals["coupon_issued"] < stock:
        failures.append("global under-issue: coupon_issued=%d, expected_stock=%d" % (totals["coupon_issued"], stock))
    if totals["coupon_issued"] > stock:
        failures.append("global over-issue: coupon_issued=%d, expected_stock=%d" % (totals["coupon_issued"], stock))
    if totals["coupon_sold_out"] == 0:
        failures.append("no sold-out observation: coupon_sold_out=0")
    if totals["coupon_duplicate"] != 0:
        failures.append("duplicate issue observed: coupon_duplicate=%d" % totals["coupon_duplicate"])
    if totals["dropped_iterations"] != 0:
        failures.append("dropped iterations observed: dropped_iterations=%d" % totals["dropped_iterations"])
    if failures:
        raise EvidenceError("; ".join(failures))
    return {"aggregate_metrics": totals, "durable_reconciliation": {"required": True, "script": "verify-aws-consistency.sql", "status": "not_claimed_by_k6_aggregate"}, "expected_stock": stock, "local_thresholds_passed": True, "policy": "sold-out", "provenance_ids": identities, "schema_version": 1, "summary_count": len(identities)}


def write_report(destination, payload):
    serialized = json.dumps(payload, sort_keys=True, indent=2) + "\n"
    if destination:
        output = Path(destination)
        output.parent.mkdir(parents=True, exist_ok=True)
        try:
            with output.open("x", encoding="utf-8") as stream:
                stream.write(serialized)
        except FileExistsError as error:
            raise EvidenceError("aggregate output already exists and cannot be overwritten: %s" % output) from error
    sys.stdout.write(serialized)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-stock", type=positive_integer, help="optional value that must exactly match the bound plan manifests")
    parser.add_argument("--publication-manifest", action="append", default=[], metavar="SUMMARY=MANIFEST=PLAN=RUNTIME=RESULT=PACKAGE=CONSOLE", help="hash-bound local copies of the exact six published objects for a summary")
    parser.add_argument("--output", help="optional aggregate JSON output path; JSON is always also printed")
    parser.add_argument("summaries", nargs="+", metavar="K6_SUMMARY")
    args = parser.parse_args(argv)
    if len(args.summaries) < 2:
        parser.error("at least two k6 summary paths are required")
    try:
        paths = [str(Path(path)) for path in args.summaries]
        resolved = {str(Path(path).resolve()) for path in paths}
        if len(resolved) != len(paths):
            raise EvidenceError("duplicate summary input path")
        bindings = parse_manifest_bindings(args.publication_manifest)
        if set(bindings) != resolved:
            raise EvidenceError("each summary requires exactly one publication manifest binding")
        identities, totals, stock = collect(paths, bindings)
        if args.expected_stock is not None and args.expected_stock != stock:
            raise EvidenceError("--expected-stock does not match the bound plan manifests")
        write_report(args.output, report(stock, identities, totals))
    except EvidenceError as error:
        parser.exit(1, "aggregate-k6-evidence: %s\n" % error)


if __name__ == "__main__":
    main()
