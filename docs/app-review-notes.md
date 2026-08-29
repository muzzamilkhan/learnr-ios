# App Review notes

Paste the block below into **App Review Information → Notes** in App Store
Connect, and fill in the two bracketed values first. The rest of this file is
why it says what it says — for us, not for Apple.

---

## The note to paste

```
HOW TO SIGN IN

This app is for children only. There is no registration, no email address
and no password anywhere in it. A parent uses our web app and hands their
child a four-character code; typing that code is the app's entire sign-in.

The test device does not need a code. The build you have has already been
signed in as a demo child, and the session does not expire, so the app opens
straight onto the home screen with practice ready to start.

If you do need to sign in from scratch — a fresh install, or a device wipe —
please use this code:

    Code: [CODE]
    Issued: [DATE/TIME UTC]

IMPORTANT, PLEASE READ: a login code lasts ONE HOUR from when it is issued
and can only be redeemed ONCE. This is a deliberate safety property of a
children's app, not a limitation we can lift for review. If the code above
has expired or has already been used, the app will say "That code did not
work." That is the app behaving correctly.

If that happens, please contact us at [CONTACT] and we will issue a fresh
code within minutes, at whatever time suits you. We are happy to be on
standby during your review — please just tell us when.

WHAT TO EXPECT

- The app opens on a home screen showing the child's stars and streak.
- Tapping through starts a practice sitting: maths and English questions
  for the child's school year, answered on a large on-screen pad.
- There is also a timed "speed run" mode.
- Everything works offline. Questions are generated on-device and answers
  sync when a connection returns.

WHAT THE APP DOES NOT DO

- No account creation, no sign-up, no password.
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

**A code cannot simply be written in the note, and this is the trap.** The two
facts that decide it, both confirmed against the server side via the ledger:

- `CODE_TTL_MS` is **one hour** (`src/lib/login-code.ts`).
- Redemption is **single-use** — the argument for why four characters is safe
  rests on it.

Review can begin days after submission. A code pasted into the note at
submission time is dead long before anyone reads it, and the reviewer sees
"That code did not work." — which reads as a broken app rather than an expired
credential. This is a rejection waiting to happen, so the note is written to
make the demo build carry the session instead.

**A redeemed session is what makes this work.** `SESSION_LIFETIME_MS` is 100
years (`apps/api/src/data/accounts.ts:276`), and the token is held in the
Keychain, so a build signed in before submission stays signed in through review
indefinitely. That is why the note leads with "the test device does not need a
code": it is true, and it removes the expiry from the reviewer's path entirely.

### What to actually do before submitting

1. Have a parent account issue a login code for a demo child. Give that child a
   realistic amount of history — a few sittings and a speed run — so the home
   screen shows stars and a streak rather than an empty state.
2. **Redeem it on the device or simulator you archive from**, so the shipped
   build is already signed in. Redeem it *once*: a second attempt with the same
   code fails by design.
3. Issue a **second, fresh code** immediately before hitting Submit, and put it
   in the note with the time you issued it. It will very likely be expired when
   read — the note says so plainly — but it costs nothing and covers the case
   where a reviewer wipes the app.
4. Fill in `[CONTACT]` with a channel that is genuinely monitored. The offer to
   issue a code on demand is the real fallback, so it has to be answerable.

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
