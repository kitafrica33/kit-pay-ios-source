# Kit Pay iOS — the four items of the 1.0.17 (105) device report, 2026-09-21

The owner tested 1.0.17 build 105 on a signed-in phone and reported four things. This is what
each one turned out to be, what changed, and what was measured.

| # | Report | Root cause | Shipped in |
| --- | --- | --- | --- |
| 1 | The share extension does not work at all | A self-inflicted permanent deadlock: sharing demanded a biometric-bound keychain credential, and the failure to read it wrote a hard denial only a successful read could clear | 106 |
| 2 | Lag between chats and when scrolling messages | Three chat surfaces called ImageIO **synchronously inside `body`**, at up to 11.6× the pixels they could draw, against a cache too small to hold one screenful | 106 |
| 3 | Swiping left and right on media | Two of the three ways to open media were dead ends that opened a standalone viewer with nowhere to swipe | 106 |
| 4 | Verify once, and blur the background until verified | Home locked on every tab switch, the pay screen prompted unconditionally, and Home *replaced* its content instead of blurring it | 106 |

Nothing here touches the 1.0.17 App Store submission, which remains attached to build 104.

---

## 1. The share extension

### What the phone said

> Nothing was sent. Sharing is locked or your account changed. Unlock Kit Pay and share again.
> Tap Retry to check sharing access again.

That string is `MessagingProcessBroker.Failure.accountChanged`.

### The precise condition on the owner's phone

`publishApprovedDestinations(…, requiresBiometricUnlock: biometricUnlockEnabled)` wrote the
share extension's destination list under a `.biometryCurrentSet` access control whenever Face ID
app-unlock was switched on. `.biometryCurrentSet` is destroyed by design when the enrolled
biometric set changes — a Face ID re-enrolment, an added face — and the binding was also keyed to
the session id, so a session change invalidated it too.

That alone would have been a recoverable error. What made it permanent was the handler: when
publication threw, `AppModel.revokeSharedMessagingAccess()` wrote a **hard** `sharing.denied`
marker and deleted `destinations.secure`. Only a *successful publication* clears that marker —
which is exactly the operation that was failing. Every relaunch re-ran the same publication,
threw the same error, and re-wrote the same denial. The share sheet could never recover, and
reinstalling was the only way out.

### The fix

Sharing no longer has an opinion about the app's lock state. The owner's rule is that biometrics
are for payments, not for chats:

* the destination list is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
  **no** `SecAccessControl` biometric flag, so the extension can read it while the phone is
  locked and after a Face ID re-enrolment;
* `suspendSharingForBiometricLock`, the `#if KIT_SHARE_EXTENSION` lease `.authenticationRequired`
  branch and `biometricSharingApprovalBlockedEpoch` are gone;
* "account changed" detection is kept **only** where the account truly changed — a different
  user id or a different account epoch — which is a real security boundary and a real refusal;
* the extension never needs the main app to be running or foregrounded.

If the customer is genuinely signed out, the copy says so plainly instead of blaming a lock.

### Proof

`ShareAuthorizationPolicy` is pure Foundation and runs on Linux through
`run_share_authorization_linux_gate.sh`. `test_share_lock_independence.py` reproduces the exact
refusal from a signed-in fixture with the app "locked" and is red against the build-105 sources:
`/data/artifacts/kstream-ops/store/xc/2026-09-21-share-lock-independence-RED-on-build105-sources.txt`.

---

## 2. Scrolling a thread of mixed media

### Three defects, none of which a behavioural test can see

The app renders the right pixels either way. It just could not render them at 60 Hz.

**(a) `body` decoded.** Three surfaces — the photo bubble, the album cell and the queued bubble —
called `downsampledImage(…)` / `CGImageSourceCreateThumbnailAtIndex(…)` **inside `body`**. A
`body` that decodes blocks the main thread for the whole decode, so every row arriving on screen
stalled the run loop tracking the finger. Every decoder on `ChatMediaThumbnailStore` is now
`async`; the store offers no synchronous entry point at all, so the mistake cannot be made again
by accident, and a Python contract asserts that it offers none.

**(b) They asked for pixels they could never draw.**

| Surface | Draws | Build 105 asked for | Oversampling |
| --- | --- | --- | --- |
| Photo bubble | ~900 px | 3 072 px (37.7 MB) | **11.6× the area** |
| Album cell | ~672 px | 1 024 px, uncached | 2.3× |
| Queued bubble | ~672 px | 2 048 px (16.8 MB), uncached | 9.3× |

