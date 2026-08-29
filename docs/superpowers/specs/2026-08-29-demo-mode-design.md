# Offline demo mode, and the grown-up route

**Ledger item:** `L26` (raised by the web side, 2026-08-28, on Muzzamil's
ruling). Plus a second, smaller thing asked for on this side: a way for a
grown-up who has no account to find out how to get one.

**Status:** design, approved 2026-08-29. Nothing here touches the API, the
contract, the engine or the digests, and nothing ships from `learnr` for it.

## Why a demo mode rather than a demo account

Apple's Guideline 2.1 wants a reviewer to be able to see the app. This app's
only credential is the four-character login code, which lives one hour
(`CODE_TTL_MS`) and is spent at redemption, so nothing typeable can sit in App
Store Connect and still work days later when a reviewer opens it.

A reserved always-valid code was costed on the web side and rejected. The three
reasons, recorded here because they are the ones that would be re-derived
otherwise:

1. Both redeem throttles **clear the caller on success**, so a code that always
   succeeds is a free counter reset — and it defeats the only thing bounding
   guesses against a 923,521-code space where `redeemLoginCode` matches *any*
   live code.
2. `SESSION_LIFETIME_MS` is **100 years**, so every stranger who ever typed it
   keeps access permanently, and a valid child session is write access to the
   attempt endpoints.
3. The child's home screen draws the **family leaderboard**, so a demo child
   hung off a real parent shows strangers real children's faces and names.

The previous plan — recorded in `docs/app-review-notes.md` — was to archive a
build already signed in as a demo child, with a fallback code in the note. This
supersedes it, and removes the expiring-code trap from the reviewer's path
entirely.

## What is being built

Two independent things, on the same screen, sharing nothing but their location.

1. **Demo mode** — a purely local child a reviewer (or anyone) can play as.
2. **The grown-up route** — one external link, behind a parental gate.

They are specified separately below because they fail separately.

---

## Part 1: Demo mode

### The shape

A third case on `Session.State`:

```swift
enum State: Equatable {
    case loading
    case signedOut
    case signedIn(Account)
    case demo            // new
}
```

`RootView` switches on it and shows the same `HomeView` a signed-in child sees,
driven by a demo-flavoured session. The reviewer walks the real product: play, a
diagram question, a speed run and its result, and the sitting summary.

### Isolation is structural, not filtered

The web side asked specifically that a demo run be **unable** to reach the sync
queue rather than filtered out at flush, on the same reasoning as the speed-run
sealing argument. That is met by absence, not by a flag:

- **`PlaySession.queue` becomes `SyncQueue?`.** `SpeedSession` already takes an
  optional queue where `nil` means "queue nothing", so this makes the two
  consistent rather than introducing a new idea. A demo `PlaySession` is
  constructed with `nil`, so there is no object on which an attempt could be
  recorded.
- **No `ApiClient` traffic.** The only two network readers on this path are
  `PlaySession.loadProfile()` and `Session.refreshPlayer()`; a demo session
  calls neither.
- **No caches.** `NoAccountCache` and `NoPlayerSnapshotCache` already exist in
  the engine for exactly this purpose, so nothing is written to Application
  Support and nothing survives the process.

The profile and the selector are fed from an in-memory `LearnerProfileState`
owned by the demo session. It is discarded when the session is released.

There is nothing to filter at flush because nothing ever reaches a queue.

### Content

The **bundled packs** (`f705afe`, `ff4946b`) via `ContentLibrary.packForPlay`,
which is cache-first and never blocks on the network. Demo therefore works on a
device that has never signed in, has no connection, and has never fetched
anything — which is the reviewer's device on a lab wifi, and is the case that
must not fail.

### Defaults

**Year 3, maths.** This reuses `Session`'s existing `.three` fallback rather
than inventing a second demo-only constant, so there is one rule about "what
level when nobody has said" rather than two. Year 3 is mid-range, so a reviewer
sees real arithmetic and real figures rather than the trivial or the hardest
end.

No level picker: it is ruled not to exist on iOS, because every account that can
reach this app is a managed child by construction. A demo child is not an
exception worth breaking that for.

### Leaving

A demo session ends by returning to code entry. Releasing the object *is* the
discard — there is no teardown to forget, because there is nothing persisted to
tear down.

No confirmation prompt. A child who wandered in should get out in one tap.

### It ships to everyone

The reviewer uses the same binary as every child, so this button is reachable in
production and real children will find it. The web side reads that as a feature
rather than a risk, and this design agrees: a child who taps it gets maths
practice that does not count, which is a fair thing for it to be. The wording is
chosen to be honest to a child, not just legible to a reviewer.

