#!/usr/bin/env python3
"""Map xcresult attachment exports to the stable App Store screenshot names."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
from typing import Any, Iterator, NoReturn


SCREENSHOT_NAMES = (
    "01-home.png",
    "02-chats.png",
    "03-conversation.png",
    "04-mobile-money.png",
    "05-bank-transfer.png",
    "06-calls.png",
    "07-profile.png",
)


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def records(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from records(child)
    elif isinstance(value, list):
        for child in value:
            yield from records(child)


def strings(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def labels_by_exported_filename(
    export_directory: pathlib.Path,
    exported_filenames: set[str],
) -> dict[str, set[str]]:
    labels: dict[str, set[str]] = {}
    manifests = sorted(export_directory.rglob("*.json"))
    if not manifests:
        fail(f"xcresult attachment export has no JSON manifest: {export_directory}")
    for manifest in manifests:
        if manifest.is_symlink() or not manifest.is_file():
            fail(f"Unsafe xcresult attachment manifest: {manifest}")
        try:
            value = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"Could not decode xcresult attachment manifest {manifest}: {error}")
        for record in records(value):
            values = [child for child in record.values() if isinstance(child, str)]
            for value_string in values:
                basename = pathlib.PurePath(value_string).name
                if basename in exported_filenames:
                    labels.setdefault(basename, set()).update(values)
    return labels


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-directory", type=pathlib.Path, required=True)
    parser.add_argument("--output-directory", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    export_directory = args.export_directory.resolve()
    if not export_directory.is_dir() or export_directory.is_symlink():
        fail(f"xcresult attachment export is missing or unsafe: {export_directory}")

    pngs = [
        path
        for path in export_directory.rglob("*")
        if path.suffix.lower() == ".png" and path.is_file() and not path.is_symlink()
    ]
    if len(pngs) != len(SCREENSHOT_NAMES):
        fail(
            f"Expected exactly {len(SCREENSHOT_NAMES)} exported PNG attachments; "
            f"found {len(pngs)}"
        )
    labels = labels_by_exported_filename(
        export_directory,
        {path.name for path in pngs},
    )

    mapping: dict[str, pathlib.Path] = {}
    for expected_name in SCREENSHOT_NAMES:
        stem = pathlib.Path(expected_name).stem.casefold()
        matches = []
        for path in pngs:
            associated = labels.get(path.name, set())
            searchable = [path.name, *associated]
            if any(stem in value.casefold() for value in searchable):
                matches.append(path)
        if len(matches) != 1:
            fail(
                f"Expected one xcresult attachment for {expected_name}; "
                f"found {[path.name for path in matches]}"
            )
        mapping[expected_name] = matches[0]

    if len(set(mapping.values())) != len(mapping):
        fail("One xcresult attachment matched more than one screenshot name")

    args.output_directory.mkdir(parents=True, exist_ok=True)
    if args.output_directory.is_symlink():
        fail(f"Unsafe screenshot output directory: {args.output_directory}")
    existing = list(args.output_directory.iterdir())
    if existing:
        fail(f"Screenshot output directory is not empty: {args.output_directory}")
    for expected_name, source in mapping.items():
        shutil.copyfile(source, args.output_directory / expected_name)


if __name__ == "__main__":
    main()
