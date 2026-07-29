"""Offline contracts for build-api-fault-evidence.py."""

import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "build-api-fault-evidence.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("api_fault_evidence_contract", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_inputs():
    return {
        "stop_receipt": {
            "run_id": "api-fault-1", "event_id": 1, "target_instance_id": "i-api",
            "action": "stop", "command_id": "stop-1", "status": "Success",
            "submitted_at": "2026-07-28T00:01:00Z", "completed_at": "2026-07-28T00:02:00Z",
            "service": "coupon-api-reactive",
        },
        "start_receipt": {
            "run_id": "api-fault-1", "event_id": 1, "target_instance_id": "i-api",
            "action": "start", "command_id": "start-1", "status": "Success",
            "submitted_at": "2026-07-28T00:03:00Z", "completed_at": "2026-07-28T00:04:00Z",
            "service": "coupon-api-reactive",
        },
        "timeline": {
            "run_id": "api-fault-1", "event_id": 1, "load_started_at": "2026-07-28T00:00:00Z",
            "stop_submitted_at": "2026-07-28T00:01:00Z", "stop_completed_at": "2026-07-28T00:02:00Z",
            "start_submitted_at": "2026-07-28T00:03:00Z", "start_completed_at": "2026-07-28T00:04:00Z",
            "recovery_completed_at": "2026-07-28T00:05:00Z",
        },
        "alb": {
            "run_id": "api-fault-1", "event_id": 1, "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z", "target_instance_id": "i-api",
            "transitions": [
                {"state": "healthy", "observed_at": "2026-07-28T00:02:00Z"},
                {"state": "draining", "observed_at": "2026-07-28T00:03:00Z"},
                {"state": "healthy", "observed_at": "2026-07-28T00:04:00Z"},
            ],
        },
        "api": {
            "run_id": "api-fault-1", "event_id": 1, "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z", "successful_requests": 1,
            "transport_failures": 1, "transport_failure_limit": 1, "unexpected_responses": 0,
            "duplicate_issues": 0, "over_issued": 0,
        },
        "mysql": {
            "run_id": "api-fault-1", "event_id": 1, "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z", "over_issued": 0, "duplicate_issues": 0,
        },
    }


class ApiFaultEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_tool()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def files(self, inputs=None):
        paths = {}
        for name, payload in (inputs or valid_inputs()).items():
            path = self.root / (name + ".json")
            path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
            paths[name] = path
        return paths

    def invoke(self, paths, output=None):
        output = output or self.root / "api-fault-evidence.json"
        arguments = []
        for name in self.tool.INPUT_SCHEMAS:
            arguments.extend(("--" + name.replace("_", "-"), str(paths[name])))
        arguments.extend(("--output", str(output)))
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                self.tool.main(arguments)
                code = 0
            except SystemExit as error:
                code = error.code
        return code, stderr.getvalue(), output

    def assert_rejected(self, inputs, message):
        code, diagnostic, _ = self.invoke(self.files(inputs))
        self.assertEqual(code, 1)
        self.assertIn(message, diagnostic)

    def test_emits_canonical_manifest_with_input_hashes(self):
        paths = self.files()
        code, diagnostic, output = self.invoke(paths)
        self.assertEqual(code, 0)
        self.assertEqual(diagnostic, "")
        manifest = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(output.read_text(encoding="utf-8"), json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        self.assertEqual(set(manifest["inputs"]), set(valid_inputs()))
        self.assertEqual(
            manifest["api_fault"]["bindings"],
            {
                "run_id": "api-fault-1",
                "event_id": 1,
                "target_instance_id": "i-api",
                "service": "coupon-api-reactive",
            },
        )
        self.assertEqual(manifest["api_fault"]["stop"]["action"], "stop")
        self.assertEqual(manifest["api_fault"]["start"]["action"], "start")
        for name, path in paths.items():
            self.assertEqual(manifest["inputs"][name]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(manifest["inputs"][name]["bytes"], path.stat().st_size)

    def test_rejects_missing_and_extra_fields(self):
        inputs = valid_inputs()
        del inputs["api"]["successful_requests"]
        self.assert_rejected(inputs, "api has missing successful_requests")
        inputs = valid_inputs()
        inputs["mysql"]["unexpected"] = 0
        self.assert_rejected(inputs, "mysql has extra unexpected")

    def test_rejects_invalid_command_and_timeline_ordering(self):
        inputs = valid_inputs()
        inputs["start_receipt"]["command_id"] = "stop-1"
        self.assert_rejected(inputs, "command IDs must differ")
        inputs = valid_inputs()
        inputs["timeline"]["start_submitted_at"] = "2026-07-28T00:01:30Z"
        self.assert_rejected(inputs, "timeline timestamps are not ordered")
    def test_rejects_mixed_run_and_event_bindings(self):
        inputs = valid_inputs()
        inputs["api"]["run_id"] = "other-run"
        self.assert_rejected(inputs, "api.run_id does not match timeline.run_id")
        inputs = valid_inputs()
        inputs["mysql"]["event_id"] = 2
        self.assert_rejected(inputs, "mysql.event_id does not match timeline.event_id")

    def test_rejects_invalid_actions_and_receipt_bindings(self):
        inputs = valid_inputs()
        inputs["stop_receipt"]["action"] = "start"
        self.assert_rejected(inputs, "actions must be exact stop and start")
        inputs = valid_inputs()
        del inputs["start_receipt"]["action"]
        self.assert_rejected(inputs, "start_receipt has missing action")
        inputs = valid_inputs()
        inputs["start_receipt"]["target_instance_id"] = "i-other"
        self.assert_rejected(inputs, "target instance IDs must match")
        inputs = valid_inputs()
        inputs["start_receipt"]["service"] = "coupon-api-other"
        self.assert_rejected(inputs, "must identify the same API service")
        inputs = valid_inputs()
        inputs["stop_receipt"]["service"] = inputs["start_receipt"]["service"] = "coupon-worker-stream"
        self.assert_rejected(inputs, "must be an approved API service identity")

    def test_rejects_boolean_and_nonpositive_event_ids(self):
        for name, event_id in zip(valid_inputs(), (True, 0, -1, True, 0, -1)):
            inputs = valid_inputs()
            inputs[name]["event_id"] = event_id
            self.assert_rejected(inputs, "%s.event_id must be a positive integer" % name)

    def test_rejects_unbounded_alb_observations_and_snapshot_before_recovered_health(self):
        inputs = valid_inputs()
        inputs["alb"]["target_instance_id"] = "i-other"
        self.assert_rejected(inputs, "must match the selected API instance")
        inputs = valid_inputs()
        inputs["alb"]["transitions"] = inputs["alb"]["transitions"][:2]
        self.assert_rejected(inputs, "healthy, away, and healthy")
        inputs = valid_inputs()
        inputs["alb"]["transitions"][2]["state"] = "unhealthy"
        self.assert_rejected(inputs, "move away from healthy and recover to healthy")
        inputs = valid_inputs()
        inputs["alb"]["transitions"][0]["observed_at"] = "2026-07-27T23:59:59Z"
        self.assert_rejected(inputs, "outside the active load/fault/recovery timeline")
        inputs = valid_inputs()
        inputs["alb"]["transitions"][2]["observed_at"] = "2026-07-28T00:05:01Z"
        self.assert_rejected(inputs, "outside the active load/fault/recovery timeline")
        inputs = valid_inputs()
        inputs["alb"]["captured_at"] = "2026-07-28T00:04:00Z"
        self.assert_rejected(inputs, "must follow recovered health")

    def test_rejects_reconciliation_failures_and_unbounded_transport_failures(self):
        inputs = valid_inputs()
        inputs["api"]["duplicate_issues"] = 1
        self.assert_rejected(inputs, "api reconciliation failed")
        inputs = valid_inputs()
        inputs["api"]["unexpected_responses"] = 1
        self.assert_rejected(inputs, "api reconciliation failed")
        inputs = valid_inputs()
        inputs["api"]["transport_failures"] = 2
        self.assert_rejected(inputs, "exceeds transport_failure_limit")
        inputs = valid_inputs()
        inputs["mysql"]["over_issued"] = 1
        self.assert_rejected(inputs, "mysql.over_issued must be zero")

    def test_rejects_duplicate_json_keys_and_input_aliases(self):
        paths = self.files()
        paths["start_receipt"] = paths["stop_receipt"]
        code, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("duplicate input file", diagnostic)
        paths = self.files()
        paths["api"].write_text(
            '{"run_id":"api-fault-1","run_id":"other"}',
            encoding="utf-8",
        )
        code, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("duplicate key", diagnostic)
        try:
            alias = self.root / "start-receipt-hard-link.json"
            os.link(paths["stop_receipt"], alias)
        except OSError:
            self.skipTest("hard links are unavailable")
        paths["start_receipt"] = alias
        code, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("duplicate input file", diagnostic)
        if hasattr(os, "symlink"):
            paths = self.files()
            link = self.root / "api-link.json"
            try:
                link.symlink_to(paths["api"])
            except OSError:
                self.skipTest("symlinks are unavailable")
            paths["api"] = link
            code, diagnostic, _ = self.invoke(paths)
            self.assertEqual(code, 1)
            self.assertIn("api input must not be a symlink", diagnostic)

    def test_rejects_existing_symlink_and_hard_link_output(self):
        paths = self.files()
        output = self.root / "existing.json"
        output.write_text("existing", encoding="utf-8")
        code, diagnostic, _ = self.invoke(paths, output)
        self.assertEqual(code, 1)
        self.assertIn("output already exists", diagnostic)
        code, diagnostic, _ = self.invoke(paths, paths["api"])
        self.assertEqual(code, 1)
        self.assertIn("output must not overwrite an input", diagnostic)
        try:
            alias = self.root / "api-output-hard-link.json"
            os.link(paths["api"], alias)
        except OSError:
            self.skipTest("hard links are unavailable")
        code, diagnostic, _ = self.invoke(paths, alias)
        self.assertEqual(code, 1)
        self.assertIn("output must not overwrite an input", diagnostic)
        if hasattr(os, "symlink"):
            target = self.root / "output-target.json"
            link = self.root / "output-link.json"
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest("symlinks are unavailable")
            code, diagnostic, _ = self.invoke(paths, link)
            self.assertEqual(code, 1)
            self.assertIn("output must not be a symlink", diagnostic)


if __name__ == "__main__":
    unittest.main()
