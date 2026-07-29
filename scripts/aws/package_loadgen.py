"""Build a reproducible, self-verifying load-generator tarball."""

import argparse
import gzip
import hashlib
import io
import json
import os
import tarfile
import tempfile
from pathlib import Path

REQUIRED_SOURCES = (
    "k6/lib/config.js",
    "k6/lib/aws-claim.js",
    "k6/scenarios/aws-capacity.js",
    "k6/scenarios/aws-worker-recovery.js",
    "k6/scenarios/aws-generator-calibration.js",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_info(name: str, size: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size, info.mode, info.mtime = size, 0o644, 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def snapshots(root: Path):
    missing = [str(root / source) for source in REQUIRED_SOURCES if not (root / source).is_file()]
    if missing:
        raise SystemExit("Missing required load-generator source files: " + ", ".join(missing))
    result = []
    for source in REQUIRED_SOURCES:
        data = (root / source).read_bytes()
        result.append((source[len("k6/") :], data))
    return result


def make_manifest(files):
    entries = [
        {"path": f"coupon-loadtest/{path}", "sha256": sha256(data), "bytes": len(data)}
        for path, data in files
    ]
    return json.dumps(
        {"schema_version": 1, "files": entries}, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"


def manifest_entries(manifest: bytes):
    try:
        document = json.loads(manifest.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError("Package manifest is not valid UTF-8 JSON") from error
    canonical = json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    if manifest != canonical:
        raise RuntimeError("Package manifest is not canonically encoded")
    if not isinstance(document, dict) or set(document) != {"schema_version", "files"} or document["schema_version"] != 1 or not isinstance(document["files"], list):
        raise RuntimeError("Package manifest has an unsupported schema")
    entries = {}
    for entry in document["files"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "bytes"}:
            raise RuntimeError("Package manifest contains an invalid file entry")
        name, digest, size = entry["path"], entry["sha256"], entry["bytes"]
        if (
            not isinstance(name, str)
            or not name.startswith("coupon-loadtest/")
            or any(part in {"", ".", ".."} for part in name.split("/"))
            or name == "coupon-loadtest/package-manifest.json"
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or name in entries
        ):
            raise RuntimeError("Package manifest contains an unsafe or duplicate file entry")
        entries[name] = (digest, size)
    return entries


def verify_archive(path: Path, manifest: bytes) -> None:
    expected_payloads = manifest_entries(manifest)
    expected_members = set(expected_payloads) | {"coupon-loadtest/package-manifest.json"}
    with gzip.open(path, "rb") as compressed:
        with tarfile.open(fileobj=compressed, mode="r:") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            if len(names) != len(set(names)):
                raise RuntimeError("Published archive contains duplicate member names")
            if set(names) != expected_members:
                raise RuntimeError("Published archive member set does not match its manifest")
            if any(not member.isfile() for member in members):
                raise RuntimeError("Published archive contains a non-regular payload")
            archive_manifest = archive.extractfile("coupon-loadtest/package-manifest.json")
            if archive_manifest is None or archive_manifest.read() != manifest:
                raise RuntimeError("Published archive manifest does not match the source snapshot")
            for name, (expected_digest, expected_size) in expected_payloads.items():
                member = archive.getmember(name)
                payload = archive.extractfile(member)
                if payload is None:
                    raise RuntimeError(f"Published archive payload is unreadable: {name}")
                data = payload.read()
                if member.size != expected_size or len(data) != expected_size or sha256(data) != expected_digest:
                    raise RuntimeError(f"Published archive payload does not match its manifest: {name}")


def atomic_write(path: Path, writer, verifier=None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            writer(output)
            output.flush()
            os.fsync(output.fileno())
        if verifier is not None:
            verifier(Path(temporary))
        os.replace(temporary, path)
    except BaseException as primary:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        except OSError as cleanup_error:
            message = f"Could not remove temporary package file {temporary}; it was retained: {cleanup_error}"
            if hasattr(primary, "add_note"):
                primary.add_note(message)
            else:
                primary.args = (*primary.args, message)
        raise


def embedded_manifest(path: Path) -> bytes:
    with gzip.open(path, "rb") as compressed:
        with tarfile.open(fileobj=compressed, mode="r:") as archive:
            members = [member for member in archive.getmembers() if member.name == "coupon-loadtest/package-manifest.json"]
            if len(members) != 1 or not members[0].isfile():
                raise RuntimeError("Published archive does not contain exactly one regular package manifest")
            manifest_file = archive.extractfile(members[0])
            if manifest_file is None:
                raise RuntimeError("Published archive manifest is unreadable")
            return manifest_file.read()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--manifest-only", action="store_true", help="Atomically write only package-manifest.json metadata.")
    mode.add_argument("--extract-manifest", type=Path, metavar="ARCHIVE", help="Verify an archive and atomically write its embedded package-manifest.json.")
    args = parser.parse_args()

    if args.extract_manifest is not None:
        if args.root is not None:
            parser.error("--root cannot be used with --extract-manifest")
        manifest = embedded_manifest(args.extract_manifest)
        verify_archive(args.extract_manifest, manifest)
        atomic_write(args.output, lambda output: output.write(manifest))
        return
    if args.root is None:
        parser.error("--root is required unless --extract-manifest is used")

    files = snapshots(args.root.resolve())
    manifest = make_manifest(files)
    if args.manifest_only:
        atomic_write(args.output, lambda output: output.write(manifest))
        return

    def write_archive(raw):
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for path, data in files:
                    archive.addfile(normalized_info(f"coupon-loadtest/{path}", len(data)), io.BytesIO(data))
                archive.addfile(normalized_info("coupon-loadtest/package-manifest.json", len(manifest)), io.BytesIO(manifest))

    atomic_write(args.output, write_archive, lambda temporary: verify_archive(temporary, manifest))


if __name__ == "__main__":
    main()
