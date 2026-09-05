#!/usr/bin/env python3
"""Install existing native test products and observe their Simulator registration.

This checks installed-app visibility, not FrontBoard launch readiness. XCTest
remains responsible for launching the runner; tests and installs are never retried.
"""
from __future__ import annotations

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


def checked(arguments, *, data=None, timeout=90):
    return subprocess.run(arguments, input=data, capture_output=True, check=True,
                          timeout=timeout).stdout


def prepare(device: str, runner_temp: Path, *, clock=time.monotonic, pause=time.sleep):
    products = runner_temp / "KitPay-quality-derived/Build/Products/Debug-iphonesimulator"
    selected = []
    for name, identifier in PRODUCTS.items():
        bundle = products / name
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        executable = info.get("CFBundleExecutable")
        if (info.get("CFBundleIdentifier") != identifier
                or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
                or not isinstance(executable, str) or Path(executable).name != executable
                or not (bundle / executable).is_file()):
            raise RuntimeError("Unexpected Simulator test product: " + name)
        selected.append((bundle, identifier))

    receipt = runner_temp / ("KitPay-test-product-registration-" + device + ".json")
    evidence = {"deviceId": device, "installs": [], "observations": [],
                "installedApplicationsVisible": False, "frontBoardReadinessProven": False,
                "testInvocations": 0}

    def retain():
        receipt.write_text(json.dumps(evidence, indent=2) + "\n")

    try:
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
