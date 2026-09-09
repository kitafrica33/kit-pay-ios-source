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
| Review-account PIN and biometric unlock on iPad | Seven targeted tests from the same compiled products, for App Store archives only |
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
package pins. A cache miss can reuse downloads from the same architecture and
Xcode version, so adding a target does not discard unchanged archives. Libsignal
checks its pinned archive SHA-256 before extraction; SwiftPM validates package
binary checksums. The scripts require the reviewed
package pins and disable automatic resolution for subsequent builds/tests. No
certificate, provisioning profile, keychain, or signed artifact enters that cache.

Build products are reused only within the same runner and selected source. A
Simulator test build cannot replace the Release device archive. The archive's IPA,
dSYMs, archive, hashes and source identity are retained for publication; the upload
workflow never recompiles them. Certificate import, both extension profiles, and
all entitlement checks remain mandatory. Physical-device acceptance remains as
documented in PARITY.md; Simulator evidence does not establish it.

The existing Simulator build step verifies the built app and share extension before
running tests. Xcode resolves their teamless ad-hoc identity to `FAKETEAMID.` and
embeds the simulated entitlements in each executable's `__TEXT,__entitlements`
section; the ordinary code-signature entitlement dictionary can be empty. The
verifier checks the thin arm64 iOS Simulator executable, bounded Mach-O sections,
exact bundle/platform metadata, matching application identifiers, and ordered
app-private plus messaging groups (messaging only for the share extension).
It separately verifies the original signatures with `codesign --verify --deep --strict`,
logs the non-secret bundle/platform/group evidence, and never modifies
or re-signs products. Distribution profile and signed-entitlement checks remain
unchanged. Build88 compiled all native test products but stopped at the previous
Simulator verifier before any native test executed; a successful compilation alone
does not establish test acceptance.

The focused native phase runs chat opening, pull-to-camera, attachment picker opening and
cancellation, long-history scrolling, and call-banner layout before the remaining suite.
A failure stops that run early. Each focused check is
excluded from the remaining phase, so this ordering adds no compilation or test runs.

Build 96 compiled successfully but the focused phase failed on the new attachment
test's final editing assertion: Photos and Files opened and cancelled, the draft
survived, and repeated panel toggles succeeded, but the final edit appeared before
the draft instead of after it. Build 97 checks one complete insertion at the tapped
position while requiring every original character to remain in order. The picker,
keyboard, dismissal and draft assertions remain. The remaining suite and signed
archive did not run for build 96; it was never uploaded. No test is removed or retried
automatically, and the published build 96 source tag remains immutable.

Build 97 stopped in the shared preflight checks because the workflow's example
source URL still named build 96. Exact runtime source availability passed, but the
release-identity check correctly required matching metadata. No native build or
signed archive ran. Build 98 aligns the example URL, archive default and all six
app/extension build configurations. It preserves the full validator and native
test selections and the immutable source 97 release.

Build 98 passed 256 shared checks and all 2,018 selected native cases (2,003 unit
and 15 UI) in archive run `34218845703`. It was not uploaded. Apple's September 9
review of build 82 then exposed a separate login bug: the review account's local
read-only request guard rejected PIN unlock before contacting the backend. Build
99 allows only the three session-authentication POST routes for PIN unlock and
biometric challenge/assertion. Financial, profile, enrollment and messaging writes
remain prohibited. Regression tests exercise the production API client, assurance
decoding and account-setup transition, including wrong PIN and stale-session cases.
An explicit invalid-PIN or invalid-biometric-proof response consumes one verification
attempt; it no longer refreshes credentials and resubmits the same rejected proof.
An expired access token still refreshes normally before retrying the unlock request.

Build 99 passed shared checks but stopped while compiling the new regression tests:
its route-restriction test referenced an empty request type declared privately in
another file. Build 100 uses an empty encodable dictionary in that assertion. It
retains the authentication fix and every selected test. No native test, signed
archive or Apple upload ran for build 99; its published source remains immutable.

App Store archives also run those seven regression cases on a clean iPad Air
11-inch (M3) Simulator, reusing the compiled products and existing dependency setup.
The pinned runner provides iOS 26.5; Apple's report used iPadOS 26.6. These are
native transport/policy tests, not proof of a physical-device PIN-screen test.
TestFlight-only archives do not create the extra iPad or run that device check.

Native tests use the original generated `.xctestrun` unchanged. XCTest installs and launches
its own products; Simulator does not support `UseDestinationArtifacts`. Exact compiled product
and plan validation precede the first group. After it succeeds, installed-app observation and
the Contacts grant prepare real-launch checks in the second group. Marketing uses validate-only
checks with the same generated plan and its prompt-free fixture. No manual installs, test retries,
extra compilations are introduced. The targeted App Store iPad check described above
uses its own recorded Simulator; the ordinary test path uses one. Each fresh pinned Simulator has one
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
The user also reported successful testing of that update. Build 83's messaging changes stopped
at native compilation: two session checks passed optional IDs to a nonoptional API, and a chat
disappearance expression exceeded the compiler's type-checking limit. No native tests, signing
or upload ran. Build 84 corrects those expressions while preserving logout rejection and staged
imports across local editors. The messaging and media review changes are described in
[MESSAGING_SPEED.md](MESSAGING_SPEED.md); native validation runs once in the selected archive
workflow. Frame geometry is functional evidence only;
physical responsiveness and delivery latency require device measurements.

Workflow conditions and native command selection are exercised by
`test_ios_workflow_consolidation.py`. The tests check the target/screenshot-reuse
matrix, no automatic triggers, early camera/banner checks, one test compilation,
artifact-only upload, Linux processing, and real temporary signing-key validation.
Run all cheap checks with `python3 -m unittest discover -s .github/scripts/tests`.
`test_ios_simulator_messaging.py` also exercises observed Xcode entitlement values,
malformed/device binaries, exact group isolation, and signature failures using
small local fixtures without additional builds or Simulators.
