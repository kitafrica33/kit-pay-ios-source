#!/usr/bin/env python3
"""Check the ad-hoc Simulator products, without relaxing any distribution signing rule."""
from __future__ import annotations
import pathlib
import plistlib
import subprocess
import sys

SIMULATOR_PREFIX = "KITSIM0001."
BASE_BUNDLE = "africa.kit.pay.ios"


def validate(info: dict, entitlements: dict, *, share: bool) -> None:
    messaging = SIMULATOR_PREFIX + BASE_BUNDLE + ".messaging"
    expected = [messaging] if share else [SIMULATOR_PREFIX + BASE_BUNDLE, messaging]
    if info.get("KitMessagingKeychainGroup") != messaging:
        raise ValueError("Simulator messaging Keychain group was not resolved with the explicit test prefix")
    if entitlements.get("keychain-access-groups") != expected:
        raise ValueError("Simulator signed Keychain groups do not match messaging/private isolation")


def main() -> None:
    app = pathlib.Path(sys.argv[1])
    for path, share in ((app, False), (app / "PlugIns" / "KitPayShare.appex", True)):
        info = plistlib.loads((path / "Info.plist").read_bytes())
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)],
                                check=True, capture_output=True)
        validate(info, plistlib.loads(result.stdout), share=share)


if __name__ == "__main__":
    main()
