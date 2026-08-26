#!/usr/bin/env python3
"""Create Kit Pay's App Store profile through the App Store Connect API.

The script enables the explicit bundle ID's required capabilities,
matches the already-imported distribution certificate by its exact DER bytes,
and creates one fresh IOS_APP_STORE profile. It never logs API response bodies,
resource identifiers, tokens, private-key material, or provisioning-profile
content. The caller must still decode and validate the resulting profile before
using it to sign an archive.
"""

from __future__ import annotations

import argparse
import base64
from collections.abc import Callable
import datetime as dt
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import NoReturn
import urllib.error
import urllib.parse
import urllib.request


_API_ORIGIN = "https://api.appstoreconnect.apple.com"
_MAX_RESPONSE_BYTES = 2_000_000
_MAX_CERTIFICATE_BYTES = 100_000
_MAX_PROFILE_BYTES = 1_000_000
_UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
_RESOURCE_ID_PATTERN = re.compile(r"[A-Za-z0-9._:-]{1,256}")
_BUNDLE_ID_PATTERN = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_PROFILE_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._()-]{0,99}")
_IOS_BUNDLE_ID_PLATFORMS = {"IOS", "UNIVERSAL"}
_DISTRIBUTION_CERTIFICATE_TYPES = {"DISTRIBUTION", "IOS_DISTRIBUTION"}
_TRANSIENT_HTTP_STATUSES = frozenset({429, 500, 502, 503, 504})
_PROFILE_CREATION_RETRYABLE_HTTP_STATUSES = _TRANSIENT_HTTP_STATUSES | {409}
_CAPABILITY_PROPAGATION_DELAYS_SECONDS = (1.0, 2.0, 4.0, 8.0, 16.0)
_PROFILE_CREATION_RETRY_DELAYS_SECONDS = (1.0, 2.0, 4.0, 8.0, 16.0)
_ICLOUD_SETTINGS = [
    {
        "key": "ICLOUD_VERSION",
        "options": [{"key": "XCODE_6"}],
    }
]


class ProvisioningError(RuntimeError):
    """A credential-safe, user-actionable provisioning failure."""


class AppStoreConnectHTTPError(ProvisioningError):
    """An App Store Connect HTTP failure whose response body stays private."""

    def __init__(self, status: int, operation: str) -> None:
        self.status = status
        super().__init__(
            f"App Store Connect {operation} failed with HTTP {status}; "
            "no body was logged."
        )


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        del request, file_pointer, code, message, headers, new_url
        return None


def _fail(message: str) -> NoReturn:
    raise ProvisioningError(message)


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        _fail(f"{name} is required for App Store profile generation.")
    return value


