#!/usr/bin/env python3
"""Validate deterministic App Store screenshots and record immutable evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import struct
import zlib
from typing import NoReturn


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
SCREENSHOT_NAMES = (
    "01-home.png",
    "02-chats.png",
    "03-conversation.png",
    "04-mobile-money.png",
    "05-bank-transfer.png",
    "06-calls.png",
    "07-profile.png",
)
DEVICE_SPECS = (
    {
        "directory": "iphone-6.5",
        "deviceName": "iPhone 14 Plus",
        "width": 1284,
        "height": 2778,
        "runtimeArgument": "iphone_runtime",
    },
    {
        "directory": "ipad-13",
        "deviceName": "iPad Pro 13-inch (M4)",
        "width": 2064,
        "height": 2752,
        "runtimeArgument": "ipad_runtime",
    },
)


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def sha256(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def validate_png(path: pathlib.Path, width: int, height: int) -> dict[str, object]:
    if not path.is_file() or path.is_symlink():
        fail(f"Expected a regular screenshot: {path}")
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        fail(f"Screenshot is not a PNG: {path}")

    offset = len(PNG_SIGNATURE)
    chunk_index = 0
    found_idat = False
    found_iend = False
    image_width: int | None = None
    image_height: int | None = None
    color_type: int | None = None
    while offset < len(data):
        if len(data) - offset < 12:
            fail(f"Screenshot has a truncated PNG chunk: {path}")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(data):
            fail(f"Screenshot has a truncated PNG chunk: {path}")
        payload = data[payload_start:payload_end]
        expected_crc = struct.unpack(">I", data[payload_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            fail(f"Screenshot has an invalid PNG checksum: {path}")

        if chunk_index == 0 and chunk_type != b"IHDR":
            fail(f"Screenshot PNG does not begin with IHDR: {path}")
        if chunk_type == b"IHDR":
            if chunk_index != 0 or image_width is not None or length != 13:
                fail(f"Screenshot has a malformed PNG IHDR: {path}")
            (
                image_width,
                image_height,
                _bit_depth,
                color_type,
                compression_method,
                filter_method,
                interlace_method,
            ) = struct.unpack(">IIBBBBB", payload)
            if compression_method != 0 or filter_method != 0 or interlace_method not in (0, 1):
                fail(f"Screenshot has unsupported PNG encoding metadata: {path}")
            if color_type in (4, 6):
                fail(f"Screenshot PNG contains an alpha channel: {path}")
            if color_type not in (0, 2, 3):
                fail(f"Screenshot has an unsupported PNG color type: {path}")
        elif chunk_type == b"tRNS":
            fail(f"Screenshot PNG contains transparency metadata: {path}")
        elif chunk_type == b"IDAT":
            found_idat = True
        elif chunk_type == b"IEND":
            if length != 0:
                fail(f"Screenshot has a malformed PNG IEND: {path}")
            found_iend = True
            offset = crc_end
            break

        offset = crc_end
        chunk_index += 1

    if not found_idat or not found_iend or offset != len(data):
        fail(f"Screenshot is not a complete PNG: {path}")
    if (image_width, image_height) != (width, height):
        fail(
            f"Screenshot has dimensions {image_width}x{image_height}; "
            f"expected {width}x{height}: {path}"
        )
    return {
        "filename": path.name,
        "sha256": sha256(path),
        "size": len(data),
    }


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--iphone-runtime", required=True)
    parser.add_argument("--ipad-runtime", required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    if not SHA_PATTERN.fullmatch(args.source_commit):
        fail("The source commit must be a full lowercase Git SHA")
    if not re.fullmatch(r"[a-z]{2}(?:-[A-Z]{2})?", args.locale):
        fail("The screenshot locale is malformed")

    sets: list[dict[str, object]] = []
    all_hashes: set[str] = set()
    for specification in DEVICE_SPECS:
        directory = args.root / str(specification["directory"]) / args.locale
        if not directory.is_dir() or directory.is_symlink():
            fail(f"Screenshot directory is missing or unsafe: {directory}")
        actual_names = {
            path.name
            for path in directory.iterdir()
            if path.is_file() or path.is_symlink()
        }
        expected_names = set(SCREENSHOT_NAMES)
        if actual_names != expected_names:
            missing = sorted(expected_names - actual_names)
            unexpected = sorted(actual_names - expected_names)
            fail(
                f"Screenshot set is not exact for {directory}; "
                f"missing={missing}, unexpected={unexpected}"
            )

        screenshots = [
            validate_png(
                directory / filename,
                int(specification["width"]),
                int(specification["height"]),
            )
            for filename in SCREENSHOT_NAMES
        ]
        set_hashes = {str(item["sha256"]) for item in screenshots}
        if len(set_hashes) != len(screenshots):
            fail(f"Screenshot set contains duplicate images: {directory}")
        all_hashes.update(set_hashes)
        runtime = getattr(args, str(specification["runtimeArgument"]))
        if not runtime.strip():
            fail(f"Simulator runtime is empty for {directory}")
        sets.append(
            {
                "deviceClass": specification["directory"],
                "deviceName": specification["deviceName"],
                "runtime": runtime,
                "dimensions": {
                    "width": specification["width"],
                    "height": specification["height"],
                },
                "screenshots": screenshots,
            }
        )

    if len(all_hashes) != len(SCREENSHOT_NAMES) * len(DEVICE_SPECS):
        fail("Screenshots must be unique across both device sets")

    evidence = {
        "schemaVersion": 1,
        "evidenceType": "app-store-screenshot-set",
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "sourceCommit": args.source_commit,
        "locale": args.locale,
        "sets": sets,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
