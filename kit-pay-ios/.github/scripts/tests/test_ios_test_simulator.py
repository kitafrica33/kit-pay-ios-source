import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_ios_test_simulator.py"
SPEC = importlib.util.spec_from_file_location("prepare_ios_test_simulator", SCRIPT)
SIMULATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIMULATOR)
DEVICE_ID = "A31F4280-67BF-4C9C-B900-6B90FD46732D"
PREEXISTING_ID = "5E45DEBC-23C9-4EED-8392-34F63EC1A225"


class PrepareSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {
            "GITHUB_RUN_ID": "33999123456", "GITHUB_RUN_ATTEMPT": "1",
            "RUNNER_TEMP": str(self.root), "GITHUB_ENV": str(self.root / "github-env"),
        }
        self.receipt = self.root / "KitPay-native-simulator-33999123456-1.json"
        self.runtimes = [{
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "name": "iOS 26.5",
            "version": "26.5", "buildversion": "23F77", "isAvailable": True,
        }]
        self.device_types = [{
            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro",
        }]
        self.create_output = DEVICE_ID + "\n"
        self.failure = None
        self.timeout = None
        self.calls = []
        self.before_boot = None
        runner = patch.object(SIMULATOR.subprocess, "run", side_effect=self.fake_run)
        runner.start()
        self.addCleanup(runner.stop)

    def fake_run(self, command, **options):
        self.assertEqual(command[:2], ["xcrun", "simctl"])
        self.assertIs(options["check"], True)
        arguments = command[2:]
        self.calls.append(arguments)
        self.assertEqual(options["timeout"], 300 if arguments[0] == "bootstatus" else 60)
        if arguments[0] == self.timeout:
            raise subprocess.TimeoutExpired(command, options["timeout"])
        if arguments[0] == self.failure:
            raise subprocess.CalledProcessError(71, command)
        if arguments == ["list", "runtimes", "-j"]:
            output = json.dumps({"runtimes": self.runtimes})
        elif arguments == ["list", "devicetypes", "-j"]:
            output = json.dumps({"devicetypes": self.device_types})
        elif arguments[:2] == ["list", "devices"]:
            # The old first-available-device strategy would select this wrong runtime/device.
            output = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                {"name": "iPhone 16", "isAvailable": True, "udid": PREEXISTING_ID},
            ]}})
        elif arguments[0] == "create":
            output = self.create_output
        elif arguments[0] in {"boot", "bootstatus"}:
            if arguments[0] == "boot":
                self.before_boot = (
                    json.loads(self.receipt.read_text()),
                    Path(self.env["GITHUB_ENV"]).read_text(),
                )
            output = None
        else:
            self.fail(f"Unexpected Simulator command: {command}")
        return subprocess.CompletedProcess(command, 0, stdout=output)

    def assert_no_creation(self):
        self.assertFalse(any(call[0] == "create" for call in self.calls))
        self.assertFalse(self.receipt.exists())

    def test_creates_one_pinned_device_and_records_ownership_before_boot(self):
        self.assertEqual(SIMULATOR.prepare(self.env), DEVICE_ID)
        self.assertEqual(self.calls, [
            ["list", "runtimes", "-j"], ["list", "devicetypes", "-j"],
            ["create", "KitPay Native Tests 33999123456-1", SIMULATOR.DEVICE_TYPE["identifier"],
             SIMULATOR.RUNTIME["identifier"]],
            ["boot", DEVICE_ID], ["bootstatus", DEVICE_ID, "-b"],
        ])
        receipt, environment = self.before_boot
        self.assertEqual(receipt["device_id"], DEVICE_ID)
        self.assertEqual(receipt["runtime"], SIMULATOR.RUNTIME)
        self.assertEqual(receipt["device_type"], SIMULATOR.DEVICE_TYPE)
        self.assertEqual(environment.splitlines(), [
            f"KITPAY_TEST_DEVICE_ID={DEVICE_ID}", f"KITPAY_NATIVE_TEST_DEVICE_ID={DEVICE_ID}",
        ])
        self.assertNotIn(PREEXISTING_ID, str(self.calls))

    def test_missing_unavailable_and_ambiguous_runtime_rejected_before_create(self):
        cases = [[], [{**SIMULATOR.RUNTIME, "isAvailable": False}], [dict(SIMULATOR.RUNTIME)],
                 [{**SIMULATOR.RUNTIME, "isAvailable": 1}], self.runtimes * 2,
                 [self.runtimes[0], {**SIMULATOR.RUNTIME, "isAvailable": False}]]
        for runtimes in cases:
            with self.subTest(runtimes=runtimes):
                self.runtimes = runtimes
                self.calls.clear()
                with self.assertRaises(ValueError):
                    SIMULATOR.prepare(self.env)
                self.assert_no_creation()

    def test_runtime_identity_fields_must_all_match_before_create(self):
        for field in SIMULATOR.RUNTIME:
            with self.subTest(field=field):
                self.runtimes = [{**SIMULATOR.RUNTIME, "isAvailable": True, field: "wrong"}]
                self.calls.clear()
                with self.assertRaises(ValueError):
                    SIMULATOR.prepare(self.env)
                self.assert_no_creation()

    def test_required_device_type_must_be_present_unique_and_exact(self):
        for device_types in ([], [SIMULATOR.DEVICE_TYPE] * 2,
                             [{**SIMULATOR.DEVICE_TYPE, "name": "iPhone 16"}],
                             [{**SIMULATOR.DEVICE_TYPE, "identifier": "wrong"}]):
            with self.subTest(device_types=device_types):
                self.device_types = device_types
                self.calls.clear()
                with self.assertRaises(ValueError):
                    SIMULATOR.prepare(self.env)
                self.assert_no_creation()

    def test_invalid_run_identity_or_missing_environment_has_no_commands(self):
        environments = [{}, {**self.env, "RUNNER_TEMP": ""}, {**self.env, "GITHUB_ENV": ""}]
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
            environments.extend({**self.env, key: value} for value in ("", "0", "1/2", "-1", "１", "1\n2"))
        for env in environments:
            with self.subTest(env=env):
                with self.assertRaises(ValueError):
                    SIMULATOR.prepare(env)
                self.assertEqual(self.calls, [])
                self.assert_no_creation()

    def test_existing_receipt_preserves_owned_device_and_prevents_recreation(self):
        self.receipt.write_text('{"device_id": "earlier-owned-device"}\n')
        original = self.receipt.read_bytes()
        with self.assertRaises(FileExistsError):
            SIMULATOR.prepare(self.env)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.receipt.read_bytes(), original)

    def test_unwritable_environment_destination_prevents_creation(self):
        self.env["GITHUB_ENV"] = str(self.root)
        with self.assertRaises(IsADirectoryError):
            SIMULATOR.prepare(self.env)
        self.assert_no_creation()

    def test_creation_failure_propagates_without_boot_or_device_export(self):
        self.failure = "create"
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            SIMULATOR.prepare(self.env)
        self.assertEqual(raised.exception.returncode, 71)
        self.assertEqual([call[0] for call in self.calls], ["list", "list", "create"])
        self.assertEqual(Path(self.env["GITHUB_ENV"]).read_text(), "")
        self.assertEqual(self.receipt.read_text(), "")

    def test_malformed_creation_identity_is_never_booted_or_exported(self):
        for output in ("", "not-a-uuid", DEVICE_ID + "\n" + PREEXISTING_ID):
            with self.subTest(output=output):
                self.create_output = output
                with self.assertRaises(ValueError):
                    SIMULATOR.prepare(self.env)
                self.assertEqual(self.calls[-1][0], "create")
                self.assertEqual(Path(self.env["GITHUB_ENV"]).read_text(), "")
                self.receipt.unlink()

    def test_boot_and_readiness_failures_keep_exact_cleanup_identity(self):
        for failure in ("boot", "bootstatus"):
            with self.subTest(failure=failure):
                self.failure = failure
                self.calls.clear()
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    SIMULATOR.prepare(self.env)
                self.assertEqual(raised.exception.returncode, 71)
                self.assertEqual(self.calls[-1][0], failure)
                self.assertEqual(sum(call[0] == "create" for call in self.calls), 1)
                self.assertEqual(json.loads(self.receipt.read_text())["device_id"], DEVICE_ID)
                self.assertIn(f"KITPAY_NATIVE_TEST_DEVICE_ID={DEVICE_ID}", Path(self.env["GITHUB_ENV"]).read_text())
                self.receipt.unlink()
                Path(self.env["GITHUB_ENV"]).unlink()

    def test_command_timeouts_propagate_without_retry_and_keep_created_identity(self):
        for command in ("list", "create", "boot", "bootstatus"):
            with self.subTest(command=command):
                self.timeout = command
                self.calls.clear()
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    SIMULATOR.prepare(self.env)
                self.assertEqual(raised.exception.timeout, 300 if command == "bootstatus" else 60)
                self.assertEqual(self.calls[-1][0], command)
                self.assertEqual(sum(call[0] == command for call in self.calls), 1)
                if command in {"boot", "bootstatus"}:
                    self.assertEqual(json.loads(self.receipt.read_text())["device_id"], DEVICE_ID)
                    self.assertIn(f"KITPAY_NATIVE_TEST_DEVICE_ID={DEVICE_ID}", Path(self.env["GITHUB_ENV"]).read_text())
                self.receipt.unlink(missing_ok=True)
                Path(self.env["GITHUB_ENV"]).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
