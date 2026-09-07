# Call holding, scheduled calls, and invitations

When a cellular or another app's answered call takes audio, Kit Pay holds its current
call and stops the microphone, camera, and screen sharing. A ringing external call
alone does not trigger hold. Kit Pay automatically resumes an interruption hold
after all connected external calls end and CallKit returns audio ownership. Either
event may arrive first. Manual holds remain held until an explicit Resume. Mute,
camera preference, audio route preference, and duration survive recovery; camera
capture waits for foreground and screen sharing requires a new explicit start.

CallKit can host one speaking Kit Pay call and one held or waiting call. Hold &
Answer and Swap validate both memberships and their revisions, pause old capture,
and use the server's atomic admission response. A failed answer cancels the new
membership before the original can resume; uncertain cancellation is retained for
retry. Older peers retain a paused room so their legacy remote-absence timers do
not end the interrupted call. A fresh media admission is required after the server
retires a held generation or local RTC teardown fails.

An exact pending Answer or reviewed invitation owns its admission timeout. A
notification announcing the same answer cannot prematurely retire that attempt.
Late completion after End, timeout, account replacement, or registry invalidation
cannot reclaim media ownership. Failed resumes retain a visible held call and the
latest mute choice.

The Calls tab exposes Scheduled calls when the authenticated capability
`calls_scheduling` is enabled. New call includes a Group call launcher that selects
1–20 Kit Pay recipients and delegates voice/video admission to
`AppModel.queueGroupCall`. Contact and directory results use the existing call
privacy/readiness checks.

Scheduled calls are stored and dispatched by the server. The client lists and
refreshes schedules, creates and edits their title/time/audience, accepts or declines
invitations, and lets the organizer cancel. Dates are selected in the device's time
zone and sent as UTC ISO 8601 timestamps. An uncertain creation retains its UUID
and complete request while the schedule screen remains open; retrying preserves the
original start time even if it has passed. Editing carries the server revision,
and clearing a title sends explicit null.

With `calls_invite_links`, scheduled-call organizers can create, share, and revoke
an audience-bound invitation. The active call's More controls also offer create,
share, and revoke while the authenticated user is joined and the call is not held.
That action revalidates live membership before creating the link. Only the canonical
`kitpay://call-invites/{64 ASCII alphanumeric characters}` route is accepted.
`kitwallet` remains registered for existing authentication links. A signed-out link
is retained only in memory, with the first such intent preserved until sign-in.
The review binds to the signed-in account; sign-out, account replacement, protected
communication concealment, and biometric relocking discard it.

Opening a link only fetches an authenticated review. Accepting a future schedule
uses the RSVP endpoint, which cannot issue RTC credentials if its due time races
the tap. Joining a live invitation uses `AppModel.joinCallInvitation` so permission
requests, CallKit, account/session fencing, Hold & Answer, and cancellation
compensation share the normal call lifecycle. Every scheduling/link API operation
uses `withCallAccountSession`, except live redemption inside that lifecycle hook.
Invitation tokens and scheduling UI details are not added to persistent local
storage.

The backend dispatcher runs every 60 seconds with a five-minute catch-up window;
clients do not start a local background timer. The backend flags `calls_hold`,
`calls_scheduling`, and `calls_invite_links` remain disabled by default. Dispatch,
queued ringing, and link access recheck account eligibility, blocks, and organizer
and recipient conversation/parent membership. Leaving the organizing conversation
prevents the scheduled call from ringing on the former member's behalf.

Validation includes 11 XCTest cases for strict link routes and share URLs,
account-bound in-memory intents, UTC requests, revision/null encoding, recipient
limits, date bounds, DTO validation, and future-versus-started review targets.
The source grammar parser, plist/project registration checks, and 18 existing
Python tests for native test-product registration pass locally. XCTest execution,
SwiftUI type checking, simulator behavior, and physical-device calls still require
the authorized native build/test lane. Linux Swift validation separately exercises
11 media-driver tests and 21 recovery/admission tests using controlled RTC and OS
boundaries; it does not establish CallKit behavior on a real device. The consolidated
archive runs the native checks once and generates no TestFlight screenshots.

Physical acceptance must cover cellular and other-app interruptions on both locked
and unlocked phones, both event orders, overlapping external calls, manual holds,
Bluetooth controls, held video recovery, offline cancellation, participant changes,
and scheduled ringing after app inactivity. Automatic resume and delivery timing
remain unmeasured on physical devices until those checks are recorded.

Build 85 stopped during Xcode compilation because its synchronous PushKit callback
read a main-actor admission guard without declaring that boundary. Build 86 keeps
the registry on the main queue and reads the guard synchronously with
`MainActor.assumeIsolated`, preserving immediate CallKit reporting and pending-answer
lease protection. Build 85 ran no native tests and produced no signed archive.
