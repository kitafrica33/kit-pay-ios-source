# Kit Pay iOS 1.0.16 (58) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `1.0.16`
- build number: `58`
- Kit Pay source commit: `c359df14046a79282ab9a0ae1b17ec9968fa1521`
- Kit Pay source tree: `62a20ee37b335ef45e70d562abecd0f4faabe46c`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`
- LibSignal source tree: `4ce005a0bf17a445ab14052f8e0c414aa3ddccb9`

`kit-pay-ios/` contains the exact tracked application source used by the signed archive workflow,
including its Xcode project, pinned Podfile, build workflow, source resources and tests.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision pinned
by the Podfile. The public FFI archive checksum used by CocoaPods remains recorded in that Podfile.

Build prerequisites and commands are documented in `kit-pay-ios/README.md` and in the pinned
`.github/workflows/ios-app-store-archive.yml`. Apple signing credentials are intentionally not part
of corresponding source.
