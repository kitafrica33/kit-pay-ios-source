#!/usr/bin/env python3
"""Reuse verified screenshot evidence without changing its capture provenance."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from validate_app_store_screenshots import DEVICE_SPECS, SCREENSHOT_NAMES, validate_png


REPOSITORY = "kitafrica33/kit-pay-ios"
REPOSITORY_ID = 1337983268
WORKFLOWS = {
    341567650: (".github/workflows/ios-app-store-screenshots.yml", "capture"),
    336812515: (".github/workflows/ios-app-store-archive.yml", "Sign, verify, and retain App Store artifacts"),
}
MANIFEST = "KitPay-App-Store-screenshots.json"
LOCALE = "en-US"
EXCLUDED_PATHS = ("LOCAL_FIRST_MEDIA.md", "PARITY.md", "README.md")
PREPARED_INPUTS = ("KitPay.xcodeproj/project.pbxproj", "KitPay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
DIGEST_ALGORITHM = "sha256-git-tree-v1"
SHA = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
ARTIFACT_NAME = re.compile(r"kit-pay-app-store-screenshots-([0-9a-f]{40})-([1-9][0-9]*)-([1-9][0-9]*)")
MAX_ZIP_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_PNG_BYTES = 64 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_ZIP_ENTRIES = 20000
CAPTURE_STEPS = (
    "Select pinned Xcode",
    "Require exact App Store device classes",
    "Capture iPhone 6.5-inch screenshots",
    "Capture iPad 13-inch screenshots",
    "Export, normalize, and validate screenshots",
    "Retain screenshots and test evidence",
)


class EvidenceRejected(Exception):
    """A cache miss with a safe, credential-free explanation."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise EvidenceRejected(reason)


def positive_integer(value: object) -> bool:
    return type(value) is int and value > 0


def valid_sha(value: object) -> bool:
    return isinstance(value, str) and SHA.fullmatch(value) is not None


