from __future__ import annotations

import base64
import copy
import functools
import hashlib
import io
import json
import os
import pathlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import warnings
import zipfile
import zlib
from unittest import mock


SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import ios_screenshot_reuse as reuse


SOURCE = "a" * 40
CURRENT = "b" * 40
ARTIFACT_ID = 9901519893
RUN_ID = 33772861440
ATTEMPT = 1
XCODE = "Xcode 26.6\nBuild version 17F113"
RUNTIME = "iOS 26.5 23F77"
PINNED_WORKFLOW = """jobs:
  capture:
    steps:
      - name: Select pinned Xcode
        run: |
          set -euo pipefail
          test "$(xcodebuild -version)" = $'Xcode 26.6\\nBuild version 17F113'
      - name: Next step
        run: true
"""


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def png(width: int, height: int, marker: str, compressed_pixels: bytes, color_type: int = 2) -> bytes:
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
            + chunk(b"tEXt", f"fixture={marker}".encode()) + chunk(b"IDAT", compressed_pixels) + chunk(b"IEND", b""))


def blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


class FixtureGitHub(reuse.GitHub):
    def __init__(self, files: dict[str, bytes], *, schema: int = 2, workflow_id: int = 336812515):
        super().__init__(token="test-token-never-sent")
        self.files = copy.deepcopy(files)
        self.manifest = json.loads(self.files[reuse.MANIFEST])
        self.manifest["schemaVersion"] = schema
        path, job_name = reuse.WORKFLOWS[workflow_id]
        workflow_bytes = PINNED_WORKFLOW.encode()
        workflow_blob = blob_id(workflow_bytes)
        self.original_tree = [
            {"path": "README.md", "mode": "100644", "type": "blob", "sha": "1" * 40},
            {"path": "KitPay/App.swift", "mode": "100644", "type": "blob", "sha": "2" * 40},
            {"path": path, "mode": "100644", "type": "blob", "sha": workflow_blob},
        ]
        self.current_tree = copy.deepcopy(self.original_tree)
        self.current_tree[0]["sha"] = "3" * 40
        if schema == 2:
            self.manifest["captureEnvironment"] = {"xcodeVersion": XCODE, "runtime": RUNTIME}
            self.manifest["inputDigest"] = {"algorithm": reuse.DIGEST_ALGORITHM,
                                            "excludedPaths": list(reuse.EXCLUDED_PATHS),
                                            "sha256": reuse.tree_digest(self.original_tree)}
        self.metadata = {
            "id": ARTIFACT_ID, "name": f"kit-pay-app-store-screenshots-{SOURCE}-{RUN_ID}-{ATTEMPT}",
            "expired": False, "expires_at": "2999-10-03T15:58:48Z", "created_at": "2026-09-03T15:58:51Z",
            "workflow_run": {"id": RUN_ID, "repository_id": reuse.REPOSITORY_ID,
                             "head_repository_id": reuse.REPOSITORY_ID, "head_branch": "main", "head_sha": SOURCE},
        }
        self.run = {
            "id": RUN_ID, "run_attempt": ATTEMPT, "head_sha": SOURCE, "head_branch": "main",
            "event": "workflow_dispatch", "path": path, "workflow_id": workflow_id,
            "status": "completed", "conclusion": "success",
            "repository": {"id": reuse.REPOSITORY_ID, "full_name": reuse.REPOSITORY},
            "head_repository": {"id": reuse.REPOSITORY_ID, "full_name": reuse.REPOSITORY},
        }
        names = list(reuse.CAPTURE_STEPS) + (["Validate exact dispatched source"] if workflow_id == 341567650 else [
            "Recheck exact selected source", "Compile all native tests once", "Run native unit and UI checks from the same build",
        ])
        self.job = {
            "id": 100707229378, "name": job_name, "run_id": RUN_ID, "run_attempt": ATTEMPT,
            "head_sha": SOURCE, "head_branch": "main", "status": "completed", "conclusion": "success",
            "steps": [{"name": name, "status": "completed", "conclusion": "success"} for name in names],
        }
        self.responses = {
            f"/actions/artifacts/{ARTIFACT_ID}": self.metadata,
            f"/actions/runs/{RUN_ID}/attempts/{ATTEMPT}": self.run,
            f"/actions/runs/{RUN_ID}/attempts/{ATTEMPT}/jobs?per_page=100&page=1": {"jobs": [self.job]},
            "/actions/artifacts?per_page=100&page=1": {"artifacts": [self.metadata]},
            f"/git/commits/{SOURCE}": {"sha": SOURCE, "tree": {"sha": "c" * 40}},
            f"/git/commits/{CURRENT}": {"sha": CURRENT, "tree": {"sha": "d" * 40}},
            f"/git/trees/{'c' * 40}?recursive=1": {"sha": "c" * 40, "truncated": False, "tree": self.original_tree},
            f"/git/trees/{'d' * 40}?recursive=1": {"sha": "d" * 40, "truncated": False, "tree": self.current_tree},
            f"/git/blobs/{workflow_blob}": {"sha": workflow_blob, "encoding": "base64", "content": base64.b64encode(workflow_bytes).decode()},
        }
        self.downloads = []
        self.pack()

    def pack(self, *, extras: list[tuple[object, bytes]] = (), prefix: str = "") -> None:
        self.files[reuse.MANIFEST] = (json.dumps(self.manifest, indent=2) + "\n").encode()
        output = io.BytesIO()
        with warnings.catch_warnings(), zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            warnings.simplefilter("ignore", UserWarning)
            for name, data in self.files.items():
                archive.writestr(prefix + name, data)
            archive.writestr(prefix + "KitPay-iPhone.xcresult/Data/retained-test-result", b"native evidence")
            for name, data in extras:
                archive.writestr(name, data)
        self.zip_bytes = output.getvalue()
        self.metadata.update({"digest": "sha256:" + hashlib.sha256(self.zip_bytes).hexdigest(), "size_in_bytes": len(self.zip_bytes)})

    def api(self, endpoint: str) -> dict:
        return copy.deepcopy(self.responses[endpoint])

    def download(self, artifact_id: int, destination: pathlib.Path) -> None:
        self.downloads.append(artifact_id)
        destination.write_bytes(self.zip_bytes)


