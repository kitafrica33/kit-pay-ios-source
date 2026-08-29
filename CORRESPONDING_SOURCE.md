# Kit Pay iOS 1.0.16 (38) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `1.0.16`
- build number: `38`
- Kit Pay source commit: `bf815ac1b9608967f6c8c88cdafcc8a09c1f2761`
- Kit Pay source tree: `d2884bb4eeb7a716fa477dd77df810156d335b71`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`
- LibSignal source tree: `4ce005a0bf17a445ab14052f8e0c414aa3ddccb9`

`kit-pay-ios/` contains the exact tracked application source used by the signed archive workflow,
including its Xcode project, pinned Podfile, build workflow, source resources and tests.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision pinned
by the Podfile. The public FFI archive checksum used by CocoaPods remains recorded in that Podfile.

Build prerequisites and commands are documented in `kit-pay-ios/README.md` and in the pinned
`.github/workflows/ios-app-store-archive.yml`. Apple signing credentials are intentionally not part
of corresponding source.
