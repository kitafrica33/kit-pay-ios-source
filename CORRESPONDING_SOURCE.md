# Kit Pay iOS 1.0.16 (53) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `1.0.16`
- build number: `53`
- Kit Pay source commit: `1e88bd4fd114e22571803e7cc7a98a2895d4a494`
- Kit Pay source tree: `2124d8be022f43535235367aa19ba4b15f464121`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`
- LibSignal source tree: `4ce005a0bf17a445ab14052f8e0c414aa3ddccb9`

`kit-pay-ios/` contains the exact tracked application source used by the signed archive workflow,
including its Xcode project, pinned Podfile, build workflow, source resources and tests.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision pinned
by the Podfile. The public FFI archive checksum used by CocoaPods remains recorded in that Podfile.

Build prerequisites and commands are documented in `kit-pay-ios/README.md` and in the pinned
`.github/workflows/ios-app-store-archive.yml`. Apple signing credentials are intentionally not part
of corresponding source.
