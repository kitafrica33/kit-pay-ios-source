#!/usr/bin/env python3
"""Wait for one exact App Store Connect build to finish TestFlight processing.

The poller never prints API resource identifiers, credentials, tokens, URLs,
or response bodies. Its dependencies are limited to Python and OpenSSL.
"""

from __future__ import annotations

import base64
import http.client
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Callable, NoReturn
import urllib.error
import urllib.parse
import urllib.request


_API_ORIGIN = "https://api.appstoreconnect.apple.com"
_MAX_RESPONSE_BYTES = 1_000_000
_DEFAULT_POLL_TIMEOUT_SECONDS = 1_800.0
_MAX_POLL_TIMEOUT_SECONDS = 3_600.0
_DEFAULT_POLL_INTERVAL_SECONDS = 30.0
_MAX_POLL_INTERVAL_SECONDS = 300.0
_UUID_PATTERN = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)


class PollingError(RuntimeError):
    """A credential-safe, user-actionable polling failure."""


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        del request, file_pointer, code, message, headers, new_url
        return None


class _RetryablePollError(RuntimeError):
    def __init__(self, retry_after_seconds: float | None = None) -> None:
        super().__init__("App Store Connect returned a transient response.")
        self.retry_after_seconds = retry_after_seconds


TokenFactory = Callable[[str, str, str], str]
AppLoader = Callable[[str, str], list[object]]
BuildLoader = Callable[[str, str, str, str], list[object]]
BetaDetailLoader = Callable[[str, str], object | None]
Reporter = Callable[[str], None]


def _fail(message: str) -> NoReturn:
    raise PollingError(message)


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        _fail(f"{name} is required while waiting for TestFlight processing.")
    return value


def _duration_environment(name: str, default: float, maximum: float) -> float:
    raw_value = os.environ.get(name, "").strip()
    if not raw_value:
        return default
    try:
        value = float(raw_value)
    except ValueError:
        _fail(f"{name} must be a finite positive number of seconds.")
    if not math.isfinite(value) or value < 1.0 or value > maximum:
        _fail(f"{name} must be between 1 and {maximum:g} seconds.")
    return value


def _configuration() -> tuple[str, str, str, str, str, str, float, float]:
    issuer_id = _required_environment("APP_STORE_CONNECT_ISSUER_ID")
    key_id = _required_environment("APP_STORE_CONNECT_KEY_ID")
    private_key = _required_environment("APP_STORE_CONNECT_PRIVATE_KEY")
    bundle_id = _required_environment("IOS_BUNDLE_ID")
    version = _required_environment("IOS_VERSION")
    build_number = _required_environment("IOS_BUILD_NUMBER")

    if _UUID_PATTERN.fullmatch(issuer_id) is None:
        _fail("APP_STORE_CONNECT_ISSUER_ID must be a UUID.")
    if re.fullmatch(r"[A-Z0-9]{10}", key_id) is None:
        _fail("APP_STORE_CONNECT_KEY_ID must be a 10-character key identifier.")
    if "\\n" in private_key and "\n" not in private_key:
        private_key = private_key.replace("\\n", "\n")
    private_key = private_key.strip() + "\n"
    if not (
        private_key.startswith("-----BEGIN PRIVATE KEY-----\n")
        and private_key.endswith("\n-----END PRIVATE KEY-----\n")
    ):
        _fail("APP_STORE_CONNECT_PRIVATE_KEY must be a PKCS#8 PEM key.")
    if len(bundle_id) > 255 or re.fullmatch(
        r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id
    ) is None:
        _fail("IOS_BUNDLE_ID must be a valid explicit bundle identifier.")
    if len(version) > 64 or re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version) is None:
        _fail("IOS_VERSION must be a numeric marketing version.")
    if len(build_number) > 18 or re.fullmatch(r"[1-9][0-9]*", build_number) is None:
        _fail("IOS_BUILD_NUMBER must be a positive integer build version.")

    return (
        issuer_id,
        key_id,
        private_key,
        bundle_id,
        version,
        build_number,
        _duration_environment(
            "TESTFLIGHT_POLL_TIMEOUT_SECONDS",
            _DEFAULT_POLL_TIMEOUT_SECONDS,
            _MAX_POLL_TIMEOUT_SECONDS,
        ),
        _duration_environment(
            "TESTFLIGHT_POLL_INTERVAL_SECONDS",
            _DEFAULT_POLL_INTERVAL_SECONDS,
            _MAX_POLL_INTERVAL_SECONDS,
        ),
    )


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

    with tempfile.TemporaryDirectory(prefix="kitpay-testflight-token-") as directory:
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
    return f"{encoded_header}.{encoded_payload}.{_base64url(_der_to_jose_signature(result.stdout))}"


