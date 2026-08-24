# Kit Pay iOS 0.2.7 (22) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `0.2.7`
- build number: `22`
- Kit Pay source commit: `ab80381d3b9ff71f1850a772758defb2a2fa81a2`
- Kit Pay source tree: `dfda55dc8d17017b643e92a77bbd8dd6681a8048`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`
- LibSignal source tree: `4ce005a0bf17a445ab14052f8e0c414aa3ddccb9`

`kit-pay-ios/` contains the exact tracked application source used by the signed archive workflow,
including its Xcode project, pinned Podfile, build workflow, source resources and tests.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision pinned
by the Podfile. The public FFI archive checksum used by CocoaPods remains recorded in that Podfile.

Build prerequisites and commands are documented in `kit-pay-ios/README.md` and in the pinned
`.github/workflows/ios-app-store-archive.yml`. Apple signing credentials are intentionally not part
of corresponding source.
