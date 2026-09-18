# Kit Pay iOS — TestFlight crash feedback, 2026-09-18

Owner request: check Kit Pay iOS feedback, fix the crash, and publish again.

## 1. What Apple had on file

Pulled from the App Store Connect API for `africa.kit.pay.ios` (app `6802582070`) on
2026-09-18.

| Source | Result |
| --- | --- |
| `betaFeedbackCrashSubmissions` | **1** submission, 2026-09-18T17:22:25Z |
| `betaFeedbackScreenshotSubmissions` | 0 |
| `customerReviews` (all territories) | **0** — the app has never been on sale |
| `appStoreVersions` | one record only: **1.0.17, REJECTED**, `releaseType` AFTER_APPROVAL |
| `reviewSubmissions` | newest is `371935eb-…`, submitted 2026-09-09, **UNRESOLVED_ISSUES** |
| Latest TestFlight build | **1.0.17 (100)**, uploaded 2026-09-09, `VALID`, not expired |

There are no customer reviews to answer: 1.0.17 is the only version record and it has never
been approved, so nothing has ever shipped to the store. The single crash submission is
therefore the whole of the feedback.

### The one crash signature

```
Comment:      "App crushed when I tried opening a chat"
Build:        1.0.17 (100)           Distributor: com.apple.TestFlight
Device:       iPhone15,4 (iPhone 15 Plus), arm64e
OS:           iPhone OS 26.6 (23G71)
Locale:       en-UG, Africa/Kampala
Exception:    EXC_BAD_ACCESS (SIGSEGV)
Subtype:      KERN_PROTECTION_FAILURE at 0x000000016cd63fc0
Message:      Thread stack size exceeded due to excessive recursion
Triggered by: Thread 0 (main)
```

Top frames, crashed thread (full log in `~/kstream-ops/crash/kitpay/`):

```
0-6    libswiftCore  decodeMangledType / swift_getTypeByMangledNode / swift_getTypeByMangledName
7-10   libswiftCore  _checkGenericRequirements / _gatherGenericParameters / createBoundGenericType
11-62  libswiftCore  decodeMangledType ⇄ decodeGenericArgs        ← the recursion, frames elided
63-69  libswiftCore  swift_getTypeByMangledNameInContextImpl
70     KitPay        __swift_instantiateConcreteTypeFromMangledNameV2
71-72  KitPay        closure #4 in ConversationView.conversationLayout.getter
73-76  SwiftUICore   VStack.init(alignment:spacing:content:)      MessagesView.swift:2726
77-81  KitPay        ConversationView.conversationWithSharedReview.getter    :3033, :3041
82     KitPay        ConversationView.conversationMediaPickers.getter
83     KitPay        ConversationView.conversationSheets.getter              :3175
84     KitPay        ConversationView.conversationDeleteConfirmation.getter  :3818
85     KitPay        ConversationView.conversationTasks.getter               :3849
86     KitPay        ConversationView.conversationLifecycle.getter           :3942
87     KitPay        ConversationView.body.getter                            :2069
```

No dSYM symbolication was needed: every KitPay frame already carries its symbol and source
line, and the fault is entirely inside the Swift runtime's own type decoder.

## 2. Root cause

This is not a logic bug and not a retain cycle. It is the Swift runtime failing to *decode the
type of the screen*.

`ConversationView.body` was one opaque SwiftUI type composed through eight chained stages —
`conversationLayout` → `conversationWithSharedReview` → `conversationMediaPickers` →
`conversationSheets` → `conversationDeleteConfirmation` → `conversationTasks` →
`conversationLifecycle` → `body`. Each stage wraps the previous one in more modifiers, and
`conversationSheets` alone adds 16 `.sheet`, 6 `.fullScreenCover`, an `.alert` and a
`.confirmationDialog`, each carrying its whole presented subtree's type inside its own.

Inside that, `conversationLayout`'s `ForEach(renderedTimeline)` inlined an eleven-case `switch`
whose `.message` case held a further five-branch `if / else if` chain. `ViewBuilder` folds every
branch into another `_ConditionalContent` layer, so one timeline row nested roughly sixteen
generic levels deep with a full bubble type at each leaf. A five-branch composer chain sat
directly beneath it.

The product of those nestings is a single generic type whose mangled name the runtime must decode
before it can build the view. `decodeMangledType` and `decodeGenericArgs` recurse once per generic
level; on the 1 MB main-thread stack that recursion ran off the end of the stack guard page, which
is exactly what the exception says. Opening any chat hit it, deterministically, on a released
TestFlight build.

The same over-large type had already bitten this screen from the other side: build 83 failed to
compile because "a chat disappearance expression exceeded the compiler's type-checking limit"
(`CI_WORKFLOWS.md`). That was the warning; this crash is the same shape reaching a customer.

