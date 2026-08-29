# App Review notes

Paste the block below into **App Review Information → Notes** in App Store
Connect, and fill in the bracketed value first. The rest of this file is why
it says what it says — for us, not for Apple.

---

## The note to paste

```
HOW TO SIGN IN

You do not need a code, and you do not need an account.

On the first screen, tap "Have a look around". That opens a full demo of
the app — practice questions, diagrams, an end-of-sitting summary and the
timed speed run — with no sign-in of any kind. Questions come from a pack
bundled in the app, so it works with no network connection. Nothing you
answer is saved: there is no account behind the demo, so there is nothing to
attach an answer to and nothing kept after you leave it.

This app is for children only. There is no registration, no email address
and no password anywhere in it. In normal use a parent uses our web app and
hands their child a four-character code; typing that code is the app's
entire sign-in. Those codes last one hour and can be redeemed once, which
is a deliberate safety property of a children's app — so rather than paste
one here that would expire before you read it, the demo above needs no code
at all.

If you would like a live code to see the signed-in experience, contact us
at [CONTACT] and we will issue one within minutes, at whatever time suits
you.

WHAT TO EXPECT IN THE DEMO

- A plain home screen: a greeting, a Play button and a Speed button. It shows
  no stars or streak — those belong to a signed-in child's history, and the
  demo has none.
- Play starts a maths practice sitting at Year 3, answered on a large
  on-screen pad, and ends on a summary of what was answered.
- Speed is a 90-second timed round with its own score screen.
- None of this needs a network connection: play draws from a pack bundled in
  the app, and speed draws from a table built into the app.

A signed-in child (the fallback above) sees the same screens plus their own
stars, streak and speed-run history, and their answers sync to our server in
the background.

WHAT THE APP DOES NOT DO

- No account creation, no sign-up and no password anywhere in the app itself.
- No name, email address, date of birth or device identifier is collected.
- No analytics, no crash reporting, no advertising, and no third-party
  SDKs of any kind.
- No in-app purchases and no user-to-user communication. The one external
  link — a grown-up setting up an account — sits behind a date-of-birth
  parental gate and is account-only wording, not a purchase route.
- No camera, microphone, location or contacts access.

The app talks only to our own API at learnr-api-syd.fly.dev.
```

---

## Why the note is shaped this way

**A code cannot simply be written in the note, and this used to be the trap.**
The two facts that decide it, both confirmed against the server side via the
ledger:

- `CODE_TTL_MS` is **one hour** (`src/lib/login-code.ts`).
- Redemption is **single-use** — the argument for why four characters is safe
  rests on it.

Review can begin days after submission. A code pasted into the note at
submission time is dead long before anyone reads it, and the reviewer would
see "That code did not work." — which reads as a broken app rather than an
expired credential. That used to be worked around by archiving a
build already signed in as a demo child; the session token does not expire
(`SESSION_LIFETIME_MS` is 100 years, `apps/api/src/data/accounts.ts:276`), but
that approach was still tied to whichever device the build happened to be
archived from, and still fell back to a code that would be dead on arrival.

**Demo mode removes the credential from the path entirely.** "Have a look
around" (`CodeEntryView.swift`, `Session.enterDemo()`) needs no token, no code
and no network — see `LearnrApp/LearnrApp/Support/Session.swift`. It cannot
expire because nothing is issued, it cannot be single-use because nothing is
redeemed, and it does not depend on which device or simulator the archive was
built from. That is strictly stronger than a pre-signed-in build, so the note
leads with it and offers a live code only as a fallback for a reviewer who
specifically wants the signed-in experience.

### What to actually do before submitting

1. Check that "Have a look around" is reachable on the first screen of the
   build you are archiving, and walk it once: play, a speed run, and back out.
   That path is what the note tells the reviewer to use, so it is the one that
   must work in the shipped binary.
2. Fill in `[CONTACT]` with a channel that is genuinely monitored. The offer to
   issue a live code on demand is the fallback, so it has to be answerable.

### Why the note volunteers the negatives

The "what the app does not do" list is not padding. This is a children's app,
and if the Kids Category is selected Apple applies extra scrutiny to exactly
those points — third-party analytics, external links without a parental gate,
and data collection. Each line is checked against the source, matches
`LearnrApp/PrivacyInfo.xcprivacy`, and is cheaper to state up front than to be
asked about in a rejection.

One point to be ready to defend rather than assert: **the code entry screen is
not a parental gate**, and it is not claimed to be one. It is a credential
prompt. If a reviewer raises the gate requirement, the answer is that the app
has no purchases and no outbound web content reachable by a child — the one
external link (a grown-up setting up an account, from `GrownUpGate.swift`) sits
behind its own date-of-birth gate, asked fresh every time and never stored,
matching `LearnrApp/PrivacyInfo.xcprivacy`'s "no date of birth collected".
