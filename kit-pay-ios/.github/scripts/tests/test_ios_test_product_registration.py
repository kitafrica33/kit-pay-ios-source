import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "ios_test_products", Path(__file__).resolve().parents[1] / "install_ios_test_products.py")
PRODUCTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCTS)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apps = {}
        for name, identifier in PRODUCTS.PRODUCTS.items():
            bundle = self.root / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator" / name
            bundle.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            }))
            (bundle / "fixture").write_bytes(b"fixture")
            self.apps[identifier] = {"CFBundleIdentifier": identifier, "ApplicationType": "User",
                                     "Path": str(self.root / "installed" / identifier)}
        self.calls = []
        self.now = 0
        self.listings = []

    def checked(self, arguments, *, data=None, timeout=90):
        self.calls.append(arguments)
        if arguments[0] == "plutil":
            return data
        if arguments[2] == "listapps":
            return json.dumps(self.listings.pop(0) if self.listings else self.apps).encode()
        if arguments[2] == "get_app_container":
            return str(self.root / "installed" / arguments[4]).encode()
        return b""

    def pause(self, interval):
        self.now += interval

    def run_prepare(self):
        return PRODUCTS.prepare("fixture-device", self.root, clock=lambda: self.now, pause=self.pause)

    def test_registration_can_lag_without_reinstalling_or_starting_tests(self):
        self.listings = [{}, self.apps]
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            result = self.run_prepare()
        self.assertEqual([call[2] for call in self.calls if call[0] == "xcrun"].count("install"), 2)
        self.assertEqual(len(result["observations"]), 2)
        self.assertTrue(result["installedApplicationsVisible"])
        self.assertTrue(result["contactsPermissionGranted"])
        self.assertEqual(self.calls[-1][2:], ["privacy", "fixture-device", "grant", "contacts", "africa.kit.pay.ios"])
        self.assertFalse(result["frontBoardReadinessProven"])
        self.assertFalse(any("launch" in call or "xcodebuild" in call for call in self.calls))

    def test_wrong_product_identity_stops_before_installation(self):
        info = self.root / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator/KitPay.app/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app"}))
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_prepare()
        checked.assert_not_called()

    def test_registration_deadline_stops_and_retains_failed_visibility(self):
        self.apps = {}
        with patch.object(PRODUCTS, "checked", side_effect=self.checked), self.assertRaisesRegex(RuntimeError, "30"):
            self.run_prepare()
        self.assertEqual([call[2] for call in self.calls if call[0] == "xcrun"].count("install"), 2)
        result = json.loads((self.root / "KitPay-test-product-registration-fixture-device.json").read_text())
        self.assertFalse(result["installedApplicationsVisible"])
        self.assertLessEqual(self.now, 30)

    def test_container_mismatch_cannot_pass_visibility_guard(self):
        for value in self.apps.values():
            value["Path"] = "/wrong/app/location"
        with patch.object(PRODUCTS, "checked", side_effect=self.checked), self.assertRaises(RuntimeError):
            self.run_prepare()

    def test_install_failure_stops_without_a_second_install_or_test_invocation(self):
        with patch.object(PRODUCTS, "checked", side_effect=subprocess.CalledProcessError(
                1, ["xcrun"], stderr=b"Simulator installation was denied")) as checked:
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_prepare()
        self.assertEqual(checked.call_count, 1)
        result = json.loads((self.root / "KitPay-test-product-registration-fixture-device.json").read_text())
        self.assertEqual(result["installs"], [])
        self.assertEqual(result["testInvocations"], 0)
        self.assertEqual(result["failure"]["stderr"], "Simulator installation was denied")

    def test_command_timeout_keeps_bounded_platform_diagnostics(self):
        with patch.object(PRODUCTS, "checked", side_effect=subprocess.TimeoutExpired(
                ["xcrun", "simctl", "install"], 90, stderr=b"x" * 5000)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run_prepare()
        result = json.loads((self.root / "KitPay-test-product-registration-fixture-device.json").read_text())
        self.assertEqual(result["failure"]["timeoutSeconds"], 90)
        self.assertEqual(len(result["failure"]["stderr"]), 4096)
        self.assertEqual(result["testInvocations"], 0)


if __name__ == "__main__":
    unittest.main()