def _configuration() -> tuple[str, str, str]:
    issuer_id = _required_environment("APP_STORE_CONNECT_ISSUER_ID")
    key_id = _required_environment("APP_STORE_CONNECT_KEY_ID")
    private_key = _required_environment("APP_STORE_CONNECT_PRIVATE_KEY")

    if _UUID_PATTERN.fullmatch(issuer_id) is None:
        _fail("APP_STORE_CONNECT_ISSUER_ID must be a UUID.")
    if re.fullmatch(r"[A-Z0-9]{10}", key_id) is None:
        _fail("APP_STORE_CONNECT_KEY_ID must be a 10-character key identifier.")
    if "\\n" in private_key and "\n" not in private_key:
        private_key = private_key.replace("\\n", "\n")
    private_key = private_key.strip() + "\n"
    if len(private_key) > 20_000 or not (
        private_key.startswith("-----BEGIN PRIVATE KEY-----\n")
        and private_key.endswith("\n-----END PRIVATE KEY-----\n")
    ):
        _fail("APP_STORE_CONNECT_PRIVATE_KEY must be a PKCS#8 PEM key.")
    return issuer_id, key_id, private_key


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _read_der_length(value: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(value):
        _fail("App Store Connect signing returned an invalid ECDSA signature.")
    first = value[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    length_octets = first & 0x7F
    if length_octets == 0 or length_octets > 4 or offset + length_octets > len(value):
        _fail("App Store Connect signing returned an invalid ECDSA signature.")
    length = int.from_bytes(value[offset : offset + length_octets], "big")
    return length, offset + length_octets


def _der_to_jose_signature(signature: bytes) -> bytes:
    if not signature or signature[0] != 0x30:
        _fail("App Store Connect signing returned an invalid ECDSA signature.")
    sequence_length, offset = _read_der_length(signature, 1)
    sequence_end = offset + sequence_length
    if sequence_end != len(signature):
        _fail("App Store Connect signing returned an invalid ECDSA signature.")

    integers: list[bytes] = []
    for _ in range(2):
        if offset >= sequence_end or signature[offset] != 0x02:
            _fail("App Store Connect signing returned an invalid ECDSA signature.")
        integer_length, offset = _read_der_length(signature, offset + 1)
        integer_end = offset + integer_length
        if integer_length == 0 or integer_end > sequence_end:
            _fail("App Store Connect signing returned an invalid ECDSA signature.")
        integer = signature[offset:integer_end]
        offset = integer_end
        if integer[0] & 0x80:
            _fail("App Store Connect signing returned an invalid ECDSA signature.")
        while len(integer) > 32 and integer[0] == 0:
            integer = integer[1:]
        if len(integer) > 32:
            _fail("App Store Connect signing returned an invalid ECDSA signature.")
        integers.append(integer.rjust(32, b"\0"))
    if offset != sequence_end:
        _fail("App Store Connect signing returned an invalid ECDSA signature.")
    return b"".join(integers)


def _create_token(issuer_id: str, key_id: str, private_key: str) -> str:
    issued_at = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": issued_at,
        "exp": issued_at + 600,
        "aud": "appstoreconnect-v1",
    }
    encoded_header = _base64url(
        json.dumps(header, separators=(",", ":"), sort_keys=True).encode("ascii")
    )
    encoded_payload = _base64url(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("ascii")
    )
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    openssl = shutil.which("openssl")
    if openssl is None:
        _fail("OpenSSL is required for App Store Connect authentication.")

    with tempfile.TemporaryDirectory(prefix="kitpay-profile-token-") as directory:
        key_path = Path(directory) / "AuthKey.p8"
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="ascii") as key_file:
            key_file.write(private_key)
        result = subprocess.run(
            [openssl, "dgst", "-sha256", "-sign", str(key_path)],
            input=signing_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"},
        )
    if result.returncode != 0 or not result.stdout:
        _fail("The App Store Connect private key could not sign an API token.")
    signature = _base64url(_der_to_jose_signature(result.stdout))
    return f"{encoded_header}.{encoded_payload}.{signature}"


