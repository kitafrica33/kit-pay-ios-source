# Notification delivery and recovery

Build 66 advertises `1.0.16-r66` in the authenticated device record and
`ios/1.0.16-r66` request header. The server enables the new visible encrypted-message
fallback only for a compatible client whose current device/enrollment preferences
enable alerts and do not mute the message's conversation. A separate rollout flag
defaults to false and must remain false until old workers have drained. Older
clients and ineligible deliveries retain the exact silent `messaging.sync` contract.

`messaging.message_available` contains only its type, messaging scope, notification
UUID, opaque message UUID, recipient UUID, and a generic APS alert. It contains no
sender, conversation, ciphertext, or message text. The client accepts the exact
generic title/body and sound; `content-available: 1` is optional only for the
compatible envelope produced during an older worker handoff. The silent parser is
unchanged. Known scalar Firebase transport/analytics metadata is removed before
the six application keys are validated.

Background delivery deduplicates local alerts by recipient and message, including
delivered system notifications after process restart. Foreground delivery overrides
an inferred background presentation and reconsiders the exact durable message, so
callback ordering cannot hide both alerts. Foreground messages honor the local
open-conversation and mute rules. A notification tap resolves the actual received
message to its local conversation after authenticated restoration; an unavailable
message opens the messages list. Background callbacks never navigate.

Conversation mutes also apply to OS-rendered background message alerts. The client
synchronizes its durable local mute list with authenticated `GET` and `PUT
/notifications/preferences`. Preferences belong to the current device and messaging
enrollment; a missing current-enrollment record has revision zero with visible
encrypted-message alerts disabled. PUT includes both expected enrollment epoch and
revision. Each accepted write increments the revision exactly once, including an
unchanged value, so a late request from an old enrollment or revision cannot undo a
newer setting. Epochs are 1 through 9,007,199,254,740,991; revisions start at zero,
and PUT reserves one revision for the increment.

Sync fetches current server state before reading the latest local list, checks the
exact acknowledgement, and rechecks local/account/session state before confirming.
Timeouts and conflicts start a fresh GET on retry; they never replay an obsolete
PUT snapshot. A durable uncertainty receipt is written before enabling alerts. If
an enabling request may still be delayed at the fetched revision, even an already
matching disabled setting receives a CAS write to fence that late request. Pending
mute changes use the existing error/status display until confirmed, including an
offline change after an enabling write timed out. More than 2,048 distinct muted
conversation UUIDs, or an invalid local identifier, disables the generic visible
message fallback rather than dropping mutes. Call and ordinary notification
recovery do not depend on this encrypted-message preference.

Foreground, reconnect, successful messaging sync, and durable local mute changes
trigger preference reconciliation. Transient failures retry after 30 seconds;
server `Retry-After` delays can extend this to at most one hour.
HTTP 404, 405, or 501 waits for the next foreground/reconnect or a one-hour cooldown
before ordinary sync callbacks may retry. This keeps build 66 compatible with a
server that has not deployed the preference endpoint yet.

The authenticated unread notification inbox recovers missed calls and ordinary
notifications when a push was lost. Each pass reads the newest 100 rows, then up to
three older pages, and persists the next older cursor. Pending pages and transient
failures continue after 30 seconds while the current account remains online.
Foreground and reconnect events start another scan. Every pass rereads the head;
creation time is not an incremental watermark because scheduled rows may become
visible later. There is no recent-history age cutoff.

Missed-call rows require `call.missed`, `state: missed`, the true missed-call alert
marker, and the restored recipient. Other call lifecycle rows, messaging rows,
silent rows, and read rows do not generate recovered alerts. System-delivered
notification IDs and recipient/call IDs suppress duplicates. At most 12 recovered
alerts remain active; older pages cannot evict newer alerts. Permission denial,
quota limits, or failed publication never acknowledge an unseen alert.

Presentation receipts and scan cursors are stored under an account fingerprint.
Receipts contain only opaque identity digests and are pruned only after a complete
authenticated unread scan proves that their rows are absent. Displaying an alert
does not mark the server notification read. Missed-call taps retain an account-bound
route through cold restoration and open call history without dialing or answering.
Recovered ordinary notifications open Home. Existing claim notification routes keep
their deferred ownership binding during cold launch.

Account/session and privacy checks fence network reads, publication, removal, and
cursor commits. Existing PushKit setup, CallKit reporting, independent APNs/VoIP
token caching, durable registration retries, and reconnect replay remain in place.
Alert permission does not gate authenticated background message or inbox sync.

Automated coverage includes strict envelopes and Firebase metadata, callback order,
permission denial, account replacement, cold tap restoration, inbox pagination and
restart, notification deduplication, failed-publication retry, quota handling, mute
CAS acknowledgements, uncertain writes, enrollment replacement, and unsupported
preference endpoints.
Physical locked-device ringing and OS delivery after extended inactivity still
require device acceptance; provider receipts are not evidence of audible ringing.