def json_object(data: bytes) -> dict:
    def pairs(items: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in items:
            require(key not in result, "JSON contains duplicate keys")
            result[key] = value
        return result

    def reject_constant(_: str) -> None:
        raise EvidenceRejected("JSON contains a non-finite number")

    try:
        result = json.loads(data, object_pairs_hook=pairs, parse_constant=reject_constant)
    except (ValueError, UnicodeError) as error:
        raise EvidenceRejected("Evidence is not valid JSON") from error
    require(isinstance(result, dict), "Expected a JSON object")
    return result


def checked_path(value: object) -> str:
    require(isinstance(value, str) and bool(value), "Evidence path is missing")
    require("\\" not in value and ":" not in value and not any(ord(c) < 32 for c in value), "Unsafe evidence path")
    parts = value.split("/")
    require(all(part not in ("", ".", "..") for part in parts), "Unsafe evidence path")
    return value


def tree_digest(entries: list[dict]) -> str:
    """Hash every tracked entry, including directory and submodule object IDs."""
    require(isinstance(entries, list) and bool(entries), "Git tree is empty or malformed")
    records = []
    seen = set()
    for entry in entries:
        require(isinstance(entry, dict), "Git tree entry is malformed")
        path = checked_path(entry.get("path"))
        require(path not in seen, "Git tree contains duplicate paths")
        seen.add(path)
        mode, kind, object_id = entry.get("mode"), entry.get("type"), entry.get("sha")
        require((mode, kind) in {
            ("040000", "tree"), ("100644", "blob"), ("100755", "blob"),
            ("120000", "blob"), ("160000", "commit"),
        } and valid_sha(object_id), "Git tree entry has an invalid identity")
        if path not in EXCLUDED_PATHS or (mode, kind) != ("100644", "blob"):
            records.append([path, mode, kind, object_id])
    payload = json.dumps(sorted(records), ensure_ascii=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def local_tree_digest(source_sha: str) -> str:
    require(valid_sha(source_sha), "Source must be a full lowercase Git SHA")
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL).decode().strip()
        require(head == source_sha, "Capture source does not match the checked-out commit")
        raw = subprocess.check_output(["git", "ls-tree", "-rzt", source_sha], stderr=subprocess.DEVNULL)
        differences = subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-only", "-z", source_sha, "--", "."], stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise EvidenceRejected("Cannot read the immutable capture Git tree") from error
    entries = []
    for item in raw.split(b"\0"):
        if item:
            metadata, path = item.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            entries.append({"path": path.decode("utf-8"), "mode": mode, "type": kind, "sha": object_id})
    changed = {checked_path(path.decode("utf-8")) for path in differences.split(b"\0") if path}
    tracked = {entry["path"]: entry for entry in entries}

    def regular_tracked_file(path: str) -> bool:
        entry = tracked.get(path, {})
        file = pathlib.Path(path)
        return (entry.get("mode") == "100644" and entry.get("type") == "blob" and file.is_file()
                and not any(part.is_symlink() for part in (file, *file.parents))
                and not file.stat().st_mode & 0o111)

    ignored_docs = {path for path in EXCLUDED_PATHS if regular_tracked_file(path)}
    require(changed <= set(PREPARED_INPUTS) | ignored_docs, "Tracked screenshot inputs differ from the capture commit")
    if changed & set(PREPARED_INPUTS):
        runner_temp = os.environ.get("RUNNER_TEMP")
        require(bool(runner_temp), "Prepared native input receipt is unavailable")
        receipt_path = pathlib.Path(runner_temp) / "KitPay-prepared-native-inputs.json"
        require(receipt_path.is_file() and not receipt_path.is_symlink() and receipt_path.stat().st_size <= MAX_MANIFEST_BYTES,
                "Prepared native input receipt is missing or unsafe")
        receipt = json_object(receipt_path.read_bytes())
        generated = receipt.get("generatedInputs")
        require(receipt.get("sourceCommit") == source_sha and isinstance(generated, dict) and set(generated) == set(PREPARED_INPUTS),
                "Prepared native input receipt does not match the capture source")
        for path in PREPARED_INPUTS:
            require(regular_tracked_file(path), "Prepared native input is no longer a regular tracked file")
            require(isinstance(generated[path], str) and SHA256.fullmatch(generated[path]) is not None
                    and hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() == generated[path],
                    "Native project inputs changed after verified dependency preparation")
    return tree_digest(entries)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class GitHub:
    def __init__(self, token: str | None = None):
        self.token = token or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        self.opener = urllib.request.build_opener(NoRedirect())
        self.trees: dict[str, list[dict]] = {}

    def request(self, url: str, *, authenticated: bool):
        headers = {"User-Agent": "KitPay-screenshot-evidence", "Accept": "application/vnd.github+json"}
        if authenticated:
            require(urllib.parse.urlsplit(url).netloc == "api.github.com", "Refusing authorization outside GitHub API")
            headers["X-GitHub-Api-Version"] = "2022-11-28"
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
        try:
            return self.opener.open(urllib.request.Request(url, headers=headers), timeout=60)
        except urllib.error.HTTPError as response:
            if response.code in (301, 302, 303, 307, 308):
                return response
            raise EvidenceRejected(f"GitHub evidence request failed with HTTP {response.code}") from None
        except (OSError, urllib.error.URLError):
            raise EvidenceRejected("GitHub evidence request was unavailable") from None

    def api(self, endpoint: str) -> dict:
        require(endpoint.startswith("/") and not endpoint.startswith("//"), "Invalid GitHub API endpoint")
        with self.request(f"https://api.github.com/repos/{REPOSITORY}{endpoint}", authenticated=True) as response:
            require(response.status == 200, "GitHub metadata redirected unexpectedly")
            data = response.read(32 * 1024 * 1024 + 1)
        require(len(data) <= 32 * 1024 * 1024, "GitHub metadata is too large")
        return json_object(data)

    def pages(self, endpoint: str, key: str, *, max_pages: int = 20) -> list[dict]:
        items = []
        for page in range(1, max_pages + 1):
            batch = self.api(f"{endpoint}{'&' if '?' in endpoint else '?'}per_page=100&page={page}").get(key)
            require(isinstance(batch, list) and all(isinstance(item, dict) for item in batch), "GitHub list is malformed")
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise EvidenceRejected("GitHub evidence search exceeded its bounded page limit")

    def tree(self, source_sha: str) -> list[dict]:
        require(valid_sha(source_sha), "Git source identity is malformed")
        if source_sha not in self.trees:
            commit = self.api(f"/git/commits/{source_sha}")
            require(commit.get("sha") == source_sha, "GitHub commit identity does not match")
            tree_sha = commit.get("tree", {}).get("sha")
            require(valid_sha(tree_sha), "GitHub commit has no immutable tree")
            tree = self.api(f"/git/trees/{tree_sha}?recursive=1")
            require(tree.get("sha") == tree_sha and tree.get("truncated") is False, "GitHub tree is incomplete")
            entries = tree.get("tree")
            tree_digest(entries)
            self.trees[source_sha] = entries
        return self.trees[source_sha]

    def workflow_source(self, source_sha: str, path: str) -> str:
        entries = [entry for entry in self.tree(source_sha) if entry["path"] == path and entry["type"] == "blob"]
        require(len(entries) == 1, "Origin workflow is absent from its source tree")
        blob = self.api(f"/git/blobs/{entries[0]['sha']}")
        require(blob.get("sha") == entries[0]["sha"] and blob.get("encoding") == "base64", "Origin workflow blob identity is invalid")
        try:
            data = base64.b64decode("".join(blob["content"].split()), validate=True)
            require(len(data) <= MAX_MANIFEST_BYTES, "Origin workflow is too large")
            git_id = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
            require(git_id == entries[0]["sha"], "Origin workflow bytes do not match their Git object")
            return data.decode("utf-8")
        except (ValueError, KeyError, UnicodeError):
            raise EvidenceRejected("Origin workflow content is malformed") from None

    def download(self, artifact_id: int, destination: pathlib.Path) -> None:
        url = f"https://api.github.com/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"
        for attempt in range(4):
            with self.request(url, authenticated=attempt == 0) as response:
                if response.status in (301, 302, 303, 307, 308):
                    url = response.headers.get("Location", "")
                    parsed = urllib.parse.urlsplit(url)
                    host = parsed.hostname or ""
                    require(parsed.scheme == "https" and not parsed.username and not parsed.password
                            and (host.endswith(".blob.core.windows.net") or host.endswith(".githubusercontent.com")),
                            "Artifact redirect is not an approved HTTPS download host")
                    continue
                require(response.status == 200, "Artifact download did not succeed")
                size = 0
                with destination.open("xb") as target:
                    while chunk := response.read(1024 * 1024):
                        size += len(chunk)
                        require(size <= MAX_ZIP_BYTES, "Artifact download exceeds its size limit")
                        target.write(chunk)
                return
        raise EvidenceRejected("Artifact download exceeded its redirect limit")


def verify_origin(github: GitHub, metadata: dict, artifact_id: int) -> dict:
    require(positive_integer(artifact_id) and positive_integer(metadata.get("id")) and metadata["id"] == artifact_id, "Artifact ID does not match")
    match = ARTIFACT_NAME.fullmatch(str(metadata.get("name", "")))
    require(match is not None, "Artifact name does not identify screenshot provenance")
    source_sha, run_id_text, attempt_text = match.groups()
    run_id, attempt = int(run_id_text), int(attempt_text)
    size = metadata.get("size_in_bytes")
    require(metadata.get("expired") is False and positive_integer(size) and size <= MAX_ZIP_BYTES, "Artifact is empty, expired, or oversized")
    try:
        expires = dt.datetime.fromisoformat(metadata["expires_at"].replace("Z", "+00:00"))
        require(expires.utcoffset() is not None and expires > dt.datetime.now(dt.timezone.utc), "Artifact retention has expired")
    except (KeyError, ValueError, TypeError, AttributeError):
        raise EvidenceRejected("Artifact expiry is missing or malformed") from None
    digest = metadata.get("digest")
    require(isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is not None, "Artifact has no valid SHA256 digest")
    workflow_run = metadata.get("workflow_run")
    require(isinstance(workflow_run, dict), "Artifact lacks workflow identity")
    require(all(type(workflow_run.get(key)) is type(value) and workflow_run[key] == value for key, value in {
        "id": run_id, "repository_id": REPOSITORY_ID, "head_repository_id": REPOSITORY_ID,
        "head_branch": "main", "head_sha": source_sha,
    }.items()), "Artifact came from a different repository, branch, source, or run")
    run = github.api(f"/actions/runs/{run_id}/attempts/{attempt}")
    workflow_id = run.get("workflow_id")
    require(type(workflow_id) is int and workflow_id in WORKFLOWS, "Origin workflow is not approved for screenshots")
    path, job_name = WORKFLOWS[workflow_id]
    legacy_capture = workflow_id == 341567650
    allowed_conclusions = ("success",) if legacy_capture else ("success", "failure")
    require(all(type(run.get(key)) is type(value) and run[key] == value for key, value in {
        "id": run_id, "run_attempt": attempt, "head_sha": source_sha, "head_branch": "main",
        "event": "workflow_dispatch", "path": path, "status": "completed",
    }.items()) and run.get("conclusion") in allowed_conclusions, "Origin workflow run or attempt was not a completed main capture")
    for field in ("repository", "head_repository"):
        repository = run.get(field)
        require(isinstance(repository, dict) and repository.get("id") == REPOSITORY_ID
                and repository.get("full_name") == REPOSITORY, "Origin workflow repository does not match")
    jobs = github.pages(f"/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
    capture_jobs = [job for job in jobs if job.get("name") == job_name]
    require(len(capture_jobs) == 1, "Origin capture job is absent or ambiguous")
    job = capture_jobs[0]
    require(positive_integer(job.get("id")), "Origin capture job ID is invalid")
    require(all(type(job.get(key)) is type(value) and job[key] == value for key, value in {
        "run_id": run_id, "run_attempt": attempt, "head_sha": source_sha, "head_branch": "main",
        "status": "completed",
    }.items()) and job.get("conclusion") in allowed_conclusions, "Origin capture job did not finish for the exact source")
    steps = job.get("steps")
    require(isinstance(steps, list) and all(isinstance(step, dict) for step in steps), "Origin capture steps are missing")
    required = CAPTURE_STEPS + (("Validate exact dispatched source",) if legacy_capture else (
        "Recheck exact selected source", "Compile all native tests once", "Run native unit and UI checks from the same build",
    ))
    for name in required:
        found = [step for step in steps if step.get("name") == name]
        require(len(found) == 1 and found[0].get("status") == "completed" and found[0].get("conclusion") == "success",
                f"Origin step did not succeed: {name}")
    return {"sourceCommit": source_sha, "artifactId": artifact_id, "artifactSha256": digest[7:],
            "artifactSize": size, "runId": run_id, "runAttempt": attempt, "workflowId": workflow_id, "workflowPath": path,
            "runConclusion": run["conclusion"], "captureJobId": job["id"], "captureJobConclusion": job["conclusion"],
            "verifiedSuccessfulSteps": list(required)}


def verify_xcode_pin(source: str, xcode_version: str) -> None:
    require(re.fullmatch(r"Xcode [0-9]+(?:\.[0-9]+)*\nBuild version [A-Za-z0-9]+", xcode_version) is not None,
            "Xcode identity must include its exact build version")
    lines = source.splitlines()
    locations = [i for i, line in enumerate(lines) if line.strip() == "- name: Select pinned Xcode"]
    require(len(locations) == 1, "Origin workflow Xcode selection is absent or ambiguous")
    start = locations[0]
    indent = len(lines[start]) - len(lines[start].lstrip())
    body = []
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        body.append(line.strip())
    escaped = xcode_version.replace("\n", r"\n")
    require(f'test "$(xcodebuild -version)" = $\'{escaped}\'' in body,
            "Origin workflow does not prove the requested exact Xcode version")


def expected_files() -> set[str]:
    return {MANIFEST} | {f"{spec['directory']}/{LOCALE}/{name}" for spec in DEVICE_SPECS for name in SCREENSHOT_NAMES}


def extract_screenshots(archive_path: pathlib.Path, destination: pathlib.Path) -> None:
    """Validate every ZIP member; extract only the manifest and exact PNG sets."""
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        require(0 < len(infos) <= MAX_ZIP_ENTRIES, "Artifact has an invalid number of ZIP entries")
        members = {}
        folded = set()
        total = 0
        for info in infos:
            require(info.orig_filename == info.filename, "Artifact contains a truncated ZIP path")
            name = checked_path(info.filename[:-1] if info.is_dir() else info.filename)
            require(name not in members and name.casefold() not in folded, "Artifact contains duplicate or ambiguous ZIP paths")
            members[name] = info
            folded.add(name.casefold())
            mode = info.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG), "Artifact contains a symlink or special file")
            require(not info.flag_bits & 1 and info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "Artifact uses unsupported ZIP encoding")
            total += info.file_size
            require(total <= MAX_EXPANDED_BYTES, "Expanded artifact exceeds its size limit")
        manifests = [name for name, info in members.items() if not info.is_dir() and pathlib.PurePosixPath(name).name == MANIFEST]
        require(len(manifests) == 1, "Artifact manifest is absent or ambiguous")
        prefix = manifests[0][:-len(MANIFEST)]
        wanted = expected_files()
        selected = {}
        for name, info in members.items():
            if info.is_dir():
                continue
            require(name.startswith(prefix), "Artifact contains files outside its screenshot root")
            relative = name[len(prefix):]
            if relative in wanted:
                limit = MAX_MANIFEST_BYTES if relative == MANIFEST else MAX_PNG_BYTES
                require(0 < info.file_size <= limit, "Screenshot evidence file is empty or oversized")
                selected[relative] = info
            else:
                require(relative.startswith(("KitPay-iPhone.xcresult/", "KitPay-iPad.xcresult/"))
                        and not relative.lower().endswith(".png"), "Artifact contains unexpected screenshot files")
        require(set(selected) == wanted, "Artifact does not contain the exact screenshot file set")
        for relative, info in selected.items():
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open("xb") as output:
                data = source.read(info.file_size + 1)
                require(len(data) == info.file_size, "Screenshot ZIP member size does not match")
                output.write(data)


