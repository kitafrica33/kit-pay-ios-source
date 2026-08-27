#!/usr/bin/env python3
"""Validate Kit Pay's CloudKit schema and optionally import it to development.

The default operation is local validation only. The supported remote operation
imports the schema to CloudKit's development environment with an exact
confirmation and a CloudKit management token. Apple requires production schemas
to be promoted from development in CloudKit Console; App Store Connect
credentials cannot manage CloudKit schemas.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import NoReturn


EXPECTED_CONTAINER_ID = "iCloud.africa.kit.pay.ios"
EXPECTED_TEAM_ID = "AU55CKVJ55"
IMPORT_CONFIRMATION = "IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT"
EXPECTED_SCHEMA = """DEFINE SCHEMA
  RECORD TYPE KitMessageBackup (
    payload ASSET,
    createdAt TIMESTAMP,
    newestMessageAt TIMESTAMP,
    byteSize INT64,
    messageCount INT64,
    schemaVersion INT64,
    generation INT64,
    deviceName STRING,
    contentDigest STRING,
    GRANT WRITE TO "_creator",
    GRANT CREATE TO "_icloud",
    GRANT READ TO "_creator"
  );
"""
DEFAULT_SCHEMA = (
    Path(__file__).resolve().parents[1] / "cloudkit" / "KitMessageBackup.ckdb"
)


class SchemaError(RuntimeError):
    """A credential-safe CloudKit schema failure."""


def fail(message: str) -> NoReturn:
    raise SchemaError(message)


def validate_schema(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        fail("The CloudKit schema must be a regular checked-in file.")
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        fail("The CloudKit schema could not be read as UTF-8.")
    if content != EXPECTED_SCHEMA:
        fail("The CloudKit schema does not exactly match KitMessageBackup's fields.")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate the KitMessageBackup schema locally; optionally validate "
            "and import it explicitly to the CloudKit development environment."
        )
    )
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--import-development", action="store_true")
    parser.add_argument("--team-id")
    parser.add_argument("--container-id")
    parser.add_argument("--environment")
    parser.add_argument("--confirmation")
    parser.add_argument(
        "--use-saved-management-token",
        action="store_true",
        help="Use a management token previously stored by `xcrun cktool save-token`.",
    )
    return parser.parse_args()


def import_development_schema(args: argparse.Namespace) -> None:
    if args.environment != "development":
        fail("--environment must exactly match the selected development import.")
    if args.confirmation != IMPORT_CONFIRMATION:
        fail(f"Schema import requires confirmation {IMPORT_CONFIRMATION}.")
    if args.team_id != EXPECTED_TEAM_ID:
        fail(f"--team-id must be exactly {EXPECTED_TEAM_ID}.")
    if args.container_id != EXPECTED_CONTAINER_ID:
        fail(f"--container-id must be exactly {EXPECTED_CONTAINER_ID}.")

    management_token = os.environ.get("CLOUDKIT_MANAGEMENT_TOKEN", "")
    if args.use_saved_management_token and management_token:
        fail("Choose either a saved or an environment-provided management token.")
    if not args.use_saved_management_token and not management_token:
        fail(
            "Import requires --use-saved-management-token or the separate "
            "CLOUDKIT_MANAGEMENT_TOKEN environment variable."
        )
    if management_token and (
        len(management_token) > 16_384
        or any(character.isspace() or character == "\0" for character in management_token)
    ):
        fail("CLOUDKIT_MANAGEMENT_TOKEN has an invalid format.")

    xcrun = shutil.which("xcrun")
    if xcrun is None:
        fail("xcrun with cktool is required for an explicit schema import.")
    child_environment = os.environ.copy()
    child_environment.pop("CLOUDKIT_MANAGEMENT_TOKEN", None)
    common_arguments = [
        "--team-id",
        EXPECTED_TEAM_ID,
        "--container-id",
        EXPECTED_CONTAINER_ID,
        "--environment",
        "development",
        "--file",
        str(args.schema.resolve()),
    ]
    token_arguments = ["--token", management_token] if management_token else []
    for operation in ("validate-schema", "import-schema"):
        result = subprocess.run(
            [xcrun, "cktool", operation, *common_arguments, *token_arguments],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=child_environment,
        )
        if result.returncode != 0:
            fail(
                f"cktool could not {operation}; no command output or token was logged."
            )


def main() -> None:
    args = arguments()
    validate_schema(args.schema)
    if not args.import_development:
        unexpected = (
            args.team_id,
            args.container_id,
            args.environment,
            args.confirmation,
            args.use_saved_management_token,
        )
        if any(value not in (None, False) for value in unexpected):
            fail("Import-only options require an explicit import switch.")
        print("KitMessageBackup CloudKit schema is valid; no remote action was taken.")
        return
    import_development_schema(args)
    print(
        "KitMessageBackup schema was validated and imported to CloudKit development; "
        "promote it to production from CloudKit Console after reviewing the pending changes."
    )


if __name__ == "__main__":
    try:
        main()
    except SchemaError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None
