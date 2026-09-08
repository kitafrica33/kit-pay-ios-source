# Messaging responsiveness

The September 2026 update targets immediate send feedback, online text delivery below one
second, and typical photo/voice-note delivery below five seconds. These are device-test targets,
not guarantees for iCloud originals, large videos, unavailable recipients or slow networks.

## Sending and receiving

- Text enters the durable outbox without an additional serial draft write. A failed queue keeps
  the composer and immediately restores normal draft persistence.
- For an established device, the fresh conversation, enrollment status and recipient-device
  roster reads overlap. No authorization or roster result is cached across sends, uploads or
  encryption-state retries. First enrollment keeps its required ordering.
- Two bounded foreground media workers prepare uploads without holding later text behind an
  unsealed attachment. Sealed Signal envelopes retain FIFO and retry ordering; account/session,
  block-list, capability and recipient-roster checks still apply before publication.
- Multi-attachment sends respect the last authenticated server availability decision before
  clearing the composer. Existing unsealed batches that cannot pass the capability check show
  a waiting reason and release later messages during their retry backoff. Their files, caption,
  message identity and retry deadline are retained. Known server denial avoids upload setup;
  capability and roster checks run again when preparation can proceed. Recovery retains the
  existing bounded backoff of at most 120 seconds. Single photos, videos and voice notes do not
  depend on the multi-attachment feature.
- New foreground encrypted uploads up to 4 MiB use the existing idempotent single-request
  endpoint. Larger uploads retain resumable checkpoints. A recovered upload retains its existing
  object/offset identity instead of creating a second transfer.
- Active-app resumable chunks use a responsive foreground session. Recovery inventories both
  sessions once and tracks subsequent task changes; each chunk no longer repeats that inventory.
  An existing transfer is rejoined. Background recovery retains the
  background session and the same protected chunk/completion ledger. Task IDs are scoped to
  their session so overlapping foreground/background callbacks cannot mix their responses.
- Each completed preprocessing job wakes its message immediately. Incoming synchronization
  activates once and schedules older-history repair separately from publishing new arrivals.
- Established-device sync fetches its first encrypted page while enrollment is verified. A
  changed device binding or cursor discards that read. Authenticated messages become visible
  after their durable page commit, before the delivery-receipt HTTP response finishes.
- Photos retain their 2048-pixel bound with a 2 MiB encoding target and one initial JPEG encode
  at quality 0.82. Supported camera capture prefers 1080p. Large imported videos are optimized
  only when metadata shows an unnecessarily large resolution or bitrate; the durable job
  preserves the full duration and audio and reuses a verified completed output after interruption.
  A failed or larger export falls back to the original bytes and container. Sending a document
  as a file preserves its original representation.

## Picking and sharing

The native photo picker requests the current representation, shows selected positions
immediately, and loads provider thumbnails independently from two bounded original imports.
Originals remain file-backed and are adopted into protected storage before they can be sent.
Thumbnail placeholders are not counted as rendered photo/video previews in diagnostics.

After choosing a shared-media recipient, a review appears with previews, a caption and an
explicit Send button. Photos use the existing filter/crop/drawing editor; videos offer trimming.
PDFs offer page/range selection and a native preview. Confirming PDF pages creates a new
protected file; cancellation and export errors retain the original. Other document formats
retain their whole-file preview. Edits preserve the share's single batch/idempotency identity.

Send uses a paper-plane icon. No attachment is sent merely by selecting a recipient or closing
an editor. Local imports continue across media viewers, and a new share waits for the existing
selection to finish rather than invalidating its pending files.

The iOS share extension sends directly through the reviewed encrypted messaging protocol.
Choosing a recipient and confirming Send no longer opens the containing app or creates a
"Continue in Kit Pay" handoff. A successful dismissal follows a validated message receipt;
interrupted or uncertain sends retain their exact encrypted request for retry in the sheet or
authenticated app recovery. Closing an uncertain send does not claim delivery or guarantee
that iOS will immediately grant background execution.

The extension and app coordinate a single encrypted Signal state through a cross-process lock,
compare-and-swap and durable commit journal. An uncertain POST reuses the committed ciphertext.
The original wallet store and its key remain private to the app; only messaging state and the
authenticated session needed for sending use the dedicated shared Keychain group. Logout,
account replacement and privacy quarantine revoke extension authority before teardown awaits.
When the app's UI is biometrically locked, the sheet authenticates locally against its existing
account-bound biometric enrollment. That temporary authorization does not unlock the wallet.