The cache limit is 64 MB. A single photo bubble's thumbnail was 37.7 MB of it, so a thread with
three photos could not hold its own thumbnails and every scroll pass re-decoded what the pass
before it had just evicted. `ChatMediaDisplayBucket` now quantises every request onto a ladder
(`128 … 4096`), so the cache key is a property of the photo and its rough display size rather
than of one layout pass — and `ChatMediaAlbumGridView`, which used to key on the caller's raw
point size, stops fragmenting the budget into near-duplicate entries.

**(c) Six whole-thread folds per render.** `conversationLayout` re-folded the entire message
array on every render pass, on top of the projection memo. `ConversationLayoutCache`, keyed by
`ConversationLayoutKey` (projection identity, selection mode, group-ness, current user, separator
day, locale), derives it once per genuine change; `timelineItems`, `reactionTallies` and
`galleryItems` all read the memo.

**(d) The waveform allocated two arrays per body**, at 60 Hz, for every voice note on screen.
`ChatWaveformShape` is now arithmetic over the message UUID's own bytes: no allocation, stable
per message, and provable on Linux.

**(e) The gallery pager** rebuilt `Array(items.enumerated())` and ran `Date.formatted` per page
per render, inside a non-lazy `TabView(.page)`. It now iterates `items.indices` and builds its
accessibility labels once, off the main thread.

### Measuring it

`populateLongHistory` — the existing 2 000-message fixture — cannot show any of this: every one
of its rows is plain text, and plain text never touches the image decoder, the poster generator,
the waveform or the size formatter. The paths the owner was feeling were not under test at all.

`--kit-chat-mixed-media-scroll-fixture-v1` seeds the thread the report describes: **320 messages**
— 96 photos carrying **real JPEG bytes** at phone-camera proportions, 32 videos, 32 voice notes,
32 imported audio files, 32 documents and 96 text rows, several of them replies. Six images are
shared across the 96 photo rows, which costs the measurement nothing: every bubble mints its
thumbnail cache key from its own message id, so all 96 still pay for a full decode. It is
entirely local, so the workload is reproducible with no network.

### What a row costs, before and after

Every figure below is arithmetic over the source, so it is reproducible without a device:
a thumbnail's decoded cost is `edge x edge x 4` bytes, and the bubble cache is budgeted at
`64 * 1024 * 1024` = 67 108 864 bytes of decoded pixels (`ChatMediaThumbnails.swift:297`).
"Draws" is the larger edge of the frame at the 3x scale of every current iPhone.

| Surface | Draws | 105 asked | 106 asks | Decoded per thumbnail | Whole thumbnails the 64 MB cache can hold |
| --- | --- | --- | --- | --- | --- |
| `SecureImageMessageView` (photo bubble) | 900 px | 3 072 px (11.7x area) | 1 024 px (1.29x) | 37.7 MB -> **4.2 MB** | **1 -> 16** |
| `PendingSecureMediaMessageView` (queued photo/video) | 672 px | 2 048 px (9.3x) | 768 px (1.31x) | 16.8 MB -> **2.4 MB** | 4 -> 28 |
| `SecureMediaBatchItemView` (album cell) | 672 px | 1 024 px (2.3x) | 768 px (1.31x) | 4.2 MB -> **2.4 MB** | 16 -> 28 |

The middle column is the decode; the right-hand column is why it kept happening. A photo bubble
that costs 37.7 MB against a 67 MB budget means **one** bubble fits. Two photos on screen at once
evicted each other, so scrolling up and back down re-decoded every bubble it had just decoded —
and did it inside `body`, on the main thread. At 4.2 MB a screenful fits sixteen times over, so
the second pass over the same rows costs nothing at all.

| Per-render work | Build 105 | Build 106 |
| --- | --- | --- |
| ImageIO calls inside a `body` | 3 surfaces | **0** (`test_no_chat_bubble_decodes_inside_its_body`) |
| Whole-thread folds in `conversationLayout` | 6 per render | 1 per genuine change (`ConversationLayoutCache`) |
| Array allocations per `VoiceNoteWaveform` body | 2 | **0** (integer arithmetic over the message UUID) |
| Gallery pager per render | `Array(items.enumerated())` + a `Date.formatted` per page | `items.indices`; labels built once, off the main thread |
| Thumbnail cache key | the caller's raw `CGFloat` | a ladder rung, so one photo is one entry in every layout |

