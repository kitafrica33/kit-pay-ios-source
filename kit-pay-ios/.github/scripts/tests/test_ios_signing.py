from __future__ import annotations

import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
PREPARE = ROOT / ".github/scripts/prepare_ios_signing.py"
VERIFY = ROOT / ".github/scripts/verify_ios_archive.py"
PROFILE_GENERATOR_PATH = ROOT / ".github/scripts/create_ios_app_store_profile.py"
PROFILE_ENTITLEMENTS_PATH = ROOT / ".github/scripts/ios_profile_entitlements.py"
CLOUDKIT_HELPER = ROOT / ".github/scripts/prepare_cloudkit_schema.py"
CLOUDKIT_SCHEMA = ROOT / ".github/cloudkit/KitMessageBackup.ckdb"
TEAM = "A1B2C3D4E5"
CLOUDKIT_TEAM = "AU55CKVJ55"
BUNDLE = "africa.kit.pay.ios"
EXECUTABLE = "KitPay"
PROFILE_UUID = "11111111-2222-3333-4444-555555555555"
CERTIFICATE_DER = b"synthetic-distribution-certificate"
SOURCE_URL = (
    "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/"
    "v1.2.3-build42"
)
ICLOUD_CONTAINER = f"iCloud.{BUNDLE}"
ICLOUD_ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"
APP_GROUP_KEY = "com.apple.security.application-groups"
APP_GROUP = "group.africa.kit.pay.ios"
SHARE_BUNDLE = "africa.kit.pay.ios.share"
SHARE_PROFILE_UUID = "66666666-7777-8888-9999-aaaaaaaaaaaa"

PROFILE_GENERATOR_SPEC = importlib.util.spec_from_file_location(
    "kitpay_create_ios_app_store_profile",
    PROFILE_GENERATOR_PATH,
)
if PROFILE_GENERATOR_SPEC is None or PROFILE_GENERATOR_SPEC.loader is None:
    raise RuntimeError("Could not load create_ios_app_store_profile.py")
PROFILE_GENERATOR = importlib.util.module_from_spec(PROFILE_GENERATOR_SPEC)
sys.modules[PROFILE_GENERATOR_SPEC.name] = PROFILE_GENERATOR
PROFILE_GENERATOR_SPEC.loader.exec_module(PROFILE_GENERATOR)

PROFILE_ENTITLEMENTS_SPEC = importlib.util.spec_from_file_location(
    "kitpay_ios_profile_entitlements",
    PROFILE_ENTITLEMENTS_PATH,
)
if PROFILE_ENTITLEMENTS_SPEC is None or PROFILE_ENTITLEMENTS_SPEC.loader is None:
    raise RuntimeError("Could not load ios_profile_entitlements.py")
PROFILE_ENTITLEMENTS = importlib.util.module_from_spec(PROFILE_ENTITLEMENTS_SPEC)
PROFILE_ENTITLEMENTS_SPEC.loader.exec_module(PROFILE_ENTITLEMENTS)
sys.modules["ios_profile_entitlements"] = PROFILE_ENTITLEMENTS

PREPARE_SPEC = importlib.util.spec_from_file_location(
    "kitpay_prepare_ios_signing",
    PREPARE,
)
if PREPARE_SPEC is None or PREPARE_SPEC.loader is None:
    raise RuntimeError("Could not load prepare_ios_signing.py")
PREPARE_MODULE = importlib.util.module_from_spec(PREPARE_SPEC)
PREPARE_SPEC.loader.exec_module(PREPARE_MODULE)

VERIFY_SPEC = importlib.util.spec_from_file_location(
    "kitpay_verify_ios_archive",
    VERIFY,
)
if VERIFY_SPEC is None or VERIFY_SPEC.loader is None:
    raise RuntimeError("Could not load verify_ios_archive.py")
VERIFY_MODULE = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(VERIFY_MODULE)


def write_plist(path: pathlib.Path, value: dict) -> None:
    with path.open("wb") as destination:
        plistlib.dump(value, destination)


