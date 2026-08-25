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
- Voice notes, videos, video notes, and documents up to 200 MiB for compatible iPhone recipients,
  plus pinned/muted chat filters, multi-select, message forwarding, per-chat search across text,
  captions, and document names, and local deletion. Every message kind queues offline-first: it
  commits locally in an instant bubble (large media parks in the encrypted file cache) and the
  durable outbox uploads, encrypts, and delivers when connectivity returns.
- Client support for encrypted iCloud chat backup and restore. Message content and included inline
  media are sealed with ChaChaPoly before upload and the key is stored in the user's synchronizable
  Keychain; the private CloudKit record still exposes operational metadata including its
  account-derived record name, creation time, encrypted size, message count, device name, and schema
  version. Customers can explicitly delete both the encrypted record and its backup key.
- Biometrics are preferred for local unlock and financial approval, with an explicit server-verified
  wallet PIN recovery path when biometrics are locked or unavailable.
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
- Abuse reporting appears only for a valid two-party conversation when the backend advertises
  `features.abuse_reporting`. A report carries account/conversation/message references, the user's
  selected reason and optional note, and no decrypted history by default. The user may separately
  select and consent to share at most five delivered text messages; media/payment descriptors,
  attachments and all unselected history remain on-device. Ambiguous retries keep only an
  account-bound request digest and idempotency key in this device's Keychain; report notes and
  selected plaintext are never persisted there. Reports are never queued offline.
  Device-local App Review/demo conversations are UI previews, not valid moderation targets: a
  successful reviewer test requires a real direct-conversation row with exactly the reviewer and
  an enrolled peer as active members, plus a real peer-authored message row for message reports.
  The client must show the server's neutral unavailable result and must never fake acceptance.
- APNs/PushKit server support is implemented on backend PR 18, but production credentials and
  deployment are separate operational steps.
- Rich voice/video/document media is limited to 200 MiB and requires the server's bounded
  `kit-media-v1` capability plus an all-iOS recipient roster at version 0.2.5 build 16 or later.
  The capability handshake pins the advertised byte bounds exactly, so the backend must declare
  `maximum_plaintext_bytes` 209715200 and `maximum_ciphertext_bytes` 209715264. Android and older
  iOS devices remain image-only; unknown types fail closed. Caveat: the attachment cipher and the
  multipart transport currently materialize their buffers in memory, so a transfer near the cap
  briefly costs a low multiple of its size in RAM — acceptable on recent iPhones, but streaming
  encrypt/upload/download is the follow-up required before the cap can be considered robust on
  older, memory-constrained devices.
- Kit Pay → Kit Pay transfers post a canonical encrypted `KITPAY1` event into the 1:1 chat. The
  cross-platform action set is `request|paid|declined|cancelled|transfer|sent|accepted|rejected|
  reversed|expired`; optional `note` precedes optional `rsn`, and older clients show a redacted
  "Payment" preview. A held `transfer` references `transaction.claim.id`; an immediate `sent`
  references the transaction id. Accept/Reject for the recipient and Reverse for the sender appear
  only when the backend advertises `features.claimable_transfers`, the authoritative claim is
  `pending`, the signed-in user and conversation peer match its nested `sender`/`recipient`, and
  the viewer-specific `can_accept|can_reject|can_reverse` permits the action. The API is
  `GET transfer-claims[/{id}]` and `POST transfer-claims/{id}/accept|reject|reverse`; reject and
  reverse accept `{reason}` capped to the wire's 140 UTF-16 units. iOS supplies an optional
  `X-Kit-Wallet-Step-Up` proof for reverse using purpose `wallet_transfer_reverse` and exact intent
  `{action,claim_id,reason}`; supporting backends validate and consume supplied proofs atomically,
  while an absent proof remains compatible with Android. Statuses are
  `pending|accepted|rejected|reversed|expired`.
  The backend must return all statuses when the list filter is omitted, auto-return unaccepted
  transfers after 7 days, and push-notify both parties. The sender's device also records expiry
  once with a deterministic encrypted receipt. Without the flag, transfers settle immediately
  and use `sent`; no claim action is exposed.
  Transfer and response chat cards use deterministic message IDs, so retries cannot duplicate
  them. The post-transfer share is still best-effort across the narrow interval between the
  server committing the money movement and iOS durably queuing its encrypted card; a process
  termination in that interval can omit the card. Durable, bounded receipt recovery is a
  follow-up and must not be implemented as an unrestricted transaction-history replay.
- iCloud chat backups require the `iCloud.africa.kit.pay.ios` CloudKit container to be
  provisioned in the Apple Developer portal, an App Store profile authorizing the signed CloudKit
  entitlements, and the `KitMessageBackup` record type deployed to the production schema. Release
  also requires two-device backup/restore/delete testing and privacy-report/App Store labels
  covering both encrypted content and
  the readable operational metadata. The entitlement and client code alone do not establish
  production readiness.

### CloudKit production-schema release

App Store Connect API credentials cannot manage a CloudKit database schema, and `cktool` supports
schema import only into the development environment. An Account Holder or Admin with permission to
edit production must promote the reviewed development schema in CloudKit Console.

For a file-based import, generate a CloudKit **management** token from the user-account Settings in
CloudKit Console (not a container API token from **Tokens & Keys**). On a Mac with Xcode 13 or later,
store it in Keychain and import the checked-in schema into development only:

```sh
xcrun cktool save-token --type management
python3 .github/scripts/prepare_cloudkit_schema.py \
  --import-development \
  --team-id AU55CKVJ55 \
  --container-id iCloud.africa.kit.pay.ios \
  --environment development \
  --confirmation IMPORT_KIT_PAY_CLOUDKIT_DEVELOPMENT \
  --use-saved-management-token
```

If no Mac is available, use CloudKit Console's development **Record Types** and **Security Roles**
editors to reproduce `.github/cloudkit/KitMessageBackup.ckdb`: nine fields, no indexes, Creator
read/write, Authenticated create, and no World access. Then select **Deploy Schema Changes**, verify
that the pending production diff contains only the intended `KitMessageBackup` additions, and click
**Deploy**. Do not deploy if unrelated development changes appear. Finally, switch the Console to
production and verify the record type and all field types before running the two-device
backup/restore/delete acceptance test. Production schema changes are additive and cannot be
reversed by this helper.

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
