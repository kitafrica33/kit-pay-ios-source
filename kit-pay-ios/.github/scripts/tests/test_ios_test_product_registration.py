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
    "ios_test_products", Path(__file__).resolve().parents[1] / "install_ios_test_products.py")
PRODUCTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCTS)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.generated, self.plan = write_native_products(self.root)
        self.apps = {}
        for name, identifier in PRODUCTS.PRODUCTS.items():
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

    def test_embedded_unit_and_ui_test_identity_is_verified_before_installation(self):
        for relative in ("KitPay.app/PlugIns/KitPayTests.xctest",
                         "KitPayUITests-Runner.app/PlugIns/KitPayUITests.xctest"):
            info = self.generated.parent / "Debug-iphonesimulator" / relative / "Info.plist"
            original = info.read_bytes()
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.test"}))
            with self.subTest(bundle=relative), patch.object(PRODUCTS, "checked") as checked:
                with self.assertRaises(RuntimeError):
                    self.run_prepare()
                checked.assert_not_called()
            info.write_bytes(original)

    def test_generated_plan_and_unrelated_fields_remain_unchanged(self):
        original = self.generated.read_bytes()
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            result = self.run_prepare()
        configuration = result["testRunConfiguration"]
        prepared_path = Path(configuration["preparedPath"])
        self.assertEqual(prepared_path.parent, self.generated.parent)
        self.assertEqual(self.generated.read_bytes(), original)
        self.assertEqual(configuration["generatedSHA256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(configuration["preparedSHA256"], hashlib.sha256(prepared_path.read_bytes()).hexdigest())
        prepared = plistlib.loads(prepared_path.read_bytes())
        for key in self.plan.keys() - {"TestConfigurations"}:
            self.assertEqual(prepared[key], self.plan[key])
        original_configuration = self.plan["TestConfigurations"][0]
        prepared_configuration = prepared["TestConfigurations"][0]
        for key in original_configuration.keys() - {"TestTargets"}:
            self.assertEqual(prepared_configuration[key], original_configuration[key])
        changed = {"TestBundlePath", "TestHostPath", "UITargetAppPath",
                   "UseDestinationArtifacts", "TestHostBundleIdentifier",
                   "TestBundleDestinationRelativePath", "UITargetAppBundleIdentifier"}
        for before, after in zip(original_configuration["TestTargets"], prepared_configuration["TestTargets"]):
            name = before["BlueprintName"]
            self.assertEqual({key: value for key, value in before.items() if key not in changed},
                             {key: value for key, value in after.items() if key not in changed})
            self.assertTrue(after["UseDestinationArtifacts"])
            self.assertEqual(after["TestHostBundleIdentifier"], before["TestHostBundleIdentifier"])
            self.assertEqual(after["UITargetAppBundleIdentifier"], "africa.kit.pay.ios")
            self.assertEqual(after["TestBundleDestinationRelativePath"],
                             "__TESTHOST__/PlugIns/" + name + ".xctest")
            for key in ("TestBundlePath", "TestHostPath", "UITargetAppPath"):
                self.assertNotIn(key, after)

    def test_repeated_preparation_for_one_device_does_not_reinstall(self):
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            self.run_prepare()
            count = len(self.calls)
            with self.assertRaises(FileExistsError):
                self.run_prepare()
        self.assertEqual(len(self.calls), count)

    def test_generated_executable_host_paths_use_the_same_bundle_mapping(self):
        for target in self.plan["TestConfigurations"][0]["TestTargets"]:
            target["TestHostPath"] += "/fixture"
        original = plistlib.dumps(self.plan)
        self.generated.write_bytes(original)
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            result = self.run_prepare()
        prepared = plistlib.loads(Path(result["testRunConfiguration"]["preparedPath"]).read_bytes())
        self.assertEqual(self.generated.read_bytes(), original)
        for target in prepared["TestConfigurations"][0]["TestTargets"]:
            self.assertEqual(target["TestBundleDestinationRelativePath"],
                             "__TESTHOST__/PlugIns/" + target["BlueprintName"] + ".xctest")
            self.assertNotIn("TestHostPath", target)

    def test_second_device_reuses_the_unchanged_prepared_plan(self):
        with patch.object(PRODUCTS, "checked", side_effect=self.checked):
            first = self.run_prepare()
            prepared = Path(first["testRunConfiguration"]["preparedPath"])
            previous = prepared.stat().st_mtime_ns
            second = PRODUCTS.prepare("second-device", self.root, clock=lambda: self.now, pause=self.pause)
        self.assertEqual(first["testRunConfiguration"], second["testRunConfiguration"])
        self.assertEqual(prepared.stat().st_mtime_ns, previous)
        self.assertEqual([call[2] for call in self.calls if call[0] == "xcrun"].count("install"), 4)

    def test_ambiguous_generated_plan_stops_before_installation(self):
        self.generated.with_name("another.xctestrun").write_bytes(self.generated.read_bytes())
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_prepare()
        checked.assert_not_called()

    def test_altered_prepared_plan_is_never_overwritten_or_installed(self):
        binding = PRODUCTS.destination_test_run(self.generated.parent)
        prepared = Path(binding["preparedPath"])
        prepared.write_bytes(b"unexpected earlier configuration")
        with patch.object(PRODUCTS, "checked") as checked, self.assertRaises(RuntimeError):
            self.run_prepare()
        checked.assert_not_called()
        self.assertEqual(prepared.read_bytes(), b"unexpected earlier configuration")

    def test_generated_configuration_rejects_wrong_scope_and_bindings(self):
        cases = []
        value = copy.deepcopy(self.plan)
        value["__xctestrun_metadata__"]["FormatVersion"] = 1
        cases.append(value)
        value = copy.deepcopy(self.plan)
        value["TestConfigurations"].append(copy.deepcopy(value["TestConfigurations"][0]))
        cases.append(value)
        for key, replacement in (("BlueprintName", "AnotherTarget"),
                                 ("TestHostPath", "__TESTROOT__/other.app"),
                                 ("TestHostPath", "__TESTROOT__/Debug-iphonesimulator/KitPay.app/wrong-executable"),
                                 ("TestBundlePath", "__TESTHOST__/PlugIns/other.xctest"),
                                 ("TestHostBundleIdentifier", "another.app"),
                                 ("UITargetAppBundleIdentifier", "another.app"),
                                 ("TestingEnvironmentVariables", None),
                                 ("UseDestinationArtifacts", True)):
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
                    PRODUCTS.destination_test_run(self.generated.parent)
                self.assertFalse((self.generated.parent / PRODUCTS.DESTINATION_RUN).exists())

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
