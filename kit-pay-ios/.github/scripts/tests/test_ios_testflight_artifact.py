from __future__ import annotations

import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[3]
VERIFY = ROOT / ".github/scripts/verify_ios_testflight_artifact.py"
SOURCE_SHA = "a" * 40
RUN_ID = "123456789"
RUN_ATTEMPT = "2"
BUNDLE = "africa.kit.pay.ios"
VERSION = "1.2.3"
BUILD = "42"


def artifact_record(path: pathlib.Path) -> dict[str, object]:
    return {
        "filename": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": path.stat().st_size,
    }


def create_artifact(root: pathlib.Path) -> None:
    info = plistlib.dumps(
        {
            "CFBundleIdentifier": BUNDLE,
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": BUILD,
        }
    )
    ipa = root / "KitPay.ipa"
    with zipfile.ZipFile(ipa, "w") as archive:
        archive.writestr("Payload/KitPay.app/Info.plist", info)
    archive_zip = root / "KitPay.xcarchive.zip"
    archive_zip.write_bytes(b"signed archive")
    dsyms = root / "KitPay.dSYMs.zip"
    dsyms.write_bytes(b"debug symbols")
    evidence = {
        "schemaVersion": 1,
        "evidenceType": "github-actions-ios-app-store-archive",
        "sourceCommit": SOURCE_SHA,
        "target": {"bundleId": BUNDLE, "version": VERSION, "buildNumber": BUILD},
        "workflow": {"runId": RUN_ID, "runAttempt": RUN_ATTEMPT},
        "artifacts": {
            "ipa": artifact_record(ipa),
            "xcarchive": artifact_record(archive_zip),
            "dsyms": artifact_record(dsyms),
        },
    }
    (root / "KitPay-archive-evidence.json").write_text(
        json.dumps(evidence),
        encoding="utf-8",
    )


def command(root: pathlib.Path, output: pathlib.Path) -> list[str]:
    return [
        "python3",
        str(VERIFY),
        "--artifact-directory",
        str(root),
        "--archive-run-id",
        RUN_ID,
        "--archive-run-attempt",
        RUN_ATTEMPT,
        "--source-commit",
        SOURCE_SHA,
        "--bundle-id",
        BUNDLE,
        "--version",
        VERSION,
        "--build-number",
        BUILD,
        "--ipa-sha-output",
        str(output),
    ]


class VerifyIOSTestFlightArtifactTests(unittest.TestCase):
    def test_accepts_exact_archive_capsule_and_records_ipa_hash(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            create_artifact(root)
            output = root / "ipa-sha"
            subprocess.run(command(root, output), check=True, capture_output=True, text=True)
            self.assertEqual(
                output.read_text(encoding="ascii").strip(),
                hashlib.sha256((root / "KitPay.ipa").read_bytes()).hexdigest(),
            )

    def test_rejects_wrong_source_version_and_changed_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            create_artifact(root)

            wrong_source = command(root, root / "source-sha")
            wrong_source[wrong_source.index(SOURCE_SHA)] = "b" * 40
            result = subprocess.run(wrong_source, check=False, capture_output=True, text=True)
            self.assertIn("source commit", result.stderr)

            wrong_version = command(root, root / "version-sha")
            wrong_version[wrong_version.index(VERSION)] = "9.9.9"
            result = subprocess.run(wrong_version, check=False, capture_output=True, text=True)
            self.assertIn("version", result.stderr)

            (root / "KitPay.ipa").write_bytes(b"changed IPA")
            result = subprocess.run(
                command(root, root / "changed-sha"),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertIn("does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