def validate_manifest(root: pathlib.Path, source_sha: str, runtime: str) -> dict:
    require(re.fullmatch(r"iOS [0-9]+(?:\.[0-9]+)* [A-Za-z0-9]+", runtime) is not None,
            "Runtime identity must include its exact iOS build")
    path = root / MANIFEST
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_MANIFEST_BYTES, "Screenshot manifest is missing or unsafe")
    manifest = json_object(path.read_bytes())
    require(type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] in (1, 2), "Unsupported screenshot manifest schema")
    require(manifest.get("evidenceType") == "app-store-screenshot-set" and manifest.get("sourceCommit") == source_sha
            and manifest.get("locale") == LOCALE, "Screenshot manifest provenance or locale does not match")
    try:
        created = dt.datetime.fromisoformat(manifest["createdAt"].replace("Z", "+00:00"))
        require(created.utcoffset() is not None, "Screenshot capture time lacks a timezone")
    except (KeyError, ValueError, TypeError, AttributeError):
        raise EvidenceRejected("Screenshot capture time is malformed") from None
    sets = manifest.get("sets")
    require(isinstance(sets, list) and len(sets) == len(DEVICE_SPECS) and all(isinstance(item, dict) for item in sets), "Screenshot device sets are incomplete")
    hashes = set()
    for spec in DEVICE_SPECS:
        found = [item for item in sets if item.get("deviceClass") == spec["directory"]]
        require(len(found) == 1, "Screenshot device set is absent or duplicated")
        item = found[0]
        require(item.get("deviceName") == spec["deviceName"] and item.get("runtime") == runtime
                and item.get("dimensions") == {"width": spec["width"], "height": spec["height"]}, "Screenshot device, dimensions, or runtime does not match")
        screenshots = item.get("screenshots")
        require(isinstance(screenshots, list) and len(screenshots) == len(SCREENSHOT_NAMES)
                and all(isinstance(record, dict) for record in screenshots), "Screenshot records are incomplete")
        directory = root / spec["directory"] / LOCALE
        require(directory.is_dir() and not directory.is_symlink() and not directory.parent.is_symlink(), "Screenshot directory is unsafe")
        require({file.name for file in directory.iterdir()} == set(SCREENSHOT_NAMES), "Screenshot directory has missing or unexpected files")
        for filename in SCREENSHOT_NAMES:
            records = [record for record in screenshots if record.get("filename") == filename]
            require(len(records) == 1, "Screenshot filename is absent or duplicated")
            record = records[0]
            require(positive_integer(record.get("size")) and record["size"] <= MAX_PNG_BYTES
                    and isinstance(record.get("sha256"), str) and SHA256.fullmatch(record["sha256"]) is not None, "Screenshot file identity is malformed")
            require((directory / filename).stat().st_size <= MAX_PNG_BYTES, "Screenshot PNG is oversized")
            try:
                actual = validate_png(directory / filename, spec["width"], spec["height"])
            except SystemExit:
                raise EvidenceRejected("Screenshot PNG failed format, dimensions, or transparency validation") from None
            require(actual == record, "Screenshot PNG bytes do not match the original manifest")
            require(record["sha256"] not in hashes, "Screenshot evidence contains duplicate images")
            hashes.add(record["sha256"])
    return manifest