def _retry_after_seconds(headers: object) -> float | None:
    getter = getattr(headers, "get", None)
    if not callable(getter):
        return None
    raw_value = getter("Retry-After")
    if not isinstance(raw_value, str):
        return None
    try:
        value = float(raw_value.strip())
    except ValueError:
        return None
    if not math.isfinite(value) or value < 0:
        return None
    return value


def _load_json(request: urllib.request.Request, *, retry_not_found: bool) -> object | None:
    opener = urllib.request.build_opener(_NoRedirectHandler())
    try:
        with opener.open(request, timeout=30) as response:
            status = response.status
            if status == 404 and retry_not_found:
                return None
            if status == 429 or 500 <= status <= 599:
                raise _RetryablePollError(_retry_after_seconds(response.headers))
            if status != 200:
                _fail(f"App Store Connect polling failed with HTTP {status}; no body was logged.")
            final_url = urllib.parse.urlsplit(response.geturl())
            try:
                final_port = final_url.port
            except ValueError:
                final_port = -1
            if not (
                final_url.scheme == "https"
                and final_url.hostname == "api.appstoreconnect.apple.com"
                and final_url.username is None
                and final_url.password is None
                and final_port in (None, 443)
            ):
                _fail("App Store Connect polling returned an unexpected endpoint.")
            body = response.read(_MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        retry_after = _retry_after_seconds(error.headers)
        error.close()
        if status == 404 and retry_not_found:
            return None
        if status == 429 or 500 <= status <= 599:
            raise _RetryablePollError(retry_after) from None
        _fail(f"App Store Connect polling failed with HTTP {status}; no body was logged.")
    except _RetryablePollError:
        raise
    except (
        urllib.error.URLError,
        TimeoutError,
        ConnectionError,
        http.client.HTTPException,
    ):
        raise _RetryablePollError() from None

    if len(body) > _MAX_RESPONSE_BYTES:
        _fail("App Store Connect returned an oversized polling response.")
    try:
        return json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        _fail("App Store Connect returned invalid polling JSON.")


def _request(token: str, path: str, query: dict[str, str], *, retry_not_found: bool) -> object | None:
    encoded_query = urllib.parse.urlencode(query)
    request = urllib.request.Request(
        f"{_API_ORIGIN}{path}?{encoded_query}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "kitpay-testflight-build-poller/1",
        },
        method="GET",
    )
    return _load_json(request, retry_not_found=retry_not_found)


