from __future__ import annotations

import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
PREPARE = ROOT / ".github/scripts/prepare_ios_signing.py"
VERIFY = ROOT / ".github/scripts/verify_ios_archive.py"
TEAM = "A1B2C3D4E5"
BUNDLE = "africa.kit.pay.ios"
PROFILE_UUID = "11111111-2222-3333-4444-555555555555"
CERTIFICATE_DER = b"synthetic-distribution-certificate"


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
        },
    }


class PrepareIOSSigningTests(unittest.TestCase):
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


class SigningConfigurationTests(unittest.TestCase):
    def test_manual_profile_is_scoped_to_the_app_target(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        project = (ROOT / "KitPay.xcodeproj/project.pbxproj").read_text()

        self.assertIn('KITPAY_PROFILE_UUID="$profile_uuid"', workflow)
        self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER="$profile_uuid"', workflow)
        self.assertIn(
            'PROVISIONING_PROFILE_SPECIFIER = "$(KITPAY_PROFILE_UUID)"',
            project,
        )
        self.assertIn('DEVELOPMENT_TEAM = "$(KITPAY_APPLE_TEAM_ID)"', project)

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


class VerifyIOSArchiveTests(unittest.TestCase):
    def test_verifies_identity_and_records_artifact_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            app = root / "KitPay.app"
            app.mkdir()
            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
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
                "--version",
                "1.2.3",
                "--build-number",
                "42",
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
            self.assertIs(result["target"]["usesNonExemptEncryption"], False)
            self.assertEqual(
                result["artifacts"]["ipa"]["sha256"],
                hashlib.sha256(b"ipa").hexdigest(),
            )

            write_plist(
                app / "Info.plist",
                {
                    "CFBundleIdentifier": BUNDLE,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
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
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
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
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                    "ITSAppUsesNonExemptEncryption": False,
                },
            )

            write_plist(
                signed,
                {
                    "application-identifier": f"{TEAM}.{BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "aps-environment": "production",
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