def verify_candidate(github: GitHub, artifact_id: int, source_sha: str, destination: pathlib.Path,
                     xcode_version: str, runtime: str) -> dict:
    metadata = github.api(f"/actions/artifacts/{artifact_id}")
    proof = verify_origin(github, metadata, artifact_id)
    original_sha = proof["sourceCommit"]
    original_digest = tree_digest(github.tree(original_sha))
    current_digest = tree_digest(github.tree(source_sha))
    require(original_digest == current_digest, "Relevant source inputs changed since the original capture")
    verify_xcode_pin(github.workflow_source(original_sha, proof["workflowPath"]), xcode_version)
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(not any(parent.is_symlink() for parent in (destination, *destination.parents)), "Screenshot destination contains a symlink")
    require(not destination.exists() or (destination.is_dir() and not any(destination.iterdir())), "Screenshot destination is not empty")
    with tempfile.TemporaryDirectory(prefix=".screenshot-verification-", dir=destination.parent) as raw:
        temporary = pathlib.Path(raw)
        archive = temporary / "artifact.zip"
        github.download(artifact_id, archive)
        require(archive.stat().st_size == proof["artifactSize"], "Downloaded artifact size does not match GitHub metadata")
        hasher = hashlib.sha256()
        with archive.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
        require(hasher.hexdigest() == proof["artifactSha256"], "Downloaded artifact SHA256 does not match GitHub metadata")
        staged = temporary / "screenshots"
        staged.mkdir()
        extract_screenshots(archive, staged)
        manifest = validate_manifest(staged, original_sha, runtime)
        if manifest["schemaVersion"] == 1:
            require(original_sha == source_sha, "Schema 1 evidence can only be reused for its original source commit")
        else:
            require(manifest.get("captureEnvironment") == {"xcodeVersion": xcode_version, "runtime": runtime}, "Recorded capture toolchain does not match")
            require(manifest.get("inputDigest") == {"algorithm": DIGEST_ALGORITHM, "excludedPaths": list(EXCLUDED_PATHS), "sha256": original_digest}, "Recorded input digest does not match the immutable source tree")
        proof.update({"manifestSchemaVersion": manifest["schemaVersion"], "createdAt": manifest["createdAt"],
                      "currentSourceCommit": source_sha, "inputDigest": current_digest,
                      "captureEnvironment": {"xcodeVersion": xcode_version, "runtime": runtime},
                      "manifestSha256": hashlib.sha256((staged / MANIFEST).read_bytes()).hexdigest()})
        if destination.exists():
            destination.rmdir()
        os.replace(staged, destination)
    return proof


