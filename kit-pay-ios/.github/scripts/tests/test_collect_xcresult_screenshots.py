from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
COLLECTOR = ROOT / ".github/scripts/collect_xcresult_screenshots.py"
NAMES = (
    "01-home.png",
    "02-chats.png",
    "03-conversation.png",
    "04-mobile-money.png",
    "05-bank-transfer.png",
    "06-calls.png",
    "07-profile.png",
)


class XCResultScreenshotCollectorTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        exported = root / "exported"
        output = root / "output"
        exported.mkdir()
        attachments = []
        for index, name in enumerate(NAMES):
            exported_name = f"attachment-{index}.png"
            (exported / exported_name).write_bytes(f"png-{index}".encode("ascii"))
            attachments.append(
                {
                    "exportedFileName": exported_name,
                    "suggestedHumanReadableName": f"Kit Pay screenshot - {name}",
                }
            )
        (exported / "manifest.json").write_text(
            json.dumps({"tests": [{"attachments": attachments}]}),
            encoding="utf-8",
        )
        return exported, output

    def command(self, exported: pathlib.Path, output: pathlib.Path) -> list[str]:
        return [
            sys.executable,
            str(COLLECTOR),
            "--export-directory",
            str(exported),
            "--output-directory",
            str(output),
        ]

    def test_maps_manifest_labels_to_stable_names(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            exported, output = self.fixture(pathlib.Path(raw))
            subprocess.run(
                self.command(exported, output),
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(sorted(path.name for path in output.iterdir()), sorted(NAMES))
            for index, name in enumerate(NAMES):
                self.assertEqual((output / name).read_bytes(), f"png-{index}".encode("ascii"))

    def test_rejects_an_unlabelled_attachment(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            exported, output = self.fixture(pathlib.Path(raw))
            manifest = exported / "manifest.json"
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["tests"][0]["attachments"][0]["suggestedHumanReadableName"] = "unknown"
            manifest.write_text(json.dumps(value), encoding="utf-8")
            result = subprocess.run(
                self.command(exported, output),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("01-home.png", result.stderr)

    def test_rejects_extra_pngs_and_nonempty_output(self) -> None:
        for case in ("extra", "nonempty"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                exported, output = self.fixture(pathlib.Path(raw))
                if case == "extra":
                    (exported / "extra.png").write_bytes(b"extra")
                else:
                    output.mkdir()
                    (output / "old.png").write_bytes(b"old")
                result = subprocess.run(
                    self.command(exported, output),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "exactly" if case == "extra" else "not empty",
                    result.stderr,
                )


if __name__ == "__main__":
    unittest.main()