class AppStoreConnectClient:
    def __init__(self, issuer_id: str, key_id: str, private_key: str) -> None:
        self._token = _create_token(issuer_id, key_id, private_key)
        self._opener = urllib.request.build_opener(_NoRedirectHandler())

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict[str, object] | None = None,
        expected_status: int,
        operation: str,
    ) -> object:
        if method not in {"GET", "POST", "PATCH"} or not path.startswith("/v1/"):
            _fail("Refusing an unsupported App Store Connect request.")
        url = _API_ORIGIN + path
        if query:
            url += "?" + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        encoded_body = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._token}",
            "User-Agent": "KitPay-iOS-release-provisioning/1",
        }
        if body is not None:
            encoded_body = json.dumps(
                body,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            url,
            data=encoded_body,
            headers=headers,
            method=method,
        )
        try:
            with self._opener.open(request, timeout=30) as response:
                if response.status != expected_status:
                    raise AppStoreConnectHTTPError(response.status, operation)
                if response.geturl() != url:
                    _fail(f"App Store Connect {operation} returned an unexpected endpoint.")
                content_type = response.headers.get_content_type()
                if content_type != "application/json":
                    _fail(f"App Store Connect {operation} returned unexpected content.")
                response_body = response.read(_MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise AppStoreConnectHTTPError(status, operation) from None
        except (OSError, TimeoutError, urllib.error.URLError):
            _fail(f"App Store Connect {operation} could not be completed.")
        if not response_body or len(response_body) > _MAX_RESPONSE_BYTES:
            _fail(f"App Store Connect {operation} returned an invalid response size.")
        try:
            return json.loads(response_body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            _fail(f"App Store Connect {operation} returned invalid JSON.")


def _resource(value: object, expected_type: str, label: str) -> tuple[str, dict[str, object]]:
    if not isinstance(value, dict) or value.get("type") != expected_type:
        _fail(f"App Store Connect returned an invalid {label} resource.")
    resource_id = value.get("id")
    attributes = value.get("attributes")
    if (
        not isinstance(resource_id, str)
        or _RESOURCE_ID_PATTERN.fullmatch(resource_id) is None
        or not isinstance(attributes, dict)
    ):
        _fail(f"App Store Connect returned an invalid {label} resource.")
    return resource_id, attributes


def _collection(value: object, label: str) -> list[object]:
    if not isinstance(value, dict) or not isinstance(value.get("data"), list):
        _fail(f"App Store Connect returned an invalid {label} collection.")
    links = value.get("links")
    if not isinstance(links, dict) or links.get("next") not in (None, ""):
        _fail(f"App Store Connect returned an incomplete {label} collection.")
    return value["data"]


def _single_response(value: object, expected_type: str, label: str) -> tuple[str, dict[str, object]]:
    if not isinstance(value, dict):
        _fail(f"App Store Connect returned an invalid {label} response.")
    return _resource(value.get("data"), expected_type, label)


def _matching_bundle_ids(client: object, bundle_id: str) -> list[str]:
    response = client.request(
        "GET",
        "/v1/bundleIds",
        query={
            "filter[identifier]": bundle_id,
            "fields[bundleIds]": "identifier,platform",
            "limit": "2",
        },
        expected_status=200,
        operation="bundle ID lookup",
    )
    matches: list[str] = []
    for candidate in _collection(response, "bundle ID"):
        resource_id, attributes = _resource(candidate, "bundleIds", "bundle ID")
        if (
            attributes.get("identifier") == bundle_id
            and attributes.get("platform") in _IOS_BUNDLE_ID_PLATFORMS
        ):
            matches.append(resource_id)
    return matches


def _find_bundle_id(client: object, bundle_id: str) -> str:
    matches = _matching_bundle_ids(client, bundle_id)
    if len(matches) != 1:
        _fail("The exact explicit iOS bundle ID was not found uniquely.")
    return matches[0]


def _ensure_bundle_id(client: object, bundle_id: str, name: str | None) -> str:
    """Find an explicit iOS App ID, registering only when the caller names the new bundle."""
    matches = _matching_bundle_ids(client, bundle_id)
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1 or name is None:
        _fail("The exact explicit iOS bundle ID was not found uniquely.")
    response = client.request(
        "POST",
        "/v1/bundleIds",
        body={
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": bundle_id,
                    "name": name,
                    "platform": "IOS",
                },
            }
        },
        expected_status=201,
        operation="bundle ID registration",
    )
    resource_id, attributes = _single_response(response, "bundleIds", "bundle ID")
    if attributes.get("identifier") != bundle_id or attributes.get("platform") != "IOS":
        _fail("App Store Connect registered an unexpected bundle ID.")
    return resource_id


def _icloud_xcode6_is_enabled(attributes: dict[str, object]) -> bool:
    if attributes.get("capabilityType") != "ICLOUD":
        return False
    settings = attributes.get("settings")
    if not isinstance(settings, list):
        return False
    matching_settings = [
        setting
        for setting in settings
        if isinstance(setting, dict) and setting.get("key") == "ICLOUD_VERSION"
    ]
    if len(matching_settings) != 1:
        return False
    options = matching_settings[0].get("options")
    if not isinstance(options, list):
        return False

    selected: set[str] = set()
    for option in options:
        if not isinstance(option, dict) or not isinstance(option.get("key"), str):
            return False
        enabled = option.get("enabled", True)
        if not isinstance(enabled, bool):
            return False
        if enabled:
            selected.add(option["key"])
    return selected == {"XCODE_6"}


