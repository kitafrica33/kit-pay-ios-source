# Kit Pay iOS — the chat that would not scroll, 2026-09-21

Owner report: on a long conversation the timeline sometimes stops responding to a finger
altogether. Borrowed-Mac session #2 reproduced it on the untouched baseline
(`db5dd47`): `AppStoreScreenshotUITests/testLongHistoryVerticalBubbleDragsPreserveReadingPosition`
failed with `("0.0") is not greater than ("90.0")` — a 170-point drag that started inside a
message bubble, ran for 3.5 seconds and moved the timeline **exactly nothing**.

This is what it turned out to be, how that was established without further Mac time, and what
changed.

## 1. Root cause

`ConversationView.correctedProjection` (`KitPay/Features/Messages/MessagesView.swift:1659` on
`db5dd47`) folds the whole account: it filters every message the app holds down to this
conversation, applies the authenticated corrections, drops the correction rows, sorts by
timeline date and allocates a fresh `[LocalMessage]`. It was a plain computed property, and the
conversation screen reads it about **fifteen times in a single `body`** — the timeline, a
`.task(id:)`, two `onChange(of: messages)` comparisons that deep-compare 2 000 elements each
carrying optional attachment `Data`, and, through `.contextMenu { messageContextMenu(message) }`
→ `forwardPayloadItems(for:)`, **once per visible bubble**. On the 2 000-message fixture that is
tens of thousands of message copies per render, all on the main thread, all while the same
thread is supposed to be delivering touch moves. It is not a gesture-ownership bug at all: the
main thread simply never got round to the pan.

## 2. How that was established

The device log recovered from the failing run (`/data/artifacts/kstream-ops/store/xc/pull/`,
42 MB reassembled) carries the fixture-only `[KitPayCameraPull]` trace, which prints every
reply-recognizer admission and every scroll-view position sample.

| Evidence | Reading |
| --- | --- |
| Touch-down state, failing drag | `admitted=true x=309.333 y=19701.667 scrollEnabled=true scrollPan=0`, `offset=19261.0 rest=19261.0` — **byte-identical** to the passing pass-1 drag |
| Synthesized events | Two identical 2 682-byte `XCSynthesizedEventRecord` plists; XCUITest sent the same gesture both times |
| The failing drag's 3.51 s window | **Empty.** No `reply begin`, no scroll `pan state=`, no KVO position sample, and not one pixel of screen change |
| First slop-exceeding pan sample, short conversation (pid 3532) | 106 ms, 112 ms, 99 ms after touch-down |
| First slop-exceeding pan sample, 2 000-message thread (pid 3588) | **644 ms and 381 ms** — a 4–6× penalty that scales with thread length |

A gesture that is being *stolen* produces callbacks belonging to the thief. A gesture that is
being *starved* produces nothing at all, and the latency it has to beat grows with the thread.
The log shows the second. Under the extra machine load left by the two UI tests that run before
it, the whole 3.5-second drag elapsed before either the swipe-to-reply pan or the scroll view's
own pan reached its ~10-point slop, so the timeline moved 0.0 points and the drag was reported
as a dead stop rather than as jank.

Three earlier leads were killed by the same evidence, and are recorded so nobody pays for them
twice:

* **"Three stacked scroll views."** The failure-time hierarchy does show two extra full-window
  `{0,0,402,874}` scroll views above `conversation-timeline {0,0,402,772}` — they are the other
  two `TabView` roots (Home/Wallet and Profile). They share `elementID` values with the real one
  (an XCUI dump artefact) and they are present in the **passing** hierarchy too.
* **A context-menu lift swallowing the drag.** Frame-by-frame extraction of the failure video
  shows zero pixel change throughout; no menu, no lift, no highlight.
* **Leftover state from the preceding tests.** `suite.log` records `Terminate
  africa.kit.pay.ios:3532` and a fresh `Launch` for every UI test, so the failing process was
  brand new. The preceding tests matter only because of the machine load they leave behind.

## 3. The fix

Memoise the fold on a key that costs nothing to build.

* `AppModel.state` gains a `didSet` that bumps a monotonic `stateGeneration`
  (`KitPay/App/AppModel.swift`). The model writes `state` from about twenty call sites, so
  anything a writer has to remember to do would eventually be forgotten; a `didSet` cannot be.
* `KitPay/Core/ConversationProjectionCache.swift` holds the last projection with the
  `ConversationProjectionKey` it was built from — `(stateGeneration, conversationID,
  scheduledMessageIDs)`. Send Later rows mature on the presentation clock without a state
  publish, which is why the scheduled set is part of the key and not inferred from the
  generation.
* `ConversationView` holds one cache in `@State` and `correctedProjection` reads through it. The
  fold itself moved verbatim into `correctedProjectionFold(conversationID:waiting:)`; what the
  timeline shows is unchanged, only how often it is computed.

Returning the *same array instance* for an unchanged key is load-bearing beyond skipping the
fold: `Array`'s `==` short-circuits on shared buffer identity, so both
`onChange(of: messages)` comparisons stop walking 2 000 messages and their attachment bytes on
every render.

