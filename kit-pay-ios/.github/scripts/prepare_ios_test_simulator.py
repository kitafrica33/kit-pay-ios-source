#!/usr/bin/env python3
"""Create and record one clean, pinned Simulator for native validation."""

import json
import os
from pathlib import Path
import re
import subprocess


RUNTIME = {
    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "name": "iOS 26.5",
    "version": "26.5",
    "buildversion": "23F77",
}
DEVICE_TYPE = {
    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "name": "iPhone 17 Pro",
}
UUID_PATTERN = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"


def simctl(*arguments, capture=False):
    return subprocess.run(
        ["xcrun", "simctl", *arguments], check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
        timeout=300 if arguments[0] == "bootstatus" else 60,
    ).stdout


def require_metadata(items, expected, kind):
    matches = [item for item in items if item.get("identifier") == expected["identifier"]]
    if len(matches) != 1:
        raise ValueError(f"Required {kind} {expected['identifier']} is missing or ambiguous")
    for field, value in expected.items():
        if matches[0].get(field) != value:
            raise ValueError(f"Required {kind} {field}={value!r}; found {matches[0].get(field)!r}")
    return matches[0]


def prepare(env=None):
    env = os.environ if env is None else env
    run_id, attempt = (env.get(key, "") for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"))
    if not all(re.fullmatch(r"[1-9][0-9]*", value) for value in (run_id, attempt)):
        raise ValueError("GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be positive ASCII integers")
    if not env.get("RUNNER_TEMP") or not env.get("GITHUB_ENV"):
        raise ValueError("RUNNER_TEMP and GITHUB_ENV are required")
    runner_temp = Path(env["RUNNER_TEMP"])
    if not runner_temp.is_dir():
        raise ValueError("RUNNER_TEMP must be an existing directory")
    receipt = runner_temp / f"KitPay-native-simulator-{run_id}-{attempt}.json"
    if receipt.exists():
        raise FileExistsError(f"Simulator preparation already has a receipt: {receipt}")

    runtimes = json.loads(simctl("list", "runtimes", "-j", capture=True))["runtimes"]
    runtime = require_metadata(runtimes, RUNTIME, "runtime")
    if runtime.get("isAvailable") is not True:
        raise ValueError(f"Required runtime {RUNTIME['identifier']} is unavailable")
    device_types = json.loads(simctl("list", "devicetypes", "-j", capture=True))["devicetypes"]
    require_metadata(device_types, DEVICE_TYPE, "device type")

    name = f"KitPay Native Tests {run_id}-{attempt}"
    # Reserve writable evidence and environment files before creating anything.
    # Never replace an earlier run/attempt receipt or use a pre-existing device.
    with Path(env["GITHUB_ENV"]).open("a") as github_env, receipt.open("x") as evidence:
        device_id = simctl("create", name, DEVICE_TYPE["identifier"], RUNTIME["identifier"], capture=True).strip()
        if re.fullmatch(UUID_PATTERN, device_id) is None:
            raise ValueError(f"simctl create returned an invalid device UUID: {device_id!r}")
        json.dump({
            "device_id": device_id, "name": name, "run_id": run_id, "run_attempt": attempt,
            "runtime": RUNTIME, "device_type": DEVICE_TYPE,
        }, evidence, indent=2)
        evidence.write("\n")
        evidence.flush()
        github_env.write(f"KITPAY_TEST_DEVICE_ID={device_id}\nKITPAY_NATIVE_TEST_DEVICE_ID={device_id}\n")
        github_env.flush()

    simctl("boot", device_id)
    simctl("bootstatus", device_id, "-b")
    return device_id


if __name__ == "__main__":
    print(prepare())
