# Kit Pay for iOS

Native SwiftUI client for Kit Pay at `https://pay.kit.africa`. The separately
maintained Android app remains the product-contract reference; this client uses
native iOS navigation, Keychain, APNs/PushKit, CallKit, protected local storage,
and Apple Liquid Glass.

## Implemented

- Phone OTP authentication, rotating sessions, Keychain secrets, and strict profile/PIN setup.
- Wallet bootstrap, balances, contacts, internal transfers, receive details, transaction history,
  payment requests, PIN step-up, idempotency, and fail-closed offline behavior.
- Launch-time Contacts permission with foreground/change-triggered and iOS-scheduled background
  sync, progress reporting, regional phone matching, Kit Pay contacts first, and invites last.
- Didit hosted identity collection. Final KYC approval remains controlled by backend compliance.
- Encrypted offline projections, conversation drafts, and outbox state for wallet, messaging, and calls.
- APNs and PushKit registration, opaque secure-message wakes, private locally derived message
  alerts, tap-to-chat routing, encrypted offline-first inline reply, CallKit lifecycle,
  incoming-call recovery, authenticated call accept/decline/end, and LiveKit audio/video media.
- Capability-gated bills, airtime, bank, and mobile-money interfaces.
- Native iOS 26 Liquid Glass navigation with accessible iOS 17–25 and Reduce Transparency fallbacks,
  circular glass bar controls, and a seamless Kit-green chat wallpaper that falls back to the flat
  brand canvas under Reduce Transparency or Increase Contrast.
- An ongoing call keeps one floating surface above every sheet, cover, and tab, with inline mute and
  hang-up, and a video call hands off to system Picture in Picture when you leave the app.
- App Store icon, privacy manifest, and Xcode CI build/test validation.

## Deliberate release gates

- Secure messages use the reviewed Signal PQXDH/Double Ratchet path only when the server advertises
  messaging wire v2 and the current device has a valid enrollment. Plaintext fallback is forbidden.
- LiveKit media is linked and lifecycle-wired; audio/video, reconnect, Bluetooth, and background
  behavior still require physical-device validation.
- Provider payment rails stay disabled unless backend capabilities confirm the required provider,
  authorization, webhook, settlement, reconciliation, and compliance controls.
- APNs/PushKit server support is implemented on backend PR 18, but production credentials and
  deployment are separate operational steps.

Open `KitPay.xcodeproj` in Xcode 26 or later. Select the Apple development team, keep the bundle ID
aligned with the backend APNs topic, and use a physical device for APNs, PushKit, CallKit, camera,
microphone, and background-delivery validation.

## App Store submission prerequisites

Complete these checks before submission; a green build alone does not establish release
readiness.

1. **Export compliance.** The app uses published, industry-standard cryptography through
   LibSignalClient and WebRTC/SRTP, contains no proprietary or unpublished cryptographic
   algorithm, and is not distributed on the French App Store. Apple therefore treats the current
   configuration as exempt from documentation upload and does not issue an export-compliance
   code. `ITSAppUsesNonExemptEncryption` remains `false`; reassess the declaration before enabling
   French App Store distribution or adding non-standard cryptography.

2. **AGPL corresponding source.** LibSignalClient is AGPL-3.0-only, so each distributed build must
   offer the corresponding source for that exact version. Publish the source at
   `github.com/kitafrica33/kit-pay-ios-source` tagged `v<marketing version>-build<build number>`,
   then pass that release URL as the `corresponding_source_url` input to the same workflow. The app
   validates the URL against the running build's own tag and, when it does not match, tells the
   customer the source is not yet published rather than linking nowhere.

3. **Physical-device acceptance.** APNs, PushKit, CallKit, biometric prompts, LiveKit audio and
   video, Bluetooth routing, and Picture in Picture cannot be exercised in the Simulator or in CI.
   `PARITY.md` carries the acceptance script.

See [PARITY.md](PARITY.md) for parity, TestFlight gates, and the post-TestFlight product backlog.