---

## Part 2: The grown-up route

### The problem it solves

A grown-up holding a child's device has no way to discover how to get an
account. The child-facing screen says "your grown-up will give it to you",
which is useless if the grown-up is the one reading it.

### The gate, and why there is one

`docs/app-review-notes.md` currently promises Apple — twice — that the app has
**no external links**, and uses that promise as its defence against the Kids
Category parental-gate requirement ("nothing behind a gate to guard"). Adding an
ungated link would contradict a claim already written for the reviewer, in the
category where Apple scrutinises exactly this.

So the link sits behind a **date-of-birth parental gate**.

**The date of birth is verified and discarded.** It is held in view state for as
long as the sheet is open, compared against 18 years before the current date,
and never written to disk, never sent to the API, and never retained after the
sheet closes. Nothing is *collected* in Apple's sense, so:

- `PrivacyInfo.xcprivacy` stays true as written ("no name, no email address, no
  date of birth and no device identifier in any request") and needs no change.
- The review notes' data claims stay true; only the external-links claim needs
  rewriting, which Part 3 covers.

The gate is deliberately **not** remembered between openings. Remembering it
means holding a date of birth or a flag derived from one, which is the thing
that would force a privacy-declaration change and make a kids-app data claim
harder to defend. Re-asking costs a grown-up five seconds, once.

### The destination

`https://learnr.muzza.tech` — the web app root, verified to respond 200.

This is a compromise and is recorded as one. `/signup`, `/sign-up`, `/register`
and `/login` all 404, there is no `learnr` clone on this Mac, and parent sign-in
is Google-only, so the exact route a parent should land on is not knowable from
here. A ledger ask is raised for it; the URL is a single constant so swapping it
is a one-line change when the answer comes back.

### Wording, and Guideline 3.1.1

The copy is strictly about **setting up an account**. No prices, no
"subscribe", no "upgrade", nothing that reads as routing a purchase around
in-app purchase. A link to create an account is ordinary; language that reads
as a purchase flow is what 3.1.1 bars.

This is a judgement call made on the product's behalf, not legal advice.

### Layout

```
        [ _ ][ _ ][ _ ][ _ ]

    Your grown-up will give it to you.

         Have a look around  ›          <- demo, secondary

  ── ─────────────────────────────── ──

   New here? Grown-ups can set up an
   account  ›                            <- opens the gate
```

---

## Part 3: The App Review notes

`docs/app-review-notes.md` is rewritten in its own commit, because it is
documentation rather than code and because it is what a reviewer actually reads.

What changes:

- **The lede.** "You do not need a code — tap *Have a look around*" replaces the
  pre-signed-in-build strategy and the `[CODE]`/`[DATE]` fallback. This is
  strictly stronger: it cannot expire, cannot be single-use, and does not
  depend on which device was archived from.
- **The external-links claim.** "No in-app purchases, no external links" becomes
  an accurate statement that there is exactly one outbound link, that it goes to
  our own web app, that it is behind a date-of-birth parental gate, and that the
  date is not stored or transmitted.
- **The parental-gate paragraph.** The current argument ("nothing behind a gate
  to guard") no longer holds and is replaced by the fact that the one thing
  which needs a gate has one.

What does **not** change: the data-collection list, which is still true, and
`PrivacyInfo.xcprivacy`, which is unaffected.

---

## Testing

The point of the tests is the web side's requirement, so that gets the most
direct one available.

| What | Why |
| --- | --- |
| A demo sitting records an answer and `SyncQueue.pendingAttemptCount` stays `0` | The direct proof that demo cannot reach the queue |
| A demo speed run leaves `pendingRunCount` at `0` | Same, for the other path that queues |
| A demo session with no network stub still deals a question | Proves the bundled-pack path, which is the reviewer's actual device |
| Exiting demo and re-entering starts an empty profile | Proves the discard |
| The existing 73 app tests still pass | Proves making `PlaySession.queue` optional did not quietly stop recording for real children — the regression that would matter most |
| The gate refuses a date under 18 and opens the link on a date over it | The gate does its job |
| The gate holds no date of birth after dismissal | The privacy claim |

## Out of scope

- Any change to the API, the contract, the engine, or the digests.
- A level picker (ruled against on iOS).
- An in-app parent sign-up or purchase flow.
- Remembering that the gate was passed.

## Open question

`L27`-style ask to the web side: the exact URL a parent should be sent to in
order to create an account. Nothing blocks on it — the root is a working
destination in the meantime.