def _load_matching_apps(token: str, bundle_id: str) -> list[object]:
    document = _request(
        token,
        "/v1/apps",
        {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId", "limit": "2"},
        retry_not_found=False,
    )
    if not isinstance(document, dict) or not isinstance(document.get("data"), list):
        _fail("App Store Connect returned an invalid app response shape.")
    return document["data"]


def _load_matching_builds(
    token: str,
    app_id: str,
    version: str,
    build_number: str,
) -> list[object]:
    document = _request(
        token,
        "/v1/builds",
        {
            "filter[app]": app_id,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": "IOS",
            "fields[builds]": "version,processingState,expired,usesNonExemptEncryption",
            "sort": "-uploadedDate",
            "limit": "2",
        },
        retry_not_found=False,
    )
    if not isinstance(document, dict) or not isinstance(document.get("data"), list):
        _fail("App Store Connect returned an invalid build response shape.")
    return document["data"]


def _load_beta_detail(token: str, build_id: str) -> object | None:
    if not isinstance(build_id, str) or not build_id or len(build_id) > 255:
        _fail("App Store Connect returned an invalid build record.")
    encoded_build_id = urllib.parse.quote(build_id, safe="")
    document = _request(
        token,
        f"/v1/builds/{encoded_build_id}/buildBetaDetail",
        {"fields[buildBetaDetails]": "internalBuildState"},
        retry_not_found=True,
    )
    if document is None:
        return None
    if not isinstance(document, dict) or not isinstance(document.get("data"), dict):
        _fail("App Store Connect returned an invalid beta-detail response shape.")
    return document["data"]


def _exact_app_id(apps: list[object], bundle_id: str) -> str:
    if not apps:
        _fail("No App Store Connect app record exists for the configured bundle.")
    if len(apps) != 1:
        _fail("App Store Connect returned ambiguous app records for the configured bundle.")
    app = apps[0]
    if not isinstance(app, dict) or app.get("type") != "apps":
        _fail("App Store Connect returned an invalid app record.")
    attributes = app.get("attributes")
    app_id = app.get("id")
    if (
        not isinstance(attributes, dict)
        or attributes.get("bundleId") != bundle_id
        or not isinstance(app_id, str)
        or not app_id
        or len(app_id) > 255
    ):
        _fail("App Store Connect returned an invalid app record.")
    return app_id


def _build_status(builds: list[object], build_number: str) -> tuple[str | None, str | None]:
    if not builds:
        return None, None
    if len(builds) != 1:
        _fail("App Store Connect returned ambiguous records for the configured build.")
    build = builds[0]
    if not isinstance(build, dict) or build.get("type") != "builds":
        _fail("App Store Connect returned an invalid build record.")
    attributes = build.get("attributes")
    resource_id = build.get("id")
    if (
        not isinstance(resource_id, str)
        or not resource_id
        or len(resource_id) > 255
        or not isinstance(attributes, dict)
        or attributes.get("version") != build_number
        or not isinstance(attributes.get("expired"), bool)
        or not isinstance(attributes.get("processingState"), str)
        or "usesNonExemptEncryption" not in attributes
        or (
            attributes.get("usesNonExemptEncryption") is not None
            and not isinstance(attributes.get("usesNonExemptEncryption"), bool)
        )
    ):
        _fail("App Store Connect returned an invalid build record.")
    if attributes["expired"]:
        _fail("The configured TestFlight build has expired.")
    state = attributes["processingState"]
    if state in {"FAILED", "INVALID"}:
        _fail("The configured TestFlight build failed Apple processing.")
    if state not in {"PROCESSING", "VALID"}:
        _fail("The configured TestFlight build has an unsupported processing state.")
    if state == "VALID" and attributes["usesNonExemptEncryption"] is None:
        _fail("The configured TestFlight build has no export-compliance response.")
    return state, resource_id


def _beta_readiness(detail: object | None) -> bool:
    if detail is None:
        return False
    if not isinstance(detail, dict) or detail.get("type") != "buildBetaDetails":
        _fail("App Store Connect returned an invalid beta-detail record.")
    attributes = detail.get("attributes")
    resource_id = detail.get("id")
    if (
        not isinstance(resource_id, str)
        or not resource_id
        or len(resource_id) > 255
        or not isinstance(attributes, dict)
        or not isinstance(attributes.get("internalBuildState"), str)
    ):
        _fail("App Store Connect returned an invalid beta-detail record.")
    state = attributes["internalBuildState"]
    if state == "MISSING_EXPORT_COMPLIANCE":
        _fail("The configured TestFlight build is missing export compliance.")
    if state == "IN_EXPORT_COMPLIANCE_REVIEW":
        _fail("The configured TestFlight build is in export compliance review.")
    if state == "PROCESSING_EXCEPTION":
        _fail("The configured TestFlight build has a beta-processing exception.")
    if state == "EXPIRED":
        _fail("The configured TestFlight build has expired.")
    if state == "PROCESSING":
        return False
    if state not in {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}:
        _fail("The configured TestFlight build has an unsupported beta state.")
    return True


def wait_for_testflight_build(
    issuer_id: str,
    key_id: str,
    private_key: str,
    bundle_id: str,
    version: str,
    build_number: str,
    *,
    timeout_seconds: float,
    poll_interval_seconds: float,
    token_factory: TokenFactory = _create_token,
    app_loader: AppLoader = _load_matching_apps,
    build_loader: BuildLoader = _load_matching_builds,
    beta_detail_loader: BetaDetailLoader = _load_beta_detail,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    reporter: Reporter | None = None,
) -> None:
    """Poll the exact build with injectable I/O and time for offline tests."""

    if not math.isfinite(timeout_seconds) or not (
        0 < timeout_seconds <= _MAX_POLL_TIMEOUT_SECONDS
    ):
        _fail("The TestFlight polling timeout is outside its safe bounds.")
    if not math.isfinite(poll_interval_seconds) or not (
        0 < poll_interval_seconds <= _MAX_POLL_INTERVAL_SECONDS
    ):
        _fail("The TestFlight polling interval is outside its safe bounds.")
    deadline = monotonic() + timeout_seconds

    app_attempted = False
    while True:
        if app_attempted and monotonic() >= deadline:
            _fail("Timed out before the configured TestFlight build finished processing.")
        app_attempted = True
        try:
            token = token_factory(issuer_id, key_id, private_key)
            app_id = _exact_app_id(app_loader(token, bundle_id), bundle_id)
            break
        except _RetryablePollError as error:
            if reporter:
                reporter("App Store Connect is temporarily unavailable; retrying.")
            remaining = deadline - monotonic()
            if remaining <= 0:
                _fail("Timed out before the configured TestFlight build finished processing.")
            delay = max(poll_interval_seconds, error.retry_after_seconds or 0)
            sleeper(min(delay, remaining))

    attempted = False
    while True:
        if attempted and monotonic() >= deadline:
            _fail("Timed out before the configured TestFlight build finished processing.")
        attempted = True
        retry_after: float | None = None
        try:
            token = token_factory(issuer_id, key_id, private_key)
            state, build_id = _build_status(
                build_loader(token, app_id, version, build_number), build_number
            )
            if state == "VALID":
                if build_id is None:
                    _fail("App Store Connect returned an invalid build record.")
                detail_token = token_factory(issuer_id, key_id, private_key)
                if _beta_readiness(beta_detail_loader(detail_token, build_id)):
                    return
                if reporter:
                    reporter("The TestFlight beta detail is still processing; waiting.")
            elif reporter:
                reporter(
                    "The TestFlight build has not appeared yet; waiting."
                    if state is None
                    else "The TestFlight build is still processing; waiting."
                )
        except _RetryablePollError as error:
            retry_after = error.retry_after_seconds
            if reporter:
                reporter("App Store Connect is temporarily unavailable; retrying.")

        remaining = deadline - monotonic()
        if remaining <= 0:
            _fail("Timed out before the configured TestFlight build finished processing.")
        delay = max(poll_interval_seconds, retry_after or 0)
        sleeper(min(delay, remaining))


def _run_from_environment() -> None:
    configuration = _configuration()
    wait_for_testflight_build(
        *configuration[:6],
        timeout_seconds=configuration[6],
        poll_interval_seconds=configuration[7],
        reporter=lambda message: print(message, flush=True),
    )


def main() -> int:
    try:
        _run_from_environment()
    except PollingError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    except Exception:
        print(
            "::error::TestFlight processing polling failed unexpectedly; no identifiers, "
            "credentials, URLs, or response data were logged.",
            file=sys.stderr,
        )
        return 1
    print("The exact TestFlight build finished processing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