def select_reuse(github: GitHub, source_sha: str, candidate_id: str, destination: pathlib.Path,
                 xcode_version: str, runtime: str) -> dict:
    receipt = {"schemaVersion": 1, "evidenceType": "app-store-screenshot-reuse", "reused": False,
               "currentSourceCommit": source_sha, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "rejections": []}
    try:
        require(valid_sha(source_sha), "Current source must be a full lowercase Git SHA")
        if candidate_id:
            require(re.fullmatch(r"[1-9][0-9]{0,18}", candidate_id) is not None, "Candidate artifact ID is malformed")
            candidates = [int(candidate_id)]
        else:
            artifacts = github.pages("/actions/artifacts", "artifacts")
            artifacts = [item for item in artifacts if ARTIFACT_NAME.fullmatch(str(item.get("name", "")))
                         and positive_integer(item.get("id"))]
            artifacts.sort(key=lambda item: (str(item.get("created_at", "")), item["id"]), reverse=True)
            candidates = [item["id"] for item in artifacts[:20]]
        for artifact_id in candidates:
            try:
                proof = verify_candidate(github, artifact_id, source_sha, destination, xcode_version, runtime)
            except EvidenceRejected as error:
                receipt["rejections"].append({"artifactId": artifact_id, "reason": str(error)})
            except (OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile):
                receipt["rejections"].append({"artifactId": artifact_id, "reason": "Artifact evidence is malformed or unreadable"})
            else:
                receipt.update({"reused": True, "reason": "Verified original capture, artifact bytes, environment, and unchanged source inputs", "originalCapture": proof})
                return receipt
        receipt["reason"] = "No acceptable screenshot artifact was found"
    except EvidenceRejected as error:
        receipt["reason"] = str(error)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        receipt["reason"] = "Screenshot evidence lookup was unavailable or malformed"
    return receipt