@functools.lru_cache(maxsize=1)
def validator_fixture() -> dict[str, bytes]:
    # Exercise the existing validator to produce the actual schema consumed by reuse.
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        for spec in reuse.DEVICE_SPECS:
            pixels = zlib.compress((b"\0" + b"\x20\x40\x60" * spec["width"]) * spec["height"])
            directory = root / spec["directory"] / reuse.LOCALE
            directory.mkdir(parents=True)
            for name in reuse.SCREENSHOT_NAMES:
                (directory / name).write_bytes(png(spec["width"], spec["height"], spec["directory"] + name, pixels))
        subprocess.run([sys.executable, str(SCRIPTS / "validate_app_store_screenshots.py"), "--root", str(root),
                        "--source-commit", SOURCE, "--locale", reuse.LOCALE, "--iphone-runtime", RUNTIME,
                        "--ipad-runtime", RUNTIME, "--manifest", str(root / reuse.MANIFEST)], check=True, capture_output=True)
        return {path.relative_to(root).as_posix(): path.read_bytes() for path in root.rglob("*") if path.is_file()}

class ScreenshotReuseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.files = validator_fixture()

    def selection(self, github: FixtureGitHub, *, source: str = SOURCE, candidate: str = str(ARTIFACT_ID),
                  xcode: str = XCODE, runtime: str = RUNTIME) -> tuple[dict, dict[str, bytes]]:
        with tempfile.TemporaryDirectory() as raw:
            destination = pathlib.Path(raw) / "screenshots"
            receipt = reuse.select_reuse(github, source, candidate, destination, xcode, runtime)
            files = {path.relative_to(destination).as_posix(): path.read_bytes()
                     for path in destination.rglob("*") if path.is_file()} if destination.exists() else {}
            return receipt, files

    def rejected(self, github: FixtureGitHub, **options) -> dict:
        receipt, files = self.selection(github, **options)
        self.assertFalse(receipt["reused"], receipt)
        self.assertEqual(files, {})
        return receipt

    def test_schema_two_reuse_preserves_original_manifest_bytes_and_capture(self) -> None:
        github = FixtureGitHub(self.files)
        receipt, files = self.selection(github, source=CURRENT)
        self.assertTrue(receipt["reused"], receipt)
        self.assertEqual(files, github.files)
        self.assertEqual(receipt["currentSourceCommit"], CURRENT)
        self.assertEqual(receipt["originalCapture"]["sourceCommit"], SOURCE)
        self.assertEqual(receipt["originalCapture"]["createdAt"], github.manifest["createdAt"])
        self.assertEqual(json.loads(files[reuse.MANIFEST])["sourceCommit"], SOURCE)
        self.assertEqual(receipt["originalCapture"]["captureJobId"], github.job["id"])

    def test_schema_one_requires_same_source_and_proven_exact_xcode(self) -> None:
        github = FixtureGitHub(self.files, schema=1, workflow_id=341567650)
        receipt, _ = self.selection(github)
        self.assertTrue(receipt["reused"], receipt)
        self.rejected(github, source=CURRENT)
        self.rejected(github, xcode="Xcode 26.6\nBuild version DIFFERENT")

    def test_archive_signing_failure_after_complete_capture_reuses_evidence(self) -> None:
        github = FixtureGitHub(self.files)
        self.assertEqual(github.job["name"], "Sign, verify, and retain App Store artifacts")
        github.run["conclusion"] = github.job["conclusion"] = "failure"
        github.job["steps"].append({"name": "Archive and export signed IPA", "status": "completed", "conclusion": "failure"})
        receipt, _ = self.selection(github)
        self.assertTrue(receipt["reused"], receipt)
        self.assertEqual(receipt["originalCapture"]["runConclusion"], "failure")

    def test_failed_legacy_run_cancelled_archive_or_unfinished_run_is_rejected(self) -> None:
        for workflow, status, conclusion in ((341567650, "completed", "failure"),
                                             (336812515, "completed", "cancelled"),
                                             (336812515, "in_progress", None),
                                             (336812515, "completed", "timed_out")):
            with self.subTest(workflow=workflow, status=status, conclusion=conclusion):
                github = FixtureGitHub(self.files, workflow_id=workflow)
                github.run.update(status=status, conclusion=conclusion)
                self.rejected(github)

    def test_every_native_capture_and_retention_step_must_succeed_even_after_signing_failure(self) -> None:
        for name in FixtureGitHub(self.files).job["steps"]:
            with self.subTest(step=name["name"]):
                github = FixtureGitHub(self.files)
                github.run["conclusion"] = github.job["conclusion"] = "failure"
                next(step for step in github.job["steps"] if step["name"] == name["name"])["conclusion"] = "skipped"
                self.rejected(github)

    def test_artifact_expiry_identity_size_and_digest_are_enforced(self) -> None:
        for field, value in (("id", 3), ("expired", True), ("expired", None), ("expires_at", "2020-01-01T00:00:00Z"),
                             ("expires_at", "2999-01-01"), ("expires_at", None), ("size_in_bytes", 0),
                             ("size_in_bytes", reuse.MAX_ZIP_BYTES + 1), ("digest", None), ("digest", "sha256:bad"),
                             ("name", f"kit-pay-app-store-screenshots-{SOURCE}-{RUN_ID}-2")):
            with self.subTest(field=field, value=value):
                github = FixtureGitHub(self.files)
                github.metadata[field] = value
                self.rejected(github)
                self.assertEqual(github.downloads, [])

    def test_repository_branch_workflow_run_attempt_and_job_identity_are_enforced(self) -> None:
        cases = (
            ("workflow_run", "repository_id", 1), ("workflow_run", "head_repository_id", 1),
            ("workflow_run", "head_branch", "feature"), ("workflow_run", "head_sha", CURRENT),
            ("run", "workflow_id", 1), ("run", "path", ".github/workflows/other.yml"),
            ("run", "event", "pull_request"), ("run", "run_attempt", 2), ("run", "run_attempt", True),
            ("job", "name", "archive"), ("job", "id", None), ("job", "id", True), ("job", "id", 0),
            ("job", "head_branch", "feature"), ("job", "head_sha", CURRENT), ("job", "run_attempt", 2),
            ("job", "conclusion", "cancelled"),
        )
        for target, field, value in cases:
            with self.subTest(target=target, field=field, value=value):
                github = FixtureGitHub(self.files)
                record = github.metadata["workflow_run"] if target == "workflow_run" else getattr(github, target)
                record[field] = value
                self.rejected(github)
        github = FixtureGitHub(self.files)
        github.run["head_repository"]["full_name"] = "fork/kit-pay-ios"
        self.rejected(github)

    def test_input_change_or_forged_manifest_digest_is_not_reused(self) -> None:
        github = FixtureGitHub(self.files)
        github.current_tree[1]["sha"] = "9" * 40
        self.rejected(github, source=CURRENT)
        self.assertEqual(github.downloads, [])
        github = FixtureGitHub(self.files)
        github.manifest["inputDigest"]["sha256"] = "9" * 64
        github.pack()
        self.rejected(github)

    def test_remote_tree_must_be_complete_and_workflow_blob_bytes_authentic(self) -> None:
        github = FixtureGitHub(self.files)
        github.responses[f"/git/trees/{'c' * 40}?recursive=1"]["truncated"] = True
        self.rejected(github)
        github = FixtureGitHub(self.files)
        next(value for key, value in github.responses.items() if key.startswith("/git/blobs/"))["content"] = base64.b64encode(b"changed").decode()
        self.rejected(github)

    def test_environment_requires_exact_xcode_and_runtime_build(self) -> None:
        for value in ("iOS 26.5", "iOS 26.5 23F81b", "iOS 26.4 23E214"):
            with self.subTest(runtime=value):
                self.rejected(FixtureGitHub(self.files), runtime=value)
        github = FixtureGitHub(self.files)
        github.manifest["captureEnvironment"]["xcodeVersion"] = "Xcode 26.6\nBuild version OTHER"
        github.pack()
        self.rejected(github)

    def test_downloaded_zip_size_and_sha256_must_match_metadata(self) -> None:
        for mutation in (lambda data: data + b"extra", lambda data: bytes([data[0] ^ 1]) + data[1:]):
            github = FixtureGitHub(self.files)
            github.zip_bytes = mutation(github.zip_bytes)
            self.rejected(github)

    def test_zip_rejects_traversal_duplicates_symlinks_ambiguous_roots_and_extra_pngs(self) -> None:
        symlink = zipfile.ZipInfo("KitPay-iPhone.xcresult/unsafe-link")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        cases = [
            ("../outside", b"bad"), ("/absolute", b"bad"), ("folder\\outside", b"bad"),
            (reuse.MANIFEST, b"duplicate"), ("another/" + reuse.MANIFEST, b"{}"),
            ("iphone-6.5/en-US/extra.png", b"bad"), ("KitPay-iPhone.xcresult/unexpected.png", b"bad"),
            (symlink, b"../../outside"), ("IPHONE-6.5/en-US/01-home.png", b"ambiguous case"),
        ]
        for extra in cases:
            with self.subTest(path=str(extra[0])):
                github = FixtureGitHub(self.files)
                github.pack(extras=[extra])
                self.rejected(github)

    def test_single_safe_zip_root_is_normalized_without_extracting_xcresult(self) -> None:
        github = FixtureGitHub(self.files)
        github.pack(prefix="build/app-store-screenshots/")
        receipt, files = self.selection(github)
        self.assertTrue(receipt["reused"], receipt)
        self.assertEqual(set(files), reuse.expected_files())

    def test_manifest_and_png_provenance_integrity_dimensions_alpha_and_uniqueness(self) -> None:
        for case in ("source", "locale", "missing set", "size", "hash", "dimensions", "alpha", "crc", "duplicate image"):
            with self.subTest(case=case):
                github = FixtureGitHub(self.files)
                manifest = github.manifest
                record = manifest["sets"][0]["screenshots"][0]
                path = f"iphone-6.5/en-US/{record['filename']}"
                if case == "source":
                    manifest["sourceCommit"] = CURRENT
                elif case == "locale":
                    manifest["locale"] = "fr-FR"
                elif case == "missing set":
                    manifest["sets"].pop()
                elif case == "size":
                    record["size"] += 1
                elif case == "hash":
                    record["sha256"] = "0" * 64
                else:
                    if case == "dimensions":
                        github.files[path] = png(1290, 2796, "wrong-size", zlib.compress(b"\0\0\0\0"))
                    elif case == "alpha":
                        github.files[path] = png(1284, 2778, "alpha", zlib.compress(b"\0\0\0\0\0"), color_type=6)
                    elif case == "crc":
                        github.files[path] = github.files[path][:-1] + bytes([github.files[path][-1] ^ 1])
                    elif case == "duplicate image":
                        github.files[path] = github.files["iphone-6.5/en-US/02-chats.png"]
                    record.update(size=len(github.files[path]), sha256=hashlib.sha256(github.files[path]).hexdigest())
                github.pack()
                self.rejected(github)

    def test_candidate_discovery_returns_newest_valid_evidence(self) -> None:
        github = FixtureGitHub(self.files)
        rejected_id = ARTIFACT_ID + 1
        newer = copy.deepcopy(github.metadata)
        newer.update(id=rejected_id, created_at="2026-09-04T00:00:00Z", expired=True)
        github.responses[f"/actions/artifacts/{rejected_id}"] = newer
        github.responses["/actions/artifacts?per_page=100&page=1"]["artifacts"].append(newer)
        receipt, _ = self.selection(github, candidate="")
        self.assertTrue(receipt["reused"], receipt)
        self.assertEqual(receipt["originalCapture"]["artifactId"], ARTIFACT_ID)
        self.assertEqual(receipt["rejections"][0]["artifactId"], rejected_id)
        self.assertEqual(github.downloads, [ARTIFACT_ID])

    def test_existing_destination_is_preserved_on_reuse_miss(self) -> None:
        github = FixtureGitHub(self.files)
        with tempfile.TemporaryDirectory() as raw:
            destination = pathlib.Path(raw)
            sentinel = destination / "existing.png"
            sentinel.write_bytes(b"existing evidence")
            receipt = reuse.select_reuse(github, SOURCE, str(ARTIFACT_ID), destination, XCODE, RUNTIME)
            self.assertFalse(receipt["reused"])
            self.assertEqual(sentinel.read_bytes(), b"existing evidence")
            self.assertEqual(github.downloads, [])

    def test_json_duplicate_keys_are_rejected(self) -> None:
        with self.assertRaises(reuse.EvidenceRejected):
            reuse.json_object(b'{"sourceCommit":"a", "sourceCommit":"b"}')

    def test_missing_reuse_is_a_normal_cli_result_with_receipt_and_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            result = subprocess.run([sys.executable, str(SCRIPTS / "ios_screenshot_reuse.py"), "reuse",
                                     "--source-sha", SOURCE, "--candidate-artifact-id", "invalid", "--destination", str(root / "screenshots"),
                                     "--xcode-version", XCODE, "--runtime", RUNTIME,
                                     "--receipt", str(root / "receipt.json"), "--github-output", str(root / "output")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "output").read_text(), "reused=false\n")
            receipt = json.loads((root / "receipt.json").read_text())
            self.assertFalse(receipt["reused"])
            self.assertIn("malformed", receipt["reason"])


