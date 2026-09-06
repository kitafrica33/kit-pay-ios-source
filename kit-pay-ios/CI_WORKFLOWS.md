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

Build 73 stopped in this first phase after the long-history reading-position assertion failed.
Its pan log ended away from the bottom, while later row frames returned to their opening positions;
the evidence does not yet distinguish momentum from automatic positioning. Build 74 retained the same
workload, test inventory and assertions, added a 0.5-second stationary hold before finger lift, and
retained intermediate geometry plus Debug fixture positioning logs. Its archive failed during fresh
Simulator preparation: the 300-second bootstatus deadline expired after cold-boot data migration
progressed to waiting for the system app. Compilation and native tests were skipped, so build 74
produced no native result for the scrolling change.

Build 75 raises only the initial bootstatus wait to 600 seconds. Fresh pinned iOS 26.5/iPhone 17 Pro
creation, one boot sequence, successful readiness and all other 60-second simctl limits remain required.
It retains build 74's native tests and adds static SwiftUI positioning logs only for the active Debug
screenshot fixture; the bottom-scroll log also records its animation flag. Runtime scrolling anchors
are unchanged. Native validation remains required; no physical-device acceptance or latency result is claimed.

Build 75 completed simulator setup and 22 of 23 first-phase checks passed. The stationary history
remained 122.33 points from latest; its reading-position assertions passed, then the required Jump
button was absent in all three final accessibility queries. The second native phase did not run.
Build 76 replaces the separate SwiftUI reading-position measurements with coalesced reports from
the existing validated native scroll samples. UIScrollView tests exercise adjusted insets, threshold
crossings, unread clearing, geometry changes and callback cancellation on detach or conversation
replacement. Opening and layout-follow corrections precede reading reports. The existing UI workload,
exact Jump selector, assertions, two-phase ordering and 600-second initial boot wait are unchanged.
Native build 76 validation remains pending.

Workflow conditions and native command selection are exercised by
`test_ios_workflow_consolidation.py`. The tests check the target/screenshot-reuse
matrix, no automatic triggers, early camera/banner checks, one test compilation,
artifact-only upload, Linux processing, and real temporary signing-key validation.
Run all cheap checks with `python3 -m unittest discover -s .github/scripts/tests`.
