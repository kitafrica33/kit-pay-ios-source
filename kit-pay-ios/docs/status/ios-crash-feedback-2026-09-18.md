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
editable and must be reused rather than duplicated. The build number goes **100 → 101**
(`CURRENT_PROJECT_VERSION` in all six configurations, plus the archive workflow's default and
its corresponding-source example URL).

<!-- publication evidence appended after the runs -->
