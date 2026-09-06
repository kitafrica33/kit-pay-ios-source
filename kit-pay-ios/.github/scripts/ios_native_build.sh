#!/usr/bin/env bash
set -euo pipefail

mode="${1:?Select build, test, marketing-iphone, or marketing-ipad}"
: "${KITPAY_TEST_DEVICE_ID:?A prepared Simulator is required}"
: "${RUNNER_TEMP:?}"
common=(
  -workspace KitPay.xcworkspace -scheme KitPay -configuration Debug
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$KITPAY_TEST_DEVICE_ID,arch=arm64"
  -derivedDataPath "$RUNNER_TEMP/KitPay-quality-derived"
  -clonedSourcePackagesDirPath "$RUNNER_TEMP/KitPayPackages"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
  -parallel-testing-enabled NO
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) APP_STORE_SCREENSHOTS'
  ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=
)
select_test_run() {
  local generated_test_run
  generated_test_run="$(python3 .github/scripts/prepare_ios_test_products.py "$1")"
  test_common=(
    -xctestrun "$generated_test_run"
    -destination "platform=iOS Simulator,id=$KITPAY_TEST_DEVICE_ID,arch=arm64"
    -parallel-testing-enabled NO
  )
}

case "$mode" in
  build)
    xcodebuild "${common[@]}" build-for-testing
    ;;
  test)
    select_test_run prepare
    xcrun simctl spawn "$KITPAY_TEST_DEVICE_ID" log stream \
      --style compact --level debug \
      --predicate 'eventMessage CONTAINS "[KitPayCameraPull]"' \
      > "$RUNNER_TEMP/KitPay-camera-pan.log" 2>&1 &
    camera_log_pid=$!
    trap 'kill "$camera_log_pid" 2>/dev/null || true' EXIT
    xcodebuild "${test_common[@]}" \
      -resultBundlePath "$RUNNER_TEMP/KitPay-opening-camera.xcresult" \
      -only-testing:KitPayTests/ConversationNativeOpeningTests \
      -only-testing:KitPayTests/SwipeToReplyNativeGestureTests \
      -only-testing:KitPayTests/ChatMediaPolicyTests/testReceivedVideoPlaysToEndAndReplaysAfterParentFileCleanup \
      -only-testing:KitPayTests/ChatMediaPolicyTests/testGalleryScrubbingRejectsInvalidTimesAndPreservesPauseIntent \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testChatBottomPullOpensCameraOnlyAfterADeliberateRelease \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testLongHistoryVerticalBubbleDragsPreserveReadingPosition \
      -only-testing:KitPayUITests/CallLayoutUITests \
      test-without-building
    # XCTest owns installation. The first invocation uses unit hosts and UI
    # fixtures that skip Contacts; real AppLaunchUITests run in the second.
    python3 .github/scripts/prepare_ios_test_products.py register
    xcodebuild "${test_common[@]}" \
      -resultBundlePath "$RUNNER_TEMP/KitPay-quality.xcresult" \
      -skip-testing:KitPayTests/ConversationNativeOpeningTests \
      -skip-testing:KitPayTests/SwipeToReplyNativeGestureTests \
      -skip-testing:KitPayTests/ChatMediaPolicyTests/testReceivedVideoPlaysToEndAndReplaysAfterParentFileCleanup \
      -skip-testing:KitPayTests/ChatMediaPolicyTests/testGalleryScrubbingRejectsInvalidTimesAndPreservesPauseIntent \
      -skip-testing:KitPayUITests/CallLayoutUITests \
      -skip-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots \
      -skip-testing:KitPayUITests/AppStoreScreenshotUITests/testChatBottomPullOpensCameraOnlyAfterADeliberateRelease \
      -skip-testing:KitPayUITests/AppStoreScreenshotUITests/testLongHistoryVerticalBubbleDragsPreserveReadingPosition \
      test-without-building
    ;;
  marketing-iphone)
    # This iPhone has already passed camera/opening and the complete native suite.
    select_test_run validate
    xcodebuild "${test_common[@]}" -resultBundlePath "$RUNNER_TEMP/KitPay-iPhone.xcresult" \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots \
      test-without-building
    ;;
  marketing-ipad)
    select_test_run validate
    xcodebuild "${test_common[@]}" -resultBundlePath "$RUNNER_TEMP/KitPay-iPad.xcresult" \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots \
      test-without-building
    ;;
  *) echo 'Unknown native build mode' >&2; exit 2 ;;
esac
