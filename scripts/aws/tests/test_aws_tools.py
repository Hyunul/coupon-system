"""Offline regression contracts for AWS packaging and TTL cleanup tools."""
import gzip
import hashlib
import importlib.util
import io
import json
import os
import sys
import tarfile
import tempfile
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "scripts" / "aws" / "package_loadgen.py"
TTL = ROOT / "infra" / "aws" / "ttl_cleanup.py"


def load_module(name, path, boto3_client=None):
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = boto3_client or mock.Mock()
    previous = sys.modules.get("boto3")
    sys.modules["boto3"] = fake_boto3
    try:
        spec = importlib.util.spec_from_file_location(name, str(path))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if previous is None:
            del sys.modules["boto3"]
        else:
            sys.modules["boto3"] = previous


class PackageLoadgenContractTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_module("package_loadgen_contract", PACKAGE)
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for index, source in enumerate(self.tool.REQUIRED_SOURCES):
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("source-%d\n" % index).encode("ascii"))

    def tearDown(self):
        self.temp.cleanup()

    def run_main(self, *args):
        with mock.patch.object(sys, "argv", ["package_loadgen.py"] + list(args)):
            self.tool.main()

    def build_archive(self, output):
        self.run_main("--root", str(self.root), "--output", str(output))
        manifest = self.tool.make_manifest(self.tool.snapshots(self.root))
        self.tool.verify_archive(output, manifest)
        return manifest

    def write_archive(self, output, members):
        with open(output, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    for info, data in members:
                        archive.addfile(info, io.BytesIO(data) if info.isfile() else None)

    def archive_members(self, path):
        with gzip.open(path, "rb") as compressed:
            with tarfile.open(fileobj=compressed, mode="r:") as archive:
                return [
                    (self.tool.normalized_info(member.name, member.size), archive.extractfile(member).read())
                    for member in archive.getmembers()
                ]

    def test_archive_is_deterministic_and_has_exact_closure_and_manifest_hashes(self):
        first, second = self.root / "one.tgz", self.root / "two.tgz"
        first_manifest = self.build_archive(first)
        second_manifest = self.build_archive(second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(first_manifest, second_manifest)
        expected = [(source[len("k6/"):], (self.root / source).read_bytes()) for source in self.tool.REQUIRED_SOURCES]
        expected_manifest = self.tool.make_manifest(expected)
        with gzip.open(str(first), "rb") as compressed:
            with tarfile.open(fileobj=compressed, mode="r:") as archive:
                names = archive.getnames()
                self.assertEqual(names, ["coupon-loadtest/" + item[0] for item in expected] + ["coupon-loadtest/package-manifest.json"])
                manifest = archive.extractfile("coupon-loadtest/package-manifest.json").read()
                self.assertEqual(manifest, expected_manifest)
                entries = json.loads(manifest.decode("utf-8"))["files"]
                self.assertEqual([entry["path"] for entry in entries], names[:-1])
                for entry, (_, data) in zip(entries, expected):
                    self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
                    self.assertEqual(entry["bytes"], len(data))

    def test_verify_archive_rejects_mutated_payloads_and_member_closure(self):
        source = self.root / "valid.tgz"
        manifest = self.build_archive(source)
        members = self.archive_members(source)
        payload_index = 0
        manifest_index = len(members) - 1

        def with_manifest(document):
            encoded = json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
            mutated = list(members)
            mutated[manifest_index] = (self.tool.normalized_info("coupon-loadtest/package-manifest.json", len(encoded)), encoded)
            return mutated, encoded

        cases = {}
        changed_payload = list(members)
        info, data = changed_payload[payload_index]
        changed_payload[payload_index] = (info, b"X" + data[1:])
        cases["payload bytes"] = (changed_payload, manifest)

        document = json.loads(manifest.decode("utf-8"))
        document["files"][payload_index]["sha256"] = "0" * 64
        cases["payload hash"] = with_manifest(document)

        document = json.loads(manifest.decode("utf-8"))
        document["files"][payload_index]["bytes"] += 1
        cases["payload size"] = with_manifest(document)

        duplicate = list(members) + [(self.tool.normalized_info(members[payload_index][0].name, members[payload_index][0].size), members[payload_index][1])]
        cases["duplicate member"] = (duplicate, manifest)

        extra = list(members)
        extra.insert(manifest_index, (self.tool.normalized_info("coupon-loadtest/extra.txt", 1), b"x"))
        cases["extra member"] = (extra, manifest)

        cases["missing member"] = (members[1:], manifest)

        non_regular = list(members)
        link = tarfile.TarInfo(members[payload_index][0].name)
        link.type, link.linkname = tarfile.SYMTYPE, "lib/config.js"
        non_regular[payload_index] = (link, b"")
        cases["non-regular member"] = (non_regular, manifest)

        for name, (mutated_members, expected_manifest) in cases.items():
            with self.subTest(name=name):
                output = self.root / (name.replace(" ", "-") + ".tgz")
                self.write_archive(output, mutated_members)
                with self.assertRaises(RuntimeError):
                    self.tool.verify_archive(output, expected_manifest)

    def test_missing_required_source_fails_closed(self):
        (self.root / self.tool.REQUIRED_SOURCES[0]).unlink()
        with self.assertRaises(SystemExit) as error:
            self.tool.snapshots(self.root)
        self.assertIn(Path(self.tool.REQUIRED_SOURCES[0]).name, str(error.exception))

    def test_atomic_publish_never_replaces_existing_file_with_truncated_output(self):
        output = self.root / "artifact.tgz"
        output.write_bytes(b"known-good")
        def fail_after_partial_write(stream):
            stream.write(b"truncated")
            raise RuntimeError("writer failed")
        with self.assertRaisesRegex(RuntimeError, "writer failed"):
            self.tool.atomic_write(output, fail_after_partial_write)
        self.assertEqual(output.read_bytes(), b"known-good")
        self.assertEqual(list(output.parent.glob(".artifact.tgz.*")), [])
    def test_prepublication_verification_failure_preserves_existing_valid_output(self):
        output = self.root / "artifact.tgz"
        self.build_archive(output)
        existing = output.read_bytes()
        with mock.patch.object(self.tool, "verify_archive", side_effect=RuntimeError("verification failed")):
            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                self.run_main("--root", str(self.root), "--output", str(output))
        self.assertEqual(output.read_bytes(), existing)
        self.assertEqual(list(output.parent.glob(".artifact.tgz.*")), [])

    def test_embedded_manifest_hash_remains_bound_to_archive_after_source_mutation(self):
        archive = self.root / "artifact.tgz"
        archive_manifest = self.build_archive(archive)
        (self.root / self.tool.REQUIRED_SOURCES[0]).write_bytes(b"later source mutation\n")
        extracted_manifest = self.root / "extracted-manifest.json"
        self.run_main("--extract-manifest", str(archive), "--output", str(extracted_manifest))
        self.assertEqual(extracted_manifest.read_bytes(), archive_manifest)
        self.assertEqual(
            hashlib.sha256(extracted_manifest.read_bytes()).hexdigest(),
            hashlib.sha256(archive_manifest).hexdigest(),
        )
        self.assertNotEqual(archive_manifest, self.tool.make_manifest(self.tool.snapshots(self.root)))


class TtlCleanupContractTests(unittest.TestCase):
    def setUp(self):
        self.clients = {"ec2": mock.Mock(), "rds": mock.Mock()}
        self.client = mock.Mock(side_effect=lambda service: self.clients[service])
        self.tool = load_module("ttl_cleanup_contract", TTL, self.client)
        self.environ = {
            "PROJECT": "coupon-benchmark",
            "OWNER": "owner@example.test",
            "EXPIRES_AT": "2026-01-01T00:00:00Z",
            "ENABLE_RDS": "true",
        }

    def invoke_at(self, now):
        class FrozenDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                return now.astimezone(tz or timezone.utc)
        with mock.patch.dict(os.environ, self.environ, clear=True), mock.patch.object(self.tool, "datetime", FrozenDateTime):
            return self.tool.lambda_handler({}, None)

    def test_not_expired_creates_no_clients(self):
        result = self.invoke_at(datetime(2025, 12, 31, tzinfo=timezone.utc))
        self.assertEqual(result["status"], "not-expired")
        self.client.assert_not_called()

    def test_expiry_boundary_starts_cleanup(self):
        ec2 = self.clients["ec2"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": [{"Instances": [{"InstanceId": "i-boundary"}]}]}]
        self.clients["rds"].get_paginator.return_value.paginate.return_value = [{"DBInstances": []}]
        result = self.invoke_at(datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(result["status"], "expired")
        self.assertEqual(result["stopped_instance_ids"], ["i-boundary"])
        self.assertEqual(self.client.call_args_list, [mock.call("ec2"), mock.call("rds")])
        self.assertEqual(ec2.stop_instances.call_args_list, [mock.call(InstanceIds=["i-boundary"])])

    def test_tokyo_mode_never_creates_rds_client_and_uses_exact_ec2_tags(self):
        self.environ["ENABLE_RDS"] = "false"
        ec2 = self.clients["ec2"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": [{"Instances": [{"InstanceId": "i-1"}]}]}]
        result = self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        self.assertEqual(result["stopped_instance_ids"], ["i-1"])
        self.assertEqual(result["stopped_databases"], [])
        self.assertEqual(self.client.call_args_list, [mock.call("ec2")])
        self.assertEqual(ec2.get_paginator.return_value.paginate.call_args.kwargs["Filters"], [
            {"Name": "tag:Project", "Values": [self.environ["PROJECT"]]},
            {"Name": "tag:ExpiresAt", "Values": [self.environ["EXPIRES_AT"]]},
            {"Name": "tag:Owner", "Values": [self.environ["OWNER"]]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ])

    def test_paginates_ec2_and_rds_and_stops_only_exactly_tagged_available_database(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.return_value = [
            {"Reservations": [{"Instances": [{"InstanceId": "i-one"}]}]},
            {"Reservations": [{"Instances": [{"InstanceId": "i-two"}]}]},
        ]
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [
            {"DBInstanceIdentifier": "db-good", "DBInstanceArn": "arn:good", "DBInstanceStatus": "available"},
            {"DBInstanceIdentifier": "db-wrong-owner", "DBInstanceArn": "arn:wrong", "DBInstanceStatus": "available"},
        ]}]
        rds.list_tags_for_resource.side_effect = [
            {"TagList": [{"Key": "Project", "Value": self.environ["PROJECT"]}, {"Key": "Owner", "Value": self.environ["OWNER"]}, {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]}]},
            {"TagList": [{"Key": "Project", "Value": self.environ["PROJECT"]}, {"Key": "Owner", "Value": "other"}, {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]}]},
        ]
        result = self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        self.assertEqual(result["stopped_instance_ids"], ["i-one", "i-two"])
        self.assertEqual(result["stopped_databases"], ["db-good"])
        self.assertEqual(ec2.stop_instances.call_args_list, [mock.call(InstanceIds=["i-one"]), mock.call(InstanceIds=["i-two"])])
        rds.stop_db_instance.assert_called_once_with(DBInstanceIdentifier="db-good")

    def test_ec2_paginator_failure_still_continues_rds_cleanup(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.side_effect = RuntimeError("ec2 pagination unavailable")
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [
            {"DBInstanceIdentifier": "db-good", "DBInstanceArn": "arn:good", "DBInstanceStatus": "available"},
        ]}]
        rds.list_tags_for_resource.return_value = {"TagList": [
            {"Key": "Project", "Value": self.environ["PROJECT"]},
            {"Key": "Owner", "Value": self.environ["OWNER"]},
            {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]},
        ]}
        with self.assertRaisesRegex(RuntimeError, '"scope": "ec2-discovery"'):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        rds.stop_db_instance.assert_called_once_with(DBInstanceIdentifier="db-good")

    def test_rds_stop_failure_does_not_block_later_database(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": []}]
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [
            {"DBInstanceIdentifier": "db-bad", "DBInstanceArn": "arn:bad", "DBInstanceStatus": "available"},
            {"DBInstanceIdentifier": "db-good", "DBInstanceArn": "arn:good", "DBInstanceStatus": "available"},
        ]}]
        rds.list_tags_for_resource.return_value = {"TagList": [
            {"Key": "Project", "Value": self.environ["PROJECT"]},
            {"Key": "Owner", "Value": self.environ["OWNER"]},
            {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]},
        ]}
        rds.stop_db_instance.side_effect = [RuntimeError("db-bad stop failed"), None]
        with self.assertRaisesRegex(RuntimeError, '"scope": "rds-stop"') as error:
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        self.assertIn("db-bad", str(error.exception))
        self.assertEqual(rds.stop_db_instance.call_args_list, [
            mock.call(DBInstanceIdentifier="db-bad"),
            mock.call(DBInstanceIdentifier="db-good"),
        ])
    def test_invalid_enable_rds_fails_before_creating_clients(self):
        self.environ["ENABLE_RDS"] = "TRUE"
        with self.assertRaisesRegex(ValueError, "ENABLE_RDS"):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        self.client.assert_not_called()

    def test_ec2_client_failure_still_attempts_rds_cleanup(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        self.client.side_effect = [RuntimeError("ec2 client unavailable"), rds]
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [
            {"DBInstanceIdentifier": "db-good", "DBInstanceArn": "arn:good", "DBInstanceStatus": "available"},
        ]}]
        rds.list_tags_for_resource.return_value = {"TagList": [
            {"Key": "Project", "Value": self.environ["PROJECT"]},
            {"Key": "Owner", "Value": self.environ["OWNER"]},
            {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]},
        ]}
        with self.assertRaisesRegex(RuntimeError, '"scope": "ec2-client"'):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        ec2.assert_not_called()
        rds.stop_db_instance.assert_called_once_with(DBInstanceIdentifier="db-good")

    def test_rds_client_failure_after_ec2_cleanup_is_aggregated(self):
        ec2 = self.clients["ec2"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": [
            {"Instances": [{"InstanceId": "i-good"}]},
        ]}]
        self.client.side_effect = [ec2, RuntimeError("rds client unavailable")]
        with self.assertRaisesRegex(RuntimeError, '"scope": "rds-client"'):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        ec2.stop_instances.assert_called_once_with(InstanceIds=["i-good"])

    def test_rds_discovery_failure_after_ec2_cleanup_is_aggregated(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": [
            {"Instances": [{"InstanceId": "i-good"}]},
        ]}]
        rds.get_paginator.return_value.paginate.side_effect = RuntimeError("rds discovery unavailable")
        with self.assertRaisesRegex(RuntimeError, '"scope": "rds-discovery"'):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        ec2.stop_instances.assert_called_once_with(InstanceIds=["i-good"])

    def test_rds_resource_failure_does_not_block_later_database(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": []}]
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [
            {"DBInstanceIdentifier": "db-bad", "DBInstanceArn": "arn:bad", "DBInstanceStatus": "available"},
            {"DBInstanceIdentifier": "db-good", "DBInstanceArn": "arn:good", "DBInstanceStatus": "available"},
        ]}]
        rds.list_tags_for_resource.side_effect = [
            RuntimeError("db-bad tags unavailable"),
            {"TagList": [
                {"Key": "Project", "Value": self.environ["PROJECT"]},
                {"Key": "Owner", "Value": self.environ["OWNER"]},
                {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]},
            ]},
        ]
        with self.assertRaisesRegex(RuntimeError, '"resource": "db-bad"'):
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        rds.stop_db_instance.assert_called_once_with(DBInstanceIdentifier="db-good")
    def test_ec2_partial_failure_still_attempts_all_resources_and_rds_then_raises_aggregated_evidence(self):
        ec2, rds = self.clients["ec2"], self.clients["rds"]
        ec2.get_paginator.return_value.paginate.return_value = [{"Reservations": [{"Instances": [{"InstanceId": "i-bad"}, {"InstanceId": "i-good"}]}]}]
        ec2.stop_instances.side_effect = [RuntimeError("ec2 unavailable"), None]
        rds.get_paginator.return_value.paginate.return_value = [{"DBInstances": [{"DBInstanceIdentifier": "db-one", "DBInstanceArn": "arn:db", "DBInstanceStatus": "available"}]}]
        rds.list_tags_for_resource.return_value = {"TagList": [{"Key": "Project", "Value": self.environ["PROJECT"]}, {"Key": "Owner", "Value": self.environ["OWNER"]}, {"Key": "ExpiresAt", "Value": self.environ["EXPIRES_AT"]}]}
        with self.assertRaisesRegex(RuntimeError, '"scope": "ec2-stop"') as error:
            self.invoke_at(datetime(2026, 1, 2, tzinfo=timezone.utc))
        self.assertIn("i-bad", str(error.exception))
        self.assertEqual(ec2.stop_instances.call_args_list, [
            mock.call(InstanceIds=["i-bad"]),
            mock.call(InstanceIds=["i-good"]),
        ])
        rds.stop_db_instance.assert_called_once_with(DBInstanceIdentifier="db-one")


if __name__ == "__main__":
    unittest.main()
