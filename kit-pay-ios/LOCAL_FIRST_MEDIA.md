# Local-first messaging media

This document is the release contract for the iOS messaging-media pipeline.

## Invariants

- Capture or selection creates a permanent client media UUID and an app-owned local original
  before the durable message/outbox transaction is committed.
- The sender bubble and sender playback resolve that local original. They never require upload,
  a remote object URL, server processing, delivery, or a download of bytes already on the device.
- Large originals are file-backed, excluded from backup, and use iOS Data Protection
  (`completeUntilFirstUserAuthentication`). Small legacy/inline values remain inside the
  account-bound encrypted state. Sign-out purges the account's local media and wrapping key.
- E2EE is fail-closed. Compression/transcoding, deterministic attachment encryption, upload, and
  Signal fanout happen after the local commit. If secure transmission is unavailable, the message
  and original remain pending; local admission never performs capability discovery, and plaintext
  is never sent as a fallback. Authenticated service and recipient-device capability checks run at
  the background dispatch boundary before any ciphertext upload or Signal fanout.
- Recipients authenticate and stream-decrypt to an unpublished file, atomically publish the local
  copy, then mark the media `localCached`. Reopening uses that copy without another download.
- Sent originals are never cache-eviction candidates. Received files use a 512 MiB high-water /
  384 MiB low-water LRU. Eviction first reserves an unleased, non-recent file, atomically changes
  its record to `remoteOnly`, then deletes the exact fingerprinted file. Opening it later performs
  one authenticated download and restores `localCached`.
- Share-extension files already reside in Kit Pay's protected app-group container. Containing-app
  adoption requires same-volume APFS copy-on-write clones, so attaching a shared batch is bounded
  metadata work rather than a serial copy of every byte. A clone failure leaves the inbox intact
  and visible for retry. Security-scoped third-party document providers are the distinct unavoidable
  localization boundary: the picked provider URL is shown immediately, while a background
  file-to-file copy produces the restart-safe app-owned original before Send becomes available.
- Finalized voice-note segments are moved on the same app-owned volume (metadata-only) and the
  durable bubble is committed before asynchronous assembly. The sender plays those segment files
  immediately while assembly, encryption and transfer continue independently.
- Camera and single-library videos are adopted into permanent protected storage and shown before
  the optional trim editor opens. The editor reads that original directly; an edited export is
  published under a new permanent media ID before the superseded original is retired. Untrimmed
  and cancelled edits keep the original intact.
- Passive image surfaces use bounded ImageIO downsampling, and video bubbles reuse a bounded
  in-memory poster cache. User-initiated full export remains separate from scrolling/rendering so
  a large compressed image cannot force an unbounded decode on the conversation path.

## Durable states and retry

Each record binds conversation ID, message ID, permanent media ID, local storage key, remote
encrypted object ID, MIME type, size, duration, processing/upload/download/encryption states, and
availability. Preprocessing jobs, deterministic ciphertext spool digest/size, server upload lease,
and authoritative offset are persisted. Relaunch resumes the same IDs and never creates a second
message. A 404/410 upload lease starts a new server lease while retaining media identity and E2EE
key material. If a completed server object expires before message acceptance, KITMEDIA1 and
KITMEDIA2 return to pending from the retained local original and clear only remote-derived state.
Immediately before sealing, each resumable READY declaration is replayed exactly: a live lease is
renewed in place, while a retention-swept object receives a fresh empty session and is refilled
from retained deterministic ciphertext. Ciphertext spools are removed only after that final pass.
Every first, resumed, renewed, or replacement server storage key is admitted in the same atomic
state mutation that checkpoints it. Admission binds the key to one permanent attachment and
rejects aliases with any message record/spool id, local source, transform output, sibling, other
message, or active composer draft. A cache copy created before a losing compare-and-set is never
deleted inline because another actor may have claimed it while file I/O was suspended; the
bounded, age-gated orphan sweep is the sole reclamation path.

## Termination-surviving transfer and hard rollout gate

Resumable ciphertext PATCHes use a dedicated background `URLSession`. Every bounded chunk is
staged as a backup-excluded, Data-Protected file and receives a durable task description bound to
fingerprints of the account, authenticated session and access-token generation plus the upload id,
offset, size and chunk digest. A relaunched process reattaches to the task or consumes its durable,
bounded response. Successful replay is idempotent, server offsets remain authoritative, and a 401
passes through the existing session-fenced single-flight refresh before the exact chunk is retried.
Sign-out cancels only the revoked account/session's tasks. `BGProcessingTask` remains an
opportunistic extra wake for work that has not yet been handed to the background session.

**Physical-device evidence remains a hard production-rollout gate.** Do not broaden the existing
feature/server capability cohort, or claim validated continuous upload after force quit, until the
matrix below demonstrates delegate relaunch, checkpoint reconciliation and subsequent chunk
progress on supported iPhones. A detached task or longer background assertion is not an acceptable
substitute. Feature and server capability gates remain unchanged by this work.

## Measurement and release gate

Privacy-safe signposts/logs separately measure capture-to-visible, capture-to-locally-playable,
capture-to-encrypted, capture-to-server-accepted, and recipient-descriptor-to-local. The first two
must remain independent of network latency.

Hosted source/unit tests are necessary but not sufficient. Before enabling a broader rollout, run
on physical supported iPhones with a 10-second, 2-minute, and 10-minute video; large photos; long
voice notes; large PDF/DOCX/XLSX/CSV files; mixed and rapid multi-attachment sends; simultaneous
text/media; offline capture; low bandwidth; network loss during a chunk; app backgrounding; and
app termination/relaunch. For each case record both local latency metrics and recipient
availability, confirm sender playback while upload is blocked, verify checkpointed resume without
duplicates, and verify cached recipient reopen without a second download. Any sender path that
waits for network, any plaintext fallback, any duplicate, or any lost local original blocks release.
