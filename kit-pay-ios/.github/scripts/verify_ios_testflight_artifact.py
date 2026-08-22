#!/usr/bin/env python3
"""Verify an archived iOS artifact before any TestFlight authentication."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import zipfile


SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
RUN_ID_PATTERN = re.compile(r"[1-9][0-9]{0,19}")
RUN_ATTEMPT_PATTERN = re.compile(r"[1-9][0-9]{0,9}")
EXPECTED_FILES = {
    "KitPay.ipa",
    "KitPay.xcarchive.zip",
    "KitPay.dSYMs.zip",
    "KitPay-archive-evidence.json",
}
ARTIFACT_FILES = {
    "ipa": "KitPay.ipa",
    "xcarchive": "KitPay.xcarchive.zip",
    "dsyms": "KitPay.dSYMs.zip",
}


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def digest(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def require_dictionary(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-directory", type=pathlib.Path, required=True)
    parser.add_argument("--archive-run-id", required=True)
    parser.add_argument("--archive-run-attempt", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--ipa-sha-output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    if not RUN_ID_PATTERN.fullmatch(args.archive_run_id):
        fail("The archive run ID is malformed")
    if not RUN_ATTEMPT_PATTERN.fullmatch(args.archive_run_attempt):
        fail("The archive run attempt is malformed")
    if not SHA_PATTERN.fullmatch(args.source_commit):
        fail("The source commit must be a full lowercase Git SHA")

    root = args.artifact_directory
    if not root.is_dir() or root.is_symlink():
        fail("The downloaded archive artifact directory is invalid")
    entries = list(root.iterdir())
    if {entry.name for entry in entries} != EXPECTED_FILES or len(entries) != len(EXPECTED_FILES):
        fail("The archive artifact must contain exactly the four expected files")
    for entry in entries:
        if not entry.is_file() or entry.is_symlink():
            fail(f"The archive artifact contains an invalid entry: {entry.name}")

    evidence_path = root / "KitPay-archive-evidence.json"
    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"Archive evidence could not be decoded: {error}")
    evidence = require_dictionary(evidence, "Archive evidence")
    target = require_dictionary(evidence.get("target"), "Archive evidence target")
    workflow = require_dictionary(evidence.get("workflow"), "Archive evidence workflow")
    artifacts = require_dictionary(evidence.get("artifacts"), "Archive evidence artifacts")

    checks = (
        (type(evidence.get("schemaVersion")) is int and evidence["schemaVersion"] == 1,
         "Unexpected archive evidence schema"),
        (evidence.get("evidenceType") == "github-actions-ios-app-store-archive",
         "Unexpected archive evidence type"),
        (evidence.get("sourceCommit") == args.source_commit,
         "Archive evidence source commit does not match protected main"),
        (target.get("bundleId") == args.bundle_id, "Archive evidence bundle identifier is incorrect"),
        (target.get("version") == args.version, "Archive evidence version is incorrect"),
        (target.get("buildNumber") == args.build_number, "Archive evidence build number is incorrect"),
        (workflow.get("runId") == args.archive_run_id, "Archive evidence run ID is incorrect"),
        (workflow.get("runAttempt") == args.archive_run_attempt,
         "Archive evidence run attempt is incorrect"),
    )
    for passed, message in checks:
        if not passed:
            fail(message)

    for artifact_key, filename in ARTIFACT_FILES.items():
        record = require_dictionary(artifacts.get(artifact_key), f"Evidence for {artifact_key}")
        path = root / filename
        expected_sha = record.get("sha256")
        expected_size = record.get("size")
        if record.get("filename") != filename:
            fail(f"Evidence filename for {artifact_key} is incorrect")
        if not isinstance(expected_sha, str) or not SHA256_PATTERN.fullmatch(expected_sha):
            fail(f"Evidence SHA-256 for {artifact_key} is malformed")
        if type(expected_size) is not int or expected_size <= 0:
            fail(f"Evidence size for {artifact_key} is malformed")
        if path.stat().st_size != expected_size or digest(path) != expected_sha:
            fail(f"Downloaded {filename} does not match its archive evidence")

    ipa_path = root / "KitPay.ipa"
    try:
        with zipfile.ZipFile(ipa_path) as ipa:
            info_entries = [
                entry
                for entry in ipa.infolist()
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", entry.filename)
            ]
            if len(info_entries) != 1 or info_entries[0].file_size > 1024 * 1024:
                fail("The IPA must contain exactly one bounded app Info.plist")
            info = plistlib.loads(ipa.read(info_entries[0]))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        fail(f"The IPA identity could not be decoded: {error}")
    if not isinstance(info, dict):
        fail("The IPA app Info.plist is not a dictionary")
    identity_checks = (
        (info.get("CFBundleIdentifier") == args.bundle_id, "The IPA bundle identifier is incorrect"),
        (info.get("CFBundleShortVersionString") == args.version, "The IPA version is incorrect"),
        (info.get("CFBundleVersion") == args.build_number, "The IPA build number is incorrect"),
    )
    for passed, message in identity_checks:
        if not passed:
            fail(message)

    if args.ipa_sha_output.exists() or args.ipa_sha_output.is_symlink():
        fail("Refusing to overwrite the IPA SHA-256 output")
    args.ipa_sha_output.write_text(artifacts["ipa"]["sha256"] + "\n", encoding="ascii")
    args.ipa_sha_output.chmod(0o600)


if __name__ == "__main__":
    main()
