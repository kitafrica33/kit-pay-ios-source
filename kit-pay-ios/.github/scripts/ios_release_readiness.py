#!/usr/bin/env python3
"""Read-only publication and credential checks before allocating a native build."""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile

import create_ios_app_store_profile as profiles


def openssl(*arguments: str, data: bytes | None = None) -> bytes:
    result = subprocess.run(["openssl", *arguments], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0 or not result.stdout:
        raise profiles.ProvisioningError("Apple signing material could not be verified.")
    return result.stdout


def distribution_certificate() -> bytes:
    team = os.environ.get("APPLE_TEAM_ID", "").strip()
    password = os.environ.get("CERTIFICATE_PASSWORD", "").strip()
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[a-fA-F0-9]{64}", password):
        raise profiles.ProvisioningError("Apple team or distribution certificate password is malformed.")
    try:
        payload = base64.b64decode("".join(os.environ.get("CERTIFICATE_BASE64", "").split()), validate=True)
    except ValueError:
        raise profiles.ProvisioningError("Distribution certificate is not valid base64.") from None
    if not payload or len(payload) > 1_000_000:
        raise profiles.ProvisioningError("Distribution certificate is empty or oversized.")
    # Match the existing signing import's normalization without putting the password in argv.
    os.environ["KITPAY_READINESS_P12_PASSWORD"] = password
    try:
        with tempfile.TemporaryDirectory(prefix="kitpay-readiness-") as directory:
            certificate = Path(directory) / "distribution.p12"
            certificate.write_bytes(payload)
            certificate.chmod(0o600)
            common = ("pkcs12", "-in", str(certificate), "-passin", "env:KITPAY_READINESS_P12_PASSWORD")
            try:
                pem = openssl(*common, "-clcerts", "-nokeys")
                private = openssl(*common, "-nocerts", "-nodes")
            except profiles.ProvisioningError:
                # OpenSSL 3 disables older PKCS#12 ciphers by default. macOS
                # still imports those valid key containers; preserve that support.
                pem = openssl(*common, "-legacy", "-clcerts", "-nokeys")
                private = openssl(*common, "-legacy", "-nocerts", "-nodes")
            if pem.count(b"-----BEGIN CERTIFICATE-----") != 1:
                raise profiles.ProvisioningError("Expected exactly one distribution certificate.")
            public_key = openssl("x509", "-pubkey", "-noout", data=pem)
            if openssl("pkey", "-pubout", "-outform", "DER", data=private) != openssl(
                "pkey", "-pubin", "-outform", "DER", data=public_key
            ):
                raise profiles.ProvisioningError("Distribution certificate and private key do not match.")
            subject = openssl("x509", "-subject", "-noout", "-nameopt", "RFC2253", data=pem).decode()
            if f"OU={team}" not in subject or "Apple Distribution:" not in subject:
                raise profiles.ProvisioningError("Distribution certificate has the wrong team or type.")
            return openssl("x509", "-outform", "DER", data=pem)
    finally:
        os.environ.pop("KITPAY_READINESS_P12_PASSWORD", None)


def verify_app_and_unused_build(client, bundle: str, version: str, build: str) -> None:
    if bundle != "africa.kit.pay.ios" or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version) \
            or not re.fullmatch(r"[1-9][0-9]{0,17}", build):
        raise profiles.ProvisioningError("The selected iOS publication identity is invalid.")
    response = client.request("GET", "/v1/apps", query={"filter[bundleId]": bundle, "limit": "2"},
                              expected_status=200, operation="publication readiness lookup")
    apps = profiles._collection(response, "app")
    if len(apps) != 1:
        raise profiles.ProvisioningError("The selected App Store application was not found uniquely.")
    app_id, attributes = profiles._resource(apps[0], "apps", "app")
    if attributes.get("bundleId") != bundle:
        raise profiles.ProvisioningError("App Store returned the wrong application.")
    response = client.request("GET", "/v1/builds", query={
        "filter[app]": app_id, "filter[version]": build,
        "filter[preReleaseVersion.version]": version, "filter[preReleaseVersion.platform]": "IOS", "limit": "1",
    }, expected_status=200, operation="unused build number lookup")
    if profiles._collection(response, "build"):
        raise profiles.ProvisioningError("This iOS build already exists in App Store Connect; reuse its retained release evidence.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("archive", "upload"), required=True)
    args = parser.parse_args()
    try:
        client = profiles.AppStoreConnectClient(*profiles._configuration())
        verify_app_and_unused_build(client, os.environ.get("IOS_BUNDLE_ID", ""),
                                    os.environ.get("MARKETING_VERSION", ""), os.environ.get("BUILD_NUMBER", ""))
        if args.mode == "archive":
            profiles._find_distribution_certificate(client, distribution_certificate())
    except profiles.ProvisioningError as error:
        raise SystemExit(f"iOS release readiness refused: {error}") from None
    print("Apple authentication, application identity, and unused build number verified.")


if __name__ == "__main__":
    main()
