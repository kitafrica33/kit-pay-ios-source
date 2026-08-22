from __future__ import annotations

import contextlib
import io
import pathlib
import sys
import unittest
from unittest import mock


SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import wait_for_testflight_build as poller  # noqa: E402


ISSUER = "11111111-2222-3333-4444-555555555555"
KEY_ID = "ABCDEFGHIJ"
PRIVATE_KEY = "private-key-material"
BUNDLE = "africa.kit.pay.ios"
VERSION = "1.2.3"
BUILD = "42"
APP_ID = "private-app-id"


def app_record(resource_id: str = APP_ID) -> dict[str, object]:
    return {
        "type": "apps",
        "id": resource_id,
        "attributes": {"bundleId": BUNDLE},
    }


def build_record(state: str, *, version: str = BUILD) -> dict[str, object]:
    return {
        "type": "builds",
        "id": "private-build-id",
        "attributes": {
            "version": version,
            "processingState": state,
            "expired": False,
            "usesNonExemptEncryption": False,
        },
    }


def beta_detail(state: str) -> dict[str, object]:
    return {
        "type": "buildBetaDetails",
        "id": "private-beta-detail-id",
        "attributes": {"internalBuildState": state},
    }


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


class WaitForTestFlightBuildTests(unittest.TestCase):
    def run_poller(self, build_loader, *, beta_loader=None, reporter=None):
        tokens: list[str] = []
        clock = FakeClock()

        def token_factory(issuer: str, key_id: str, private_key: str) -> str:
            self.assertEqual((issuer, key_id, private_key), (ISSUER, KEY_ID, PRIVATE_KEY))
            tokens.append(f"token-{len(tokens) + 1}")
            return tokens[-1]

        poller.wait_for_testflight_build(
            ISSUER,
            KEY_ID,
            PRIVATE_KEY,
            BUNDLE,
            VERSION,
            BUILD,
            timeout_seconds=10,
            poll_interval_seconds=1,
            token_factory=token_factory,
            app_loader=lambda _token, _bundle: [app_record()],
            build_loader=build_loader,
            beta_detail_loader=beta_loader
            or (lambda _token, _build: beta_detail("READY_FOR_BETA_TESTING")),
            monotonic=clock.monotonic,
            sleeper=clock.sleep,
            reporter=reporter,
        )
        return tokens, clock

    def test_waits_for_exact_build_and_beta_readiness(self) -> None:
        build_responses = [[], [build_record("PROCESSING")], [build_record("VALID")]]
        beta_responses = [None, beta_detail("READY_FOR_BETA_TESTING")]
        messages: list[str] = []

        def load_builds(token: str, app_id: str, version: str, build: str):
            self.assertTrue(token.startswith("token-"))
            self.assertEqual((app_id, version, build), (APP_ID, VERSION, BUILD))
            response = build_responses.pop(0)
            if response and response[0]["attributes"]["processingState"] == "VALID":
                build_responses.append([build_record("VALID")])
            return response

        tokens, clock = self.run_poller(
            load_builds,
            beta_loader=lambda _token, _build: beta_responses.pop(0),
            reporter=messages.append,
        )

        self.assertEqual(len(tokens), 7)
        self.assertEqual(clock.sleeps, [1, 1, 1])
        self.assertEqual(
            messages,
            [
                "The TestFlight build has not appeared yet; waiting.",
                "The TestFlight build is still processing; waiting.",
                "The TestFlight beta detail is still processing; waiting.",
            ],
        )

    def test_failed_wrong_or_ambiguous_builds_fail_closed(self) -> None:
        cases = (
            ([build_record("FAILED")], "failed Apple processing"),
            ([build_record("VALID", version="99")], "invalid build record"),
            ([build_record("VALID"), build_record("VALID")], "ambiguous records"),
        )
        for response, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(poller.PollingError, message):
                    self.run_poller(
                        lambda _token, _app, _version, _build, response=response: response
                    )

    def test_build_query_is_scoped_to_exact_ios_version_train(self) -> None:
        captured: list[tuple[str, dict[str, str]]] = []

        def request(_token, path, query, *, retry_not_found):
            self.assertFalse(retry_not_found)
            captured.append((path, query))
            return {"data": []}

        with mock.patch.object(poller, "_request", side_effect=request):
            self.assertEqual(
                poller._load_matching_builds("private-token", APP_ID, VERSION, BUILD),
                [],
            )

        path, query = captured[0]
        self.assertEqual(path, "/v1/builds")
        self.assertEqual(query["filter[app]"], APP_ID)
        self.assertEqual(query["filter[version]"], BUILD)
        self.assertEqual(query["filter[preReleaseVersion.version]"], VERSION)
        self.assertEqual(query["filter[preReleaseVersion.platform]"], "IOS")

    def test_unexpected_failure_never_logs_exception_data(self) -> None:
        secret = "private-token-resource-response"
        stderr = io.StringIO()
        with mock.patch.object(poller, "_run_from_environment", side_effect=RuntimeError(secret)):
            with contextlib.redirect_stderr(stderr):
                result = poller.main()
        self.assertEqual(result, 1)
        self.assertNotIn(secret, stderr.getvalue())
        self.assertIn("no identifiers", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