def _load_icloud_capability(client: object, bundle_resource_id: str) -> tuple[str, bool] | None:
    response = client.request(
        "GET",
        f"/v1/bundleIds/{urllib.parse.quote(bundle_resource_id, safe='')}/bundleIdCapabilities",
        query={
            "fields[bundleIdCapabilities]": "capabilityType,settings",
        },
        expected_status=200,
        operation="bundle capability lookup",
    )
    matches: list[tuple[str, bool]] = []
    for candidate in _collection(response, "bundle capability"):
        resource_id, attributes = _resource(
            candidate,
            "bundleIdCapabilities",
            "bundle capability",
        )
        if attributes.get("capabilityType") == "ICLOUD":
            matches.append((resource_id, _icloud_xcode6_is_enabled(attributes)))
    if len(matches) > 1:
        _fail("The bundle ID has ambiguous iCloud capability records.")
    return matches[0] if matches else None


def _ensure_icloud_xcode6(
    client: object,
    bundle_resource_id: str,
    *,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    capability = _load_icloud_capability(client, bundle_resource_id)
    if capability is not None and capability[1]:
        return
    if capability is None:
        client.request(
            "POST",
            "/v1/bundleIdCapabilities",
            body={
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {
                        "capabilityType": "ICLOUD",
                        "settings": _ICLOUD_SETTINGS,
                    },
                    "relationships": {
                        "bundleId": {
                            "data": {
                                "type": "bundleIds",
                                "id": bundle_resource_id,
                            }
                        }
                    },
                }
            },
            expected_status=201,
            operation="iCloud capability creation",
        )
    else:
        capability_id = capability[0]
        client.request(
            "PATCH",
            f"/v1/bundleIdCapabilities/{urllib.parse.quote(capability_id, safe='')}",
            body={
                "data": {
                    "type": "bundleIdCapabilities",
                    "id": capability_id,
                    "attributes": {
                        "capabilityType": "ICLOUD",
                        "settings": _ICLOUD_SETTINGS,
                    },
                }
            },
            expected_status=200,
            operation="iCloud capability update",
        )

    last_http_error: AppStoreConnectHTTPError | None = None
    for attempt in range(len(_CAPABILITY_PROPAGATION_DELAYS_SECONDS) + 1):
        try:
            verified = _load_icloud_capability(client, bundle_resource_id)
        except AppStoreConnectHTTPError as error:
            if error.status not in _TRANSIENT_HTTP_STATUSES:
                raise
            last_http_error = error
        else:
            last_http_error = None
            if verified is not None and verified[1]:
                return
        if attempt < len(_CAPABILITY_PROPAGATION_DELAYS_SECONDS):
            sleep(_CAPABILITY_PROPAGATION_DELAYS_SECONDS[attempt])

    if last_http_error is not None:
        raise last_http_error
    _fail("The bundle ID does not have the verified ICLOUD XCODE_6 capability.")


def _load_app_groups_capability(client: object, bundle_resource_id: str) -> str | None:
    response = client.request(
        "GET",
        f"/v1/bundleIds/{urllib.parse.quote(bundle_resource_id, safe='')}/bundleIdCapabilities",
        query={"fields[bundleIdCapabilities]": "capabilityType"},
        expected_status=200,
        operation="App Groups capability lookup",
    )
    matches: list[str] = []
    for candidate in _collection(response, "bundle capability"):
        resource_id, attributes = _resource(
            candidate,
            "bundleIdCapabilities",
            "bundle capability",
        )
        if attributes.get("capabilityType") == "APP_GROUPS":
            matches.append(resource_id)
    if len(matches) > 1:
        _fail("The bundle ID has ambiguous App Groups capability records.")
    return matches[0] if matches else None


def _ensure_app_groups_enabled(
    client: object,
    bundle_resource_id: str,
    *,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    if _load_app_groups_capability(client, bundle_resource_id) is not None:
        return
    client.request(
        "POST",
        "/v1/bundleIdCapabilities",
        body={
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": "APP_GROUPS"},
                "relationships": {
                    "bundleId": {
                        "data": {"type": "bundleIds", "id": bundle_resource_id}
                    }
                },
            }
        },
        expected_status=201,
        operation="App Groups capability creation",
    )
    for attempt in range(len(_CAPABILITY_PROPAGATION_DELAYS_SECONDS) + 1):
        if _load_app_groups_capability(client, bundle_resource_id) is not None:
            return
        if attempt < len(_CAPABILITY_PROPAGATION_DELAYS_SECONDS):
            sleep(_CAPABILITY_PROPAGATION_DELAYS_SECONDS[attempt])
    _fail("The bundle ID does not have the verified APP_GROUPS capability.")