def profile(aps_environment: str = "production") -> dict:
    return {
        "UUID": PROFILE_UUID,
        "Platform": ["iOS"],
        "DeveloperCertificates": [CERTIFICATE_DER],
        "TeamIdentifier": [TEAM],
        "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30),
        "Entitlements": {
            "application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
            "aps-environment": aps_environment,
            "get-task-allow": False,
            "com.apple.developer.icloud-container-identifiers": [ICLOUD_CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            ICLOUD_ENVIRONMENT_KEY: "Production",
            APP_GROUP_KEY: [APP_GROUP],
        },
    }


def share_profile() -> dict:
    """A share-extension distribution profile: the app group, and nothing else."""
    return {
        "UUID": SHARE_PROFILE_UUID,
        "Platform": ["iOS"],
        "DeveloperCertificates": [CERTIFICATE_DER],
        "TeamIdentifier": [TEAM],
        "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30),
        "Entitlements": {
            "application-identifier": f"{TEAM}.{SHARE_BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": False,
            APP_GROUP_KEY: [APP_GROUP],
        },
    }


class FakeAppStoreConnectClient:
    def __init__(self, responses: list[object]) -> None:
        self.responses = list(responses)
        self.calls: list[dict[str, object]] = []

    def request(self, method: str, path: str, **kwargs: object) -> object:
        self.calls.append({"method": method, "path": path, **kwargs})
        if not self.responses:
            raise AssertionError("Unexpected App Store Connect request")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def api_collection(resources: list[dict[str, object]]) -> dict[str, object]:
    return {"data": resources, "links": {"next": None}}


def capability_resource(
    version: str,
    *,
    resource_id: str = "icloud-capability",
) -> dict[str, object]:
    return {
        "type": "bundleIdCapabilities",
        "id": resource_id,
        "attributes": {
            "capabilityType": "ICLOUD",
            "settings": [
                {
                    "key": "ICLOUD_VERSION",
                    "options": [{"key": version}],
                }
            ],
        },
    }


def app_groups_capability_resource(
    *, resource_id: str = "app-groups-capability"
) -> dict[str, object]:
    return {
        "type": "bundleIdCapabilities",
        "id": resource_id,
        "attributes": {"capabilityType": "APP_GROUPS"},
    }


def bundle_resource(
    platform: str,
    *,
    resource_id: str = "bundle-resource",
) -> dict[str, object]:
    return {
        "type": "bundleIds",
        "id": resource_id,
        "attributes": {
            "identifier": BUNDLE,
            "platform": platform,
        },
    }


def certificate_resource(
    content: bytes,
    *,
    resource_id: str = "distribution-certificate",
    activated: object = True,
    expiration: str = "2999-01-01T00:00:00Z",
    platform: str | None = "IOS",
    certificate_type: str = "DISTRIBUTION",
) -> dict[str, object]:
    return {
        "type": "certificates",
        "id": resource_id,
        "attributes": {
            "certificateType": certificate_type,
            "certificateContent": base64.b64encode(content).decode("ascii"),
            "expirationDate": expiration,
            "platform": platform,
            "activated": activated,
        },
    }


class IOSProfileEntitlementAuthorizationTests(unittest.TestCase):
    def test_cloudkit_service_authorization_matrix(self) -> None:
        cases = (
            ("wildcard", "*", True),
            ("exact-list", ["CloudKit"], True),
            ("superset-list", ["CloudKit", "CloudDocuments"], True),
            ("duplicate-list", ["CloudKit", "CloudKit"], True),
            ("cloudkit-and-wildcard-list", ["CloudKit", "*"], True),
            ("scalar-cloudkit", "CloudKit", False),
            ("wildcard-list", ["*"], False),
            ("missing-or-null", None, False),
            ("empty-list", [], False),
            ("nonstring-scalar", 1, False),
            ("nonstring-list", ["CloudKit", 1], False),
            ("list-without-cloudkit", ["CloudDocuments"], False),
        )

        for label, value, expected in cases:
            with self.subTest(label=label):
                self.assertIs(
                    PROFILE_ENTITLEMENTS.authorizes_cloudkit(value),
                    expected,
                )

    def test_production_icloud_environment_authorization_matrix(self) -> None:
        cases = (
            ("scalar-production", "Production", True),
            ("production-list", ["Production"], True),
            ("known-superset-list", ["Development", "Production"], True),
            ("known-superset-reversed", ["Production", "Development"], True),
            ("scalar-development", "Development", False),
            ("development-only-list", ["Development"], False),
            ("wildcard", "*", False),
            ("missing-or-null", None, False),
            ("empty-list", [], False),
            ("nonstring-scalar", 1, False),
            ("nonstring-list", ["Production", 1], False),
            ("unknown-value", ["Production", "Staging"], False),
            ("duplicate-value", ["Production", "Production"], False),
        )

        for label, value, expected in cases:
            with self.subTest(label=label):
                self.assertIs(
                    PROFILE_ENTITLEMENTS.authorizes_production_icloud(value),
                    expected,
                )


class PrepareIOSSigningTests(unittest.TestCase):
    def test_app_group_authorization_requires_one_exact_group(self) -> None:
        accepted = (
            [APP_GROUP],
            [f"{TEAM}.{APP_GROUP}"],
        )
        rejected = (
            None,
            [],
            APP_GROUP,
            [APP_GROUP, APP_GROUP],
            [APP_GROUP, f"{TEAM}.{APP_GROUP}"],
            [APP_GROUP, "group.example.unexpected"],
            ["group.example.unexpected"],
            [1],
        )
        for value in accepted:
            with self.subTest(accepted=value):
                entitlements = {APP_GROUP_KEY: value}
                self.assertTrue(
                    PREPARE_MODULE.authorizes_app_group(
                        entitlements,
                        APP_GROUP,
                        TEAM,
                    )
                )
                self.assertTrue(
                    VERIFY_MODULE.authorizes_app_group(
                        entitlements,
                        APP_GROUP,
                        TEAM,
                    )
                )
        for value in rejected:
            with self.subTest(rejected=value):
                entitlements = {APP_GROUP_KEY: value}
                self.assertFalse(
                    PREPARE_MODULE.authorizes_app_group(
                        entitlements,
                        APP_GROUP,
                        TEAM,
                    )
                )
                self.assertFalse(
                    VERIFY_MODULE.authorizes_app_group(
                        entitlements,
                        APP_GROUP,
                        TEAM,
                    )
                )

    def test_generates_manual_export_options_for_exact_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            profile_path = root / "profile.plist"
            export_path = root / "ExportOptions.plist"
            uuid_path = root / "uuid"
            certificate_path = root / "distribution.der"
            write_plist(profile_path, profile())
            certificate_path.write_bytes(CERTIFICATE_DER)

            subprocess.run(
                [
                    "python3",
                    str(PREPARE),
                    "--app-group",
                    APP_GROUP,
                    "--profile-plist",
                    str(profile_path),
                    "--certificate-der",
                    str(certificate_path),
                    "--bundle-id",
                    BUNDLE,
                    "--team-id",
                    TEAM,
                    "--export-options",
                    str(export_path),
                    "--profile-uuid-output",
                    str(uuid_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            with export_path.open("rb") as source:
                export = plistlib.load(source)
            self.assertEqual(export["method"], "app-store-connect")
            self.assertEqual(export["signingStyle"], "manual")
            self.assertEqual(export["teamID"], TEAM)
            self.assertEqual(export["provisioningProfiles"], {BUNDLE: PROFILE_UUID})
            self.assertEqual(uuid_path.read_text(encoding="ascii").strip(), PROFILE_UUID)

    def test_share_extension_profile_joins_the_app_export_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            export_path = root / "ExportOptions.plist"
            certificate_path = root / "distribution.der"
            certificate_path.write_bytes(CERTIFICATE_DER)
            app_profile_path = root / "profile.plist"
            share_profile_path = root / "share-profile.plist"
            write_plist(app_profile_path, profile())
            write_plist(share_profile_path, share_profile())

            for role, bundle, profile_path, uuid_name in (
                ("app", BUNDLE, app_profile_path, "uuid"),
                ("extension", SHARE_BUNDLE, share_profile_path, "share-uuid"),
            ):
                subprocess.run(
                    [
                        "python3",
                        str(PREPARE),
                        "--app-group",
                        APP_GROUP,
                        "--profile-plist",
                        str(profile_path),
                        "--certificate-der",
                        str(certificate_path),
                        "--bundle-id",
                        bundle,
                        "--team-id",
                        TEAM,
                        "--role",
                        role,
                        "--export-options",
                        str(export_path),
                        "--profile-uuid-output",
                        str(root / uuid_name),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )

            with export_path.open("rb") as source:
                export = plistlib.load(source)
            # Manual signing needs one profile per signed bundle; losing either entry fails the
            # export with a message that never mentions the extension.
            self.assertEqual(
                export["provisioningProfiles"],
                {BUNDLE: PROFILE_UUID, SHARE_BUNDLE: SHARE_PROFILE_UUID},
            )
            self.assertEqual(export["signingStyle"], "manual")

    def test_rejects_profiles_that_do_not_authorize_the_app_group(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            certificate_path = root / "distribution.der"
            certificate_path.write_bytes(CERTIFICATE_DER)
            cases = (
                ("app", BUNDLE, profile()),
                ("extension", SHARE_BUNDLE, share_profile()),
            )

            for role, bundle, candidate in cases:
                with self.subTest(role=role):
                    candidate["Entitlements"].pop(APP_GROUP_KEY)
                    profile_path = root / f"{role}.plist"
                    write_plist(profile_path, candidate)

                    result = subprocess.run(
                        [
                            "python3",
                            str(PREPARE),
                            "--app-group",
                            APP_GROUP,
                            "--profile-plist",
                            str(profile_path),
                            "--certificate-der",
                            str(certificate_path),
                            "--bundle-id",
                            bundle,
                            "--team-id",
                            TEAM,
                            "--role",
                            role,
                            "--export-options",
                            str(root / f"{role}-ExportOptions.plist"),
                            "--profile-uuid-output",
                            str(root / f"{role}-uuid"),
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("App Groups", result.stderr)

    def test_rejects_a_share_extension_profile_that_reaches_further(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            certificate_path = root / "distribution.der"
            certificate_path.write_bytes(CERTIFICATE_DER)
            overreaching = share_profile()
            overreaching["Entitlements"]["aps-environment"] = "production"
            profile_path = root / "share-profile.plist"
            write_plist(profile_path, overreaching)

            result = subprocess.run(
                [
                    "python3",
                    str(PREPARE),
                    "--app-group",
                    APP_GROUP,
                    "--profile-plist",
                    str(profile_path),
                    "--certificate-der",
                    str(certificate_path),
                    "--bundle-id",
                    SHARE_BUNDLE,
                    "--team-id",
                    TEAM,
                    "--role",
                    "extension",
                    "--export-options",
                    str(root / "ExportOptions.plist"),
                    "--profile-uuid-output",
                    str(root / "uuid"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("push notifications", result.stderr)

    def test_accepts_profile_icloud_authorization_supersets(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            profile_path = root / "profile.plist"
            certificate_path = root / "distribution.der"
            certificate_path.write_bytes(CERTIFICATE_DER)
            command = [
                "python3",
                str(PREPARE),
                "--app-group",
                APP_GROUP,
                "--profile-plist",
                str(profile_path),
                "--certificate-der",
                str(certificate_path),
                "--bundle-id",
                BUNDLE,
                "--team-id",
                TEAM,
                "--export-options",
                str(root / "ExportOptions.plist"),
                "--profile-uuid-output",
                str(root / "uuid"),
            ]
            cases = (
                ("*", ["Production", "Development"]),
                (["CloudKit", "CloudDocuments"], "Production"),
                (["CloudKit"], ["Production"]),
            )

            for services, environment in cases:
                with self.subTest(services=services, environment=environment):
                    candidate = profile()
                    candidate["Entitlements"][
                        "com.apple.developer.icloud-services"
                    ] = services
                    candidate["Entitlements"][ICLOUD_ENVIRONMENT_KEY] = environment
                    write_plist(profile_path, candidate)

                    result = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )

                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_nonproduction_push_profile(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            profile_path = root / "profile.plist"
            certificate_path = root / "distribution.der"
            write_plist(profile_path, profile("development"))
            certificate_path.write_bytes(CERTIFICATE_DER)
            result = subprocess.run(
                [
                    "python3",
                    str(PREPARE),
                    "--app-group",
                    APP_GROUP,
                    "--profile-plist",
                    str(profile_path),
                    "--certificate-der",
                    str(certificate_path),
                    "--bundle-id",
                    BUNDLE,
                    "--team-id",
                    TEAM,
                    "--export-options",
                    str(root / "ExportOptions.plist"),
                    "--profile-uuid-output",
                    str(root / "uuid"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("aps-environment=production", result.stderr)

    def test_rejects_profile_without_required_cloudkit_authorizations(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            profile_path = root / "profile.plist"
            certificate_path = root / "distribution.der"
            invalid = profile()
            invalid["Entitlements"].pop(
                "com.apple.developer.icloud-container-identifiers"
            )
            write_plist(profile_path, invalid)
            certificate_path.write_bytes(CERTIFICATE_DER)
            command = [
                "python3",
                str(PREPARE),
                "--app-group",
                APP_GROUP,
                "--profile-plist",
                str(profile_path),
                "--certificate-der",
                str(certificate_path),
                "--bundle-id",
                BUNDLE,
                "--team-id",
                TEAM,
                "--export-options",
                str(root / "ExportOptions.plist"),
                "--profile-uuid-output",
                str(root / "uuid"),
            ]
            missing_container = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_container.returncode, 0)
            self.assertIn("exact Kit Pay iCloud container", missing_container.stderr)

            invalid = profile()
            invalid["Entitlements"].pop("com.apple.developer.icloud-services")
            write_plist(profile_path, invalid)
            missing_service = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_service.returncode, 0)
            self.assertIn("CloudKit service", missing_service.stderr)

            invalid_service_values = (
                ("scalar-cloudkit", "CloudKit"),
                ("wildcard-list", ["*"]),
                ("empty-list", []),
                ("nonstring-list", ["CloudKit", 1]),
                ("list-without-cloudkit", ["CloudDocuments"]),
            )
            for label, value in invalid_service_values:
                with self.subTest(service=label):
                    invalid = profile()
                    invalid["Entitlements"][
                        "com.apple.developer.icloud-services"
                    ] = value
                    write_plist(profile_path, invalid)
                    invalid_service = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(invalid_service.returncode, 0)
                    self.assertIn("CloudKit service", invalid_service.stderr)

            invalid = profile()
            invalid["Entitlements"].pop(ICLOUD_ENVIRONMENT_KEY)
            write_plist(profile_path, invalid)
            missing_environment = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_environment.returncode, 0)
            self.assertIn("Production iCloud environment", missing_environment.stderr)

            invalid_environment_values = (
                ("scalar-development", "Development"),
                ("development-only-list", ["Development"]),
                ("wildcard", "*"),
                ("empty-list", []),
                ("nonstring-list", ["Production", 1]),
                ("unknown-value", ["Production", "Staging"]),
                ("duplicate-value", ["Production", "Production"]),
            )
            for label, value in invalid_environment_values:
                with self.subTest(environment=label):
                    invalid = profile()
                    invalid["Entitlements"][ICLOUD_ENVIRONMENT_KEY] = value
                    write_plist(profile_path, invalid)
                    invalid_environment = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(invalid_environment.returncode, 0)
                    self.assertIn(
                        "Production iCloud environment",
                        invalid_environment.stderr,
                    )

    def test_rejects_wrong_platform_or_distribution_certificate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            profile_path = root / "profile.plist"
            certificate_path = root / "distribution.der"
            invalid = profile()
            invalid["Platform"] = ["macOS"]
            write_plist(profile_path, invalid)
            certificate_path.write_bytes(b"different-certificate")
            common = [
                "python3",
                str(PREPARE),
                "--app-group",
                APP_GROUP,
                "--profile-plist",
                str(profile_path),
                "--certificate-der",
                str(certificate_path),
                "--bundle-id",
                BUNDLE,
                "--team-id",
                TEAM,
                "--export-options",
                str(root / "ExportOptions.plist"),
                "--profile-uuid-output",
                str(root / "uuid"),
            ]
            platform_result = subprocess.run(common, check=False, capture_output=True, text=True)
            self.assertIn("iOS platform", platform_result.stderr)

            invalid["Platform"] = ["iOS"]
            write_plist(profile_path, invalid)
            certificate_result = subprocess.run(common, check=False, capture_output=True, text=True)
            self.assertIn("not authorized by the provisioning profile", certificate_result.stderr)


class AppStoreProfileGeneratorTests(unittest.TestCase):
    def test_bundle_lookup_accepts_exact_ios_and_universal_bundle(self) -> None:
        for platform in ("IOS", "UNIVERSAL"):
            with self.subTest(platform=platform):
                client = FakeAppStoreConnectClient(
                    [api_collection([bundle_resource(platform)])]
                )

                result = PROFILE_GENERATOR._find_bundle_id(client, BUNDLE)

                self.assertEqual(result, "bundle-resource")
                self.assertEqual(
                    client.calls[0]["query"],
                    {
                        "filter[identifier]": BUNDLE,
                        "fields[bundleIds]": "identifier,platform",
                        "limit": "2",
                    },
                )

    def test_bundle_lookup_rejects_mac_platform(self) -> None:
        client = FakeAppStoreConnectClient(
            [api_collection([bundle_resource("MAC_OS")])]
        )

        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "not found uniquely",
        ):
            PROFILE_GENERATOR._find_bundle_id(client, BUNDLE)

    def test_bundle_lookup_rejects_duplicate_exact_matches(self) -> None:
        client = FakeAppStoreConnectClient(
            [
                api_collection(
                    [
                        bundle_resource("IOS", resource_id="first-bundle"),
                        bundle_resource("UNIVERSAL", resource_id="second-bundle"),
                    ]
                )
            ]
        )

        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "not found uniquely",
        ):
            PROFILE_GENERATOR._find_bundle_id(client, BUNDLE)

    def test_existing_xcode6_capability_is_verified_without_mutation(self) -> None:
        existing = capability_resource("XCODE_6")
        client = FakeAppStoreConnectClient([api_collection([existing])])

        PROFILE_GENERATOR._ensure_icloud_xcode6(client, "bundle-resource")

        self.assertEqual([call["method"] for call in client.calls], ["GET"])
        self.assertTrue(
            all("/bundleIdCapabilities" in str(call["path"]) for call in client.calls)
        )
        self.assertEqual(
            client.calls[0]["query"],
            {"fields[bundleIdCapabilities]": "capabilityType,settings"},
        )

    def test_app_groups_capability_is_enabled_and_verified(self) -> None:
        client = FakeAppStoreConnectClient(
            [
                api_collection([]),
                {"data": app_groups_capability_resource()},
                api_collection([app_groups_capability_resource()]),
            ]
        )

        PROFILE_GENERATOR._ensure_app_groups_enabled(client, "bundle-resource", sleep=lambda _: None)

        mutation = client.calls[1]
        self.assertEqual(mutation["method"], "POST")
        self.assertEqual(mutation["path"], "/v1/bundleIdCapabilities")
        self.assertEqual(
            mutation["body"],
            {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {"capabilityType": "APP_GROUPS"},
                    "relationships": {
                        "bundleId": {
                            "data": {"type": "bundleIds", "id": "bundle-resource"}
                        }
                    },
                }
            },
        )

    def test_missing_extension_bundle_id_is_registered_explicitly(self) -> None:
        for platform in ("IOS", "UNIVERSAL"):
            with self.subTest(platform=platform):
                client = FakeAppStoreConnectClient(
                    [
                        api_collection([]),
                        {
                            "data": {
                                "type": "bundleIds",
                                "id": "share-bundle-resource",
                                "attributes": {
                                    "identifier": SHARE_BUNDLE,
                                    "name": "Kit Pay Share",
                                    "platform": platform,
                                },
                            }
                        },
                    ]
                )

                resource_id = PROFILE_GENERATOR._ensure_bundle_id(
                    client,
                    SHARE_BUNDLE,
                    "Kit Pay Share",
                )

                self.assertEqual(resource_id, "share-bundle-resource")
                self.assertEqual(client.calls[1]["method"], "POST")
                self.assertEqual(client.calls[1]["path"], "/v1/bundleIds")

    def test_missing_capability_uses_exact_creation_body(self) -> None:
        client = FakeAppStoreConnectClient(
            [
                api_collection([]),
                {"data": capability_resource("XCODE_6")},
                api_collection([capability_resource("XCODE_6")]),
            ]
        )

        PROFILE_GENERATOR._ensure_icloud_xcode6(client, "bundle-resource")

        mutation = client.calls[1]
        self.assertEqual(mutation["method"], "POST")
        self.assertEqual(mutation["path"], "/v1/bundleIdCapabilities")
        self.assertEqual(mutation["expected_status"], 201)
        self.assertEqual(
            mutation["body"],
            {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {
                        "capabilityType": "ICLOUD",
                        "settings": [
                            {
                                "key": "ICLOUD_VERSION",
                                "options": [{"key": "XCODE_6"}],
                            }
                        ],
                    },
                    "relationships": {
                        "bundleId": {
                            "data": {
                                "type": "bundleIds",
                                "id": "bundle-resource",
                            }
                        }
                    },
                }
            },
        )

    def test_xcode5_capability_uses_exact_update_body(self) -> None:
        client = FakeAppStoreConnectClient(
            [
                api_collection([capability_resource("XCODE_5")]),
                {"data": capability_resource("XCODE_6")},
                api_collection([capability_resource("XCODE_6")]),
            ]
        )

        PROFILE_GENERATOR._ensure_icloud_xcode6(client, "bundle-resource")

        mutation = client.calls[1]
        self.assertEqual(mutation["method"], "PATCH")
        self.assertEqual(
            mutation["path"],
            "/v1/bundleIdCapabilities/icloud-capability",
        )
        self.assertEqual(mutation["expected_status"], 200)
        self.assertEqual(
            mutation["body"],
            {
                "data": {
                    "type": "bundleIdCapabilities",
                    "id": "icloud-capability",
                    "attributes": {
                        "capabilityType": "ICLOUD",
                        "settings": [
                            {
                                "key": "ICLOUD_VERSION",
                                "options": [{"key": "XCODE_6"}],
                            }
                        ],
                    },
                }
            },
        )

    def test_capability_propagation_poll_uses_bounded_exponential_delays(self) -> None:
        stale = api_collection([capability_resource("XCODE_5")])
        ready = api_collection([capability_resource("XCODE_6")])
        client = FakeAppStoreConnectClient(
            [
                api_collection([]),
                {"data": capability_resource("XCODE_6")},
                stale,
                stale,
                ready,
            ]
        )
        sleeps: list[float] = []

        PROFILE_GENERATOR._ensure_icloud_xcode6(
            client,
            "bundle-resource",
            sleep=sleeps.append,
        )

        self.assertEqual(sleeps, [1.0, 2.0])
        self.assertEqual(
            [call["method"] for call in client.calls],
            ["GET", "POST", "GET", "GET", "GET"],
        )

    def test_capability_propagation_exhaustion_fails_closed(self) -> None:
        stale = api_collection([capability_resource("XCODE_5")])
        client = FakeAppStoreConnectClient(
            [
                api_collection([]),
                {"data": capability_resource("XCODE_6")},
                *(
                    stale
                    for _ in range(
                        len(
                            PROFILE_GENERATOR._CAPABILITY_PROPAGATION_DELAYS_SECONDS
                        )
                        + 1
                    )
                ),
            ]
        )
        sleeps: list[float] = []

        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "verified ICLOUD XCODE_6",
        ):
            PROFILE_GENERATOR._ensure_icloud_xcode6(
                client,
                "bundle-resource",
                sleep=sleeps.append,
            )

        self.assertEqual(
            sleeps,
            list(PROFILE_GENERATOR._CAPABILITY_PROPAGATION_DELAYS_SECONDS),
        )

    def test_capability_poll_retries_only_transient_http_statuses(self) -> None:
        mutation_response = {"data": capability_resource("XCODE_6")}
        for status in sorted(PROFILE_GENERATOR._TRANSIENT_HTTP_STATUSES):
            with self.subTest(status=status):
                client = FakeAppStoreConnectClient(
                    [
                        api_collection([]),
                        mutation_response,
                        PROFILE_GENERATOR.AppStoreConnectHTTPError(
                            status,
                            "bundle capability lookup",
                        ),
                        api_collection([capability_resource("XCODE_6")]),
                    ]
                )
                sleeps: list[float] = []

                PROFILE_GENERATOR._ensure_icloud_xcode6(
                    client,
                    "bundle-resource",
                    sleep=sleeps.append,
                )

                self.assertEqual(sleeps, [1.0])

        client = FakeAppStoreConnectClient(
            [
                api_collection([]),
                mutation_response,
                PROFILE_GENERATOR.AppStoreConnectHTTPError(
                    403,
                    "bundle capability lookup",
                ),
            ]
        )
        sleeps = []
        with self.assertRaises(PROFILE_GENERATOR.AppStoreConnectHTTPError):
            PROFILE_GENERATOR._ensure_icloud_xcode6(
                client,
                "bundle-resource",
                sleep=sleeps.append,
            )
        self.assertEqual(sleeps, [])

    def test_distribution_certificate_matches_exact_der(self) -> None:
        client = FakeAppStoreConnectClient(
            [
                api_collection(
                    [
                        certificate_resource(b"unrelated", resource_id="other"),
                        certificate_resource(CERTIFICATE_DER),
                    ]
                )
            ]
        )

        result = PROFILE_GENERATOR._find_distribution_certificate(
            client,
            CERTIFICATE_DER,
        )

        self.assertEqual(result, "distribution-certificate")
        self.assertEqual(
            client.calls[0]["query"],
            {
                "filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION",
                "fields[certificates]": (
                    "certificateType,certificateContent,expirationDate,platform,activated"
                ),
                "limit": "200",
            },
        )

    def test_generic_distribution_certificate_accepts_omitted_platform(self) -> None:
        certificate = certificate_resource(CERTIFICATE_DER, platform=None)
        client = FakeAppStoreConnectClient([api_collection([certificate])])

        result = PROFILE_GENERATOR._find_distribution_certificate(
            client,
            CERTIFICATE_DER,
        )

        self.assertEqual(result, "distribution-certificate")

    def test_distribution_certificate_accepts_omitted_activation_state(self) -> None:
        certificate = certificate_resource(CERTIFICATE_DER, platform=None)
        attributes = certificate["attributes"]
        self.assertIsInstance(attributes, dict)
        attributes.pop("activated")
        client = FakeAppStoreConnectClient([api_collection([certificate])])

        result = PROFILE_GENERATOR._find_distribution_certificate(
            client,
            CERTIFICATE_DER,
        )

        self.assertEqual(result, "distribution-certificate")

    def test_distribution_certificate_rejects_invalid_activation_state(self) -> None:
        for invalid_state in (None, "true", 1, [], {}):
            with self.subTest(invalid_state=invalid_state):
                certificate = certificate_resource(
                    CERTIFICATE_DER,
                    activated=invalid_state,
                )
                client = FakeAppStoreConnectClient([api_collection([certificate])])

                with self.assertRaisesRegex(
                    PROFILE_GENERATOR.ProvisioningError,
                    "invalid certificate activation state",
                ):
                    PROFILE_GENERATOR._find_distribution_certificate(
                        client,
                        CERTIFICATE_DER,
                    )

    def test_ios_distribution_certificate_requires_platform(self) -> None:
        certificate = certificate_resource(
            CERTIFICATE_DER,
            platform=None,
            certificate_type="IOS_DISTRIBUTION",
        )
        client = FakeAppStoreConnectClient([api_collection([certificate])])

        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "not valid for iOS",
        ):
            PROFILE_GENERATOR._find_distribution_certificate(
                client,
                CERTIFICATE_DER,
            )

    def test_distribution_certificate_rejects_invalid_matches(self) -> None:
        cases = (
            (
                "missing",
                [certificate_resource(b"unrelated")],
                "not found uniquely",
            ),
            (
                "ambiguous",
                [
                    certificate_resource(CERTIFICATE_DER, resource_id="first"),
                    certificate_resource(CERTIFICATE_DER, resource_id="second"),
                ],
                "not found uniquely",
            ),
            (
                "inactive",
                [certificate_resource(CERTIFICATE_DER, activated=False)],
                "not active",
            ),
            (
                "expired",
                [
                    certificate_resource(
                        CERTIFICATE_DER,
                        expiration="2000-01-01T00:00:00Z",
                    )
                ],
                "expired",
            ),
            (
                "wrong-platform",
                [certificate_resource(CERTIFICATE_DER, platform="MAC_OS")],
                "not valid for iOS",
            ),
        )
        for label, resources, message in cases:
            with self.subTest(label=label):
                client = FakeAppStoreConnectClient([api_collection(resources)])
                with self.assertRaisesRegex(
                    PROFILE_GENERATOR.ProvisioningError,
                    message,
                ):
                    PROFILE_GENERATOR._find_distribution_certificate(
                        client,
                        CERTIFICATE_DER,
                    )

    def test_share_extension_profile_never_touches_the_icloud_capability(self) -> None:
        profile_bytes = b"\x30" + (b"p" * 255)
        client = FakeAppStoreConnectClient(
            [
                api_collection(
                    [
                        {
                            "type": "bundleIds",
                            "id": "share-bundle-resource",
                            "attributes": {
                                "identifier": SHARE_BUNDLE,
                                "platform": "IOS",
                            },
                        }
                    ]
                ),
                api_collection([app_groups_capability_resource()]),
                api_collection([certificate_resource(CERTIFICATE_DER)]),
                {
                    "data": {
                        "type": "profiles",
                        "id": "share-profile-resource",
                        "attributes": {
                            "name": "Kit Pay Share App Store 123-1",
                            "platform": "IOS",
                            "profileType": "IOS_APP_STORE",
                            "profileState": "ACTIVE",
                            "uuid": SHARE_PROFILE_UUID,
                            "expirationDate": "2999-01-01T00:00:00Z",
                            "profileContent": base64.b64encode(profile_bytes).decode(
                                "ascii"
                            ),
                        },
                    }
                },
            ]
        )

        result = PROFILE_GENERATOR.provision_profile(
            client,
            bundle_id=SHARE_BUNDLE,
            certificate_der=CERTIFICATE_DER,
            profile_name="Kit Pay Share App Store 123-1",
            icloud=False,
        )

        self.assertEqual(result, profile_bytes)
        # The extension has no iCloud capability to enable, and asking to enable one would grant
        # it reach it must never have.
        capability_mutations = [
            call
            for call in client.calls
            if call["method"] != "GET"
            and "bundleIdCapabilities" in str(call["path"])
        ]
        self.assertFalse(capability_mutations)
        self.assertTrue(
            [call for call in client.calls if "bundleIdCapabilities" in str(call["path"])]
        )

    def test_profile_creation_uses_exact_app_store_request(self) -> None:
        profile_bytes = b"\x30" + (b"p" * 255)
        client = FakeAppStoreConnectClient(
            [
                {
                    "data": {
                        "type": "profiles",
                        "id": "profile-resource",
                        "attributes": {
                            "name": "Kit Pay App Store 123-1",
                            "platform": "IOS",
                            "profileType": "IOS_APP_STORE",
                            "profileState": "ACTIVE",
                            "uuid": PROFILE_UUID,
                            "expirationDate": "2999-01-01T00:00:00Z",
                            "profileContent": base64.b64encode(profile_bytes).decode(
                                "ascii"
                            ),
                        },
                    }
                }
            ]
        )

        result = PROFILE_GENERATOR._create_profile(
            client,
            "bundle-resource",
            "certificate-resource",
            "Kit Pay App Store 123-1",
        )

        self.assertEqual(result, profile_bytes)
        self.assertEqual(client.calls[0]["method"], "POST")
        self.assertEqual(client.calls[0]["path"], "/v1/profiles")
        self.assertEqual(client.calls[0]["expected_status"], 201)
        self.assertEqual(
            client.calls[0]["body"],
            {
                "data": {
                    "type": "profiles",
                    "attributes": {
                        "name": "Kit Pay App Store 123-1",
                        "profileType": "IOS_APP_STORE",
                    },
                    "relationships": {
                        "bundleId": {
                            "data": {
                                "type": "bundleIds",
                                "id": "bundle-resource",
                            }
                        },
                        "certificates": {
                            "data": [
                                {
                                    "type": "certificates",
                                    "id": "certificate-resource",
                                }
                            ]
                        },
                    },
                }
            },
        )

    def test_profile_creation_retries_only_propagation_and_transient_statuses(self) -> None:
        profile_bytes = b"\x30" + (b"p" * 255)
        success = {
            "data": {
                "type": "profiles",
                "id": "profile-resource",
                "attributes": {
                    "name": "Kit Pay App Store 123-1",
                    "platform": "IOS",
                    "profileType": "IOS_APP_STORE",
                    "profileState": "ACTIVE",
                    "uuid": PROFILE_UUID,
                    "expirationDate": "2999-01-01T00:00:00Z",
                    "profileContent": base64.b64encode(profile_bytes).decode("ascii"),
                },
            }
        }
        for status in sorted(
            PROFILE_GENERATOR._PROFILE_CREATION_RETRYABLE_HTTP_STATUSES
        ):
            with self.subTest(status=status):
                client = FakeAppStoreConnectClient(
                    [
                        PROFILE_GENERATOR.AppStoreConnectHTTPError(
                            status,
                            "App Store profile creation",
                        ),
                        success,
                    ]
                )
                sleeps: list[float] = []

                result = PROFILE_GENERATOR._create_profile(
                    client,
                    "bundle-resource",
                    "certificate-resource",
                    "Kit Pay App Store 123-1",
                    sleep=sleeps.append,
                )

                self.assertEqual(result, profile_bytes)
                self.assertEqual(sleeps, [1.0])
                self.assertEqual(len(client.calls), 2)

        for status in (400, 401, 403, 404, 422):
            with self.subTest(nonretryable_status=status):
                client = FakeAppStoreConnectClient(
                    [
                        PROFILE_GENERATOR.AppStoreConnectHTTPError(
                            status,
                            "App Store profile creation",
                        )
                    ]
                )
                sleeps = []
                with self.assertRaises(PROFILE_GENERATOR.AppStoreConnectHTTPError):
                    PROFILE_GENERATOR._create_profile(
                        client,
                        "bundle-resource",
                        "certificate-resource",
                        "Kit Pay App Store 123-1",
                        sleep=sleeps.append,
                    )
                self.assertEqual(sleeps, [])
                self.assertEqual(len(client.calls), 1)

    def test_profile_creation_retry_exhaustion_fails_closed(self) -> None:
        status = 409
        client = FakeAppStoreConnectClient(
            [
                PROFILE_GENERATOR.AppStoreConnectHTTPError(
                    status,
                    "App Store profile creation",
                )
                for _ in range(
                    len(PROFILE_GENERATOR._PROFILE_CREATION_RETRY_DELAYS_SECONDS)
                    + 1
                )
            ]
        )
        sleeps: list[float] = []

        with self.assertRaises(PROFILE_GENERATOR.AppStoreConnectHTTPError) as raised:
            PROFILE_GENERATOR._create_profile(
                client,
                "bundle-resource",
                "certificate-resource",
                "Kit Pay App Store 123-1",
                sleep=sleeps.append,
            )

        self.assertEqual(raised.exception.status, status)
        self.assertEqual(
            sleeps,
            list(PROFILE_GENERATOR._PROFILE_CREATION_RETRY_DELAYS_SECONDS),
        )
        self.assertEqual(
            len(client.calls),
            len(PROFILE_GENERATOR._PROFILE_CREATION_RETRY_DELAYS_SECONDS) + 1,
        )

    def test_profile_response_and_output_are_fail_closed(self) -> None:
        malformed_client = FakeAppStoreConnectClient([{"data": []}])
        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "invalid profile resource",
        ):
            PROFILE_GENERATOR._create_profile(
                malformed_client,
                "bundle-resource",
                "certificate-resource",
                "Kit Pay App Store 123-1",
            )

        invalid_content_client = FakeAppStoreConnectClient(
            [
                {
                    "data": {
                        "type": "profiles",
                        "id": "profile-resource",
                        "attributes": {
                            "name": "Kit Pay App Store 123-1",
                            "platform": "IOS",
                            "profileType": "IOS_APP_STORE",
                            "profileState": "ACTIVE",
                            "uuid": PROFILE_UUID,
                            "expirationDate": "2999-01-01T00:00:00Z",
                            "profileContent": base64.b64encode(b"not-cms").decode(
                                "ascii"
                            ),
                        },
                    }
                }
            ]
        )
        with self.assertRaisesRegex(
            PROFILE_GENERATOR.ProvisioningError,
            "invalid provisioning profile content",
        ):
            PROFILE_GENERATOR._create_profile(
                invalid_content_client,
                "bundle-resource",
                "certificate-resource",
                "Kit Pay App Store 123-1",
            )

        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            fresh_output = root / "fresh.mobileprovision"
            PROFILE_GENERATOR._write_private_file(fresh_output, b"profile")
            self.assertEqual(fresh_output.read_bytes(), b"profile")
            self.assertEqual(fresh_output.stat().st_mode & 0o777, 0o600)

            output = root / "profile.mobileprovision"
            output.write_bytes(b"existing")
            with self.assertRaisesRegex(
                PROFILE_GENERATOR.ProvisioningError,
                "Refusing to overwrite",
            ):
                PROFILE_GENERATOR._write_private_file(output, b"replacement")
            self.assertEqual(output.read_bytes(), b"existing")


class SigningConfigurationTests(unittest.TestCase):
    def test_build_30_release_identity_is_consistent(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        project = (ROOT / "KitPay.xcodeproj/project.pbxproj").read_text()

        self.assertIn("default: 1.0.16", workflow)
        self.assertIn('default: "30"', workflow)
        self.assertIn("v1.0.16-build30", workflow)
        # Four each: Debug and Release of the app and of the share extension. iOS refuses to
        # install an app whose extension carries a different version, so they move together.
        self.assertEqual(project.count("MARKETING_VERSION = 1.0.16;"), 4)
        self.assertEqual(project.count("CURRENT_PROJECT_VERSION = 30;"), 4)
        self.assertNotIn("MARKETING_VERSION = 1.0.1;", project)

    def test_message_edit_floor_matches_the_build_that_ships(self) -> None:
        """The edit capability floor names a release; that release has to be this one.

        `MessagingMessageEditCapabilityPolicy` refuses to send a correction to any iOS peer below
        its declared floor. If the floor were left pointing at a build we never cut, every peer
        would fail the test and the feature would be dark; if it pointed below the build that
        first implements `KITEDIT1`, an older client would be handed a descriptor it renders as a
        chat bubble. Pinning it to the project's own version keeps the backend gate honest too,
        since the server maps builds at or above this floor onto the capability.
        """
        project = (ROOT / "KitPay.xcodeproj/project.pbxproj").read_text()
        policy = (ROOT / "KitPay/Core/MessageEditModels.swift").read_text()

        marketing = re.search(r"MARKETING_VERSION = ([\d.]+);", project).group(1)
        build = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", project).group(1)

        self.assertIn(f'static let minimumIOSRelease = "{marketing}-r{build}"', policy)
        self.assertIn(f"static let minimumIOSBuild = {build}", policy)
        expected_version = ", ".join(marketing.split("."))
        self.assertIn(f"static let minimumIOSVersion = [{expected_version}]", policy)

    def test_manual_profile_is_scoped_to_the_app_target(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        project = (ROOT / "KitPay.xcodeproj/project.pbxproj").read_text()

        self.assertIn('KITPAY_PROFILE_UUID="$profile_uuid"', workflow)
        self.assertIn('KITPAY_SHARE_PROFILE_UUID="$share_profile_uuid"', workflow)
        self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER="$profile_uuid"', workflow)
        self.assertIn(
            'PROVISIONING_PROFILE_SPECIFIER = "$(KITPAY_PROFILE_UUID)"',
            project,
        )
        self.assertIn(
            'PROVISIONING_PROFILE_SPECIFIER = "$(KITPAY_SHARE_PROFILE_UUID)"',
            project,
        )
        self.assertIn('DEVELOPMENT_TEAM = "$(KITPAY_APPLE_TEAM_ID)"', project)

    def test_share_extension_is_embedded_and_scoped_to_the_app_group(self) -> None:
        project = (ROOT / "KitPay.xcodeproj/project.pbxproj").read_text()
        with (ROOT / "KitPay/KitPay.entitlements").open("rb") as source:
            app_entitlements = plistlib.load(source)
        with (ROOT / "KitPayShare/KitPayShare.entitlements").open("rb") as source:
            share_entitlements = plistlib.load(source)
        with (ROOT / "KitPayShare/Info.plist").open("rb") as source:
            share_info = plistlib.load(source)

        self.assertIn('productType = "com.apple.product-type.app-extension"', project)
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER = {SHARE_BUNDLE};", project)
        self.assertIn("dstSubfolderSpec = 13", project)
        self.assertIn("Embed Foundation Extensions", project)
        self.assertIn("CODE_SIGN_ENTITLEMENTS = KitPayShare/KitPayShare.entitlements;", project)
        self.assertEqual(project.count("APPLICATION_EXTENSION_API_ONLY = YES;"), 2)
        self.assertIn('--register-bundle-name "Kit Pay Share"', (
            ROOT / ".github/workflows/ios-app-store-archive.yml"
        ).read_text())

        self.assertEqual(app_entitlements.get(APP_GROUP_KEY), [APP_GROUP])
        # The extension's only reach is the app group. Nothing else: no keychain, no iCloud, no
        # push — it stages files and hands off.
        self.assertEqual(share_entitlements, {APP_GROUP_KEY: [APP_GROUP]})
        self.assertEqual(
            share_info["NSExtension"]["NSExtensionPointIdentifier"],
            "com.apple.share-services",
        )

    def test_call_ui_supports_landscape_on_phone_and_tablet(self) -> None:
        with (ROOT / "KitPay/Info.plist").open("rb") as source:
            info = plistlib.load(source)

        phone = set(info.get("UISupportedInterfaceOrientations", []))
        tablet = set(info.get("UISupportedInterfaceOrientations~ipad", []))
        landscape = {
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        }
        self.assertIn("UIInterfaceOrientationPortrait", phone)
        self.assertTrue(landscape <= phone)
        self.assertIn("UIInterfaceOrientationPortrait", tablet)
        self.assertTrue(landscape <= tablet)

    def test_export_compliance_is_exempt_and_code_free(self) -> None:
        with (ROOT / "KitPay/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()

        self.assertIs(info.get("ITSAppUsesNonExemptEncryption"), False)
        self.assertNotIn("ITSEncryptionExportComplianceCode", info)
        self.assertNotIn("export_compliance_code", workflow)

    def test_archive_requires_public_source_release_for_exact_build(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        source_input = workflow.split("      corresponding_source_url:\n", 1)[1].split(
            "\n\n",
            1,
        )[0]

        self.assertIn("required: true", source_input)
        self.assertNotIn("default:", source_input)
        self.assertIn(
            'expected_source_url="https://github.com/kitafrica33/'
            'kit-pay-ios-source/releases/tag/v${MARKETING_VERSION}-build${BUILD_NUMBER}"',
            workflow,
        )
        self.assertIn(
            'test "$CORRESPONDING_SOURCE_URL" = "$expected_source_url"',
            workflow,
        )
        self.assertIn("env -u GITHUB_TOKEN -u GH_TOKEN", workflow)
        self.assertIn("curl --disable", workflow)
        self.assertIn("--header 'Authorization:'", workflow)
        self.assertIn('--corresponding-source-url "$CORRESPONDING_SOURCE_URL"', workflow)

    def test_workflow_generates_ephemeral_profile_with_scoped_credentials(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()

        self.assertNotIn("IOS_APP_STORE_PROVISIONING_PROFILE_BASE64", workflow)
        self.assertIn("IOS_DISTRIBUTION_CERTIFICATE_BASE64", workflow)
        generation_start = workflow.index(
            "      - name: Generate fresh App Store provisioning profile"
        )
        generation_end = workflow.index("\n      - name:", generation_start + 1)
        generation_step = workflow[generation_start:generation_end]
        for secret in (
            "APP_STORE_CONNECT_ISSUER_ID",
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_PRIVATE_KEY",
        ):
            reference = "${{ secrets." + secret + " }}"
            self.assertEqual(workflow.count(reference), 1)
            self.assertIn(reference, generation_step)
        self.assertIn("create_ios_app_store_profile.py", generation_step)
        self.assertIn(
            '--profile-output "$RUNNER_TEMP/kitpay-app-store.mobileprovision"',
            generation_step,
        )
        # The generated app profile, generated extension profile, and final signed archive are
        # each checked against the same exact App Group identifier.
        self.assertEqual(workflow.count('--app-group "$IOS_APP_GROUP"'), 3)
        self.assertIn(
            'security cms -D \\\n            -i "$RUNNER_TEMP/kitpay-app-store.mobileprovision"',
            workflow,
        )
        self.assertIn(
            'rm -f \\\n            "$RUNNER_TEMP/kitpay-distribution.p12"',
            workflow,
        )
        self.assertIn('"$RUNNER_TEMP/kitpay-app-store.mobileprovision"', workflow)
        self.assertIn("distinct CloudKit management token", workflow)

    def test_source_entitlements_leave_icloud_environment_to_signing(self) -> None:
        with (ROOT / "KitPay/KitPay.entitlements").open("rb") as source:
            entitlements = plistlib.load(source)

        self.assertNotIn(ICLOUD_ENVIRONMENT_KEY, entitlements)


class CloudKitSchemaTests(unittest.TestCase):
    def test_schema_has_exact_fields_and_least_privilege_grants(self) -> None:
        schema = CLOUDKIT_SCHEMA.read_text(encoding="utf-8")
        self.assertEqual(
            schema,
            """DEFINE SCHEMA
  RECORD TYPE KitMessageBackup (
    payload ASSET,
    createdAt TIMESTAMP,
    newestMessageAt TIMESTAMP,
    byteSize INT64,
    messageCount INT64,
    schemaVersion INT64,
    generation INT64,
    deviceName STRING,
    contentDigest STRING,
    GRANT WRITE TO \"_creator\",
    GRANT CREATE TO \"_icloud\",
    GRANT READ TO \"_creator\"
  );
""",
        )
        self.assertNotIn('"_world"', schema)
        self.assertNotIn('GRANT READ TO "_icloud"', schema)
        self.assertNotIn('GRANT WRITE TO "_icloud"', schema)
        self.assertNotIn("ENCRYPTED", schema)

        manager = (ROOT / "KitPay/Core/MessageBackupManager.swift").read_text(
            encoding="utf-8"
        )
        field_block = manager.split("private enum Field {", 1)[1].split("}", 1)[0]
        manager_fields = dict(
            re.findall(r'static let ([A-Za-z0-9_]+) = "([A-Za-z0-9_]+)"', field_block)
        )
        expected_fields = {
            "payload",
            "createdAt",
            "newestMessageAt",
            "byteSize",
            "messageCount",
            "schemaVersion",
            "generation",
            "deviceName",
            "contentDigest",
        }
        self.assertEqual(set(manager_fields), expected_fields)
        self.assertEqual(set(manager_fields.values()), expected_fields)

    def test_default_helper_is_local_validation_only(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CLOUDKIT_HELPER)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no remote action was taken", result.stdout)

    def test_explicit_development_import_validates_then_imports(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            capture = root / "cktool-arguments"
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/sh\n"
                "printf 'CALL\\n' >> \"$CKTOOL_CAPTURE\"\n"
                "printf '%s\\n' \"$@\" >> \"$CKTOOL_CAPTURE\"\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o700)
            environment = os.environ.copy()
            environment["PATH"] = str(root)
            environment["CKTOOL_CAPTURE"] = str(capture)
            environment.pop("CLOUDKIT_MANAGEMENT_TOKEN", None)

            result = subprocess.run(
                [
                    sys.executable,
                    str(CLOUDKIT_HELPER),
                    "--import-development",
                    "--team-id",
                    CLOUDKIT_TEAM,
                    "--container-id",
                    ICLOUD_CONTAINER,
                    "--environment",
                    "development",
                    "--confirmation",
                    "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
                    "--use-saved-management-token",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("promote it to production from CloudKit Console", result.stdout)
            calls = [
                section.strip().splitlines()
                for section in capture.read_text(encoding="utf-8").split("CALL\n")
                if section.strip()
            ]
            self.assertEqual(len(calls), 2)
            self.assertEqual(
                [call[:2] for call in calls],
                [["cktool", "validate-schema"], ["cktool", "import-schema"]],
            )
            for call in calls:
                self.assertIn("--team-id", call)
                self.assertIn(CLOUDKIT_TEAM, call)
                self.assertIn("--container-id", call)
                self.assertIn(ICLOUD_CONTAINER, call)
                self.assertIn("--environment", call)
                self.assertIn("development", call)
                self.assertNotIn("production", call)
                self.assertNotIn("reset-schema", call)

    def test_remote_import_rejects_wrong_environment_or_confirmation(self) -> None:
        helper_source = CLOUDKIT_HELPER.read_text(encoding="utf-8")
        self.assertNotIn('"reset-schema"', helper_source)
        self.assertNotIn('"deploy-schema"', helper_source)
        self.assertNotIn("--import-production", helper_source)
        self.assertNotIn("IMPORT_KIT_PAY_CLOUDKIT_PRODUCTION", helper_source)

        common = [
            sys.executable,
            str(CLOUDKIT_HELPER),
            "--team-id",
            CLOUDKIT_TEAM,
            "--container-id",
            ICLOUD_CONTAINER,
            "--use-saved-management-token",
        ]
        cases = (
            (
                [
                    "--import-development",
                    "--environment",
                    "production",
                    "--confirmation",
                    "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
                ],
                "must exactly match",
            ),
            (
                [
                    "--import-development",
                    "--environment",
                    "development",
                    "--confirmation",
                    "UNCONFIRMED_CLOUDKIT_IMPORT",
                ],
                "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
            ),
            (
                [
                    "--import-development",
                    "--environment",
                    "development",
                    "--confirmation",
                    "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
                    "--team-id",
                    TEAM,
                ],
                f"--team-id must be exactly {CLOUDKIT_TEAM}",
            ),
            (
                [
                    "--import-development",
                    "--environment",
                    "development",
                    "--confirmation",
                    "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
                    "--container-id",
                    "iCloud.invalid.example",
                ],
                f"--container-id must be exactly {ICLOUD_CONTAINER}",
            ),
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [*common, *arguments],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

        no_token = subprocess.run(
            [
                sys.executable,
                str(CLOUDKIT_HELPER),
                "--import-development",
                "--team-id",
                CLOUDKIT_TEAM,
                "--container-id",
                ICLOUD_CONTAINER,
                "--environment",
                "development",
                "--confirmation",
                "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
            ],
            check=False,
            capture_output=True,
            text=True,
            env={key: value for key, value in os.environ.items() if key != "CLOUDKIT_MANAGEMENT_TOKEN"},
        )
        self.assertNotEqual(no_token.returncode, 0)
        self.assertIn("CLOUDKIT_MANAGEMENT_TOKEN", no_token.stderr)

    def test_production_import_is_not_an_available_operation(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CLOUDKIT_HELPER), "--import-production"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized arguments: --import-production", result.stderr)

    def test_cloudkit_management_token_is_not_logged_on_cktool_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" >&2\nexit 1\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o700)
            token = "synthetic-secret-cloudkit-management-token"
            environment = os.environ.copy()
            environment["PATH"] = str(root)
            environment["CLOUDKIT_MANAGEMENT_TOKEN"] = token
            result = subprocess.run(
                [
                    sys.executable,
                    str(CLOUDKIT_HELPER),
                    "--import-development",
                    "--team-id",
                    CLOUDKIT_TEAM,
                    "--container-id",
                    ICLOUD_CONTAINER,
                    "--environment",
                    "development",
                    "--confirmation",
                    "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(token, result.stdout)
            self.assertNotIn(token, result.stderr)
            self.assertIn("no command output or token was logged", result.stderr)


class VerifyIOSArchiveTests(unittest.TestCase):
    def test_verifies_identity_and_records_artifact_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            app = root / "KitPay.app"
            app.mkdir()
            (app / EXECUTABLE).write_bytes(b"synthetic-mach-o")
            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleExecutable": EXECUTABLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "KitCorrespondingSourceURL": SOURCE_URL,
                    "ITSAppUsesNonExemptEncryption": False,
                },
            )
            write_plist(
                app / "PrivacyInfo.xcprivacy",
                {
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType":
                                "NSPrivacyAccessedAPICategoryUserDefaults",
                            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                        }
                    ]
                },
            )
            extension_path = app / "PlugIns" / "KitPayShare.appex"
            extension_path.mkdir(parents=True)
            write_plist(
                extension_path / "Info.plist",
                {
                    "CFBundleIdentifier": SHARE_BUNDLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": "com.apple.share-services",
                    },
                },
            )
            extension_embedded = root / "share-embedded.plist"
            extension_signed = root / "share-signed.plist"
            write_plist(extension_embedded, share_profile())
            write_plist(
                extension_signed,
                {
                    "application-identifier": f"{TEAM}.{SHARE_BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "get-task-allow": False,
                    APP_GROUP_KEY: [APP_GROUP],
                },
            )
            embedded = root / "embedded.plist"
            signed = root / "signed.plist"
            write_plist(embedded, profile())
            write_plist(
                signed,
                {
                    "application-identifier": f"{TEAM}.{BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "aps-environment": "production",
                    "get-task-allow": False,
                    "com.apple.developer.icloud-container-identifiers": [
                        ICLOUD_CONTAINER
                    ],
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    ICLOUD_ENVIRONMENT_KEY: "Production",
                    APP_GROUP_KEY: [APP_GROUP],
                },
            )
            artifacts = []
            for filename, payload in (
                ("KitPay.ipa", b"ipa"),
                ("KitPay.xcarchive.zip", b"archive"),
                ("KitPay.dSYMs.zip", b"symbols"),
            ):
                path = root / filename
                path.write_bytes(payload)
                artifacts.append(path)
            evidence = root / "evidence.json"

            command = [
                "python3",
                str(VERIFY),
                "--app",
                str(app),
                "--embedded-profile-plist",
                str(embedded),
                "--signed-entitlements-plist",
                str(signed),
                "--expected-profile-uuid",
                PROFILE_UUID,
                "--bundle-id",
                BUNDLE,
                "--team-id",
                TEAM,
                "--extension",
                str(extension_path),
                "--extension-bundle-id",
                SHARE_BUNDLE,
                "--extension-profile-plist",
                str(extension_embedded),
                "--extension-entitlements-plist",
                str(extension_signed),
                "--expected-extension-profile-uuid",
                SHARE_PROFILE_UUID,
                "--app-group",
                APP_GROUP,
                "--version",
                "1.2.3",
                "--build-number",
                "42",
                "--corresponding-source-url",
                SOURCE_URL,
                "--ipa",
                str(artifacts[0]),
                "--archive-zip",
                str(artifacts[1]),
                "--dsym-zip",
                str(artifacts[2]),
                "--evidence",
                str(evidence),
                "--source-commit",
                "a" * 40,
                "--run-id",
                "123",
                "--run-attempt",
                "1",
            ]
            subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )

            result = json.loads(evidence.read_text(encoding="utf-8"))
            self.assertEqual(result["target"]["bundleId"], BUNDLE)
            self.assertEqual(result["target"]["correspondingSourceURL"], SOURCE_URL)
            self.assertIs(result["target"]["usesNonExemptEncryption"], False)
            self.assertEqual(result["target"]["iCloudContainer"], ICLOUD_CONTAINER)
            self.assertEqual(
                result["artifacts"]["ipa"]["sha256"],
                hashlib.sha256(b"ipa").hexdigest(),
            )

            app_profile_without_group = profile()
            app_profile_without_group["Entitlements"].pop(APP_GROUP_KEY)
            write_plist(embedded, app_profile_without_group)
            missing_app_profile_group = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_app_profile_group.returncode, 0)
            self.assertIn(
                "Embedded profile must authorize exactly the Kit Pay app group",
                missing_app_profile_group.stderr,
            )
            write_plist(embedded, profile())

            apple_generated_profile = profile()
            apple_generated_profile["Entitlements"][
                "com.apple.developer.icloud-services"
            ] = "*"
            apple_generated_profile["Entitlements"][ICLOUD_ENVIRONMENT_KEY] = [
                "Production",
                "Development",
            ]
            write_plist(embedded, apple_generated_profile)
            wildcard_profile = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(wildcard_profile.returncode, 0, wildcard_profile.stderr)

            list_profile = profile()
            list_profile["Entitlements"][
                "com.apple.developer.icloud-services"
            ] = ["CloudKit", "CloudDocuments"]
            write_plist(embedded, list_profile)
            service_list_profile = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                service_list_profile.returncode,
                0,
                service_list_profile.stderr,
            )

            production_list_profile = profile()
            production_list_profile["Entitlements"][ICLOUD_ENVIRONMENT_KEY] = [
                "Production"
            ]
            write_plist(embedded, production_list_profile)
            single_environment_profile = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                single_environment_profile.returncode,
                0,
                single_environment_profile.stderr,
            )

            invalid_profile = profile()
            invalid_profile["Entitlements"].pop(
                "com.apple.developer.icloud-services"
            )
            write_plist(embedded, invalid_profile)
            missing_profile_service = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_profile_service.returncode, 0)
            self.assertIn(
                "Embedded profile does not authorize CloudKit",
                missing_profile_service.stderr,
            )

            invalid_service_values = (
                ("scalar-cloudkit", "CloudKit"),
                ("wildcard-list", ["*"]),
                ("empty-list", []),
                ("nonstring-list", ["CloudKit", 1]),
                ("list-without-cloudkit", ["CloudDocuments"]),
            )
            for label, value in invalid_service_values:
                with self.subTest(embedded_service=label):
                    invalid_profile = profile()
                    invalid_profile["Entitlements"][
                        "com.apple.developer.icloud-services"
                    ] = value
                    write_plist(embedded, invalid_profile)
                    invalid_profile_service = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(invalid_profile_service.returncode, 0)
                    self.assertIn(
                        "Embedded profile does not authorize CloudKit",
                        invalid_profile_service.stderr,
                    )

            invalid_profile = profile()
            invalid_profile["Entitlements"].pop(ICLOUD_ENVIRONMENT_KEY)
            write_plist(embedded, invalid_profile)
            missing_profile_environment = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_profile_environment.returncode, 0)
            self.assertIn(
                "Embedded profile does not authorize the Production iCloud environment",
                missing_profile_environment.stderr,
            )

            invalid_environment_values = (
                ("scalar-development", "Development"),
                ("development-only-list", ["Development"]),
                ("wildcard", "*"),
                ("empty-list", []),
                ("nonstring-list", ["Production", 1]),
                ("unknown-value", ["Production", "Staging"]),
                ("duplicate-value", ["Production", "Production"]),
            )
            for label, value in invalid_environment_values:
                with self.subTest(embedded_environment=label):
                    invalid_profile = profile()
                    invalid_profile["Entitlements"][ICLOUD_ENVIRONMENT_KEY] = value
                    write_plist(embedded, invalid_profile)
                    invalid_profile_environment = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(invalid_profile_environment.returncode, 0)
                    self.assertIn(
                        "Embedded profile does not authorize the Production iCloud environment",
                        invalid_profile_environment.stderr,
                    )
            write_plist(embedded, profile())

            with signed.open("rb") as source:
                signed_entitlements = plistlib.load(source)
            signed_entitlements[ICLOUD_ENVIRONMENT_KEY] = "Development"
            write_plist(signed, signed_entitlements)
            wrong_signed_environment = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(wrong_signed_environment.returncode, 0)
            self.assertIn(
                "Signed app iCloud environment entitlement is not Production",
                wrong_signed_environment.stderr,
            )
            signed_entitlements[ICLOUD_ENVIRONMENT_KEY] = "Production"
            write_plist(signed, signed_entitlements)

            signed_entitlements["com.apple.developer.icloud-services"] = [
                "CloudKit",
                "CloudDocuments",
            ]
            write_plist(signed, signed_entitlements)
            nonexact_signed_service = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(nonexact_signed_service.returncode, 0)
            self.assertIn(
                "Signed app CloudKit service entitlement is not exact",
                nonexact_signed_service.stderr,
            )
            signed_entitlements["com.apple.developer.icloud-services"] = ["CloudKit"]
            signed_entitlements[ICLOUD_ENVIRONMENT_KEY] = [
                "Production",
                "Development",
            ]
            write_plist(signed, signed_entitlements)
            nonexact_signed_environment = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(nonexact_signed_environment.returncode, 0)
            self.assertIn(
                "Signed app iCloud environment entitlement is not Production",
                nonexact_signed_environment.stderr,
            )
            signed_entitlements[ICLOUD_ENVIRONMENT_KEY] = "Production"
            write_plist(signed, signed_entitlements)

            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleExecutable": EXECUTABLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "KitCorrespondingSourceURL": SOURCE_URL,
                    "ITSAppUsesNonExemptEncryption": True,
                },
            )
            nonexempt_encryption = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(nonexempt_encryption.returncode, 0)
            self.assertIn("reviewed exempt encryption", nonexempt_encryption.stderr)

            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleExecutable": EXECUTABLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "KitCorrespondingSourceURL": SOURCE_URL,
                    "ITSAppUsesNonExemptEncryption": False,
                    "UIBackgroundModes": ["processing"],
                },
            )
            missing_task_identifiers = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_task_identifiers.returncode, 0)
            self.assertIn(
                "BGTaskSchedulerPermittedIdentifiers",
                missing_task_identifiers.stderr,
            )

            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleExecutable": EXECUTABLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "KitCorrespondingSourceURL": SOURCE_URL,
                    "ITSAppUsesNonExemptEncryption": False,
                },
            )

            mismatched_source_argument = command.copy()
            source_argument = mismatched_source_argument.index(
                "--corresponding-source-url"
            ) + 1
            mismatched_source_argument[source_argument] = SOURCE_URL + "/"
            wrong_argument = subprocess.run(
                mismatched_source_argument,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(wrong_argument.returncode, 0)
            self.assertIn("does not match the release identity", wrong_argument.stderr)

            info = {
                "CFBundleIdentifier": BUNDLE,
                "CFBundleExecutable": EXECUTABLE,
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "42",
                "KitCorrespondingSourceURL": SOURCE_URL + "/",
                "ITSAppUsesNonExemptEncryption": False,
            }
            write_plist(app / "Info.plist", info)
            wrong_signed_url = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(wrong_signed_url.returncode, 0)
            self.assertIn(
                "Unexpected signed corresponding-source URL",
                wrong_signed_url.stderr,
            )

            info["KitCorrespondingSourceURL"] = SOURCE_URL
            write_plist(app / "Info.plist", info)

            (app / EXECUTABLE).write_bytes(
                b"prefix-KITPAY_APP_STORE_SCREENSHOT_FIXTURE_V1-suffix"
            )
            fixture_in_release = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(fixture_in_release.returncode, 0)
            self.assertIn(
                "forbidden App Store screenshot fixture",
                fixture_in_release.stderr,
            )
            (app / EXECUTABLE).write_bytes(b"synthetic-mach-o")

            write_plist(
                signed,
                {
                    "application-identifier": f"{TEAM}.{BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "aps-environment": "production",
                    "com.apple.developer.icloud-container-identifiers": [
                        ICLOUD_CONTAINER
                    ],
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    ICLOUD_ENVIRONMENT_KEY: "Production",
                },
            )
            missing_debug_restriction = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_debug_restriction.returncode, 0)
            self.assertIn("explicitly prohibit debugging", missing_debug_restriction.stderr)


if __name__ == "__main__":
    unittest.main()
