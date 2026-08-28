#!/usr/bin/env python3
"""Validate an App Store profile and generate non-secret export configuration."""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import plistlib
import re

from ios_profile_entitlements import (
    authorizes_cloudkit,
    authorizes_production_icloud,
)


TEAM_PATTERN = re.compile(r"[A-Z0-9]{10}")
UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
BUNDLE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{2,254}")
APP_GROUP_KEY = "com.apple.security.application-groups"
TIME_SENSITIVE_NOTIFICATIONS_KEY = (
    "com.apple.developer.usernotifications.time-sensitive"
)


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
    # The app carries push and CloudKit; the share extension carries neither and must not be
    # provisioned as though it did. Both, however, have to authorize the app group — it is the
    # only channel the extension has, and a profile without it fails at codesign time with a
    # message that says nothing about which capability is missing.
    parser.add_argument("--role", choices=("app", "extension"), default="app")
    parser.add_argument("--app-group", required=True)
    return parser.parse_args()


def authorizes_app_group(entitlements: dict, app_group: str, team_id: str) -> bool:
    """True when the profile grants exactly the one app group Kit Pay uses.

    Apple prefixes the group with the team identifier in some profiles and not others, so both
    spellings are accepted — but nothing else is: a profile that authorizes a second, unexpected
    container is a profile that was generated against the wrong App ID.
    """
    groups = entitlements.get(APP_GROUP_KEY)
    if not isinstance(groups, list) or len(groups) != 1:
        return False
    accepted = {app_group, f"{team_id}.{app_group}"}
    return isinstance(groups[0], str) and groups[0] in accepted


def main() -> None:
    args = arguments()
    if not TEAM_PATTERN.fullmatch(args.team_id):
        fail("APPLE_TEAM_ID must be a 10-character Apple team identifier")
    if not BUNDLE_PATTERN.fullmatch(args.bundle_id):
        fail("The iOS bundle identifier is malformed")
    if not args.app_group.startswith("group.") or not BUNDLE_PATTERN.fullmatch(args.app_group):
        fail("The app group identifier is malformed")

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
    if not authorizes_app_group(entitlements, args.app_group, args.team_id):
        fail(
            "The App Store profile must authorize the App Groups capability for "
            f"{args.app_group}. Enable App Groups on the {args.bundle_id} App ID and add that "
            "group to it, then run this workflow again."
        )
    if args.role == "app":
        if entitlements.get("aps-environment") != "production":
            fail("The App Store profile must include aps-environment=production")
        if entitlements.get(TIME_SENSITIVE_NOTIFICATIONS_KEY) is not True:
            fail(
                "The App Store profile must authorize Time Sensitive Notifications"
            )
        expected_icloud_container = f"iCloud.{args.bundle_id}"
        icloud_containers = entitlements.get(
            "com.apple.developer.icloud-container-identifiers"
        )
        if icloud_containers != [expected_icloud_container]:
            fail("The App Store profile must authorize the exact Kit Pay iCloud container")
        icloud_services = entitlements.get("com.apple.developer.icloud-services")
        if not authorizes_cloudkit(icloud_services):
            fail("The App Store profile must authorize the CloudKit service")
        icloud_environment = entitlements.get(
            "com.apple.developer.icloud-container-environment"
        )
        if not authorizes_production_icloud(icloud_environment):
            fail("The App Store profile must authorize the Production iCloud environment")
    else:
        # The extension can neither receive a push nor reach CloudKit, and a profile that says it
        # can is a profile that was generated for the wrong App ID.
        if "aps-environment" in entitlements:
            fail("The share extension profile must not authorize push notifications")
        if TIME_SENSITIVE_NOTIFICATIONS_KEY in entitlements:
            fail(
                "The share extension profile must not authorize Time Sensitive Notifications"
            )
        if "com.apple.developer.icloud-container-identifiers" in entitlements:
            fail("The share extension profile must not authorize iCloud containers")
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        fail("An App Store distribution profile is required")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        fail("The provisioning profile has no valid expiration date")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        fail("The provisioning profile has expired")

    # Manual export needs one entry per signed bundle, so a second run for the share extension
    # adds to the mapping the app's run wrote rather than replacing it.
    profiles: dict[str, str] = {}
    if args.export_options.exists():
        try:
            with args.export_options.open("rb") as existing:
                previous = plistlib.load(existing)
        except (OSError, plistlib.InvalidFileException) as error:
            fail(f"The existing export options could not be decoded: {error}")
        existing_profiles = previous.get("provisioningProfiles")
        if not isinstance(existing_profiles, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in existing_profiles.items()
        ):
            fail("The existing export options have a malformed profile mapping")
        profiles.update(existing_profiles)
    profiles[args.bundle_id] = profile_uuid

    export_options = {
        "destination": "export",
        "manageAppVersionAndBuildNumber": False,
        "method": "app-store-connect",
        "provisioningProfiles": profiles,
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
