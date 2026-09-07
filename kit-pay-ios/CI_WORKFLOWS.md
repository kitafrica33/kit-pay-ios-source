# iOS build and publication workflows

Pushes and pull requests no longer trigger a standalone quality run. The manual
Simulator build remains available for diagnosis. Publishing does not require a
second diagnostic workflow: essential checks run inside the selected archive job.

| Work | When it runs |
| --- | --- |
| Source contracts and release-validator tests | Once before each selected build/archive |
| Public source, Apple API access, signing key pair, unused build number | Before archive setup |
| Pod installation and pinned SwiftPM resolution | Once in the native runner |
| Native unit, camera gesture, and call-banner UI checks | One fixture build, then tests without rebuilding |
| Production compilation | The signed Release device archive |
| Marketing screenshots | Only an explicitly selected App Store asset update that has no valid reusable set |
| Signature, profiles, entitlements, IPA identity and hashes | Archive verification and every publishing handoff |
| TestFlight processing | Linux, after the already-built IPA is uploaded |

The automatic Mac quality runs, standalone screenshot workflow, repeated ordinary
Debug compile during release, second iPad compilation, repeated iPhone camera
test during marketing capture, and upload-time validator self-tests were removed.
TestFlight preparation does not create store screenshots. Screenshot updates first
validate retained capture provenance and image bytes; reused sets retain their
original source/date and get a separate reuse receipt. Invalid or incompatible
evidence causes a fresh capture only when a store asset update was selected.

The dependency download cache is keyed by runner architecture, Xcode, Podfile and
package pins. Libsignal checks its pinned archive SHA-256 before extraction;
SwiftPM validates package binary checksums. The scripts require the reviewed
package pins and disable automatic resolution for subsequent builds/tests. No
certificate, provisioning profile, keychain, or signed artifact enters that cache.

Build products are reused only within the same runner and selected source. A
Simulator test build cannot replace the Release device archive. The archive's IPA,
dSYMs, archive, hashes and source identity are retained for publication; the upload
workflow never recompiles them. Certificate import, both extension profiles, and
all entitlement checks remain mandatory. Physical-device acceptance remains as
documented in PARITY.md; Simulator evidence does not establish it.

The focused native phase runs chat opening, pull-to-camera, long-history scrolling,
and call-banner layout before the remaining suite. A failure stops that run early. Each focused check is
excluded from the remaining phase, so this ordering adds no compilation or test runs.

Native tests use the original generated `.xctestrun` unchanged. XCTest installs and launches
its own products; Simulator does not support `UseDestinationArtifacts`. Exact compiled product
and plan validation precede the first group. After it succeeds, installed-app observation and
the Contacts grant prepare real-launch checks in the second group. Marketing uses validate-only
checks with the same generated plan and its prompt-free fixture. No manual installs, test retries,
extra compilations or additional Simulators are introduced. The fresh pinned Simulator has one
boot sequence with a 600-second initial readiness limit; other simctl operations retain their
60-second limits.

Build 80's slow vertical bubble drag did not move. Build 81's native reply recognizer passed
both slow vertical passes, reading-position checks, horizontal replies and the long-press menu.
Its first group passed 31 of 38 cases; seven new unit-fixture cases failed before the second group,
signing or upload. Build 82 corrects the fixtures' idle-recognizer input and immediate-deallocation
assumptions while preserving all admission, callback, threshold and lifecycle assertions. It adds
no jobs or test invocations and does not change the passing UI regression or app implementation.
Build 82 passed native unit/UI validation in
[archive run 34067592269](https://github.com/kitafrica33/kit-pay-ios/actions/runs/34067592269).
The user also reported successful testing of that update. Build 83 adds the messaging and media
review changes described in [MESSAGING_SPEED.md](MESSAGING_SPEED.md); its native validation
runs once in the selected archive workflow. Frame geometry is functional evidence only;
physical responsiveness and delivery latency require device measurements.

Workflow conditions and native command selection are exercised by
`test_ios_workflow_consolidation.py`. The tests check the target/screenshot-reuse
matrix, no automatic triggers, early camera/banner checks, one test compilation,
artifact-only upload, Linux processing, and real temporary signing-key validation.
Run all cheap checks with `python3 -m unittest discover -s .github/scripts/tests`.