### What a clock on a shared CI Mac can and cannot say

`testMixedMediaThreadScrollsAndRecordsSwipeWallClock` drags twelve passes into the history of
the 320-row mixed thread and then back towards the newest row, timing every one and attaching
the figures as `mixed-media-scroll-wall-clock`.

| Run | Commit | Timed passes | Fastest | Slowest | Mean |
| --- | --- | --- | --- | --- | --- |
| `6ab1666b` | `4c81a82` | 22 | 2.78 s | 4.08 s | 3.27 s |
| `6ab16c17` | `51876f3` | 22 | 3.06 s | 4.43 s | 3.66 s |
| `6ab17461` | `8c1d945` | 22 | 2.79 s | 4.57 s | 3.35 s |
| `6ab178e8` (green) | `25a282e` | 22 | 3.03 s | 4.83 s | 3.51 s |

Eighty-eight timed drags over four runs: 2.78 s to 4.83 s, no run drifting from the one before
it, and no pass in any run slower than the pass that preceded it by more than a second.

**What those figures are not.** They are not frame times and they are not device latency. Each
one is a whole XCUITest swipe: resolving the scroll view, checking for interrupting elements,
synthesizing the drag, and then waiting for the app to go idle — which includes the scroll
view's own deceleration — against a **Debug** build in the **Simulator** on shared CI hardware.
The brief asks for a hitch rate near zero and a first move under 100 ms; that is an Instruments
measurement on a physical phone on a Release build, and **this document does not claim to have
taken it**. What can be said from here is that twenty-two consecutive drags over 320 rows of
real JPEG bytes, voice notes and video posters produced no stall, no decode storm and no
growth pass over pass.

**What they are for.** A regression floor. Build 105 decoded 37.7 MB inside `body` for every
photo bubble that came on screen, against a cache that could hold exactly one of them, so every
pass re-decoded what the pass before it had evicted. That does not cost a second a swipe; it
costs tens of seconds. The test fails above **8 s** for a single swipe, and the substantive
before/after evidence is the per-row arithmetic in the table above.

**Two earlier attempts measured the wrong screen, and that is worth recording.** A chat opens
pinned to its newest message, and a deliberate upward pull from a pinned timeline is this
product's *camera* gesture — `testChatBottomPullOpensCameraOnlyAfterADeliberateRelease` asserts
exactly that. The warm-up swiped up. On run `6ab15f28` the camera opened over the thread at
t = 24.9 s, iOS raised its Camera and Microphone prompts, XCUITest dismissed them inside the
warm-up swipe, and the twelve "timed" passes that followed were synthesized into a camera
preview while the timeline sat untouched at 100 %. The numbers were real and they measured
nothing; what exposed it was an unrelated assertion and a hierarchy dump. Reading history is
`swipeDown`, the test now asserts the camera never opened and that it ends on the newest row,
and `test_reading_history_never_pulls_up_on_a_pinned_timeline` keeps the direction pinned.
Run `6ab1666b` is therefore the *first* honest measurement of this thread, and the 2.5 s ceiling
it failed had been derived from the camera-preview timings of the run before it.


---

## 3. Swiping through a conversation's media

Opening a photo from a thread should put every photo and video in that conversation a swipe
away. On build 105 only one of the three ways in actually did that.

| Tapped | Build 105 | Build 106 |
| --- | --- | --- |
| A sealed single photo | Opens the gallery | unchanged |
| A photo inside an album | Standalone viewer, **nothing to swipe to** | Opens the gallery at that item |
| A queued photo or video showing its thumbnail | Standalone viewer, **nothing to swipe to** | Opens the gallery at that item |
| A queued photo still resolving its local copy | Standalone viewer, **nothing to swipe to** | Opens the gallery at that item |

The last three are the same defect, one bubble apart, and the giveaway is that
`galleryItemsFold` had *always* counted both among the conversation's gallery items — its very
first branch reads `pendingAttachment`. The items were in the gallery; nothing routed a tap to
them. In a thread where the recent media is still uploading, the queued case is every photo on
screen.

The third row of that table is the one the simulator caught, on 2026-09-21, after the first
two were already fixed. A queued bubble has two states: the one that draws a decoded thumbnail,
and the row that stands in for it while the local original is being resolved and decoded. Only
the first had been routed. On a thread being scrolled quickly that is the *rarer* of the two --
the stand-in is what most photos on screen are showing -- so the dead end survived the fix that
was supposed to remove it, and a test that tapped whichever photo happened to be on screen is
what found it.

