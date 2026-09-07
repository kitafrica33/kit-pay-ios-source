"""Small Mach-O containers for policy tests, not signed Apple build products.

The entitlement values are transcribed from build88 native job 101751917058:
KitPayShare.appex-Simulated.xcent at log lines 5049–5064 and KitPay.app-Simulated.xcent
at lines 6972–6996. The ordinary signing .xcent dictionaries were empty.
"""
from pathlib import Path
import plistlib
import struct

PREFIX = "FAKETEAMID."
BUNDLE = "africa.kit.pay.ios"


def simulator_info(*, share=False):
    return {
        "CFBundleIdentifier": BUNDLE + (".share" if share else ""),
        "CFBundleExecutable": "KitPayShare" if share else "KitPay",
        "CFBundlePackageType": "XPC!" if share else "APPL",
        "DTPlatformName": "iphonesimulator",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "KitMessagingKeychainGroup": PREFIX + BUNDLE + ".messaging",
    }


def observed_entitlements(*, share=False):
    common = {
        "application-identifier": PREFIX + BUNDLE + (".share" if share else ""),
        "com.apple.security.application-groups": ["group." + BUNDLE],
        "keychain-access-groups": ([PREFIX + BUNDLE] if not share else []) + [PREFIX + BUNDLE + ".messaging"],
    }
    if not share:
        common.update({
            "aps-environment": "development",
            "com.apple.developer.icloud-container-identifiers": ["iCloud." + BUNDLE],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.usernotifications.time-sensitive": True,
        })
    return common


def macho(payload=None, *, platforms=(7,), section_names=(b"__entitlements",), segment=b"__TEXT", flags=0):
    payload = plistlib.dumps(observed_entitlements()) if payload is None else payload
    platform_commands = b"".join(struct.pack("<6I", 0x32, 24, value, 0x00110000, 0x001A0500, 0)
                                  for value in platforms)
    segment_size = 72 + 80 * len(section_names)
    command_size = len(platform_commands) + segment_size
    offset = (32 + command_size + 15) & ~15
    total = offset + len(payload) * len(section_names)
    vmaddr = 0x100000000
    segment_command = struct.pack("<II16sQQQQiiII", 0x19, segment_size, segment,
                                  vmaddr, (total + 0x3FFF) & ~0x3FFF, 0, total, 5, 5, len(section_names), 0)
    section_commands = b"".join(struct.pack("<16s16sQQIIIIIIII", section, segment,
                                           vmaddr + offset + i * len(payload), len(payload),
                                           offset + i * len(payload), 0, 0, 0, flags, 0, 0, 0)
                                 for i, section in enumerate(section_names))
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, len(platforms) + 1, command_size, 0x200085, 0)
    return (header + platform_commands + segment_command + section_commands).ljust(offset, b"\0") + payload * len(section_names)


def write_simulator_products(app: Path):
    for path, share in ((app, False), (app / "PlugIns/KitPayShare.appex", True)):
        path.mkdir(parents=True, exist_ok=True)
        info_path = path / "Info.plist"
        info = plistlib.loads(info_path.read_bytes()) if info_path.exists() else {}
        info.update(simulator_info(share=share))
        info_path.write_bytes(plistlib.dumps(info))
        executable = path / info["CFBundleExecutable"]
        executable.write_bytes(macho(plistlib.dumps(observed_entitlements(share=share))))
        executable.chmod(0o755)
