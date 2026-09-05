#!/usr/bin/env bash
set -euo pipefail

mode="${1:?Select build, test, marketing-iphone, or marketing-ipad}"
: "${KITPAY_TEST_DEVICE_ID:?A prepared Simulator is required}"
: "${RUNNER_TEMP:?}"
common=(
  -workspace KitPay.xcworkspace -scheme KitPay -configuration Debug
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$KITPAY_TEST_DEVICE_ID"
  -derivedDataPath "$RUNNER_TEMP/KitPay-quality-derived"
  -clonedSourcePackagesDirPath "$RUNNER_TEMP/KitPayPackages"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
  -parallel-testing-enabled NO
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) APP_STORE_SCREENSHOTS'
  ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=
)

case "$mode" in
  build)
    xcodebuild "${common[@]}" build-for-testing
    ;;
  test)
    xcrun simctl spawn "$KITPAY_TEST_DEVICE_ID" log stream \
      --style compact --level debug \
      --predicate 'eventMessage CONTAINS "[KitPayCameraPull]"' \
      > "$RUNNER_TEMP/KitPay-camera-pan.log" 2>&1 &
    camera_log_pid=$!
    trap 'kill "$camera_log_pid" 2>/dev/null || true' EXIT
    xcodebuild "${common[@]}" \
      -resultBundlePath "$RUNNER_TEMP/KitPay-opening-camera.xcresult" \
      -only-testing:KitPayTests/ConversationNativeOpeningTests \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testChatBottomPullOpensCameraOnlyAfterADeliberateRelease \
      -only-testing:KitPayUITests/CallLayoutUITests \
      test-without-building
    xcodebuild "${common[@]}" \
      -resultBundlePath "$RUNNER_TEMP/KitPay-quality.xcresult" \
      -skip-testing:KitPayTests/ConversationNativeOpeningTests \
      -skip-testing:KitPayUITests/CallLayoutUITests \
      -skip-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots \
      -skip-testing:KitPayUITests/AppStoreScreenshotUITests/testChatBottomPullOpensCameraOnlyAfterADeliberateRelease \
      test-without-building
    ;;
  marketing-iphone)
    # This iPhone has already passed camera/opening and the complete native suite.
    xcodebuild "${common[@]}" -resultBundlePath "$RUNNER_TEMP/KitPay-iPhone.xcresult" \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests/testCaptureAppStoreScreenshots \
      test-without-building
    ;;
  marketing-ipad)
    xcodebuild "${common[@]}" -resultBundlePath "$RUNNER_TEMP/KitPay-iPad.xcresult" \
      -only-testing:KitPayUITests/AppStoreScreenshotUITests \
      test-without-building
    ;;
  *) echo 'Unknown native build mode' >&2; exit 2 ;;
esac
