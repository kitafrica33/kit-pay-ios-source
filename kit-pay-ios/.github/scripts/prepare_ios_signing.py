#!/usr/bin/env python3
"""Validate an App Store profile and generate non-secret export configuration."""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import plistlib
import re


TEAM_PATTERN = re.compile(r"[A-Z0-9]{10}")
UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
BUNDLE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{2,254}")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile-plist", type=pathlib.Path, required=True)
    parser.add_argument("--certificate-der", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--export-options", type=pathlib.Path, required=True)
    parser.add_argument("--profile-uuid-output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    if not TEAM_PATTERN.fullmatch(args.team_id):
        fail("APPLE_TEAM_ID must be a 10-character Apple team identifier")
    if not BUNDLE_PATTERN.fullmatch(args.bundle_id):
        fail("The iOS bundle identifier is malformed")

    try:
        with args.profile_plist.open("rb") as source:
            profile = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"The provisioning profile could not be decoded: {error}")

    profile_uuid = profile.get("UUID")
    if not isinstance(profile_uuid, str) or not UUID_PATTERN.fullmatch(profile_uuid):
        fail("The provisioning profile has no valid UUID")

    platforms = profile.get("Platform")
    if not isinstance(platforms, list) or "iOS" not in platforms:
        fail("The provisioning profile is not authorized for the iOS platform")
    try:
        imported_certificate = args.certificate_der.read_bytes()
    except OSError as error:
        fail(f"The imported distribution certificate could not be read: {error}")
    if not imported_certificate:
        fail("The imported distribution certificate is empty")
    profile_certificates = profile.get("DeveloperCertificates")
    if not isinstance(profile_certificates, list) or not any(
        isinstance(candidate, bytes) and candidate == imported_certificate
        for candidate in profile_certificates
    ):
        fail("The imported distribution certificate is not authorized by the provisioning profile")

    teams = profile.get("TeamIdentifier")
    entitlements = profile.get("Entitlements")
    if not isinstance(teams, list) or not isinstance(entitlements, dict):
        fail("The provisioning profile is missing team or entitlement data")
    if args.team_id not in teams:
        fail("The provisioning profile does not belong to APPLE_TEAM_ID")
    if entitlements.get("com.apple.developer.team-identifier") != args.team_id:
        fail("The provisioning profile entitlement team does not match APPLE_TEAM_ID")

    expected_application_id = f"{args.team_id}.{args.bundle_id}"
    if entitlements.get("application-identifier") != expected_application_id:
        fail("The provisioning profile is not an exact bundle identifier match")
    if entitlements.get("get-task-allow") is not False:
        fail("A distribution profile with get-task-allow=false is required")
    if entitlements.get("aps-environment") != "production":
        fail("The App Store profile must include aps-environment=production")
    expected_icloud_container = f"iCloud.{args.bundle_id}"
    icloud_containers = entitlements.get(
        "com.apple.developer.icloud-container-identifiers"
    )
    if icloud_containers != [expected_icloud_container]:
        fail("The App Store profile must authorize the exact Kit Pay iCloud container")
    icloud_services = entitlements.get("com.apple.developer.icloud-services")
    if not isinstance(icloud_services, list) or "CloudKit" not in icloud_services:
        fail("The App Store profile must authorize the CloudKit service")
    if (
        entitlements.get("com.apple.developer.icloud-container-environment")
        != "Production"
    ):
        fail("The App Store profile must authorize the Production iCloud environment")
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        fail("An App Store distribution profile is required")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        fail("The provisioning profile has no valid expiration date")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        fail("The provisioning profile has expired")

    export_options = {
        "destination": "export",
        "manageAppVersionAndBuildNumber": False,
        "method": "app-store-connect",
        "provisioningProfiles": {args.bundle_id: profile_uuid},
        "signingCertificate": "Apple Distribution",
        "signingStyle": "manual",
        "stripSwiftSymbols": True,
        "teamID": args.team_id,
        "uploadSymbols": True,
    }
    args.export_options.parent.mkdir(parents=True, exist_ok=True)
    with args.export_options.open("wb") as destination:
        plistlib.dump(export_options, destination, sort_keys=True)
    args.export_options.chmod(0o600)
    args.profile_uuid_output.write_text(profile_uuid + "\n", encoding="ascii")
    args.profile_uuid_output.chmod(0o600)


if __name__ == "__main__":
    main()