## 3. The fix

`AnyView` is the cut. Erasing a view resets the type nesting to one level, so one undecodable
type becomes several shallow ones the runtime can decode comfortably. Erasure is safe here
because none of these sites is conditional on the *type* level — the wrapped type is the same on
every render, and `ForEach` still identifies rows by `ConversationTimelineItem.id`, so row
identity, selection and animation are unchanged.

In `KitPay/Features/Messages/MessagesView.swift`:

1. **The timeline row is extracted and erased.** New `timelineRow(for:…) -> AnyView` holds the
   eleven-case switch, and `messageRow(_:…) -> AnyView` holds the `.message` chain. Every branch
   `return`s an `AnyView` explicitly, so `_ConditionalContent` never forms in a row at all.
   Branch order and behaviour are preserved exactly, including the forged-KITSYS1 guard, the
   suppressed-reaction guard, the album leader/follower split and the text-bubble
   `LocalMediaPerformanceMonitor` callback.
2. **The composer footer is extracted and erased** into `conversationFooter: AnyView`, replacing
   the five-branch `if / else if` chain under the thread.
3. **All seven stage seams are erased**, so the eight-stage chain becomes eight independent
   shallow types instead of one cumulative one.

Net effect: the deepest single type the runtime has to decode drops from the whole screen to one
stage's modifiers.

## 4. Tests

`.github/scripts/tests/test_conversation_view_type_depth.py` — 5 cases. The repo has no Swift
toolchain on Linux, and the native suite cannot construct a `ConversationView`, so this follows
the directory's existing source-contract style (`test_verification_badge_placement.py`). It pins:

- every stage seam is still `AnyView(...)`;
- `timelineRow`, `messageRow` and `conversationFooter` all return `AnyView`;
- none of them is a `@ViewBuilder`, and each returns an erased view per branch;
- the `ForEach(renderedTimeline)` delegates and contains no inline `switch item`;
- `conversationLayout` carries at most 12 `ViewBuilder` branches.

All five fail against the pre-fix source at `4471818` and pass after. The full cheap suite is
green: `python3 -m unittest discover -s .github/scripts/tests` → **269 tests, OK (skipped=5)**.

Linux pre-flight for the Swift change: `swiftc -parse` on the edited file under
`docker run swift:5.10-noble` exits 0. SwiftUI cannot be type-checked off-Apple, so the real
build and the native suite run in the archive workflow.

## 5. Publication

Version stays **1.0.17** — that ASC version record already exists and is `REJECTED`, so it is
editable and must be reused rather than duplicated. The build number goes **100 → 102**
(`CURRENT_PROJECT_VERSION` in all six configurations, plus the archive workflow's default and
its corresponding-source example URL).

Build 101 was skipped. The AGPL gate needs a publicly reachable corresponding-source release
tagged `v<marketing>-build<build>` before the archive runs, and GitHub releases are now
immutable: the build 101 release was created published, so it refused its assets, and after it
was deleted the tag `v1.0.17-build101` could never be published again
(`422 tag_name was used by an immutable release`). `KitLegalURLPolicy.isTrustedCorrespondingSourceURL`
builds the expected tag from the running build's own version and build number, so a differently
named tag would have failed the in-app legal screen and `verify_ios_archive.py`. The correct
order is **create the release as a draft, upload the assets, then publish it**.

### Evidence

| Step | Identifier | Result |
| --- | --- | --- |
| App commit on `main` | `f889d1708fbda2369d5beb8c3a2db56914574d11` | pushed, fast-forward |
| Corresponding source | `kitafrica33/kit-pay-ios-source` tag `v1.0.17-build102`, release 391735392 | published, assets anonymously downloadable, tar.gz SHA-256 `5cde19c1…` |
| Signed archive run | `ios-app-store-archive.yml` run **35386372231** (`app-store`, `update_screenshots=false`) | success — native suite, iPad review-account unlock, signed IPA |
| TestFlight upload run | `ios-testflight-upload.yml` run **35393155373** | success, dispatched once |
| TestFlight build | 1.0.17 (102), ASC build `7d2644de-b342-4f64-91f2-62a3dc1ddd4e` | `VALID`, `IN_BETA_TESTING` internal and external |
| External distribution | group `Externals` `6ab1c5db-f1b8-477c-88bc-dd7883548fc4` (public link `1kpYk3Dh`) | build added, beta review submitted |
| App Store version | `fd84e0cc-f53f-4356-bc97-ae6cd22150d5` (1.0.17) | build 102 attached, `releaseType = AFTER_APPROVAL` |
| Review submission | **7c475370-ad71-4e7e-91ac-1a53fe87ac0b** | `WAITING_FOR_REVIEW`, submitted 2026-09-18T21:02:05Z |

