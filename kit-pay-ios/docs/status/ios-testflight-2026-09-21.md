# Kit Pay iOS — 1.0.17 (105) to TestFlight from Codemagic, 2026-09-21

The chat-scroll and share-extension fixes are on TestFlight. They got there without a Mac in
this building, without GitHub Actions minutes, and without touching the 1.0.17 App Store
submission that is still sitting in review on build 104.

Build **105** of version **1.0.17** was archived, signed and uploaded by one Codemagic build,
`6ab1326c87be3300700dce00`, from `main` at `de64a12`. It cost **13 min 38 s** of free
`mac_mini_m2` time and reached `VALID` in App Store Connect two minutes and twenty seconds after
the upload finished.

## 1. Why a new build and not a new version

App Store Connect will not create a second version record while an app has never been on sale —
a `POST /v1/appStoreVersions` for 1.0.18 answers `409 ENTITY_ERROR.RELATIONSHIP.INVALID`. So
1.0.17 is frozen as the marketing version and the fixes ship as a **new build under it**. The
review of 1.0.17 continues against build 104; TestFlight testers get 105. Both are true at once
and neither disturbs the other:

| Record | Value after this release |
| --- | --- |
| App Store version `fd84e0cc-f53f-4356-bc97-ae6cd22150d5` (1.0.17) | `WAITING_FOR_REVIEW`, still attached to build **104** |
| Build 105 `676a7df5-9028-4968-aa1b-a31358efe0b9` | `VALID`, `internalBuildState: IN_BETA_TESTING` |
| External state of 105 | `READY_FOR_BETA_SUBMISSION` — deliberately not submitted |

## 2. The lane

`codemagic.yaml` gains **`ios-testflight`**: `mac_mini_m2`, `max_build_duration: 55`, Xcode
pinned to the repo's requirement, and nothing interactive. It is the first Kit Pay release lane
that does not need a borrowed Mac or a GitHub runner.

Steps, in the order they must run:

1. **Machine facts** — asserts `Xcode 26.6` outright rather than hoping. The run got Xcode 26.6
   (17F113).
2. **Resolve pinned native dependencies once** — runs the repo's own
   `.github/scripts/install_ios_dependencies.sh`, which refuses a dirty tree, runs `pod install`,
   copies the reviewed `Package.resolved` into the workspace and resolves with
   `-onlyUsePackageVersionsFromResolvedFile`. It runs **before** signing because it is allowed
   to rewrite `project.pbxproj`, and signing writes there too.
3. **Build number, read live from App Store Connect** — `app-store-connect
   get-latest-testflight-build-number 6802582070 --platform IOS`, then `max(latest, floor-1) + 1`.
   No number is committed anywhere; the next build is a fact about Apple's records, not about
   this repository. The run printed `build number: 105 (App Store Connect's latest was 104,
   floor 105)`.
4. **AGPL corresponding source must already be public** — an *anonymous* `curl --fail` (with
   `Authorization:` and `Cookie:` explicitly blanked) against the tag URL the previous step
   derived. If the corresponding-source release is not reachable by a stranger, the build stops
   here, before a single minute is spent compiling.
5. **Code signing for all three signed bundles** — `keychain initialize`, then
   `fetch-signing-files --type IOS_APP_STORE --strict-match-identifier --create` for
   `africa.kit.pay.ios`, `africa.kit.pay.ios.share` and `africa.kit.pay.ios.broadcast`, then
   `keychain add-certificates` and
   `xcode-project use-profiles`. A `grep -qF` then refuses to continue if any target is still
   carrying the manual `$(KITPAY_…_PROFILE_UUID)` placeholder, and
   `manageAppVersionAndBuildNumber` is forced to `NO` so Xcode cannot renumber the build behind
   the lane's back.
6. **Build the signed IPA** — `xcode-project build-ipa`, with the same archive flags the
   proven GitHub lane uses, and `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` /
   `KIT_CORRESPONDING_SOURCE_URL` passed as xcargs.
7. **Prove the IPA before it is published** — unpacks the artefact and checks the shipped
   `Info.plist` rather than the intention: `CFBundleShortVersionString`, `CFBundleVersion`,
   `KitCorrespondingSourceURL`, exactly two `PlugIns/*.appex`, each with an expected bundle id,
   and the app-group entitlement present in all three signatures.
8. **Publishing** — `app_store_connect` with `submit_to_testflight: false` and
   `submit_to_app_store: false`.

The certificate is the team's existing Apple Distribution certificate, supplied as
`CERTIFICATE_PRIVATE_KEY` in the `appstore` variable group so that `--create` matches the
existing certificate instead of burning one of the two allowed slots. Codemagic variable groups
are **per application**, not per account: the four secure variables
(`APP_STORE_CONNECT_PRIVATE_KEY`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
`APP_STORE_CONNECT_ISSUER_ID`, `CERTIFICATE_PRIVATE_KEY`) had to be created on the kit-pay-ios
app, and no value was printed at any point.

### Why `submit_to_testflight: false` is the right setting for an internal release

Codemagic's `submit_to_testflight` holds the Mac open while Apple processes the upload, and
charges for the wait. The **upload itself is the internal release**: the `Internals` group has
`hasAccessToAllBuilds: true`, so 105 was available to internal testers the moment processing
finished. Processing was then watched from Linux, for nothing. The saving was real — the whole
build was 13 min 38 s, of which processing would have added another two or three.