Two details that had to be right:

* **The index must match the fold.** An album that mixes in a document must not renumber: item 3
  of the album has to open item 3. The fold enumerates before it filters, and a contract asserts
  it never filters first.
* **A refusal must not swallow the tap.** The fold only counts a queued row once a matching
  local media record exists, and a photo queued a moment ago may not have one yet. The hand-off
  therefore reports whether the gallery took the row, and a refused bubble keeps its own
  presentation -- opening a dead end is bad, opening nothing at all would be worse.
* **A page that is still loading shows the thumbnail the chat already decoded**, via
  `bestCachedThumbnail(forKey:)`, which walks the ladder downwards. Swiping onto a page used to
  show a spinner over black even though the bubble behind it was displaying that exact photo.

### Proof: the walk itself

`testMediaGallerySwipesThroughTheConversationsMediaInOrder` opens the gallery from a *queued*
photo — the bubble that had no way in — and then reads the gallery's own counter, "Item N of M",
for every turn. Run `6ab178e8`:

```
[KitPayGallery] labelled pages in the tree: 1 of 128
[KitPayGallery] forward walk: [96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106]
[KitPayGallery] walk back:    [106, 105, 104, 103, 102, 101, 100, 99, 98, 97, 96]
```

128 items is the whole conversation's media (96 photos + 32 videos). Eleven consecutive items
each way, in order, nothing skipped, the total unchanged throughout, both photos and videos
among them, and the landscape rotation and the 1x -> 2.5x -> 1x zoom in the middle left the
reader on item 106. It ends by closing the gallery back onto the conversation.

Three things about that test are worth keeping, because each of them cost a Mac run:

* **`TabView(.page)` keeps exactly one labelled page in the accessibility tree** — "1 of 128"
  above. A test that enumerates pages to find out what it is looking at gets one answer, and it
  is the right one; a test that enumerates `app.images` gets sixty-three and none of them
  carries the kind. The kind lives on the page's accessibility *container*.
* **A page turn is where the pager settled, not where the drag aimed.** An 84 %-width drag that
  lifts with the synthesizer's release velocity still on it can carry two items in one gesture
  (run `6ab16c17`: item 96 -> 98, against a walk that had assumed one). The drag now travels
  70 % and *holds* before lifting, and the counter is read until two consecutive readings agree.
* **A synthesized pinch cannot zoom in on a page that already fills the screen** — run
  `6ab17461` stopped on "Invalid scale 2.40 greater than maximum possible scale 0.84". The
  product also zooms on a double tap (`ZoomableImageView`, 1x <-> 2.5x anchored at the tap),
  which is both unlimited and what a reader actually does. Video pages are stepped over: they
  do not zoom, and their centre is the play button.

---

## 4. Verify once, behind a blur

### What build 105 did

Up to **three** prompts in a single foreground session, and nothing blurred:

1. `homeDidResignActive` locked Home **unconditionally**, so opening Messages and coming straight
   back was a second Face ID prompt without the app ever leaving the foreground. Leaving a *tab*
   is not leaving the app.
2. The returning-sign-in proof only unlocked Home when Home happened to be the selected tab, so
   unlocking the app into any other tab bought nothing.
3. `authorizePaymentRequestSubmission` prompted every time.
4. `HomeView` *replaced* its content with an opaque auth background. The thing the owner asked to
   see blurred — the wallet — was not on screen at all.

### What build 106 does

`ForegroundVerificationPolicy` is the single rule. One `Verification` per foreground session,
carrying the foreground epoch, the account epoch and the user id. It is recorded by any
successful biometric check (app unlock included) and by the PIN fallback, and it is honoured by
Home and by the pay screen.

It is voided by exactly one thing — a real trip through the background, in
`applicationDidEnterBackgroundSecurely` — plus the two account teardowns, and it can never be
read across an account-epoch change or a different user. Both stored properties are
`@Published private(set)`: no view can forge a proof.

Home draws `homeContent` blurred (28 pt), `.privacy`-redacted, hit-test-disabled and hidden from
VoiceOver, with `KitBiometricGateView`'s new `.blurredContent` backdrop — an `.ultraThinMaterial`
overlay — on top. Two properties follow from the policy rather than from a view:

* **Locking is instantaneous; only the reveal is animated** (0.25 s). Animating the lock would
  render intermediate frames of a legible balance, which is the "no flash of unblurred content"
  requirement stated as code.
