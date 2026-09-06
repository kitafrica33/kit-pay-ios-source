#!/usr/bin/env python3
"""Validate compiled products and observe XCTest-owned Simulator installations.

Preparation never installs or launches an app and never rewrites Xcode's plan.
After the first native invocation succeeds, registration observes visibility and
grants Contacts for the remaining real-app launch tests. Visibility alone does
not prove FrontBoard readiness or native test success.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time


PRODUCTS = {
    "KitPay.app": "africa.kit.pay.ios",
    "KitPayUITests-Runner.app": "africa.kit.pay.ios.uitests.xctrunner",
}
TEST_TARGETS = {
    "KitPayTests": ("KitPay.app", "africa.kit.pay.ios.tests"),
    "KitPayUITests": ("KitPayUITests-Runner.app", "africa.kit.pay.ios.uitests"),
}


def validate_bundle(bundle: Path, identifier: str):
    info_path = bundle / "Info.plist"
    if (not bundle.is_dir() or bundle.is_symlink() or not info_path.is_file()
            or info_path.is_symlink() or info_path.stat().st_size > 1024 * 1024):
        raise RuntimeError("Missing or unexpected Simulator test product: " + bundle.name)
    info = plistlib.loads(info_path.read_bytes())
    executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != identifier
            or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
            or not isinstance(executable, str) or executable in ("", ".", "..")
            or Path(executable).name != executable
            or not (bundle / executable).is_file() or (bundle / executable).is_symlink()):
        raise RuntimeError("Unexpected Simulator test product: " + bundle.name)
    return executable


def generated_test_run(products_root: Path):
    """Validate the original generated plan without changing any of its bytes."""
    generated = list(products_root.glob("*.xctestrun"))
    if (len(generated) != 1 or not generated[0].is_file() or generated[0].is_symlink()
            or not 0 < generated[0].stat().st_size <= 4 * 1024 * 1024):
        raise RuntimeError("Exactly one generated XCTest run configuration is required")
    source = generated[0]
    original = source.read_bytes()
    plan = plistlib.loads(original)
    metadata = plan.get("__xctestrun_metadata__") if isinstance(plan, dict) else None
    if (not isinstance(plan, dict)
            or not isinstance(metadata, dict) or type(metadata.get("FormatVersion")) is not int
            or metadata["FormatVersion"] != 2):
        raise RuntimeError("Expected generated XCTest run format version 2")
    configurations = plan.get("TestConfigurations")
    if (not isinstance(configurations, list) or len(configurations) != 1
            or not isinstance(configurations[0], dict)
            or configurations[0].get("IsEnabled", True) is not True):
        raise RuntimeError("Exactly one enabled XCTest configuration is required")
    targets = configurations[0].get("TestTargets")
    if (not isinstance(targets, list) or len(targets) != len(TEST_TARGETS)
            or any(not isinstance(target, dict) for target in targets)
            or any(not isinstance(target.get("BlueprintName"), str) for target in targets)
            or sorted(target.get("BlueprintName", "") for target in targets) != sorted(TEST_TARGETS)):
        raise RuntimeError("Expected exactly the KitPay unit and UI test targets")

    target_bindings = {}
    for target in targets:
        name = target["BlueprintName"]
        host_name, _ = TEST_TARGETS[name]
        host = products_root / "Debug-iphonesimulator" / host_name
        host_executable = host / validate_bundle(host, PRODUCTS[host_name])
        app = products_root / "Debug-iphonesimulator/KitPay.app"
        bundle = host / "PlugIns" / (name + ".xctest")

        def require_path(key, *expected, optional=False):
            if optional and key not in target:
                return None
            value = target.get(key)
            if not isinstance(value, str):
                raise RuntimeError("Missing generated " + key + " for " + name)
            expanded = value.replace("__TESTROOT__", str(products_root)).replace("__TESTHOST__", str(host))
            resolved = Path(expanded).resolve()
            if resolved not in {path.resolve() for path in expected}:
                raise RuntimeError("Unexpected generated " + key + " for " + name)
            return str(resolved)

        host_path = require_path("TestHostPath", host, host_executable)
        bundle_path = require_path("TestBundlePath", bundle)
        ui_app_path = require_path("UITargetAppPath", app, optional=name == "KitPayTests")
        environment = target.get("TestingEnvironmentVariables")
        if (not isinstance(environment, dict)
                or any(not isinstance(key, str) or not isinstance(value, str)
                       for key, value in environment.items())):
            raise RuntimeError("Missing generated testing environment for " + name)
        if target.get("UseDestinationArtifacts", False) is not False:
            raise RuntimeError("UseDestinationArtifacts is unsupported for Simulator tests")
        bindings = {
            "UseDestinationArtifacts": False,
            "TestHostBundleIdentifier": PRODUCTS[host_name],
            "TestHostPath": host_path,
            "TestBundlePath": bundle_path,
            "UITargetAppBundleIdentifier": PRODUCTS["KitPay.app"],
        }
        for key in ("TestHostBundleIdentifier", "UITargetAppBundleIdentifier"):
            if key in target and target[key] != bindings[key]:
                raise RuntimeError("Unexpected generated " + key + " for " + name)
        if ui_app_path is not None:
            bindings["UITargetAppPath"] = ui_app_path
        target_bindings[name] = bindings

    return {
        "generatedPath": str(source), "generatedSHA256": hashlib.sha256(original).hexdigest(),
        "targets": target_bindings,
    }


def checked(arguments, *, data=None, timeout=90):
    return subprocess.run(arguments, input=data, capture_output=True, check=True,
                          timeout=timeout).stdout


def validate(runner_temp: Path):
    products = runner_temp / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator"
    selected = []
    for name, identifier in PRODUCTS.items():
        bundle = products / name
        executable = validate_bundle(bundle, identifier)
        selected.append({"bundleId": identifier, "source": str(bundle), "executable": executable})
    for name, (host_name, identifier) in TEST_TARGETS.items():
        bundle = products / host_name / "PlugIns" / (name + ".xctest")
        executable = validate_bundle(bundle, identifier)
        selected.append({"bundleId": identifier, "source": str(bundle), "executable": executable})
    return selected, generated_test_run(products.parent)


def receipt_path(device: str, runner_temp: Path):
    return runner_temp / ("KitPay-test-product-registration-" + device + ".json")


def retain_failure(evidence, error, phase):
    failure = {"type": type(error).__name__, "message": str(error)[:4096]}
    if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
        failure["command"] = error.cmd
        failure["returnCode"] = getattr(error, "returncode", None)
        failure["timeoutSeconds"] = getattr(error, "timeout", None)
        for key in ("stdout", "stderr"):
            value = getattr(error, key, None)
            if isinstance(value, bytes):
                value = value.decode(errors="replace")
            if isinstance(value, str):
                failure[key] = value[-4096:]
    evidence["phase"] = phase
    evidence["failure"] = failure


def prepare(device: str, runner_temp: Path):
    receipt = receipt_path(device, runner_temp)
    evidence = {"deviceId": device, "installationOwner": "xcodebuild", "phase": "preparing",
                "products": [], "observations": [], "installedApplicationsVisible": False,
                "frontBoardReadinessProven": False}
    # A failed or completed preparation for this device must never be repeated.
    with receipt.open("x") as stream:
        stream.write(json.dumps(evidence, indent=2) + "\n")
    receipt.chmod(0o600)
    try:
        evidence["products"], evidence["testRunConfiguration"] = validate(runner_temp)
        evidence["phase"] = "prepared"
    except Exception as error:
        retain_failure(evidence, error, "preparation-failed")
        raise
    finally:
        receipt.write_text(json.dumps(evidence, indent=2) + "\n")
    return evidence


def register_after_first_native(device: str, runner_temp: Path, *, clock=time.monotonic, pause=time.sleep):
    receipt = receipt_path(device, runner_temp)
    if (not receipt.is_file() or receipt.is_symlink() or not 0 < receipt.stat().st_size <= 256 * 1024):
        raise RuntimeError("The native preparation receipt is missing or unexpected")
    evidence = json.loads(receipt.read_text())
    if (not isinstance(evidence, dict) or evidence.get("deviceId") != device
            or evidence.get("installationOwner") != "xcodebuild" or evidence.get("phase") != "prepared"
            or evidence.get("observations") != [] or evidence.get("installedApplicationsVisible") is not False
            or evidence.get("frontBoardReadinessProven") is not False or "failure" in evidence
            or "contactsPermissionGranted" in evidence):
        raise RuntimeError("Registration requires one successful, unused native preparation")

    def retain():
        receipt.write_text(json.dumps(evidence, indent=2) + "\n")

    try:
        selected, configuration = validate(runner_temp)
        if evidence.get("products") != selected or evidence.get("testRunConfiguration") != configuration:
            raise RuntimeError("Compiled product bindings or generated XCTest configuration changed after preparation")
        evidence["phase"] = "registering-after-first-native"
        retain()
        deadline = clock() + 30

        def query(arguments, *, data=None):
            remaining = deadline - clock()
            if remaining <= 0:
                raise RuntimeError("Simulator application registration exceeded its 30-second deadline")
            return checked(arguments, data=data, timeout=min(10, remaining))

        while True:
            listing = query(["xcrun", "simctl", "listapps", device])
            apps = json.loads(query(["plutil", "-convert", "json", "-o", "-", "--", "-"], data=listing))
            if not isinstance(apps, dict):
                raise RuntimeError("Simulator installed-app listing is not an object")
            observation = {}
            for identifier in PRODUCTS.values():
                attributes = apps.get(identifier)
                details = ({key: attributes.get(key) for key in
                            ("CFBundleIdentifier", "ApplicationType", "IsPlaceholder", "Path", "Bundle")}
                           if isinstance(attributes, dict) else {})
                visible = isinstance(attributes, dict) and attributes.get("CFBundleIdentifier") == identifier
                if visible:
                    visible = (attributes.get("ApplicationType", "User") == "User"
                               and not attributes.get("IsPlaceholder", False))
                if visible:
                    container = query(["xcrun", "simctl", "get_app_container", device,
                                       identifier, "app"]).decode().strip()
                    details["container"] = container
                    paths = [attributes.get(key) for key in ("Path", "Bundle")
                             if isinstance(attributes.get(key), str)]
                    visible = bool(container) and any(Path(path).resolve() == Path(container).resolve()
                                                       for path in paths)
                observation[identifier] = {**details, "visible": bool(visible)}
            evidence["observations"].append(observation)
            evidence["installedApplicationsVisible"] = all(item["visible"] for item in observation.values())
            retain()
            if evidence["installedApplicationsVisible"]:
                # The first native invocation has let XCTest install and launch the app.
                # The second invocation includes real AppLaunchUITests without the fixture.
                checked(["xcrun", "simctl", "privacy", device, "grant", "contacts", "africa.kit.pay.ios"])
                evidence["contactsPermissionGranted"] = True
                evidence["phase"] = "contacts-ready"
                retain()
                print("XCTest-installed app and runner are visible; Contacts is granted for the remaining native tests.")
                return evidence
            if clock() >= deadline:
                raise RuntimeError("Simulator application registration did not become visible within 30 seconds")
            pause(1)
    except Exception as error:
        retain_failure(evidence, error, "registration-failed")
        retain()
        raise


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    root = Path(os.environ["RUNNER_TEMP"])
    if mode == "prepare":
        print(prepare(os.environ["KITPAY_TEST_DEVICE_ID"], root)["testRunConfiguration"]["generatedPath"])
    elif mode == "validate":
        print(validate(root)[1]["generatedPath"])
    elif mode == "register":
        register_after_first_native(os.environ["KITPAY_TEST_DEVICE_ID"], root)
    else:
        raise SystemExit("Select prepare, validate, or register")
