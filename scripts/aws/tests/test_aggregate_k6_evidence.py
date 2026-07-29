"""Offline fail-closed contracts for aggregate-k6-evidence.py."""

import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "aggregate-k6-evidence.py"
REQUIRED_OBJECTS = ("plan-manifest.json", "runtime-manifest.json", "execution-result.json", "package-manifest.json", "k6-summary.json", "k6-console.txt")


def load_tool():
    spec = importlib.util.spec_from_file_location("aggregate_k6_evidence_contract", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def summary(issued, sold_out, iterations=100):
    thresholds = {"coupon_decision_duration": "p(99)<200", "coupon_duplicate": "count==0", "coupon_issued": "count>=0", "coupon_request_failure": "rate<=0.001", "coupon_transport_failure": "rate<=0.001", "coupon_unexpected": "rate<=0.001", "dropped_iterations": "count==0", "iterations": "count>=1"}
    counts = {"coupon_issued": issued, "coupon_sold_out": sold_out, "coupon_duplicate": 0, "dropped_iterations": 0, "iterations": iterations}
    metrics = {name: {"thresholds": {rule: True}} for name, rule in thresholds.items()}
    for name, count in counts.items():
        metrics.setdefault(name, {})
        metrics[name]["values"] = {"count": count}
    return {"metrics": metrics}


class AggregateK6EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_tool()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, name, payload):
        path = self.root / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def plan(self, run="run-1", event=1, stock=100, policy="sold-out", package_digest="b" * 64):
        return {
            "run_id": run, "run_type": "control", "created_at_utc": "2026-07-28T00:00:00Z",
            "commit": "abc", "git_dirty": False, "git_status": [], "application_profile": "reactive",
            "aws_cli_profile": "unset", "record_mode": "stream", "regions": ["ap-northeast-2"],
            "instance_types": "k6=c7i.2xlarge", "jvm": "n/a", "pool": "n/a", "mock_notify": "n/a",
            "event_id": event, "users": 1000, "stock": stock, "rate": 10, "duration": "10s",
            "duration_seconds": 10, "base_url": "https://benchmark.example", "user_offset": 0,
            "payload_descriptor": "null-body", "request_payload_bytes": 0, "claim_mode": True,
            "result_policy": policy, "dry_run": True, "preallocated_vus": 1, "max_vus": 1,
            "scenario": "aws-capacity.js", "scenario_sha256": "a" * 64,
            "package_manifest_sha256": package_digest, "expected_attempts": 100,
        }

    def bundle(self, name, instance, issued, sold_out, run="run-1", event=1, stock=100, policy="sold-out", status="completed", exit_code=0, summary_present=True, offset=0):
        instance = {"i-one": "i-00000001", "i-two": "i-00000002"}.get(instance, instance)
        summary_path = self.fixture(name + "-summary.json", summary(issued, sold_out))
        package_path = self.fixture(name + "-package.json", {"files": [{"path": "coupon-loadtest/scenarios/aws-capacity.js"}]})
        package_digest = hashlib.sha256(package_path.read_bytes()).hexdigest()
        plan_path = self.fixture(name + "-plan.json", self.plan(run, event, stock, policy, package_digest))
        plan_digest = hashlib.sha256(plan_path.read_bytes()).hexdigest()
        runtime_path = self.fixture(name + "-runtime.json", {
            "schema_version": 1, "run_id": run, "plan_sha256": plan_digest, "package_manifest_sha256": package_digest,
            "region": "ap-northeast-2", "instance_id": instance, "user_offset": offset, "users": 1000,
            "started_at_utc": "2026-07-28T00:00:00Z", "ami_id": "ami-1", "kernel": "kernel",
            "k6_version": "k6", "python_version": "python", "aws_cli_version": "aws", "package_nevra": ["curl"],
        })
        result_path = self.fixture(name + "-result.json", {"run_id": run, "k6_exit_code": exit_code, "status": status, "summary_present": summary_present})
        console_path = self.root / (name + "-console.txt")
        console_path.write_text("k6 console\n", encoding="utf-8")
        directory = "%s/ap-northeast-2/%s/" % (run, instance)
        sources = {"plan-manifest.json": plan_path, "runtime-manifest.json": runtime_path, "execution-result.json": result_path, "package-manifest.json": package_path, "k6-summary.json": summary_path, "k6-console.txt": console_path}
        objects = []
        for object_name in REQUIRED_OBJECTS:
            source = sources[object_name]
            objects.append({"name": object_name, "bucket": "evidence-bucket", "key": directory + object_name, "sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "version_id": "version-" + name + "-" + object_name})
        manifest_path = self.fixture(name + "-manifest.json", {"schema_version": 1, "objects": objects})
        return summary_path, manifest_path, plan_path, runtime_path, result_path, package_path, console_path

    def invoke(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                self.tool.main(list(arguments))
                code = 0
            except SystemExit as error:
                code = error.code
        return code, stdout.getvalue(), stderr.getvalue()

    def arguments(self, *bundles, expected_stock=None):
        arguments = []
        if expected_stock is not None:
            arguments += ["--expected-stock", str(expected_stock)]
        for summary_path, manifest_path, plan_path, runtime_path, result_path, package_path, console_path in bundles:
            arguments += ["--publication-manifest", "%s=%s=%s=%s=%s=%s=%s" % (summary_path, manifest_path, plan_path, runtime_path, result_path, package_path, console_path)]
        arguments += [str(bundle[0]) for bundle in bundles]
        return arguments

    def test_valid_aggregation_derives_stock_from_hash_bound_plans(self):
        first = self.bundle("one", "i-one", 40, 2)
        second = self.bundle("two", "i-two", 60, 3, offset=1000)
        code, output, diagnostic = self.invoke(*self.arguments(first, second, expected_stock=100))
        self.assertEqual(code, 0)
        self.assertEqual(diagnostic, "")
        report = json.loads(output)
        self.assertEqual(report["expected_stock"], 100)
        self.assertEqual(report["aggregate_metrics"]["coupon_issued"], 100)
        self.assertEqual(report["summary_count"], 2)
        self.assertIn("version-one-k6-summary.json", report["provenance_ids"][0])

    def test_rejects_failed_execution_and_hash_mismatch(self):
        first = self.bundle("one", "i-one", 40, 2)
        failed = self.bundle("failed", "i-two", 60, 3, status="failed", exit_code=1, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(first, failed))
        self.assertEqual(code, 1)
        self.assertIn("does not prove completed", diagnostic)

        second = self.bundle("two", "i-two", 60, 3, offset=1000)
        changed_plan = self.plan()
        changed_plan["base_url"] = "https://changed.example"
        second[2].write_text(json.dumps(changed_plan), encoding="utf-8")
        code, _, diagnostic = self.invoke(*self.arguments(first, second))
        self.assertEqual(code, 1)
        self.assertIn("plan-manifest SHA-256", diagnostic)
        result_hash = self.bundle("result-hash", "i-two", 60, 3, offset=1000)
        result_hash[4].write_text(json.dumps({"run_id": "run-1", "k6_exit_code": 0, "status": "completed", "summary_present": False}), encoding="utf-8")
        code, _, diagnostic = self.invoke(*self.arguments(first, result_hash))
        self.assertEqual(code, 1)
        self.assertIn("execution-result SHA-256", diagnostic)

    def test_rejects_mixed_or_non_sold_out_plans_and_expected_stock_override(self):
        first = self.bundle("one", "i-one", 40, 2)
        mixed = self.bundle("mixed", "i-two", 60, 3, event=2, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(first, mixed))
        self.assertEqual(code, 1)
        self.assertIn("mixed canonical plan identities", diagnostic)

        normal = self.bundle("normal", "i-two", 60, 3, policy="normal", offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(first, normal))
        self.assertEqual(code, 1)
        self.assertIn("result_policy must be sold-out", diagnostic)

        valid = self.bundle("valid", "i-two", 60, 3, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(first, valid, expected_stock=99))
        self.assertEqual(code, 1)
        self.assertIn("expected-stock does not match", diagnostic)

    def test_rejects_plan_derived_stock_under_issue_and_over_issue(self):
        under_first = self.bundle("under-one", "i-one", 40, 2)
        under_second = self.bundle("under-two", "i-two", 59, 3, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(under_first, under_second))
        self.assertEqual(code, 1)
        self.assertIn("global under-issue", diagnostic)

        over_first = self.bundle("over-one", "i-one", 40, 2)
        over_second = self.bundle("over-two", "i-two", 61, 3, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(over_first, over_second))
        self.assertEqual(code, 1)
        self.assertIn("global over-issue", diagnostic)

        mismatched_first = self.bundle("mismatch-one", "i-one", 40, 2, stock=100)
        mismatched_second = self.bundle("mismatch-two", "i-two", 60, 3, stock=101, offset=1000)
        code, _, diagnostic = self.invoke(*self.arguments(mismatched_first, mismatched_second))
        self.assertEqual(code, 1)
        self.assertIn("mixed canonical plan identities", diagnostic)

    def test_rejects_two_versions_of_the_same_logical_generator_slot(self):
        first = self.bundle("one", "i-one", 40, 2)
        second = self.bundle("two", "i-one", 60, 3)
        code, _, diagnostic = self.invoke(*self.arguments(first, second))
        self.assertEqual(code, 1)
        self.assertIn("duplicate runtime generator identity", diagnostic)

    def test_requires_plan_and_result_in_every_binding(self):
        first = self.bundle("one", "i-one", 40, 2)
        second = self.bundle("two", "i-two", 60, 3, offset=1000)
        code, _, diagnostic = self.invoke(
            "--publication-manifest", "%s=%s" % (first[0], first[1]),
            "--publication-manifest", "%s=%s=%s=%s" % second[:4],
            str(first[0]), str(second[0]),
        )
        self.assertEqual(code, 1)
        self.assertIn("SUMMARY=MANIFEST=PLAN=RUNTIME=RESULT=PACKAGE=CONSOLE", diagnostic)


if __name__ == "__main__":
    unittest.main()