* **The material is a second line of defence.** Even if the blur beneath ever rendered at radius
  zero for a frame, nothing legible shows through it.

Cancelling leaves the wallet blurred with the reason shown and an **Open Home** button that runs
the same check again.

### What deliberately did *not* change

`authorizeFinancialStepUp` — the server-verified signature behind an actual transfer — still asks
every single time. The owner's rule is that biometrics gate **payments**, not that they gate
looking, and a contract test asserts that this function never consults the session proof.

`signedInTabs` is *not* blurred behind a single app-wide gate: mounting MessagesView, CallsView
and ProfileView and running their `.task`s while the app is locked would be worse than the
problem. The app-unlock screen shows no customer content at all, which is stricter than a blur.

---

## 5. Gates run before any Mac minute was spent

| Gate | Result |
| --- | --- |
| `python3 -m unittest discover -s .github/scripts/tests` | 338 tests OK, 6 skipped |
| `run_share_authorization_linux_gate.sh` | 10/10 |
| `run_chat_media_bucket_linux_gate.sh` | 29/29 |
| `run_foreground_verification_linux_gate.sh` | 14/14 |
| `run_conversation_projection_linux_gate.sh` | 7/7 |
| `run_media_v2_linux_gate.sh` | 21/21 |
| `swiftc -parse` on every changed Swift file | clean |

Red-on-build-105 evidence, captured by running each new contract against a tree holding only the
build-105 copies of the files it reads:

| Contract | Against build 105 |
| --- | --- |
| `test_share_lock_independence.py` | red |
| `test_chat_media_render_cost.py` | 14/14 red |
| `test_foreground_verification_gate.py` | 13 red + 1 missing-file error; 1 deliberately green (the payment step-up guard-rail) |

### The Mac runs behind it

Every run below is workflow `ui-verify-media` — unit suites, then the three UI tests, on
`mac_mini_m2` with Xcode 26.6. It publishes nothing, signs nothing and creates no session.

| # | Build | Commit | Wall | What it settled |
| --- | --- | --- | --- | --- |
| 1 | `6ab14f89` | `f2d77c6` | 10 min 11 s | The lane itself: the fixture reaches the simulator |
| 2 | `6ab15445` | `abe140c` | 12 min 21 s | All seven unit suites green; first honest UI failures |
| 3 | `6ab15865` | `f5bcd5f` | 0 min 29 s | Cancelled — superseded before it got going |
| 4 | `6ab158d6` | `3f0bd7d` | 10 min 58 s | Unit suites green; the queued-photo dead end reproduced |
| 5 | `6ab15f28` | `a58b8c6` | 14 min 36 s | A queued photo opens the gallery at item 127 of 128 — and the camera-gesture trap, found |
| 6 | `6ab1666b` | `4c81a82` | 16 min 50 s | First timings of the real timeline; ten items walked in order |
| 7 | `6ab16c17` | `51876f3` | 21 min 07 s | Wall-clock test green; the pager's two-in-one gesture exposed |
| 8 | `6ab17461` | `8c1d945` | 16 min 08 s | Forward walk perfect; the pinch limit exposed |
| 9 | `6ab178e8` | `25a282e` | 23 min 40 s | **Green: 78 unit tests and all 3 UI tests, 0 failures** |

126 min 20 s of free `mac_mini_m2` time across the nine, `mac_mini_m2_paid: 0` throughout —
billing stayed OFF. The green run's log and artefacts are at
`/data/artifacts/kstream-ops/store/xc/2026-09-21-chat-media-run9-GREEN-*`.

---

## 6. What the owner should test on the phone

1. **Share.** From Photos, Files and Safari, share to a Kit Pay chat — with the phone just
   unlocked, with Face ID app-unlock switched **on**, and immediately after switching away
   mid-share. It must send without ever asking for a face.
2. **Scroll.** Open the longest chat with pictures in it and drag straight after *Jump to latest
   message*, then keep going up through the older media.
3. **Swipe.** Tap a photo inside a multi-photo message, and tap a photo that is still uploading.
   Both must open the viewer with the rest of the conversation's media a swipe away — left and
   right, through videos as well, rotating and zooming.
4. **Verify once.** Open the app with Face ID, go to Messages, come back to Home, then start a
   payment: one face for the whole session. Send the app to the background and return: it must
   ask again, and the wallet must be blurred and unreadable until it succeeds. Cancel the prompt
   and confirm the wallet stays blurred with a way to retry.
