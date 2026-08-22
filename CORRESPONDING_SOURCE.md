# Kit Pay iOS 0.2.5 (15) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `0.2.5`
- build number: `15`
- Kit Pay source commit: `0fdf8317f1deabf507d44af037e34e83940eb836`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`

`kit-pay-ios/` contains the exact tracked application source used by the signed archive workflow,
including its Xcode project, dependency lock, build workflow, tests, licence text and notices.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision pinned
by the Podfile. The public FFI archive checksum used by CocoaPods remains recorded in that Podfile.

Build prerequisites and commands are documented in `kit-pay-ios/README.md` and in the pinned
`.github/workflows/ios-app-store-archive.yml`. Apple signing credentials are intentionally not part
of corresponding source.
