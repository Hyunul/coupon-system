"""Offline contracts for build-recovery-evidence.py."""

import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "build-recovery-evidence.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("recovery_evidence_contract", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_inputs():
    return {
        "stop_receipt": {
            "run_id": "recovery-1",
            "event_id": 1,
            "target_instance_id": "i-recovery",
            "action": "stop",
            "command_id": "stop-1",
            "status": "Success",
            "submitted_at": "2026-07-28T00:01:00Z",
            "completed_at": "2026-07-28T00:02:00Z",
            "service": "coupon-worker-stream",
        },
        "start_receipt": {
            "run_id": "recovery-1",
            "event_id": 1,
            "target_instance_id": "i-recovery",
            "action": "start",
            "command_id": "start-1",
            "status": "Success",
            "submitted_at": "2026-07-28T00:03:00Z",
            "completed_at": "2026-07-28T00:04:00Z",
            "service": "coupon-worker-stream",
        },
        "timeline": {
            "run_id": "recovery-1",
            "event_id": 1,
            "load_started_at": "2026-07-28T00:00:00Z",
            "stop_submitted_at": "2026-07-28T00:01:00Z",
            "stop_completed_at": "2026-07-28T00:02:00Z",
            "start_submitted_at": "2026-07-28T00:03:00Z",
            "start_completed_at": "2026-07-28T00:04:00Z",
            "recovery_completed_at": "2026-07-28T00:05:00Z",
        },
        "redis": {
            "run_id": "recovery-1",
            "event_id": 1,
            "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z",
            "pending_before_stop": 0,
            "pending_after_stop": 4,
            "reclaimed": 4,
            "pending_after_drain": 0,
            "drained_at": "2026-07-28T00:05:00Z",
        },
        "mysql": {
            "run_id": "recovery-1",
            "event_id": 1,
            "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z",
            "over_issued": 0,
            "duplicate_issues": 0,
        },
        "api": {
            "run_id": "recovery-1",
            "event_id": 1,
            "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z",
            "successful_requests": 1,
            "transport_failures": 0,
            "unexpected_responses": 0,
            "duplicate_issues": 0,
            "over_issued": 0,
        },
        "notification": {
            "run_id": "recovery-1",
            "event_id": 1,
            "status": "PASS",
            "captured_at": "2026-07-28T00:05:00Z",
            "completed": True,
            "pending": 0,
            "failed": 0,
        },
    }


class RecoveryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_tool()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def files(self, inputs=None):
        paths = {}
        for name, payload in (valid_inputs() if inputs is None else inputs).items():
            path = self.root / (name + ".json")
            path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
            paths[name] = path
        return paths

    def invoke(self, paths, output=None):
        output = output or self.root / "recovery-evidence.json"
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
        return code, stdout.getvalue(), stderr.getvalue(), output

    def test_rejects_missing_receipt(self):
        paths = self.files()
        paths["stop_receipt"].unlink()
        code, _, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("stop_receipt input must be a regular file", diagnostic)

    def test_rejects_invalid_and_unreconciled_evidence(self):
        inputs = valid_inputs()
        inputs["timeline"]["start_completed_at"] = "2026-07-28T00:04:00+00:00"
        code, _, diagnostic, _ = self.invoke(self.files(inputs))
        self.assertEqual(code, 1)
        self.assertIn("UTC Z timestamp", diagnostic)

        inputs = valid_inputs()
        inputs["redis"]["pending_after_drain"] = 1
        code, _, diagnostic, _ = self.invoke(self.files(inputs))
        self.assertEqual(code, 1)
        self.assertIn("redis reclaim/drain reconciliation failed", diagnostic)
    def test_rejects_mixed_bindings_and_stale_recovery_snapshots(self):
        for name, field, value, diagnostic in (
            ("api", "run_id", "other-run", "run_id does not match"),
            ("mysql", "event_id", 2, "event_id does not match"),
            ("start_receipt", "target_instance_id", "i-other", "target instance IDs must match"),
            ("start_receipt", "action", "stop", "actions must be exact stop and start"),
            ("redis", "drained_at", "2026-07-28T00:05:01Z", "drained_at follows redis.captured_at"),
            ("redis", "drained_at", "2026-07-28T00:03:59Z", "outside the recovery window"),
            ("mysql", "captured_at", "2026-07-28T00:04:59Z", "mysql.captured_at precedes recovery completion"),
            ("api", "captured_at", "2026-07-28T00:04:59Z", "api.captured_at precedes recovery completion"),
            ("notification", "captured_at", "2026-07-28T00:04:59Z", "notification.captured_at precedes recovery completion"),
            ("stop_receipt", "completed_at", "2026-07-28T00:02:01Z", "timeline stop timestamps do not match stop receipt"),
            ("start_receipt", "submitted_at", "2026-07-28T00:03:01Z", "timeline start timestamps do not match start receipt"),
        ):
            with self.subTest(name=name, field=field):
                inputs = valid_inputs()
                inputs[name][field] = value
                code, _, message, _ = self.invoke(self.files(inputs))
                self.assertEqual(code, 1)
                self.assertIn(diagnostic, message)


    def test_rejects_duplicate_and_extra_input_fields(self):
        paths = self.files()
        paths["start_receipt"] = paths["stop_receipt"]
        code, _, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("duplicate input file", diagnostic)

        inputs = valid_inputs()
        inputs["api"]["unexpected"] = 0
        code, _, diagnostic, _ = self.invoke(self.files(inputs))
        self.assertEqual(code, 1)
        self.assertIn("api has extra unexpected", diagnostic)

    def test_rejects_receipt_timeline_identity_and_output_aliases(self):
        inputs = valid_inputs()
        inputs["start_receipt"]["command_id"] = inputs["stop_receipt"]["command_id"]
        code, _, diagnostic, _ = self.invoke(self.files(inputs))
        self.assertEqual(code, 1)
        self.assertIn("command IDs must differ", diagnostic)

        paths = self.files()
        output = paths["api"]
        original_bytes = output.read_bytes()
        code, _, diagnostic, _ = self.invoke(paths, output=output)
        self.assertEqual(code, 1)
        self.assertIn("output must not overwrite an input", diagnostic)
        self.assertEqual(output.read_bytes(), original_bytes)
    def test_rejects_worker_identity_event_counter_and_duplicate_key_contracts(self):
        for name, event_id in zip(valid_inputs(), (True, 0, -1, True, 0, -1, True)):
            with self.subTest(name=name, event_id=event_id):
                inputs = valid_inputs()
                inputs[name]["event_id"] = event_id
                code, _, diagnostic, _ = self.invoke(self.files(inputs))
                self.assertEqual(code, 1)
                self.assertIn("%s.event_id must be a positive integer" % name, diagnostic)

        for name, service, diagnostic in (
            ("start_receipt", "coupon-worker-other", "must identify the same worker service"),
            ("stop_receipt", "coupon-api-reactive", "approved worker service identity"),
        ):
            with self.subTest(name=name, service=service):
                inputs = valid_inputs()
                inputs[name]["service"] = service
                if name == "stop_receipt":
                    inputs["start_receipt"]["service"] = service
                code, _, message, _ = self.invoke(self.files(inputs))
                self.assertEqual(code, 1)
                self.assertIn(diagnostic, message)

        for field in ("transport_failures", "unexpected_responses"):
            with self.subTest(field=field):
                inputs = valid_inputs()
                inputs["api"][field] = 1
                code, _, diagnostic, _ = self.invoke(self.files(inputs))
                self.assertEqual(code, 1)
                self.assertIn("api transport/unexpected counters must be zero", diagnostic)

        paths = self.files()
        paths["api"].write_text(
            '{"run_id":"recovery-1","run_id":"other"}',
            encoding="utf-8",
        )
        code, _, diagnostic, _ = self.invoke(paths)
        self.assertEqual(code, 1)
        self.assertIn("duplicate key", diagnostic)

    def test_rejects_hard_link_output_alias(self):
        paths = self.files()
        output = self.root / "api-alias.json"
        try:
            os.link(paths["api"], output)
        except OSError:
            self.skipTest("hard links are unavailable")
        code, _, diagnostic, _ = self.invoke(paths, output=output)
        self.assertEqual(code, 1)
        self.assertIn("output must not overwrite an input", diagnostic)

    def test_emits_canonical_manifest_with_every_input_hash(self):
        paths = self.files()
        code, output, diagnostic, destination = self.invoke(paths)
        self.assertEqual(code, 0)
        self.assertEqual(output, "")
        self.assertEqual(diagnostic, "")
        manifest = json.loads(destination.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(destination.read_text(encoding="utf-8"), json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        self.assertEqual(set(manifest["inputs"]), set(valid_inputs()))
        for name, path in paths.items():
            self.assertEqual(manifest["inputs"][name]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(manifest["inputs"][name]["bytes"], path.stat().st_size)
        self.assertEqual(
            manifest["recovery"]["bindings"],
            {
                "run_id": "recovery-1",
                "event_id": 1,
                "target_instance_id": "i-recovery",
                "service": "coupon-worker-stream",
            },
        )
        self.assertEqual(manifest["recovery"]["stop"]["action"], "stop")
        self.assertEqual(manifest["recovery"]["start"]["action"], "start")


if __name__ == "__main__":
    unittest.main()
