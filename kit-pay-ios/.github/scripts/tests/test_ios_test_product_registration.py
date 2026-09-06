import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ios_native_test_fixture import write_native_products


SPEC = importlib.util.spec_from_file_location(
    "ios_test_products", Path(__file__).resolve().parents[1] / "prepare_ios_test_products.py")
PRODUCTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCTS)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.generated, self.plan = write_native_products(self.root)
        self.apps = {}
        for identifier in PRODUCTS.PRODUCTS.values():
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
        return PRODUCTS.prepare("fixture-device", self.root)

    def run_registration(self):
        return PRODUCTS.register_after_first_native(
            "fixture-device", self.root, clock=lambda: self.now, pause=self.pause)

    def read_receipt(self):
        return json.loads(PRODUCTS.receipt_path("fixture-device", self.root).read_text())

    def test_preparation_only_validates_products_and_records_xcodebuild_ownership(self):
        with patch.object(PRODUCTS, "checked") as checked:
            result = self.run_prepare()
        checked.assert_not_called()
        self.assertEqual(result["phase"], "prepared")
        self.assertEqual(result["installationOwner"], "xcodebuild")
        self.assertEqual(len(result["products"]), 4)
        self.assertTrue(all(product["executable"] == "fixture" for product in result["products"]))
        self.assertEqual(result["observations"], [])
        self.assertFalse(result["installedApplicationsVisible"])
        self.assertFalse(result["frontBoardReadinessProven"])
        self.assertNotIn("contactsPermissionGranted", result)
        self.assertNotIn("installs", result)
        self.assertNotIn("testInvocations", result)

    def test_registration_can_lag_without_installing_or_starting_tests(self):
        self.run_prepare()
        self.listings = [{}, self.apps]
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            result = self.run_registration()
        self.assertEqual(len(result["observations"]), 2)
        self.assertEqual(result["phase"], "contacts-ready")
        self.assertTrue(result["installedApplicationsVisible"])
        self.assertTrue(result["contactsPermissionGranted"])
        self.assertEqual(self.calls[-1][2:], ["privacy", "fixture-device", "grant", "contacts", "africa.kit.pay.ios"])
        self.assertFalse(result["frontBoardReadinessProven"])
        verbs = {call[2] for call in self.calls if call[0] == "xcrun"}
        self.assertEqual(verbs, {"listapps", "get_app_container", "privacy"})
        self.assertFalse(any("launch" in call or "xcodebuild" in call for call in self.calls))

    def test_wrong_product_identity_stops_before_any_platform_command(self):
        info = self.root / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator/KitPay.app/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app"}))
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_prepare()
        checked.assert_not_called()
        self.assertEqual(self.read_receipt()["phase"], "preparation-failed")

    def test_embedded_unit_and_ui_test_identity_is_verified(self):
        for relative in ("KitPay.app/PlugIns/KitPayTests.xctest",
                         "KitPayUITests-Runner.app/PlugIns/KitPayUITests.xctest"):
            info = self.generated.parent / "Debug-iphonesimulator" / relative / "Info.plist"
            original = info.read_bytes()
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.test"}))
            with self.subTest(bundle=relative), patch.object(PRODUCTS, "checked") as checked:
                with self.assertRaises(RuntimeError):
                    PRODUCTS.validate(self.root)
                checked.assert_not_called()
            info.write_bytes(original)

    def test_generated_plan_and_all_unrelated_fields_remain_byte_identical(self):
        original = self.generated.read_bytes()
        previous = self.generated.stat().st_mtime_ns
        result = self.run_prepare()
        configuration = result["testRunConfiguration"]
        self.assertEqual(set(configuration), {"generatedPath", "generatedSHA256", "targets"})
        self.assertEqual(configuration["generatedPath"], str(self.generated))
        self.assertEqual(configuration["generatedSHA256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(self.generated.read_bytes(), original)
        self.assertEqual(self.generated.stat().st_mtime_ns, previous)
        self.assertEqual(plistlib.loads(original), self.plan)
        self.assertEqual(list(self.generated.parent.glob("*.xctestrun")), [self.generated])
        for name, target in configuration["targets"].items():
            self.assertIs(target["UseDestinationArtifacts"], False)
            self.assertTrue(target["TestBundlePath"].endswith("/PlugIns/" + name + ".xctest"))
            self.assertNotIn("TestBundleDestinationRelativePath", target)

    def test_repeated_preparation_for_one_device_is_rejected_without_platform_work(self):
        with patch.object(PRODUCTS, "checked") as checked:
            self.run_prepare()
            with self.assertRaises(FileExistsError):
                self.run_prepare()
        checked.assert_not_called()

    def test_generated_executable_host_paths_keep_testhost_based_at_the_app(self):
        for target in self.plan["TestConfigurations"][0]["TestTargets"]:
            target["TestHostPath"] += "/fixture"
        original = plistlib.dumps(self.plan)
        self.generated.write_bytes(original)
        result = self.run_prepare()
        self.assertEqual(self.generated.read_bytes(), original)
        for name, target in result["testRunConfiguration"]["targets"].items():
            self.assertTrue(target["TestHostPath"].endswith(".app/fixture"))
            self.assertTrue(target["TestBundlePath"].endswith(".app/PlugIns/" + name + ".xctest"))

    def test_marketing_validation_reuses_original_bytes_without_receipt_or_platform_work(self):
        original = self.generated.read_bytes()
        previous = self.generated.stat().st_mtime_ns
        with patch.object(PRODUCTS, "checked") as checked:
            first = PRODUCTS.validate(self.root)
            second = PRODUCTS.validate(self.root)
        checked.assert_not_called()
        self.assertEqual(first, second)
        self.assertEqual(self.generated.read_bytes(), original)
        self.assertEqual(self.generated.stat().st_mtime_ns, previous)
        self.assertEqual(list(self.root.glob("KitPay-test-product-registration-*.json")), [])

    def test_ambiguous_generated_plan_stops_before_platform_work(self):
        self.generated.with_name("another.xctestrun").write_bytes(self.generated.read_bytes())
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_prepare()
        checked.assert_not_called()

    def test_changed_generated_plan_cannot_reach_registration_or_be_overwritten(self):
        self.run_prepare()
        self.plan["TestPlan"]["Name"] = "changed after the first invocation"
        changed = plistlib.dumps(self.plan)
        self.generated.write_bytes(changed)
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaisesRegex(RuntimeError, "changed"):
            self.run_registration()
        checked.assert_not_called()
        self.assertEqual(self.generated.read_bytes(), changed)
        self.assertEqual(self.read_receipt()["phase"], "registration-failed")

    def test_generated_configuration_rejects_wrong_scope_and_bindings(self):
        cases = []
        value = copy.deepcopy(self.plan)
        value["__xctestrun_metadata__"]["FormatVersion"] = 1
        cases.append(value)
        value = copy.deepcopy(self.plan)
        value["TestConfigurations"].append(copy.deepcopy(value["TestConfigurations"][0]))
        cases.append(value)
        value = copy.deepcopy(self.plan)
        value["TestConfigurations"][0]["IsEnabled"] = False
        cases.append(value)
        for key, replacement in (("BlueprintName", "AnotherTarget"),
                                 ("TestHostPath", "__TESTROOT__/other.app"),
                                 ("TestHostPath", "__TESTROOT__/Debug-iphonesimulator/KitPay.app/wrong-executable"),
                                 ("TestBundlePath", "__TESTHOST__/PlugIns/other.xctest"),
                                 ("UITargetAppPath", "__TESTROOT__/other.app"),
                                 ("TestHostBundleIdentifier", "another.app"),
                                 ("UITargetAppBundleIdentifier", "another.app"),
                                 ("TestingEnvironmentVariables", None),
                                 ("TestingEnvironmentVariables", {"NOT_A_STRING": 1}),
                                 ("UseDestinationArtifacts", True),
                                 ("UseDestinationArtifacts", 1),
                                 ("UseDestinationArtifacts", "false")):
            value = copy.deepcopy(self.plan)
            target = value["TestConfigurations"][0]["TestTargets"][0]
            if replacement is None:
                target.pop(key)
            else:
                target[key] = replacement
            cases.append(value)
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.generated.write_bytes(plistlib.dumps(value))
                with self.assertRaises(RuntimeError):
                    PRODUCTS.validate(self.root)
                self.assertEqual(list(self.generated.parent.glob("*.xctestrun")), [self.generated])

    def test_unit_target_ui_app_path_is_optional_but_ui_target_path_is_required(self):
        self.plan["TestConfigurations"][0]["TestTargets"][0].pop("UITargetAppPath")
        self.generated.write_bytes(plistlib.dumps(self.plan))
        _, configuration = PRODUCTS.validate(self.root)
        self.assertNotIn("UITargetAppPath", configuration["targets"]["KitPayTests"])
        self.plan["TestConfigurations"][0]["TestTargets"][1].pop("UITargetAppPath")
        self.generated.write_bytes(plistlib.dumps(self.plan))
        with self.assertRaises(RuntimeError):
            PRODUCTS.validate(self.root)

    def test_registration_requires_preparation_before_any_platform_command(self):
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_registration()
        checked.assert_not_called()

    def test_completed_registration_cannot_grant_contacts_twice(self):
        self.run_prepare()
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            self.run_registration()
            count = len(self.calls)
            with self.assertRaises(RuntimeError):
                self.run_registration()
        self.assertEqual(len(self.calls), count)

    def test_registration_deadline_stops_and_retains_failed_visibility(self):
        self.run_prepare()
        self.apps = {}
        with patch.object(PRODUCTS, "checked", side_effect=self.checked), self.assertRaisesRegex(RuntimeError, "30"):
            self.run_registration()
        result = self.read_receipt()
        self.assertEqual(result["phase"], "registration-failed")
        self.assertFalse(result["installedApplicationsVisible"])
        self.assertNotIn("contactsPermissionGranted", result)
        self.assertLessEqual(self.now, 30)

    def test_container_mismatch_cannot_pass_visibility_or_grant_contacts(self):
        self.run_prepare()
        for value in self.apps.values():
            value["Path"] = "/wrong/app/location"
        with patch.object(PRODUCTS, "checked", side_effect=self.checked), self.assertRaises(RuntimeError):
            self.run_registration()
        self.assertFalse(any("privacy" in call for call in self.calls))

    def test_contacts_failure_is_retained_and_cannot_be_retried(self):
        self.run_prepare()

        def deny_contacts(arguments, **kwargs):
            result = self.checked(arguments, **kwargs)
            if arguments[0] == "xcrun" and arguments[2] == "privacy":
                raise subprocess.CalledProcessError(1, arguments, stderr=b"Contacts grant was denied")
            return result

        with patch.object(PRODUCTS, "checked", side_effect=deny_contacts):
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_registration()
            count = len(self.calls)
            with self.assertRaises(RuntimeError):
                self.run_registration()
        self.assertEqual(len(self.calls), count)
        result = self.read_receipt()
        self.assertEqual(result["phase"], "registration-failed")
        self.assertEqual(result["failure"]["stderr"], "Contacts grant was denied")
        self.assertNotIn("contactsPermissionGranted", result)

    def test_command_timeout_keeps_bounded_platform_diagnostics(self):
        self.run_prepare()
        with patch.object(PRODUCTS, "checked", side_effect=subprocess.TimeoutExpired(
                ["xcrun", "simctl", "listapps"], 10, stderr=b"x" * 5000)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run_registration()
        result = self.read_receipt()
        self.assertEqual(result["failure"]["timeoutSeconds"], 10)
        self.assertEqual(len(result["failure"]["stderr"]), 4096)
        self.assertEqual(result["phase"], "registration-failed")


if __name__ == "__main__":
    unittest.main()