Nothing was changed in the gesture layer. `SwipeToReplyPanCoordinator` and
`ConversationScrollPanReporter` were read in full during this investigation and no defect was
found in either; their tests are unchanged and still green.

## 4. Proof, red first

| Gate | What it pins | Red before the fix |
| --- | --- | --- |
| `KitPayTests/ConversationProjectionCacheTests.swift` (7 cases) — also runs on Linux via `.github/scripts/tests/run_conversation_projection_linux_gate.sh` | fold once per key; same buffer back; never answer a changed key | Yes — with the memo hit neutered: `("15") is not equal to ("1")` twice, plus the buffer-identity case |
| `.github/scripts/tests/test_conversation_timeline_projection.py` (9 cases) | `correctedProjection` reads through the memo and does no folding of its own; the key carries all three inputs; the generation is bumped in `didSet` and is not a second publisher | Yes — 6 of 9 fail against `origin/main`'s `MessagesView.swift` and `AppModel.swift` |
| `KitPayTests/ConversationProjectionPerformanceTests.swift` (2 cases) | the render budget, measured on a real 2 000-message thread, and the cost of the two `onChange` comparisons | n/a — it measures the fix rather than the defect, and attaches the numbers to the result bundle |
| `.github/scripts/ios_native_build.sh chat-scroll` | the chat suites, three times, in the order that failed (attachment menu → camera pull → long history) | The long-history case was the original red |

The performance cases assert ratios, not milliseconds: a borrowed CI Mac cannot promise
wall-clock numbers, but a memo that has stopped memoising loses an order of magnitude and cannot
hide inside any reasonable margin.

## 5. Verification lane

`codemagic.yaml` gains a `ui-verify` workflow. It archives nothing, publishes nothing and holds
nothing open: prepare, `build-for-testing`, run `ios_native_build.sh chat-scroll`, exit.
`max_build_duration: 30` so it ends rather than overruns the free-minute budget. Unlike
`mac-session-60` the preparation runs in the foreground, because nobody is driving this machine
and a failed `pod install` must fail the build rather than leave a green run with an empty log.

`testLongHistoryVerticalBubbleDragsPreserveReadingPosition` now runs **three** drag passes
instead of two and prints the wall clock of each drag. The pass that failed is the one taken
straight after *Jump to latest message*, where the screen has just republished; repeating it is
what turns an intermittent freeze into a usable signal.

## 6. Verification — one Codemagic build, all green

Build `6ab12566b31cc0ec1f0c5417` (`ui-verify`, branch `fix/chat-scroll` at `1065aa8`,
`mac_mini_m2`, Xcode 26.6), 2026-09-21 12:39:12Z → 13:09:02Z, **29 min 50 s**, billing OFF.
Three ordered attempts, **45 tests each, zero failures**:

```
attempt 1/2/3  ConversationNativeOpeningTests            22 passed
               ConversationProjectionCacheTests           7 passed
               ConversationProjectionPerformanceTests     2 passed
               SwipeToReplyNativeGestureTests            11 passed
               testChatAttachmentMenuOpens…              passed   92.1 / 85.8 / 79.7 s
               testChatBottomPullOpensCamera…            passed   76.0 / 70.5 / 72.4 s
               testLongHistoryVerticalBubbleDrags…       passed  222.6 / 219.1 / 216.5 s
```

**Every drag moved.** Nine jump-to-latest → older-drag passes (three per attempt) and nine
return drags, all identical to the baseline's *passing* pass:

| | baseline, build 104 | after, all 9 passes |
| --- | --- | --- |
| older drag, minY | 430.62 → 600.62 (pass 1) / **430.62 → 430.62 (pass 2, dead)** | 430.62 → 600.62, **+170.0 pt every time** |
| newer drag, minY | 532.95 → 482.95 | 532.95 → 482.95, −50.0 pt every time |

The render budget, measured on the simulator inside the test run (Debug, 2 000 messages,
10 renders × 15 reads, the screen's real access pattern):

| | folds | elapsed |
| --- | --- | --- |
| before the memo | 150 | 2 260 / 2 490 / 2 209 ms |
| after | 10 | 117 / 173 / 156 ms |

That is **226 ms of folding per render** before, against 12–17 ms after: a 14–19× cut, and an
explanation of the freeze that needs no gesture theory at all. The two `onChange(of: messages)`
comparisons went from **29–33 ms per twenty** to **0 ms**, because both sides now share one
buffer.

First-move latency after touch-down on the long thread, from the fixture pan log
(`KitPay-chat-scroll-pan.log`): 559 / 556 / 415 ms, 562 / 376 / 430 ms, 570 / 369 / 410 ms for
the three older drags of each attempt, against the baseline's 644 ms — and, in the failing
baseline pass, a sample that never arrived inside the 3.51-second drag. Most of what remains is
XCUITest's own 60 pt/s synthesis reaching the ~10-point slop, not the app.

Nothing was archived, uploaded or submitted, and the pending review of 1.0.17 was not touched.
