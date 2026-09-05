from __future__ import annotations

import importlib.util
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / ".github/scripts"
sys.path.insert(0, str(SCRIPTS))
import ios_release_readiness as READINESS


def step(workflow: str, name: str) -> str:
    return workflow.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]


class WorkflowSelectionTests(unittest.TestCase):
    def test_mobile_workflows_have_no_automatic_quality_trigger(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            with self.subTest(path=path.name):
                triggers = path.read_text().split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
                self.assertNotRegex(triggers, r"(?m)^  (?:push|pull_request|schedule|workflow_run):")
                self.assertIn("  workflow_dispatch:", triggers)

    def test_store_capture_condition_matrix(self):
        archive = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        for name in ("Require exact App Store device classes", "Create clean screenshot simulators",
                     "Prepare the screenshot iPhone for all native checks", "Capture iPhone 6.5-inch screenshots",
                     "Capture iPad 13-inch screenshots", "Export, normalize, and validate screenshots",
                     "Retain screenshots and test evidence"):
            condition = re.search(r"if: \$\{\{ (.+) \}\}", step(archive, name)).group(1)
            for target in ("testflight", "app-store"):
                for update in (False, True):
                    for reused in ("", "false", "true"):
                        with self.subTest(step=name, target=target, update=update, reused=reused):
                            expression = condition.replace("inputs.publication_target", repr(target))
                            expression = expression.replace("inputs.update_screenshots", repr(update))
                            expression = expression.replace("steps.screenshots.outputs.reused", repr(reused))
                            expression = expression.replace("&&", " and ").replace("||", " or ")
                            self.assertEqual(eval(expression, {"__builtins__": {}}),
                                             target == "app-store" and update and reused != "true")

    def test_reused_or_unneeded_images_prepare_only_one_native_simulator(self):
        archive = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        condition = re.search(r"if: \$\{\{ (.+) \}\}", step(archive, "Prepare native test Simulator")).group(1)
        for update, reused, expected in ((False, "", True), (True, "true", True), (True, "false", False)):
            expression = condition.replace("inputs.update_screenshots", repr(update))
            expression = expression.replace("steps.screenshots.outputs.reused", repr(reused))
            expression = expression.replace("!", " not ").replace("||", " or ")
            self.assertEqual(eval(expression.strip(), {"__builtins__": {}}), expected)

    def test_screenshot_failure_artifact_runs_only_for_selected_new_images(self):
        archive = (ROOT / ".github/workflows/ios-app-store-archive.yml").read_text()
        condition = re.search(r"if: \$\{\{ (.+) \}\}", step(archive, "Retain native UI failure evidence")).group(1)
        for failed in (False, True):
            for target in ("testflight", "app-store"):
                for update in (False, True):
                    for reused in ("", "false", "true"):
                        expression = condition.replace("failure()", repr(failed))
                        expression = expression.replace("inputs.publication_target", repr(target))
                        expression = expression.replace("inputs.update_screenshots", repr(update))
                        expression = expression.replace("steps.screenshots.outputs.reused", repr(reused))
                        expression = expression.replace("&&", " and ")
                        self.assertEqual(eval(expression, {"__builtins__": {}}),
                                         failed and target == "app-store" and update and reused != "true")

    def test_testflight_upload_never_builds_and_processing_uses_linux(self):
        workflow = (ROOT / ".github/workflows/ios-testflight-upload.yml").read_text()
        self.assertNotIn("xcodebuild", workflow)
        self.assertNotIn("pod install", workflow)
        self.assertNotIn("unittest discover", workflow)
        preflight, remainder = workflow.split("\n  upload:\n", 1)
        upload, processing = remainder.split("\n  processing:\n", 1)
        self.assertIn("runs-on: ubuntu-latest", preflight)
        self.assertIn("ios_release_readiness.py --mode upload", preflight)
        self.assertIn("needs: preflight", upload)
        self.assertIn("verify_ios_testflight_artifact.py", upload)
        self.assertIn("codesign --verify --deep --strict", upload)
        self.assertIn("needs: upload", processing)
        self.assertIn("runs-on: ubuntu-latest", processing)
        self.assertNotIn("wait_for_testflight_build.py", upload)
        self.assertIn("wait_for_testflight_build.py", processing)


class NativeCommandTests(unittest.TestCase):
    def test_resolution_seeds_and_checks_the_selected_workspace_lock_once(self):
        for mutate in (False, True):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                source = root / "KitPay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                source.parent.mkdir(parents=True)
                payload = {"pins": [{"identity": "fixture", "state": {"revision": "a" * 40}}]}
                source.write_text(json.dumps(payload))
                (root / "KitPay.xcodeproj/project.pbxproj").write_text("fixture project\n")
                subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                                "commit", "--quiet", "-m", "fixture"], cwd=root, check=True)
                commands = root / "commands"
                commands.mkdir()
                (commands / "pod").write_text("#!/bin/sh\necho pod >> \"$KITPAY_TEST_COMMAND_LOG\"\n")
                (commands / "xcodebuild").write_text("""#!/usr/bin/env python3
import json, os
from pathlib import Path
with open(os.environ['KITPAY_TEST_COMMAND_LOG'], 'a') as f: f.write('resolve\\n')
p = Path('KitPay.xcworkspace/xcshareddata/swiftpm/Package.resolved')
data = json.loads(p.read_text())
if os.environ['KITPAY_CHANGE_PIN'] == '1':
    data['pins'][0]['state']['revision'] = 'b' * 40
    p.write_text(json.dumps(data))
""")
                for executable in commands.iterdir(): executable.chmod(0o755)
                log = root / "commands.log"
                result = subprocess.run(["bash", str(SCRIPTS / "install_ios_dependencies.sh")], cwd=root,
                                        env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                                             "RUNNER_TEMP": str(root), "KITPAY_TEST_COMMAND_LOG": str(log),
                                             "KITPAY_CHANGE_PIN": "1" if mutate else "0"},
                                        capture_output=True, text=True)
                self.assertEqual(log.read_text().splitlines(), ["pod", "resolve"])
                self.assertEqual(result.returncode == 0, not mutate, result.stderr)
                self.assertEqual(json.loads(source.read_text()), payload)

    def execute(self, mode, *, fail_focused=False):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            executable = root / "xcodebuild"
            executable.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['KITPAY_TEST_COMMAND_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if os.environ.get('KITPAY_FAIL_FOCUSED') == '1' and any(a.startswith('-only-testing:KitPayTests/ConversationNativeOpeningTests') for a in sys.argv): sys.exit(65)
""")
            executable.chmod(0o755)
            products = root / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator"
            product_ids = {"KitPay.app": "africa.kit.pay.ios",
                           "KitPayUITests-Runner.app": "africa.kit.pay.ios.uitests.xctrunner"}
            for name, identifier in product_ids.items():
                bundle = products / name
                bundle.mkdir(parents=True)
                (bundle / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture",
                    "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                }))
                (bundle / "fixture").write_bytes(b"fixture")
            (root / "xcrun").write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:3] == ['simctl', 'listapps']:
    print(json.dumps({identifier: {'CFBundleIdentifier': identifier, 'ApplicationType': 'User',
        'Path': str(Path(os.environ['RUNNER_TEMP']) / 'installed' / identifier)}
        for identifier in ('africa.kit.pay.ios', 'africa.kit.pay.ios.uitests.xctrunner')}))
elif sys.argv[1:3] == ['simctl', 'get_app_container']:
    print(Path(os.environ['RUNNER_TEMP']) / 'installed' / sys.argv[4])
""")
            (root / "xcrun").chmod(0o755)
            (root / "plutil").write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n")
            (root / "plutil").chmod(0o755)
            log = root / "commands.jsonl"
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(root), "KITPAY_TEST_DEVICE_ID": "fixture-device",
                   "KITPAY_TEST_COMMAND_LOG": str(log), "KITPAY_FAIL_FOCUSED": "1" if fail_focused else "0"}
            result = subprocess.run(["bash", str(SCRIPTS / "ios_native_build.sh"), mode],
                                    env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_test_products_compile_once_and_keep_keychain_entitlements(self):
        result, calls = self.execute("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], "build-for-testing")
        self.assertIn("CODE_SIGN_IDENTITY=-", calls[0])
        self.assertIn("ONLY_ACTIVE_ARCH=YES", calls[0])
        self.assertIn("-disableAutomaticPackageResolution", calls[0])

    def test_focused_failure_stops_remaining_tests(self):
        result, calls = self.execute("test", fail_focused=True)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(len(calls), 1)

    def test_focused_and_remaining_tests_reuse_the_same_products(self):
        result, calls = self.execute("test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(call[-1], "test-without-building")
            self.assertIn("-disableAutomaticPackageResolution", call)
        self.assertIn("-skip-testing:KitPayTests/ConversationNativeOpeningTests", calls[1])
        self.assertIn("-only-testing:KitPayUITests/CallLayoutUITests", calls[0])
        self.assertIn("-skip-testing:KitPayUITests/CallLayoutUITests", calls[1])
        self.assertIn("-skip-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots", calls[1])
        for test in (
            "testReceivedVideoPlaysToEndAndReplaysAfterParentFileCleanup",
            "testGalleryScrubbingRejectsInvalidTimesAndPreservesPauseIntent",
        ):
            selector = "KitPayTests/ChatMediaPolicyTests/" + test
            self.assertEqual(calls[0].count("-only-testing:" + selector), 1)
            self.assertEqual(calls[1].count("-skip-testing:" + selector), 1)

    def test_both_marketing_devices_use_existing_products(self):
        for mode in ("marketing-iphone", "marketing-ipad"):
            with self.subTest(mode=mode):
                result, calls = self.execute(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][-1], "test-without-building")
        _, calls = self.execute("marketing-iphone")
        self.assertIn("-only-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots", calls[0])
        _, calls = self.execute("marketing-ipad")
        self.assertIn("-only-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots", calls[0])
        self.assertNotIn("-only-testing:KitPayUITests/AppStoreScreenshotUITests", calls[0])


class ReadinessTests(unittest.TestCase):
    def test_real_distribution_key_pair_is_checked_without_logging_secrets(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            key, certificate, archive = (directory / name for name in ("key.pem", "certificate.pem", "key.p12"))
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=Apple Distribution: Fixture/OU=A1B2C3D4E5", "-keyout", str(key),
                            "-out", str(certificate)], check=True, capture_output=True)
            password = "b" * 64
            subprocess.run(["openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
                            "-out", str(archive), "-passout", "env:KITPAY_TEST_P12_PASSWORD"],
                           env={**os.environ, "KITPAY_TEST_P12_PASSWORD": password}, check=True, capture_output=True)
            environment = {"APPLE_TEAM_ID": "A1B2C3D4E5", "CERTIFICATE_PASSWORD": password,
                           "CERTIFICATE_BASE64": base64.b64encode(archive.read_bytes()).decode()}
            expected = subprocess.check_output(["openssl", "x509", "-in", str(certificate), "-outform", "DER"])
            with patch.dict(os.environ, environment):
                self.assertEqual(READINESS.distribution_certificate(), expected)
                self.assertNotIn("KITPAY_READINESS_P12_PASSWORD", os.environ)
                os.environ["CERTIFICATE_PASSWORD"] = "c" * 64
                with self.assertRaises(READINESS.profiles.ProvisioningError) as failure:
                    READINESS.distribution_certificate()
                self.assertNotIn(password, str(failure.exception))
                self.assertNotIn("KITPAY_READINESS_P12_PASSWORD", os.environ)
            # The same key and certificate in a legacy-encrypted container must
            # remain usable by the Linux preflight and macOS signing import.
            # LibreSSL does not offer OpenSSL 3's explicit legacy-provider flag.
            version = subprocess.check_output(["openssl", "version"], text=True)
            if version.startswith("OpenSSL 3"):
                subprocess.run(["openssl", "pkcs12", "-export", "-legacy", "-inkey", str(key),
                                "-in", str(certificate), "-out", str(archive),
                                "-passout", "env:KITPAY_TEST_P12_PASSWORD"],
                               env={**os.environ, "KITPAY_TEST_P12_PASSWORD": password}, check=True, capture_output=True)
                environment["CERTIFICATE_BASE64"] = base64.b64encode(archive.read_bytes()).decode()
                with patch.dict(os.environ, environment):
                    self.assertEqual(READINESS.distribution_certificate(), expected)

    def test_unused_build_and_matching_app_are_required_before_setup(self):
        class Client:
            def __init__(self, app_bundle="africa.kit.pay.ios", builds=None):
                self.app_bundle = app_bundle
                self.builds = builds or []
                self.methods = []
            def request(self, method, path, **kwargs):
                self.methods.append(method)
                data = [{"type": "apps", "id": "app", "attributes": {"bundleId": self.app_bundle}}] if path == "/v1/apps" else self.builds
                return {"data": data, "links": {"next": None}}
        client = Client()
        READINESS.verify_app_and_unused_build(client, "africa.kit.pay.ios", "1.0.16", "62")
        self.assertEqual(client.methods, ["GET", "GET"])
        for invalid in (Client(app_bundle="wrong.app"), Client(builds=[{"id": "exists"}])):
            with self.assertRaises(READINESS.profiles.ProvisioningError):
                READINESS.verify_app_and_unused_build(invalid, "africa.kit.pay.ios", "1.0.16", "62")


if __name__ == "__main__":
    unittest.main()
