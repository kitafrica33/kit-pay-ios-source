# Android-to-iOS parity and release checklist

Reference audited on 2026-08-20 at Android revision
`e0b96a7e46e18bca4d7a44f714ee8fe139d4da29` and the shared Kit Wallet v1 API.

| Area | iOS state | Remaining release work |
|---|---|---|
| Navigation/design | Four native tabs with Apple Liquid Glass, selected depth capsule, badges, Dynamic Type, iPad width, and accessibility fallbacks; the floating menu reserves exactly the space it draws and steps aside for pushed conversation and Profile detail screens; circular glass bar controls and the seamless Kit chat wallpaper | Validate appearance on physical light/dark devices |
| Authentication | Phone OTP with stable resend-challenge binding, email/password access, email registration/recovery, authenticator MFA and one-time recovery codes, refresh rotation, Keychain sessions, attempt-fenced relaunch recovery, profile setup, wallet PIN, biometrics, and linked-device revocation | Validate recovery, MFA, biometric fallback and per-device revocation on physical devices |
| Profile/settings | Avatar/name/tag editing, verified profile email, communication privacy and blocks, capability-aware Didit status, wallet PIN/biometrics/authenticator/devices, iOS-aware privacy and account-deletion notices, protected or support-assisted account deletion, and per-device logout; all presented with native glass surfaces | Validate email proofs, legal resources, PIN-only deletion approval and deletion/logout cleanup on a physical device |
| Wallet | Balances, cancellation-safe Home pull-to-refresh, contacts, send/receive, idempotent internal transfer, step-up PIN, transactions/detail, and payment requests | Physical-device happy-path and interruption testing |
| Contacts | Up-front explicit-consent sync; local/international matching; canonical dedupe; quiet background refresh with accessible Settings/retry recovery; Kit users before invite-only rows across contact-backed pickers; regression coverage for 10,001 contacts including a synthetic Uganda fixture | Validate more national numbering plans from TestFlight telemetry without uploading unsynced address books |
| Providers | Bills, airtime, mobile-money, and bank UI/API contracts implemented behind server capabilities | Keep disabled until each rail has reviewed authorization, webhook, settlement, reconciliation, and compliance evidence |
| KYC | Didit hosted collection and status refresh implemented | Final approval remains pending sanctions/compliance screening |
| Offline data | AES-GCM local state, Keychain key, protected file, durable idempotent command outbox | Exercise restore, low-storage, and interrupted-replay cases on device |
| Messaging | Conversation UI, account-bound encrypted drafts/history, image attachments, payment-request timeline cards, recipient/tag search, Signal v2 PQXDH/Double Ratchet delivery, fail-closed offline outbox, versioned privacy choices and directional blocking | Validate two-device delivery, draft recovery, privacy changes, block/unblock races, and notification handling on TestFlight devices |
| Calls | API lifecycle, capability gate, complete cursor-backed offline history, chronological in-chat call cards, process-only offline call attempts, PushKit/CallKit answer/decline/end, authenticated single-waiter Merge, Uganda-standard waiting tone, termination replay, Android-parity progress sounds, LiveKit audio/video media, live audio-route reporting, CallKit video promotion on camera toggle, a call surface that survives every sheet and cover, and video-call Picture in Picture | Deploy and validate the `client_call_id` cancellation/idempotency contract, then validate audio/video/reconnect/Bluetooth, call waiting, inline callback, Picture in Picture hand-off, and background transitions on physical devices |
| Notifications | APNs/PushKit registration, provider-specific invalidation, opaque message wakes, locally derived private alerts, account-bound tap-to-chat routing, and encrypted offline-first inline reply | Validate sandbox/production tokens, cold-launch routing/reply, and notification cleanup on two physical devices |
| Store release | App icon, privacy manifest, signed App Store archive, App Store Connect record, and first processed TestFlight build | Complete privacy labels, screenshots, review notes, and physical beta acceptance |

Financial mutations never report offline success. Secure messages never fall back to plaintext.
Capabilities are server authority; the client does not bypass compliance or provider controls.

## First TestFlight acceptance pass

1. Sign in, resend a phone OTP without rotating its challenge, terminate/relaunch, expire/refresh a
   session, complete profile and PIN setup.
2. Grant Contacts access at the launch disclosure; confirm automatic sync plus `+country-code`, `00`, and local-number forms
   resolve to one person, Kit members appear first, and invitation rows appear last.
3. Send an internal transfer and pay/cancel a payment request; verify one ledger mutation after
   retries, airplane-mode transitions, and repeated taps. Pull Home to refresh and confirm a
   SwiftUI/transport cancellation ends silently while genuine network and server errors remain
   visible.
4. Validate APNs alert/background delivery, PushKit incoming calls, CallKit answer/decline/end,
   token rotation, stale-token removal, tap-to-chat routing, and authenticated inline reply on two
   physical devices. In airplane mode, confirm a reply enters the encrypted outbox and sends once
   connectivity returns. Confirm a call screen opens silently and submits when connectivity
   returns, but does not replay after an app relaunch. Prove that a lost response and reconnect
   still create exactly one server call. During a connected call, verify one authenticated waiting
   caller can be declined or merged, an ordinary system hang-up never becomes Merge, and a third
   simultaneous caller is declined without disturbing the active room.
5. Check Liquid Glass over moving content in light/dark mode, Increased Contrast, Reduce
   Transparency, Reduce Motion, large Dynamic Type, and VoiceOver.
6. Confirm disabled provider rails explain availability and cannot submit a production debit.

## WhatsApp-informed improvements after the first TestFlight

Prioritize observed user friction and crash/reliability evidence before adding breadth.

### Messaging and contact quality

- Add archived, pinned, muted, and unread conversation filters; in-thread search; reply, reaction,
  edit/delete, star, and forward actions with clear audit semantics.
- Add safe link previews, documents, photos/video, resumable media compression, and hold-to-record
  voice notes without weakening end-to-end encryption.
- Add configurable read receipts, typing/presence privacy, disappearing messages, block/report,
  spam-rate controls, and unknown-sender boundaries.
- Preserve device contact names locally, refresh Kit membership predictably, make invitations use
  the App Store link, and expand normalization through a maintained libphonenumber data source.

### Calling and notifications

- Add LiveKit media quality adaptation, richer multi-party controls, and clearer missed/failed
  reason presentation; continue hardening reconnect, Bluetooth, PiP, and call-waiting telemetry.
- Add notification collapse/deduplication, per-thread mute, badge reconciliation, and configurable
  notification privacy previews.
- Measure ring-to-answer latency and dropped/reconnected calls using privacy-minimized operational
  metrics; never log message bodies, address books, tokens, PINs, or media credentials.

### Trust, recovery, and polish

- Add linked-device management, device-change notices, safety-number/QR verification, key
  transparency, app/chat lock, encrypted backup/recovery, and explicit session revocation.
- Add offline/poor-network progress that distinguishes queued, sending, delivered, read, failed,
  and retrying states.
- Refine one-handed reachability, swipe actions, haptics, contextual menus, keyboard behavior,
  localization, RTL, accessibility labels, and low-data/storage controls from TestFlight feedback.

These are product-pattern goals, not permission to clone proprietary assets or weaken Kit's
security/compliance boundaries.