## 3. The AGPL gate

Kit Pay must offer corresponding source for every binary it ships, and
`KitLegalURLPolicy.isTrustedCorrespondingSourceURL` rebuilds the expected URL from the running
build's own version and build number. So the tag must exist, publicly, *before* the archive is
made — a build that compiles first and tags afterwards ships a binary pointing at a 404.

| | |
| --- | --- |
| Tag | `v1.0.17-build105` in `kitafrica33/kit-pay-ios-source` |
| Release | `392988341`, published (draft → assets → `draft:false`, because GitHub releases are immutable once published) |
| Source commit | `de64a12077abe37efb906bc03bcf6fd63fb210cb` |
| Tree sha proven equal | `20d7b8499bb9ba9b7ffe1d23e78a4b4950ba1cd3` — the source repo's `kit-pay-ios/` subtree against the app commit's tree |
| Asset | `kit-pay-ios-1.0.17-build105.tar.gz`, sha256 `f8318eeec7fdbd05ac710d145eaffdac1fcba36a092bafec61c16077c5603554`, plus `SHA256SUMS` |
| Anonymous reachability | HTTP 200 from Linux before dispatch, and again from the build machine as step 4 |

## 4. Gates run before any Mac minute was spent

| Gate | Result |
| --- | --- |
| `python3 -m unittest discover -s .github/scripts/tests` | 286 tests OK, 5 skipped |
| `run_conversation_projection_linux_gate.sh` (docker `swift:5.10-noble`) | 7/7 |
| Source tree sha == app commit tree sha | `TREE MATCH` |
| Corresponding-source release anonymously reachable | HTTP 200 |

## 5. The run

Build `6ab1326c87be3300700dce00`, workflow `ios-testflight`, branch `main` at `de64a12`,
`mac_mini_m2`, 2026-09-21 13:35:34Z → 13:49:11Z, **13 min 38 s**, `finished`, no retry.

| Step | Duration |
| --- | --- |
| Preparing build machine | 33 s |
| Fetching app sources + restoring cache | 5 s |
| Machine facts | 1 s |
| Resolve pinned native dependencies once | 45 s |
| Build number, read live from App Store Connect | 3 s |
| AGPL corresponding source must already be public | 1 s |
| Code signing for all three signed bundles | 29 s |
| **Build the signed IPA** | **9 min 42 s** |
| Prove the IPA before it is published | 2 s |
| Publishing (upload to App Store Connect) | 1 min 17 s |
| Cleaning up | 40 s |

Signing resolved to three App Store profiles under manual signing, team `AU55CKVJ55`,
certificate valid to 2027-08-17:

```
africa.kit.pay.ios            Kit Pay App Store 35401810294-1            82297928-05cc-406a-a3ca-a04b2c444990
africa.kit.pay.ios.share      Kit Pay Share App Store 35401810294-1      9af2ac5a-ba82-4fe7-a85b-996b77f7cbe4
africa.kit.pay.ios.broadcast  Kit Pay Screen Sharing App Store …-1       48e2391b-b57e-40ee-9001-44ba8ca47d9b
```

The proof step answered `signed ok` for all three bundles. The upload transferred 66 741 800
bytes; delivery UUID `676a7df5-9028-4968-aa1b-a31358efe0b9`, which App Store Connect then uses
as the build's own id.

## 6. In App Store Connect

| | |
| --- | --- |
| Build | 1.0.17 (105), id `676a7df5-9028-4968-aa1b-a31358efe0b9` |
| Processing | `PROCESSING` 13:49Z → **`VALID` 13:51:33Z** |
| Internal | `internalBuildState: IN_BETA_TESTING`, newest build in group `Internals` (`af0adaab-1978-408b-8855-21784fe45cdc`, 1 tester, auto-notify on) |
| External | `READY_FOR_BETA_SUBMISSION` — not submitted, by instruction |
| Min OS / encryption | 17.0 / `usesNonExemptEncryption: false` |
| Expires | 2026-12-20 |

"What to Test" was set from `TestFlight/WhatToTest.en-GB.txt` by patching the build's
`betaBuildLocalizations` (`f288ea45-f062-4947-b9d6-2802de1a29d5`) from Linux — App Store
Connect had created only an `en-US` localisation for this build, and `whatsNew` on the *version*
is refused while the app has never been on sale. The notes ask testers to open their longest
chats and drag straight after *Jump to latest message*, and to share from Photos, Files and
Safari while switching away mid-share.

## 7. Cost

| | Free `mac_mini_m2` used | Remaining of 500 min |
| --- | --- | --- |
| Before | 149 min 34 s | 350 min 26 s |
| After | 163 min 11 s | **336 min 49 s** |

**13 min 38 s** against a 40-minute budget. `mac_mini_m2_paid` was `0` before and `0` after:
billing stayed off, and no paid machine class was touched.

## 8. Not done, deliberately

* The build was **not** promoted to the `Externals` group and **not** submitted for beta review.
* The App Store submission of 1.0.17 (build 104) was not touched; it is still
  `WAITING_FOR_REVIEW` against 104.
* No screenshot, description or metadata was captured or changed.
* Nothing was verified on a physical device by this run. The fixes themselves were proven by
  build `6ab12566b31cc0ec1f0c5417` (`ui-verify`, 135 tests, zero failures) — see
  `docs/status/ios-chat-scroll-2026-09-21.md`.
