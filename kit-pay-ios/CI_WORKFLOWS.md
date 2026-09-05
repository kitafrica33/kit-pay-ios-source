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

Workflow conditions and native command selection are exercised by
`test_ios_workflow_consolidation.py`. The tests check the target/screenshot-reuse
matrix, no automatic triggers, fail-fast camera checks, one test compilation,
artifact-only upload, Linux processing, and real temporary signing-key validation.
Run all cheap checks with `python3 -m unittest discover -s .github/scripts/tests`.