def write_json(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("reuse", "stamp"):
        command = commands.add_parser(name)
        command.add_argument("--source-sha", required=True)
        command.add_argument("--xcode-version", required=True)
        command.add_argument("--runtime", required=True, help="Exact simulator name and build, e.g. iOS 26.5 23F77")
        if name == "reuse":
            command.add_argument("--candidate-artifact-id", default="")
            command.add_argument("--destination", required=True, type=pathlib.Path)
            command.add_argument("--receipt", required=True, type=pathlib.Path)
            command.add_argument("--github-output", required=True, type=pathlib.Path)
        else:
            command.add_argument("--manifest", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.command == "stamp":
        try:
            require(args.manifest.name == MANIFEST, "Screenshot manifest filename is incorrect")
            digest = local_tree_digest(args.source_sha)
            manifest = validate_manifest(args.manifest.parent, args.source_sha, args.runtime)
            workflow = pathlib.Path(WORKFLOWS[336812515][0]).read_text(encoding="utf-8")
            verify_xcode_pin(workflow, args.xcode_version)
            manifest.update({"schemaVersion": 2, "captureEnvironment": {"xcodeVersion": args.xcode_version, "runtime": args.runtime},
                             "inputDigest": {"algorithm": DIGEST_ALGORITHM, "excludedPaths": list(EXCLUDED_PATHS), "sha256": digest}})
            write_json(args.manifest, manifest)
        except EvidenceRejected as error:
            raise SystemExit(str(error)) from None
    else:
        receipt = select_reuse(GitHub(), args.source_sha, args.candidate_artifact_id, args.destination, args.xcode_version, args.runtime)
        write_json(args.receipt, receipt)
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"reused={str(receipt['reused']).lower()}\n")
        print("Reused verified screenshot evidence" if receipt["reused"] else "No reusable screenshot evidence; a fresh capture is required")


if __name__ == "__main__":
    main()