Successful outgoing conversations donate recipient suggestions to iOS without message bodies
or attachments. An ordinary biometric UI lock retains those suggestions for sharing from other
apps; the share sheet still authenticates separately before showing its recipient directory.
Stale, blocked and concealed recipients are withdrawn; account changes also invalidate
in-flight donations. iOS controls whether and where these suggestions appear.

Build 95 coordinates main-app Face ID approval with routine destination publication so an
ordinary refresh cannot invalidate an approval in progress. Real security revocations still
win. An initial share authorization failure offers Retry, which checks access again before
reading provider content and never sends automatically. See [direct-share-ios.md](docs/direct-share-ios.md).

## Validation

Focused tests cover upload selection/checkpoint ownership, media/text ordering, account-scoped
history continuation, pending-preview durability, provider file ownership, and PDF selection,
export and cancellation. Native tests run in the existing consolidated iOS build workflow.
Keep received-video playback-to-end, relaunch recovery and camera/scroll checks enabled.

Text diagnostics now distinguish Send-to-local-commit, local-bubble display, encryption,
request start and validated server acceptance using the same monotonic clock. Retries retain
the original start. These bounded records contain no message/account identifiers or contents
and are cleared at account boundaries. Server acceptance does not establish recipient display
time. Export these records from Profile → Media diagnostics after a representative send.
Existing media capture/upload measurements also include preparation time and are not a
substitute for measuring the entire Send-to-delivery path.

Measure from the actual Send tap to server acknowledgement and online-recipient visibility,
and from picker acceptance to the first real thumbnail. Exercise text behind a large upload,
multiple images, short/long voice notes, locally available/iCloud videos, edited shares,
foreground-to-background transitions and retry after termination. Simulator checks do not
establish real-device/network latency. The reported iPhone 15 testing used TestFlight build 84;
this combined candidate needs its own physical validation. Keep process-death, simultaneous
app/share sends, locked sharing, account replacement and uncertain-response retries in that run.

Build 86 stopped during native compilation because the video-trim audio overlap call omitted
the Apple CoreMedia `otherRange:` argument label. Build 87 corrects that call without changing
its validation behavior. Build 86 ran no native tests and produced no signed archive.

Build 87 passed its 226 preflight checks but stopped during native compilation when the
expanded active-call view exceeded Swift's expression type-checking limit. Build 88 separates
that view into smaller expressions while preserving its layout, controls and event handling.
Build 87 ran no native tests and produced no signed archive.

Build 88 compiled the application, extensions and native test products successfully, then
stopped at the simulator messaging-entitlement check before running tests. Xcode uses its
simulator signing prefix and embeds simulated entitlements in the executable. Build 89 corrects
that validation while retaining the exact private/shared messaging isolation and distribution
signing requirements. Build 88 produced no signed distribution archive or upload.

Build 89 passed native compilation and the corrected simulator entitlement check. Its focused
native invocation passed 37 of 38 tests; the received-video test failed while generating a
synthetic input. Build 90 stabilizes that test input while retaining
full-length playback, decoded-frame, replay and file-lifetime assertions. The remaining native
suite, signed archive and upload did not run for build 89.

Build 90 passed native compilation, simulator entitlement verification and all 35 focused
unit tests, including received-video completion and replay. Two of three focused UI tests
passed; the long-history test could not find the Reply action after a stationary long press.
The remaining native suite, signing and upload did not run. Build 91 targets one explicit,
validated visible label center with the same one-second press, records its geometry, and
checks the exact quoted message. Production gestures are unchanged; native validation must
establish the result of this test-targeting correction. Device timing remains unmeasured.

Build 91 passed compilation, simulator verification and all 14 UI tests, including the
explicit long-press target and exact reply check. It ran 1,964 native tests: 1,963 passed and
one JPEG recovery size-limit assertion failed after the output file was rewritten. The
direct-share recovery, messaging process broker, adaptive video and received-video checks
passed. Signing and upload did not run. Build 92 validates prepared JPEG size and image
content from one fresh, bounded file read while retaining the same encoding allowance.
Native validation remains required, and physical delivery timing is unmeasured.
