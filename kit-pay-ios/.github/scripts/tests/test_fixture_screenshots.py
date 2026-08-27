from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "KitPay/App/AppStoreScreenshotFixture.swift"
REVIEW_DEMO = ROOT / "KitPay/App/AppReviewDemoContent.swift"
PROJECT = ROOT / "KitPay.xcodeproj/project.pbxproj"
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"
MESSAGES = ROOT / "KitPay/Features/Messages/MessagesView.swift"
CALLS = ROOT / "KitPay/Features/Calls/CallsView.swift"
HOME = ROOT / "KitPay/Features/Home/HomeView.swift"
MOBILE_MONEY = ROOT / "KitPay/Features/Home/MobileMoneyView.swift"
BANK_TRANSFER = ROOT / "KitPay/Features/Home/BankTransferView.swift"
SCREENSHOT_WORKFLOW = ROOT / ".github/workflows/ios-app-store-screenshots.yml"


class AppStoreScreenshotFixtureSourceTests(unittest.TestCase):
    def test_fixture_requires_debug_flag_and_exact_launch_argument(self) -> None:
        source = FIXTURE.read_text(encoding="utf-8")
        self.assertTrue(source.startswith("import Foundation\n\n#if DEBUG && APP_STORE_SCREENSHOTS\n"))
        self.assertIn('"--kit-app-store-screenshot-fixture-v1"', source)
        self.assertIn('"KITPAY_APP_STORE_SCREENSHOT_FIXTURE_V1"', source)
        self.assertIn("ProcessInfo.processInfo.arguments.contains(launchArgument)", source)

    def test_fixture_pins_all_screenshot_visible_date_presentation(self) -> None:
        fixture = FIXTURE.read_text(encoding="utf-8")
        home = HOME.read_text(encoding="utf-8")
        messages = MESSAGES.read_text(encoding="utf-8")
        calls = CALLS.read_text(encoding="utf-8")
        mobile_money = MOBILE_MONEY.read_text(encoding="utf-8")

        self.assertIn('presentationNow = timestamp("2026-08-24T09:41:00Z")', fixture)
        self.assertIn('Locale(identifier: "en_UG")', fixture)
        self.assertIn("TimeZone(secondsFromGMT: 0)!", fixture)
        self.assertIn("if AppStoreScreenshotFixture.isActive", fixture)
        self.assertIn("AppPresentationClock.calendar.component", home)
        self.assertIn("let now = AppPresentationClock.now", messages)
        self.assertIn("dateSeparatorsRelativeTo: AppPresentationClock.now", messages)
        self.assertGreaterEqual(messages.count("AppPresentationClock.shortTime"), 3)
        self.assertIn("AppPresentationClock.abbreviatedDateAndShortTime", calls)
        self.assertIn("AppPresentationClock.abbreviatedDateAndShortTime", mobile_money)

    def test_fixture_short_circuits_real_app_startup_and_rail_loaders(self) -> None:
        app_model = APP_MODEL.read_text(encoding="utf-8")
        fixture_install = app_model.index("if AppStoreScreenshotFixture.isActive")
        scheduler_install = app_model.index(
            "ContactBackgroundRefreshScheduler.shared.installHandler"
        )
        self.assertLess(fixture_install, scheduler_install)
        self.assertIn("state = AppStoreScreenshotFixture.state", app_model)
        self.assertIn("isLoading = false\n            return", app_model)

        for path, expected in (
            (MOBILE_MONEY, "AppStoreScreenshotFixture.mobileMoneyOperations"),
            (BANK_TRANSFER, "AppStoreScreenshotFixture.bankOperations"),
        ):
            source = path.read_text(encoding="utf-8")
            self.assertIn("#if DEBUG && APP_STORE_SCREENSHOTS", source)
            self.assertIn(expected, source)

    def test_fixture_and_capture_test_are_members_of_their_targets(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        self.assertEqual(project.count("AppStoreScreenshotFixture.swift in Sources"), 2)
        self.assertEqual(project.count("AppStoreScreenshotUITests.swift in Sources"), 2)
        self.assertIn("KitPay/App/AppStoreScreenshotFixture.swift", project)
        self.assertIn("KitPayUITests/AppStoreScreenshotUITests.swift", project)

    def test_authenticated_review_demo_is_release_built_and_session_gated(self) -> None:
        source = REVIEW_DEMO.read_text(encoding="utf-8")
        project = PROJECT.read_text(encoding="utf-8")
        self.assertFalse(source.startswith("#if DEBUG"))
        self.assertIn('static let featureKey = "app_review_demo"', source)
        self.assertIn("authority == .authenticatedSession", source)
        self.assertIn("profileID == sessionAccountID", source)
        self.assertIn("sessionID?.trimmingCharacters", source)
        self.assertEqual(project.count("AppReviewDemoContent.swift in Sources"), 2)
        self.assertIn("KitPay/App/AppReviewDemoContent.swift", project)

    def test_review_demo_ids_and_actions_remain_read_only(self) -> None:
        source = REVIEW_DEMO.read_text(encoding="utf-8")
        app_model = APP_MODEL.read_text(encoding="utf-8")
        messages = MESSAGES.read_text(encoding="utf-8")
        calls = CALLS.read_text(encoding="utf-8")
        self.assertIn('"d0000000-0000-4000-8000-000000000001"', source)
        self.assertIn('"d1000000-0000-4000-8000-000000000001"', source)
        self.assertGreaterEqual(
            app_model.count("isReadOnlyAppReviewDemoConversation"),
            12,
        )
        self.assertIn("AppReviewDemoMutationPolicy.peerIsReadOnly", app_model)
        self.assertIn("appReviewDemoMutationsAllowed", app_model)
        self.assertIn("hasAuthenticatedCapabilities: capabilities != nil", app_model)
        self.assertIn('Label("Read-only App Review preview"', messages)
        self.assertIn("model.isReadOnlyAppReviewDemoCall(call.id)", calls)

    def test_capture_requires_the_exact_protected_main_source(self) -> None:
        workflow = SCREENSHOT_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("test \"$GITHUB_REF\" = 'refs/heads/main'", workflow)
        self.assertIn(
            'test "$(git rev-parse HEAD)" = "$(git rev-parse refs/remotes/origin/main)"',
            workflow,
        )

    def test_capture_pins_runner_xcode_and_ios_runtime(self) -> None:
        workflow = SCREENSHOT_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("runs-on: macos-26", workflow)
        self.assertNotIn("runs-on: macos-latest", workflow)
        self.assertIn("/Applications/Xcode_26.6.app", workflow)
        self.assertIn("Build version 17F113", workflow)
        self.assertIn("com.apple.CoreSimulator.SimRuntime.iOS-26-5", workflow)
        self.assertIn('"name": "iOS 26.5"', workflow)
        self.assertNotIn("max(runtimes", workflow)
        self.assertIn('iphone = require(("iPhone 14 Plus",))', workflow)
        self.assertIn('"iPad Pro 13-inch (M4)"', workflow)


if __name__ == "__main__":
    unittest.main()