def _parse_api_date(value: object, label: str) -> dt.datetime:
    if not isinstance(value, str):
        _fail(f"App Store Connect returned an invalid {label} date.")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        _fail(f"App Store Connect returned an invalid {label} date.")
    if parsed.tzinfo is None:
        _fail(f"App Store Connect returned an invalid {label} date.")
    return parsed.astimezone(dt.timezone.utc)


def _decode_base64(value: object, label: str, maximum_bytes: int) -> bytes:
    if not isinstance(value, str) or len(value) > maximum_bytes * 2:
        _fail(f"App Store Connect returned invalid {label} content.")
    try:
        decoded = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, base64.binascii.Error):
        _fail(f"App Store Connect returned invalid {label} content.")
    if not decoded or len(decoded) > maximum_bytes:
        _fail(f"App Store Connect returned invalid {label} content.")
    return decoded


def _find_distribution_certificate(client: object, certificate_der: bytes) -> str:
    response = client.request(
        "GET",
        "/v1/certificates",
        query={
            "filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION",
            "fields[certificates]": (
                "certificateType,certificateContent,expirationDate,platform,activated"
            ),
            "limit": "200",
        },
        expected_status=200,
        operation="distribution certificate lookup",
    )
    matches: list[str] = []
    now = dt.datetime.now(dt.timezone.utc)
    for candidate in _collection(response, "certificate"):
        resource_id, attributes = _resource(candidate, "certificates", "certificate")
        certificate_type = attributes.get("certificateType")
        if certificate_type not in _DISTRIBUTION_CERTIFICATE_TYPES:
            _fail("App Store Connect returned a non-distribution certificate.")
        content = _decode_base64(
            attributes.get("certificateContent"),
            "certificate",
            _MAX_CERTIFICATE_BYTES,
        )
        if not hmac.compare_digest(content, certificate_der):
            continue
        if "activated" in attributes:
            activated = attributes["activated"]
            if not isinstance(activated, bool):
                _fail(
                    "App Store Connect returned an invalid certificate activation state."
                )
            if not activated:
                _fail("The imported distribution certificate is not active.")
        platform = attributes.get("platform")
        generic_platform_unspecified = (
            certificate_type == "DISTRIBUTION" and platform is None
        )
        if platform not in {"IOS", "UNIVERSAL"} and not generic_platform_unspecified:
            _fail("The imported distribution certificate is not valid for iOS.")
        if _parse_api_date(attributes.get("expirationDate"), "certificate expiration") <= now:
            _fail("The imported distribution certificate has expired.")
        matches.append(resource_id)
    if len(matches) != 1:
        _fail("The imported distribution certificate was not found uniquely in App Store Connect.")
    return matches[0]


def _create_profile(
    client: object,
    bundle_resource_id: str,
    certificate_resource_id: str,
    profile_name: str,
    *,
    sleep: Callable[[float], None] = time.sleep,
) -> bytes:
    request_body: dict[str, object] = {
        "data": {
            "type": "profiles",
            "attributes": {
                "name": profile_name,
                "profileType": "IOS_APP_STORE",
            },
            "relationships": {
                "bundleId": {
                    "data": {
                        "type": "bundleIds",
                        "id": bundle_resource_id,
                    }
                },
                "certificates": {
                    "data": [
                        {
                            "type": "certificates",
                            "id": certificate_resource_id,
                        }
                    ]
                },
            },
        }
    }
    for attempt in range(len(_PROFILE_CREATION_RETRY_DELAYS_SECONDS) + 1):
        try:
            response = client.request(
                "POST",
                "/v1/profiles",
                body=request_body,
                expected_status=201,
                operation="App Store profile creation",
            )
        except AppStoreConnectHTTPError as error:
            if (
                error.status not in _PROFILE_CREATION_RETRYABLE_HTTP_STATUSES
                or attempt == len(_PROFILE_CREATION_RETRY_DELAYS_SECONDS)
            ):
                raise
            sleep(_PROFILE_CREATION_RETRY_DELAYS_SECONDS[attempt])
            continue
        break
    else:  # pragma: no cover - the bounded loop always returns or raises
        _fail("App Store profile creation exhausted its bounded retries.")
    _, attributes = _single_response(response, "profiles", "profile")
    if (
        attributes.get("name") != profile_name
        or attributes.get("platform") != "IOS"
        or attributes.get("profileType") != "IOS_APP_STORE"
        or attributes.get("profileState") != "ACTIVE"
    ):
        _fail("App Store Connect created an unexpected provisioning profile.")
    profile_uuid = attributes.get("uuid")
    if not isinstance(profile_uuid, str) or _UUID_PATTERN.fullmatch(profile_uuid) is None:
        _fail("App Store Connect returned an invalid provisioning profile UUID.")
    if (
        _parse_api_date(attributes.get("expirationDate"), "profile expiration")
        <= dt.datetime.now(dt.timezone.utc)
    ):
        _fail("App Store Connect created an expired provisioning profile.")
    profile = _decode_base64(
        attributes.get("profileContent"),
        "provisioning profile",
        _MAX_PROFILE_BYTES,
    )
    if len(profile) < 256 or profile[0] != 0x30:
        _fail("App Store Connect returned invalid provisioning profile content.")
    return profile


