#!/usr/bin/env python3
"""Verify the arm64 Simulator products without changing them or distribution rules.

Xcode embeds simulated entitlements in __TEXT,__entitlements; its ad-hoc code
signature may have an empty entitlement dictionary. Read the executable's section
for Simulator policy and use codesign verification separately for integrity.
"""
from __future__ import annotations

import json
import mmap
import pathlib
import plistlib
import struct
import subprocess
import sys

# Xcode's identity for the existing teamless, ad-hoc Simulator build. Do not infer
# an allowed prefix from the very Info.plist/entitlements being verified.
SIMULATOR_PREFIX = "FAKETEAMID."
BASE_BUNDLE = "africa.kit.pay.ios"
MAX_PLIST_BYTES = 64 * 1024
MAX_LOAD_COMMAND_BYTES = 1024 * 1024


class UniqueKeys(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise ValueError(f"Duplicate plist key: {key}")
        super().__setitem__(key, value)


def dictionary(data: bytes) -> dict:
    if not 0 < len(data) <= MAX_PLIST_BYTES:
        raise ValueError("Missing or oversized Simulator plist")
    try:
        value = plistlib.loads(data, dict_type=UniqueKeys)
    except Exception as error:
        raise ValueError(f"Invalid Simulator plist ({type(error).__name__})") from error
    if not isinstance(value, dict):
        raise ValueError("Simulator plist must contain a dictionary")
    return value


def span(offset: int, size: int, limit: int, description: str) -> int:
    if offset < 0 or size < 0 or offset > limit or size > limit - offset:
        raise ValueError(f"Out-of-bounds {description}")
    return offset + size


def name(raw: bytes) -> bytes:
    value, separator, padding = raw.partition(b"\0")
    if separator and padding.strip(b"\0"):
        raise ValueError("Malformed Mach-O name padding")
    return value


def entitlements_from_executable(data: bytes | mmap.mmap) -> dict:
    """Parse only the thin arm64 executable format produced by this native job."""
    span(0, 32, len(data), "Mach-O header")
    magic, cpu, subtype, kind, count, command_bytes, _, reserved = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, kind, reserved) != (0xFEEDFACF, 0x0100000C, 0, 2, 0):
        raise ValueError("Expected a thin little-endian arm64 MH_EXECUTE Simulator binary; "
                         f"found magic={magic:#x}, cpu={cpu:#x}, subtype={subtype}, type={kind}, reserved={reserved}")
    if not 0 < command_bytes <= MAX_LOAD_COMMAND_BYTES or not 0 < count <= min(4096, command_bytes // 8):
        raise ValueError("Invalid Mach-O load-command count or size")
    command_end = span(32, command_bytes, len(data), "Mach-O load commands")
    cursor = 32
    platforms = []
    payloads = []
    segments = []
    sections = []
    text_count = 0
    for _ in range(count):
        span(cursor, 8, command_end, "Mach-O load-command header")
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or size % 8:
            raise ValueError("Invalid Mach-O load-command alignment or size")
        end = span(cursor, size, command_end, "Mach-O load command")
        if command == 0x32:  # LC_BUILD_VERSION, required for the iOS 17+ target.
            if size < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platform, _, _, tools = struct.unpack_from("<4I", data, cursor + 8)
            if size != 24 + tools * 8:
                raise ValueError("Invalid LC_BUILD_VERSION tool count")
            platforms.append(platform)
        elif command in (0x24, 0x25, 0x2F, 0x30):
            raise ValueError("Legacy platform commands are not accepted for this Simulator build")
        elif command == 0x19:  # LC_SEGMENT_64 and its section_64 records.
            if size < 72:
                raise ValueError("Truncated LC_SEGMENT_64")
            (_, _, raw_segment, vmaddr, vmsize, fileoff, filesize,
             _, _, section_count, _) = struct.unpack_from("<II16sQQQQiiII", data, cursor)
            if size != 72 + section_count * 80:
                raise ValueError("Invalid Mach-O section count")
            segment = name(raw_segment)
            segment_end = span(fileoff, filesize, len(data), "Mach-O segment")
            span(vmaddr, vmsize, 2**64, "Mach-O virtual segment")
            if filesize > vmsize:
                raise ValueError("Mach-O segment exceeds its virtual size")
            if filesize:
                segments.append((fileoff, segment_end))
            text_count += segment == b"__TEXT"
            for index in range(section_count):
                (raw_section, raw_owner, address, length, offset, alignment,
                 relocations, relocation_count, flags, _, _, _) = struct.unpack_from(
                    "<16s16sQQIIIIIIII", data, cursor + 72 + index * 80)
                section, owner = name(raw_section), name(raw_owner)
                if owner != segment or address < vmaddr or length > vmsize or address - vmaddr > vmsize - length:
                    raise ValueError("Mach-O section is outside its declared segment")
                span(relocations, relocation_count * 8, len(data), "Mach-O section relocations")
                if relocation_count and relocations < command_end:
                    raise ValueError("Mach-O relocations overlap the load-command table")
                if alignment > 31:
                    raise ValueError("Invalid Mach-O section alignment")
                section_type = flags & 0xFF
                if section_type not in (0x1, 0xC, 0x12) and length:  # File-backed, not zero-fill.
                    section_end = span(offset, length, len(data), "Mach-O section")
                    if offset < max(fileoff, command_end) or section_end > segment_end or offset % (1 << alignment):
                        raise ValueError("Mach-O section is outside its file segment or misaligned")
                    sections.append((offset, section_end))
                if section == b"__entitlements":
                    if segment != b"__TEXT" or section_type != 0 or not 0 < length <= MAX_PLIST_BYTES:
                        raise ValueError("Invalid simulated entitlement section")
                    if payloads:
                        raise ValueError("Duplicate simulated entitlement section")
                    payloads.append(bytes(data[offset:offset + length]))
        cursor = end
    if cursor != command_end:
        raise ValueError("Mach-O load-command count does not cover the declared table")
    if platforms != [7]:  # PLATFORM_IOSSIMULATOR; arm64 alone does not exclude a device binary.
        raise ValueError(f"Expected one iOS Simulator platform 7, found {platforms}")
    if text_count != 1 or len(payloads) != 1:
        raise ValueError("Expected exactly one __TEXT,__entitlements section")
    for ranges in (segments, sections):
        ordered = sorted(ranges)
        if any(left[1] > right[0] for left, right in zip(ordered, ordered[1:])):
            raise ValueError("Overlapping Mach-O file segments or sections")
    return dictionary(payloads[0])


def validate(info: dict, entitlements: dict, *, share: bool) -> None:
    bundle = BASE_BUNDLE + (".share" if share else "")
    executable = "KitPayShare" if share else "KitPay"
    messaging = SIMULATOR_PREFIX + BASE_BUNDLE + ".messaging"
    expected = [messaging] if share else [SIMULATOR_PREFIX + BASE_BUNDLE, messaging]
    for key, expected_value in {
        "CFBundleIdentifier": bundle, "CFBundleExecutable": executable,
        "CFBundlePackageType": "XPC!" if share else "APPL",
        "DTPlatformName": "iphonesimulator", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "KitMessagingKeychainGroup": messaging,
    }.items():
        if info.get(key) != expected_value:
            raise ValueError(f"{bundle}: {key} is {info.get(key)!r}; expected {expected_value!r}")
    if entitlements.get("application-identifier") != SIMULATOR_PREFIX + bundle:
        raise ValueError(f"{bundle}: embedded Simulator application-identifier does not match its bundle/prefix")
    if entitlements.get("keychain-access-groups") != expected:
        raise ValueError(f"{bundle}: embedded Keychain groups {entitlements.get('keychain-access-groups')!r} do not match {expected!r}")


def verify_products(app: pathlib.Path) -> None:
    # Keep symlink checks below while ensuring a relative path cannot become a
    # codesign option. absolute() does not resolve away the original symlink.
    app = app.absolute()
    if app.is_symlink() or not app.is_dir():
        raise ValueError("Expected a Simulator app directory, not a symlink")
    for path, share in ((app, False), (app / "PlugIns" / "KitPayShare.appex", True)):
        if path.is_symlink() or path.parent.is_symlink() or not path.is_dir():
            raise ValueError("Missing or redirected Simulator bundle")
        info_path = path / "Info.plist"
        if info_path.is_symlink() or not info_path.is_file() or info_path.stat().st_size > MAX_PLIST_BYTES:
            raise ValueError("Missing, non-file, redirected or oversized Simulator Info.plist")
        info = dictionary(info_path.read_bytes())
        executable_name = "KitPayShare" if share else "KitPay"
        executable = path / executable_name
        if executable.is_symlink() or not executable.is_file():
            raise ValueError(f"Missing or redirected Simulator executable: {executable_name}")
        with executable.open("rb") as stream:
            if executable.stat().st_size < 32:
                raise ValueError("Truncated Simulator executable")
            with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                entitlements = entitlements_from_executable(data)
        print(json.dumps({
            "bundle": info.get("CFBundleIdentifier"), "executable": info.get("CFBundleExecutable"),
            "platform": info.get("DTPlatformName"), "machOPlatform": 7, "architecture": "arm64",
            "applicationIdentifier": entitlements.get("application-identifier"),
            "expectedSimulatorPrefix": SIMULATOR_PREFIX,
            "messagingGroup": info.get("KitMessagingKeychainGroup"),
            "keychainGroups": entitlements.get("keychain-access-groups"),
        }), flush=True)
        validate(info, entitlements, share=share)
    # Verify the original ad-hoc signatures, including nested code. Never re-sign,
    # patch a plist, or ask codesign -d for the separate simulated entitlements.
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(json.dumps({"simulatorMessagingVerified": True, "signaturesVerified": True}), flush=True)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: verify_ios_simulator_messaging.py KitPay.app")
        verify_products(pathlib.Path(sys.argv[1]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Simulator messaging verification failed: {error}", file=sys.stderr)
        sys.exit(1)