class ScreenshotTreeDigestTests(unittest.TestCase):
    def test_only_three_regular_top_level_documentation_files_are_excluded(self) -> None:
        base = [{"path": "KitPay/App.swift", "mode": "100644", "type": "blob", "sha": "1" * 40}]
        baseline = reuse.tree_digest(base)
        for path in reuse.EXCLUDED_PATHS:
            entry = {"path": path, "mode": "100644", "type": "blob", "sha": "2" * 40}
            self.assertEqual(reuse.tree_digest(base + [entry]), baseline)
            for mode in ("100755", "120000"):
                self.assertNotEqual(reuse.tree_digest(base + [{**entry, "mode": mode}]), baseline)
        for path in ("CI_WORKFLOWS.md", "KitPay/README.md", "Podfile", "KitPay.xcodeproj/project.pbxproj",
                     ".github/scripts/collect_xcresult_screenshots.py", ".github/workflows/ios-app-store-archive.yml"):
            self.assertNotEqual(reuse.tree_digest(base + [{"path": path, "mode": "100644", "type": "blob", "sha": "2" * 40}]), baseline)

    def test_tree_order_is_irrelevant_but_modes_types_and_object_ids_are_inputs(self) -> None:
        entries = [{"path": "KitPay", "mode": "040000", "type": "tree", "sha": "1" * 40},
                   {"path": "KitPay/App.swift", "mode": "100644", "type": "blob", "sha": "2" * 40}]
        baseline = reuse.tree_digest(entries)
        self.assertEqual(baseline, reuse.tree_digest(list(reversed(entries))))
        entries[0]["sha"] = "3" * 40
        self.assertNotEqual(baseline, reuse.tree_digest(entries))


class PreparedNativeInputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.original_cwd = pathlib.Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.original_cwd)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.environment = mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.runner_temp)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        for path, content in {
            "KitPay/App.swift": "original app",
            "README.md": "original documentation",
            reuse.PREPARED_INPUTS[0]: "canonical project",
            reuse.PREPARED_INPUTS[1]: '{"pins":[]}',
            reuse.WORKFLOWS[336812515][0]: PINNED_WORKFLOW,
        }.items():
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        for arguments in (["init", "-q"], ["config", "user.email", "fixture@example.invalid"],
                          ["config", "user.name", "Fixture"], ["config", "core.filemode", "true"],
                          ["add", "."], ["commit", "-qm", "fixture"]):
            subprocess.run(["git", *arguments], check=True, capture_output=True)
        self.source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        self.baseline = reuse.local_tree_digest(self.source)

    def prepare(self) -> pathlib.Path:
        (self.root / reuse.PREPARED_INPUTS[0]).write_text("CocoaPods integrated project")
        (self.root / reuse.PREPARED_INPUTS[1]).write_text('{ "pins": [] }')
        receipt = {"sourceCommit": self.source, "generatedInputs": {
            path: hashlib.sha256((self.root / path).read_bytes()).hexdigest() for path in reuse.PREPARED_INPUTS
        }}
        path = self.runner_temp / "KitPay-prepared-native-inputs.json"
        path.write_text(json.dumps(receipt))
        return path

    def test_prepared_dependency_changes_preserve_canonical_git_digest(self) -> None:
        self.prepare()
        (self.root / "README.md").write_text("Updated documentation")
        self.assertEqual(reuse.local_tree_digest(self.source), self.baseline)

    def test_dirty_project_without_exact_preparation_receipt_is_rejected(self) -> None:
        receipt_path = self.prepare()
        receipt = json.loads(receipt_path.read_text())
        receipt["sourceCommit"] = "0" * 40
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(reuse.EvidenceRejected, "does not match"):
            reuse.local_tree_digest(self.source)
        receipt_path.unlink()
        with self.assertRaisesRegex(reuse.EvidenceRejected, "missing or unsafe"):
            reuse.local_tree_digest(self.source)

    def test_swift_changes_and_project_mutation_after_preparation_are_rejected(self) -> None:
        self.prepare()
        app = self.root / "KitPay/App.swift"
        app.write_text("later changed app")
        with self.assertRaisesRegex(reuse.EvidenceRejected, "Tracked screenshot inputs differ"):
            reuse.local_tree_digest(self.source)
        app.write_text("original app")
        (self.root / reuse.PREPARED_INPUTS[0]).write_text("later changed project")
        with self.assertRaisesRegex(reuse.EvidenceRejected, "changed after verified dependency preparation"):
            reuse.local_tree_digest(self.source)

    def test_documentation_symlink_or_mode_changes_are_not_exempt(self) -> None:
        documentation = self.root / "README.md"
        documentation.chmod(0o755)
        with self.assertRaisesRegex(reuse.EvidenceRejected, "Tracked screenshot inputs differ"):
            reuse.local_tree_digest(self.source)
        documentation.unlink()
        documentation.symlink_to("KitPay/App.swift")
        with self.assertRaisesRegex(reuse.EvidenceRejected, "Tracked screenshot inputs differ"):
            reuse.local_tree_digest(self.source)

    def test_prepared_file_mode_change_is_not_authorized_by_its_byte_hash(self) -> None:
        self.prepare()
        (self.root / reuse.PREPARED_INPUTS[0]).chmod(0o755)
        with self.assertRaisesRegex(reuse.EvidenceRejected, "regular tracked file"):
            reuse.local_tree_digest(self.source)

    def test_stamp_cli_keeps_capture_source_and_date_with_verified_prepared_inputs(self) -> None:
        self.prepare()
        captures = self.root / "captures"
        for path, data in validator_fixture().items():
            file = captures / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        manifest_path = captures / reuse.MANIFEST
        manifest = json.loads(manifest_path.read_text())
        manifest["sourceCommit"] = self.source
        manifest_path.write_text(json.dumps(manifest))
        result = subprocess.run([sys.executable, str(SCRIPTS / "ios_screenshot_reuse.py"), "stamp", "--source-sha", self.source,
                                 "--manifest", str(manifest_path), "--xcode-version", XCODE, "--runtime", RUNTIME], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        stamped = json.loads(manifest_path.read_text())
        self.assertEqual(stamped["schemaVersion"], 2)
        self.assertEqual(stamped["sourceCommit"], self.source)
        self.assertEqual(stamped["createdAt"], manifest["createdAt"])
        self.assertEqual(stamped["inputDigest"]["sha256"], self.baseline)
        self.assertEqual(stamped["captureEnvironment"], {"xcodeVersion": XCODE, "runtime": RUNTIME})


class DownloadCredentialTests(unittest.TestCase):
    class Response(io.BytesIO):
        def __init__(self, status: int, body: bytes = b"", headers: dict | None = None):
            super().__init__(body)
            self.status = status
            self.headers = headers or {}

    def test_authorization_never_follows_artifact_cdn_redirect(self) -> None:
        github = reuse.GitHub(token="private-test-token")
        github.opener = mock.Mock()
        github.opener.open.side_effect = [
            self.Response(302, headers={"Location": "https://productionresultssa.blob.core.windows.net/artifact?sig=private-url"}),
            self.Response(200, b"artifact zip"),
        ]
        with tempfile.TemporaryDirectory() as raw:
            github.download(ARTIFACT_ID, pathlib.Path(raw) / "artifact.zip")
        requests = [call.args[0] for call in github.opener.open.call_args_list]
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer private-test-token")
        self.assertIsNone(requests[1].get_header("Authorization"))

    def test_http_failure_does_not_disclose_signed_url_or_token(self) -> None:
        github = reuse.GitHub(token="private-test-token")
        github.opener = mock.Mock()
        github.opener.open.side_effect = urllib.error.HTTPError("https://example.com/?sig=private-url", 403, "private detail", {}, None)
        with self.assertRaises(reuse.EvidenceRejected) as caught:
            github.request("https://api.github.com/repos/example", authenticated=True)
        self.assertEqual(str(caught.exception), "GitHub evidence request failed with HTTP 403")

    def test_non_https_or_unapproved_redirect_hosts_are_rejected(self) -> None:
        for url in ("http://productionresultssa.blob.core.windows.net/a", "https://evil.example/a",
                    "https://token@productionresultssa.blob.core.windows.net/a"):
            github = reuse.GitHub(token="private-test-token")
            github.opener = mock.Mock()
            github.opener.open.return_value = self.Response(302, headers={"Location": url})
            with tempfile.TemporaryDirectory() as raw, self.assertRaises(reuse.EvidenceRejected):
                github.download(ARTIFACT_ID, pathlib.Path(raw) / "artifact.zip")
            self.assertEqual(github.opener.open.call_count, 1)


if __name__ == "__main__":
    unittest.main()