def provision_profile(
    client: object,
    *,
    bundle_id: str,
    certificate_der: bytes,
    profile_name: str,
    icloud: bool = True,
    register_bundle_name: str | None = None,
) -> bytes:
    bundle_resource_id = _ensure_bundle_id(client, bundle_id, register_bundle_name)
    # The share extension has no iCloud capability and must not be given one: it stages files in
    # the app group and nothing else, and every capability it does not need is a capability it
    # cannot misuse.
    if icloud:
        _ensure_icloud_xcode6(client, bundle_resource_id)
    _ensure_app_groups_enabled(client, bundle_resource_id)
    certificate_resource_id = _find_distribution_certificate(client, certificate_der)
    return _create_profile(
        client,
        bundle_resource_id,
        certificate_resource_id,
        profile_name,
    )


def _read_certificate(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        _fail("The distribution certificate DER input is not a regular file.")
    try:
        certificate = path.read_bytes()
    except OSError:
        _fail("The distribution certificate DER input could not be read.")
    if not certificate or len(certificate) > _MAX_CERTIFICATE_BYTES:
        _fail("The distribution certificate DER input has an invalid size.")
    return certificate


def _write_private_file(path: Path, content: bytes) -> None:
    if not path.parent.is_dir() or path.parent.is_symlink():
        _fail("The provisioning profile output directory is invalid.")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError:
        _fail("Refusing to overwrite the provisioning profile output.")
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(content)
    except OSError:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        _fail("The provisioning profile output could not be written.")


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--certificate-der", type=Path, required=True)
    parser.add_argument("--profile-name", required=True)
    parser.add_argument("--profile-output", type=Path, required=True)
    parser.add_argument(
        "--skip-icloud-capability",
        action="store_true",
        help="For the share extension App ID, which has no iCloud capability.",
    )
    parser.add_argument(
        "--register-bundle-name",
        help="Register the explicit iOS bundle ID with this name when it does not exist.",
    )
    return parser.parse_args()


def _main() -> None:
    args = _arguments()
    if len(args.bundle_id) > 255 or _BUNDLE_ID_PATTERN.fullmatch(args.bundle_id) is None:
        _fail("--bundle-id must be a valid explicit bundle identifier.")
    if _PROFILE_NAME_PATTERN.fullmatch(args.profile_name) is None:
        _fail("--profile-name has an invalid format.")
    if args.register_bundle_name is not None and (
        _PROFILE_NAME_PATTERN.fullmatch(args.register_bundle_name) is None
    ):
        _fail("--register-bundle-name has an invalid format.")
    certificate_der = _read_certificate(args.certificate_der)
    issuer_id, key_id, private_key = _configuration()
    client = AppStoreConnectClient(issuer_id, key_id, private_key)
    profile = provision_profile(
        client,
        bundle_id=args.bundle_id,
        certificate_der=certificate_der,
        profile_name=args.profile_name,
        icloud=not args.skip_icloud_capability,
        register_bundle_name=args.register_bundle_name,
    )
    _write_private_file(args.profile_output, profile)


if __name__ == "__main__":
    try:
        _main()
    except ProvisioningError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None
