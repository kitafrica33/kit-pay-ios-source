# Kit Pay iOS 1.0.16 (63) corresponding source

This archive is the complete corresponding source offered for the Kit Pay iOS binary with:

- bundle identifier: `africa.kit.pay.ios`
- marketing version: `1.0.16`
- build number: `63`
- Kit Pay source commit: `3626ff63959181b8377b400f22865fea576ba8f9`
- Kit Pay source tree: `8b8666738dd5509d86ec08c5bc6724b4e92dc081`
- LibSignal source commit: `b5121d07c72f9e631f178d907ca892587f64f9e2`
- LibSignal source tree: `4ce005a0bf17a445ab14052f8e0c414aa3ddccb9`
- LiveKit Swift SDK source commit: `8867edc5ac936053d1dd41e44c8d823ac29b82f3`
- LiveKit Swift SDK source tree: `70e8ef91f3ccd5d8269e49a1e5a8d52d771b762b`
- LiveKit bundled source tree after protocol expansion: `6be16dca58b9a054f530e490b3439c4a31f6c2fc`
- LiveKit protocol submodule commit: `a0e714995ccbf0a2f4c8df29630e4910c8c9a09a`
- LiveKit protocol submodule tree: `eb9bd02b173af9286d6211e8e5f729be3d7baeab`
- LiveKit Swift SDK public source: `https://github.com/aelsoftware/client-sdk-swift/tree/8867edc5ac936053d1dd41e44c8d823ac29b82f3`

`kit-pay-ios/` contains the exact tracked application source selected for the signed archive
workflow, including its Xcode project, pinned dependencies, build workflows, resources and tests.
`libsignal/` contains the complete source tree for the exact AGPL-3.0-only LibSignal revision
pinned by the Podfile. The public FFI archive checksum remains recorded in that Podfile.
`livekit/` contains the complete source tree for the exact Apache-2.0 LiveKit Swift SDK revision
pinned by Package.resolved, including the Kit Pay broadcast receiver lifecycle and IPC fixes.
`livekit/protocol/` expands the SDK’s pinned protocol submodule into its exact tracked files.
All other LiveKit tracked blobs and file modes match the SDK source commit exactly.
The expansion makes the source archive self-contained without requiring a Git submodule fetch.
The upstream license and copyright notices remain in each dependency tree. Runtime dependency
licenses and exact revisions are also listed in
`kit-pay-ios/KitPay/Resources/Legal/THIRD_PARTY_NOTICES.txt`.

Build prerequisites and commands are documented in `kit-pay-ios/README.md`,
`kit-pay-ios/CI_WORKFLOWS.md`, and `kit-pay-ios/.github/workflows/ios-app-store-archive.yml`.
The selected archive workflow runs native tests before producing a fresh fixture-free signed
Release archive. Existing App Store screenshots are retained for this release.
Apple signing credentials are intentionally not part of corresponding source.
