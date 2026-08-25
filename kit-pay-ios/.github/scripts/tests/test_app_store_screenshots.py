from __future__ import annotations

import hashlib
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / ".github/scripts/validate_app_store_screenshots.py"
NAMES = (
    "01-home.png",
    "02-chats.png",
    "03-conversation.png",
    "04-mobile-money.png",
    "05-bank-transfer.png",
    "06-calls.png",
    "07-profile.png",
)
SPECS = (
    ("iphone-6.5", 1284, 2778),
    ("ipad-13", 2064, 2752),
)


def chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def png(width: int, height: int, marker: str, *, color_type: int = 2, transparent: bool = False) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    result = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    result += chunk(b"tEXt", f"fixture={marker}".encode("ascii"))
    if transparent:
        result += chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00")
    result += chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00"))
    result += chunk(b"IEND", b"")
    return result


class AppStoreScreenshotValidatorTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, list[str]]:
        screenshots = root / "screenshots"
        hashes: list[str] = []
        for device, width, height in SPECS:
            directory = screenshots / device / "en-US"
            directory.mkdir(parents=True)
            for index, name in enumerate(NAMES):
                payload = png(width, height, f"{device}-{index}")
                (directory / name).write_bytes(payload)
                hashes.append(hashlib.sha256(payload).hexdigest())
        manifest = root / "manifest.json"
        return screenshots, manifest, hashes

    def command(self, screenshots: pathlib.Path, manifest: pathlib.Path) -> list[str]:
        return [
            sys.executable,
            str(VALIDATOR),
            "--root",
            str(screenshots),
            "--source-commit",
            "a" * 40,
            "--locale",
            "en-US",
            "--iphone-runtime",
            "iOS 26.4",
            "--ipad-runtime",
            "iOS 26.4",
            "--manifest",
            str(manifest),
        ]

    def test_accepts_exact_opaque_sets_and_records_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            screenshots, manifest, hashes = self.fixture(pathlib.Path(raw))
            subprocess.run(
                self.command(screenshots, manifest),
                check=True,
                capture_output=True,
                text=True,
            )

            evidence = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(evidence["sourceCommit"], "a" * 40)
            self.assertEqual(evidence["locale"], "en-US")
            self.assertEqual(len(evidence["sets"]), 2)
            recorded_hashes = [
                screenshot["sha256"]
                for screenshot_set in evidence["sets"]
                for screenshot in screenshot_set["screenshots"]
            ]
            self.assertEqual(recorded_hashes, hashes)

    def test_rejects_wrong_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            screenshots, manifest, _ = self.fixture(pathlib.Path(raw))
            path = screenshots / "iphone-6.5/en-US/01-home.png"
            path.write_bytes(png(1290, 2796, "wrong-size"))
            result = subprocess.run(
                self.command(screenshots, manifest),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected 1284x2778", result.stderr)

    def test_rejects_alpha_and_transparency_chunks(self) -> None:
        cases = (
            ("alpha channel", {"color_type": 6}),
            ("transparency metadata", {"transparent": True}),
        )
        for expected, options in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as raw:
                screenshots, manifest, _ = self.fixture(pathlib.Path(raw))
                path = screenshots / "iphone-6.5/en-US/01-home.png"
                path.write_bytes(png(1284, 2778, expected, **options))
                result = subprocess.run(
                    self.command(screenshots, manifest),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_rejects_missing_unexpected_and_duplicate_images(self) -> None:
        cases = ("missing", "unexpected", "duplicate")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                screenshots, manifest, _ = self.fixture(pathlib.Path(raw))
                directory = screenshots / "iphone-6.5/en-US"
                if case == "missing":
                    (directory / NAMES[0]).unlink()
                elif case == "unexpected":
                    (directory / "extra.png").write_bytes(png(1284, 2778, "extra"))
                else:
                    (directory / NAMES[1]).write_bytes((directory / NAMES[0]).read_bytes())
                result = subprocess.run(
                    self.command(screenshots, manifest),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "duplicate images" if case == "duplicate" else "not exact",
                    result.stderr,
                )

    def test_rejects_corrupt_png_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            screenshots, manifest, _ = self.fixture(pathlib.Path(raw))
            path = screenshots / "iphone-6.5/en-US/01-home.png"
            payload = bytearray(path.read_bytes())
            payload[-1] ^= 0xFF
            path.write_bytes(payload)
            result = subprocess.run(
                self.command(screenshots, manifest),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid PNG checksum", result.stderr)


if __name__ == "__main__":
    unittest.main()
