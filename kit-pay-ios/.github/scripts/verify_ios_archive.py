#!/usr/bin/env python3
"""Fail closed on signed IPA identity and record immutable artifact digests."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import re

from ios_profile_entitlements import (
    authorizes_cloudkit,
    authorizes_production_icloud,
)


SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
APP_STORE_SCREENSHOT_FIXTURE_MARKER = b"KITPAY_APP_STORE_SCREENSHOT_FIXTURE_V1"
SOURCE_RELEASE_URL = (
    "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/"
    "v{version}-build{build_number}"
)


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def load_plist(path: pathlib.Path, label: str) -> dict:
    try:
        with path.open("rb") as source:
            value = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{label} could not be decoded: {error}")
    if not isinstance(value, dict):
        fail(f"{label} is not a dictionary")
    return value


def digest(path: pathlib.Path) -> dict[str, object]:
    if not path.is_file() or path.is_symlink():
        fail(f"Expected a regular artifact: {path}")
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return {
        "filename": path.name,
        "sha256": hasher.hexdigest(),
        "size": path.stat().st_size,
    }


def executable_contains(path: pathlib.Path, needle: bytes) -> bool:
    if not path.is_file() or path.is_symlink():
        fail(f"Expected a regular signed executable: {path}")
    overlap = max(len(needle) - 1, 0)
    tail = b""
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            candidate = tail + chunk
            if needle in candidate:
                return True
            tail = candidate[-overlap:] if overlap else b""
    return False


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--embedded-profile-plist", type=pathlib.Path, required=True)
    parser.add_argument("--signed-entitlements-plist", type=pathlib.Path, required=True)
    parser.add_argument("--expected-profile-uuid", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--corresponding-source-url", required=True)
    parser.add_argument("--ipa", type=pathlib.Path, required=True)
    parser.add_argument("--archive-zip", type=pathlib.Path, required=True)
    parser.add_argument("--dsym-zip", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    if not SHA_PATTERN.fullmatch(args.source_commit):
        fail("The source commit must be a full lowercase Git SHA")
    expected_source_url = SOURCE_RELEASE_URL.format(
        version=args.version,
        build_number=args.build_number,
    )
    if args.corresponding_source_url != expected_source_url:
        fail("The corresponding-source URL does not match the release identity")

    info = load_plist(args.app / "Info.plist", "Signed app Info.plist")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        fail("Signed app Info.plist has no executable name")
    executable = args.app / executable_name
    if executable_contains(executable, APP_STORE_SCREENSHOT_FIXTURE_MARKER):
        fail("Signed app contains the forbidden App Store screenshot fixture")
    privacy = load_plist(
        args.app / "PrivacyInfo.xcprivacy",
        "Signed app privacy manifest",
    )
    profile = load_plist(args.embedded_profile_plist, "Embedded provisioning profile")
    signed = load_plist(args.signed_entitlements_plist, "Signed app entitlements")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        fail("The embedded provisioning profile has no entitlements")
    background_modes = info.get("UIBackgroundModes", [])
    if not isinstance(background_modes, list) or not all(
        isinstance(mode, str) for mode in background_modes
    ):
        fail("Signed app background modes are malformed")
    permitted_background_tasks = info.get("BGTaskSchedulerPermittedIdentifiers")
    valid_processing_metadata = "processing" not in background_modes or (
        isinstance(permitted_background_tasks, list)
        and bool(permitted_background_tasks)
        and all(
            isinstance(identifier, str) and bool(identifier)
            for identifier in permitted_background_tasks
        )
    )
    accessed_api_types = privacy.get("NSPrivacyAccessedAPITypes")
    valid_accessed_api_types = isinstance(accessed_api_types, list) and all(
        isinstance(entry, dict) for entry in accessed_api_types
    )
    user_defaults_reasons: list[str] = []
    if valid_accessed_api_types:
        for entry in accessed_api_types:
            if entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults":
                reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
                if isinstance(reasons, list) and all(isinstance(reason, str) for reason in reasons):
                    user_defaults_reasons.extend(reasons)

    expected_application_id = f"{args.team_id}.{args.bundle_id}"
    expected_icloud_container = f"iCloud.{args.bundle_id}"
    expected_icloud_containers = [expected_icloud_container]
    checks = (
        (info.get("CFBundleIdentifier") == args.bundle_id, "Unexpected signed bundle identifier"),
        (info.get("CFBundleShortVersionString") == args.version, "Unexpected marketing version"),
        (info.get("CFBundleVersion") == args.build_number, "Unexpected build number"),
        (
            info.get("KitCorrespondingSourceURL") == expected_source_url,
            "Unexpected signed corresponding-source URL",
        ),
        (profile.get("UUID") == args.expected_profile_uuid, "Unexpected embedded profile UUID"),
        (args.team_id in profile.get("TeamIdentifier", []), "Unexpected embedded profile team"),
        (
            profile_entitlements.get("application-identifier") == expected_application_id,
            "Embedded profile does not exactly match the app identifier",
        ),
        (
            profile_entitlements.get("aps-environment") == "production",
            "Embedded profile does not authorize production APNs",
        ),
        (
            profile_entitlements.get(
                "com.apple.developer.icloud-container-identifiers"
            ) == expected_icloud_containers,
            "Embedded profile does not authorize the exact iCloud container",
        ),
        (
            authorizes_cloudkit(
                profile_entitlements.get("com.apple.developer.icloud-services")
            ),
            "Embedded profile does not authorize CloudKit",
        ),
        (
            authorizes_production_icloud(
                profile_entitlements.get(
                    "com.apple.developer.icloud-container-environment"
                )
            ),
            "Embedded profile does not authorize the Production iCloud environment",
        ),
        (
            signed.get("application-identifier") == expected_application_id,
            "Signed app identifier entitlement is incorrect",
        ),
        (
            signed.get("com.apple.developer.team-identifier") == args.team_id,
            "Signed app team entitlement is incorrect",
        ),
        (signed.get("aps-environment") == "production", "Signed app APNs entitlement is not production"),
        (
            signed.get("com.apple.developer.icloud-container-identifiers")
            == expected_icloud_containers,
            "Signed app iCloud container entitlement is incorrect",
        ),
        (
            signed.get("com.apple.developer.icloud-services") == ["CloudKit"],
            "Signed app CloudKit service entitlement is not exact",
        ),
        (
            signed.get("com.apple.developer.icloud-container-environment")
            == "Production",
            "Signed app iCloud environment entitlement is not Production",
        ),
        (signed.get("get-task-allow") is False, "Signed app must explicitly prohibit debugging"),
        (
            valid_processing_metadata,
            "Background processing requires BGTaskSchedulerPermittedIdentifiers",
        ),
        (valid_accessed_api_types, "Privacy manifest required-reason APIs are malformed"),
        (
            "CA92.1" in user_defaults_reasons,
            "Privacy manifest does not declare the app-specific UserDefaults reason",
        ),
        (
            info.get("ITSAppUsesNonExemptEncryption") is False,
            "Signed app must declare the reviewed exempt encryption configuration",
        ),
        (
            "ITSEncryptionExportComplianceCode" not in info,
            "Signed app must not carry an export-compliance code for an exempt declaration",
        ),
    )
    for passed, message in checks:
        if not passed:
            fail(message)

    evidence = {
        "schemaVersion": 1,
        "evidenceType": "github-actions-ios-app-store-archive",
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "sourceCommit": args.source_commit,
        "target": {
            "bundleId": args.bundle_id,
            "version": args.version,
            "buildNumber": args.build_number,
            "correspondingSourceURL": expected_source_url,
            "usesNonExemptEncryption": False,
            "iCloudContainer": expected_icloud_container,
        },
        "workflow": {
            "runId": args.run_id,
            "runAttempt": args.run_attempt,
        },
        "artifacts": {
            "ipa": digest(args.ipa),
            "xcarchive": digest(args.archive_zip),
            "dsyms": digest(args.dsym_zip),
        },
    }
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
