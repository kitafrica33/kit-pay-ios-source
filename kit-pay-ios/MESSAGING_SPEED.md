# Messaging responsiveness

The September 2026 update targets immediate send feedback, online text delivery below one
second, and typical photo/voice-note delivery below five seconds. These are device-test targets,
not guarantees for iCloud originals, large videos, unavailable recipients or slow networks.

## Sending and receiving

- Text enters the durable outbox without an additional serial draft write. A failed queue keeps
  the composer and immediately restores normal draft persistence.
- Two bounded foreground media workers prepare uploads without holding later text behind an
  unsealed attachment. Sealed Signal envelopes retain FIFO and retry ordering; account/session,
  block-list, capability and recipient-roster checks still apply before publication.
- New foreground encrypted uploads up to 4 MiB use the existing idempotent single-request
  endpoint. Larger uploads retain resumable checkpoints. A recovered upload retains its existing
  object/offset identity instead of creating a second transfer.
- Active-app resumable chunks use a responsive foreground session. Before starting, the upload
  owner checks both sessions and rejoins an existing transfer. Background recovery retains the
  background session and the same protected chunk/completion ledger. Task IDs are scoped to
  their session so overlapping foreground/background callbacks cannot mix their responses.
- Each completed preprocessing job wakes its message immediately. Incoming synchronization
  activates once and schedules older-history repair separately from publishing new arrivals.

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

## Validation

Focused tests cover upload selection/checkpoint ownership, media/text ordering, account-scoped
history continuation, pending-preview durability, provider file ownership, and PDF selection,
export and cancellation. Native tests run in the existing consolidated iOS build workflow.
Keep received-video playback-to-end, relaunch recovery and camera/scroll checks enabled.

Measure from the actual Send tap to server acknowledgement and online-recipient visibility,
and from picker acceptance to the first real thumbnail. Exercise text behind a large upload,
multiple images, short/long voice notes, locally available/iCloud videos, edited shares,
foreground-to-background transitions and retry after termination. Simulator checks do not
establish real-device/network latency. The user's successful testing report applies to the
previous iOS update; this new implementation needs its own validation.
