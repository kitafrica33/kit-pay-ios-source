#!/usr/bin/env python3
"""Install existing products once and prepare XCTest to reuse those installations.

This checks installed-app visibility, not FrontBoard launch readiness. XCTest
remains responsible for launching the runner; tests and installs are never retried.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time


PRODUCTS = {
    "KitPay.app": "africa.kit.pay.ios",
    "KitPayUITests-Runner.app": "africa.kit.pay.ios.uitests.xctrunner",
}
TEST_TARGETS = {
    "KitPayTests": ("KitPay.app", "africa.kit.pay.ios.tests"),
    "KitPayUITests": ("KitPayUITests-Runner.app", "africa.kit.pay.ios.uitests"),
}
DESTINATION_RUN = "KitPay-installed-tests.xctestrun"


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


def destination_test_run(products_root: Path):
    """Derive a sibling plan using the documented xcodebuild.xctestrun(5) fields.

    Keep the generated file and its __TESTROOT__ unchanged. UseDestinationArtifacts
    prevents xcodebuild from installing either test host again during testing.
    """
    destination = products_root / DESTINATION_RUN
    generated = [path for path in products_root.glob("*.xctestrun") if path != destination]
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

    derived = copy.deepcopy(plan)
    target_bindings = {}
    for target in derived["TestConfigurations"][0]["TestTargets"]:
        name = target["BlueprintName"]
        host_name, _ = TEST_TARGETS[name]
        host = products_root / "Debug-iphonesimulator" / host_name
        host_executable = host / validate_bundle(host, PRODUCTS[host_name])
        app = products_root / "Debug-iphonesimulator/KitPay.app"
        bundle = host / "PlugIns" / (name + ".xctest")

        def require_path(key, *expected, optional=False):
            if optional and key not in target:
                return
            value = target.get(key)
            if not isinstance(value, str):
                raise RuntimeError("Missing generated " + key + " for " + name)
            expanded = value.replace("__TESTROOT__", str(products_root)).replace("__TESTHOST__", str(host))
            if Path(expanded).resolve() not in {path.resolve() for path in expected}:
                raise RuntimeError("Unexpected generated " + key + " for " + name)

        require_path("TestHostPath", host, host_executable)
        require_path("TestBundlePath", bundle)
        require_path("UITargetAppPath", app, optional=name == "KitPayTests")
        environment = target.get("TestingEnvironmentVariables")
        if (not isinstance(environment, dict)
                or any(not isinstance(key, str) or not isinstance(value, str)
                       for key, value in environment.items())):
            raise RuntimeError("Missing generated testing environment for " + name)
        if target.get("UseDestinationArtifacts", False) is not False:
            raise RuntimeError("Expected an unmodified generated XCTest target")
        bindings = {
            "UseDestinationArtifacts": True,
            "TestHostBundleIdentifier": PRODUCTS[host_name],
            "TestBundleDestinationRelativePath": "__TESTHOST__/PlugIns/" + name + ".xctest",
            "UITargetAppBundleIdentifier": PRODUCTS["KitPay.app"],
        }
        for key in ("TestHostBundleIdentifier", "UITargetAppBundleIdentifier"):
            if key in target and target[key] != bindings[key]:
                raise RuntimeError("Unexpected generated " + key + " for " + name)
        for key in ("TestBundlePath", "TestHostPath", "UITargetAppPath"):
            target.pop(key, None)
        target.update(bindings)
        target_bindings[name] = bindings

    prepared = plistlib.dumps(derived, sort_keys=False)
    if destination.exists() or destination.is_symlink():
        if (not destination.is_file() or destination.is_symlink()
                or destination.stat().st_size != len(prepared)
                or destination.read_bytes() != prepared):
            raise RuntimeError("Existing installed-product XCTest configuration does not match")
    else:
        with destination.open("xb") as stream:
            stream.write(prepared)
        destination.chmod(0o600)
    return {
        "generatedPath": str(source), "generatedSHA256": hashlib.sha256(original).hexdigest(),
        "preparedPath": str(destination), "preparedSHA256": hashlib.sha256(prepared).hexdigest(),
        "targets": target_bindings,
    }


def checked(arguments, *, data=None, timeout=90):
    return subprocess.run(arguments, input=data, capture_output=True, check=True,
                          timeout=timeout).stdout


def prepare(device: str, runner_temp: Path, *, clock=time.monotonic, pause=time.sleep):
    products = runner_temp / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator"
    selected = []
    for name, identifier in PRODUCTS.items():
        bundle = products / name
        validate_bundle(bundle, identifier)
        selected.append((bundle, identifier))
    for name, (host_name, identifier) in TEST_TARGETS.items():
        validate_bundle(products / host_name / "PlugIns" / (name + ".xctest"), identifier)

    receipt = runner_temp / ("KitPay-test-product-registration-" + device + ".json")
    evidence = {"deviceId": device, "installs": [], "observations": [],
                "installedApplicationsVisible": False, "frontBoardReadinessProven": False,
                "testInvocations": 0}
    # A failed or completed preparation for this device must never trigger another install.
    with receipt.open("x") as stream:
        stream.write(json.dumps(evidence, indent=2) + "\n")
    receipt.chmod(0o600)

    def retain():
        receipt.write_text(json.dumps(evidence, indent=2) + "\n")

    try:
        evidence["testRunConfiguration"] = destination_test_run(products.parent)
        retain()
        for bundle, identifier in selected:
            checked(["xcrun", "simctl", "install", device, str(bundle)])
            evidence["installs"].append({"bundleId": identifier, "source": str(bundle)})
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
            for _, identifier in selected:
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
                # The real app must be installed before assigning its Contacts permission.
                checked(["xcrun", "simctl", "privacy", device, "grant", "contacts", "africa.kit.pay.ios"])
                evidence["contactsPermissionGranted"] = True
                retain()
                print("Existing app and UI test runner are installed and visible on the selected Simulator.")
                return evidence
            if clock() >= deadline:
                raise RuntimeError("Simulator application registration did not become visible within 30 seconds")
            pause(1)
    except Exception as error:
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
        evidence["failure"] = failure
        retain()
        raise


if __name__ == "__main__":
    prepare(os.environ["KITPAY_TEST_DEVICE_ID"], Path(os.environ["RUNNER_TEMP"]))