The previous review submission `371935eb-61fa-4ace-a4a3-022a40cfb481` held the rejected build 100
and had to be cancelled before the version could join a new submission; Apple refuses both
`submitted` on an `UNRESOLVED_ISSUES` submission and a second submission item for a version that
is still attached to one. Cancelling it moved it to `COMPLETE` and released the version.

"What's New" could not be set: the app has never been on sale, so ASC answers
`409 STATE_ERROR — Attribute 'whatsNew' cannot be edited at this time` for a first version. The
fix wording therefore lives in the TestFlight "What to test" notes on build 102 instead.

## 6. Second crash: build 102 killed by RunningBoard

A second TestFlight crash arrived at 21:28 UTC, `AJLYv-nIkFXNeKKLq-bHyBY`, comment
"Crushed abruptly, please review", from the same iPhone 15 Plus on iOS 26.6 — this time on
**1.0.17 (102)**, the build that fixed the chat-open crash. The log is saved at
`~/kstream-ops/crash/kitpay/crash-AJLYv-nIkFXNeKKLq-bHyBY.crash`.

It is a different fault, not a recurrence:

```
Exception Type:     EXC_CRASH (SIGKILL)
Exception Codes:    0x0000000000000000, 0x0000000000000000
Termination Reason: RUNNINGBOARD 0xdead10cc
Triggered by Thread: 0
Launch Time:        2026-09-19 00:15:24   Date/Time: 2026-09-19 00:23:43
```

Thread 0 is the idle main run loop (`mach_msg2_trap` → `__CFRunLoopRun` → `GSEventRunModal`);
nothing faulted. `0xdead10cc` is the watchdog code for *terminated for holding a file lock or
SQLite lock on a file in a shared container while suspended*. The one thread doing application
work was thread 16:

```
SecureLocalStore.encryptedState  (SecureLocalStore.swift:610)   JSONEncoder.encode(PersistedState)
SecureLocalStore.persist         (SecureLocalStore.swift:573/518)
SecureLocalStore.update          → AppModel.commitAuthenticatedMutation (AppModel.swift:20643)
AppModel.flushOutbox             (AppModel.swift:20622)
closure #2 in AppModel.scheduleOutboxWake (AppModel.swift:22849)
```

`SecureLocalStore.persist` runs its whole transaction inside `messagingBroker.withLock`, and
`MessagingProcessBroker.withLock` holds `flock(LOCK_EX)` on
`<group.africa.kit.pay.ios>/MessagingBroker/transaction.lock` — a file in the app-group
container shared with the share and broadcast extensions. The outbox wake timer fires on its
own schedule, so backgrounding the app while one of those writes is in flight suspends the
process mid-lock and the OS kills it. Eight minutes of uptime and no user-visible fault match
that exactly.

### Fix

`SharedLockActivity` (in `MessagingProcessBroker.swift`, so it stays free of UIKit for the
`APPLICATION_EXTENSION_API_ONLY` targets) hands out an activity assertion that `withLock`
begins before opening the lock descriptor and ends after `flock(LOCK_UN)`, on every path
including throws. `KitPayApp.init` installs the only provider, backed by
`UIApplication.beginBackgroundTask(withName: "africa.kit.pay.shared-store-lock")`, before any
other launch work; extensions keep the no-op default. The process therefore cannot be suspended
between lock and unlock, which is Apple's prescribed remedy for `0xdead10cc`.

### Tests

- `SharedLockActivityTests` (native, 4 cases): the assertion is open for the whole locked body,
  it is ended when the body throws, it outlives the file lock (a second descriptor can take
  `flock(LOCK_EX | LOCK_NB)` only once the assertion's end handler runs), and an uninstalled
  provider still returns a balanced handler.
- `.github/scripts/tests/test_shared_lock_activity.py` (5 cases): the assertion brackets the
  descriptor and the unlock, `flock(` appears in no other source file, the broker imports no
  UIKit, the app installs the provider first, and exactly one target installs one.
  All five fail against the build 102 source. Whole Linux suite: 274 tests, OK.
- `swiftc -parse` under `docker run swift:5.10-noble` on the three edited Swift files: exit 0.

### Publication

The version stays **1.0.17** and the build goes **102 → 103**: App Store Connect refuses to
create a 1.0.18 record while the app has never been released and 1.0.17 is still editable
(`409 ENTITY_ERROR.RELATIONSHIP.INVALID — You cannot create a new version of the App in the
current state`). The 1.0.17 review submission `7c475370-ad71-4e7e-91ac-1a53fe87ac0b` that had
build 102 attached was cancelled before review started, so no crashing binary is with Apple;
the version is `DEVELOPER_REJECTED` and takes build 103 for the new submission.
