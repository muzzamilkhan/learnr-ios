---
name: ledger
description: Use when a session in learnr-ios starts, before answering anything about the server, API, contract, engine or specs, when unsure how a ported behaviour is meant to work, or when a change here alters what the learnr web side may assume. The shared LEDGER.md on tesseract replaces GitHub issues between learnr and learnr-ios.
---

# The LearnR ledger

`muzzamilkhan/learnr` (web, API, engine) is worked on from the Linux box
`tesseract`. `muzzamilkhan/learnr-ios` is worked on from this Mac. Neither
repo is ever edited from the other side's session, so a shared file is where
the two hand work over. It replaces the GitHub issues they used to raise on
each other.

The ledger is the current state of the other side. **A clone of `learnr` on
this Mac is evidence of what has shipped, not of what exists** — it runs days
behind. Never answer a question about the server from the checkout alone.

## Reaching it

The ledger lives at `/home/muzza/code/learnr-ledger/LEDGER.md` on `tesseract`,
outside both repos. A wrapper at `~/bin/ledger` makes every call one word:

```bash
ledger read       # the whole thing — do this at the start of every session
ledger items      # just what is outstanding
```

The wrapper spells the `ssh` call out rather than using the interactive `ss`
alias, because **aliases are not inherited by child shells** — a `bash` wrapper
calling `ss` fails with `exec: ss: not found`. If `~/bin/ledger` is missing,
recreate it:

```bash
cat > ~/bin/ledger <<'WRAP'
#!/usr/bin/env bash
exec ssh muzza@172.16.0.20 "cd ~/code/learnr-ledger && ./ledger $(printf '%q ' "$@")"
WRAP
chmod +x ~/bin/ledger
```

Use the **IP**: `tesseract` does not resolve from this Mac. The `printf '%q '`
quoting is load-bearing and verified — backticks, apostrophes and `$…` all reach
the ledger literally, so a title may contain `` `GET /play/state` `` safely.

A body goes over on stdin, which pipes through unchanged:

```bash
ledger entry ios progress "Short title" <<'EOF'
Long form goes here.
EOF
```

Subcommands: `read`, `items`, `status <web|ios>`, `entry <side> <kind> "<title>"`,
`ask <by> <for> "<what>"`, `answer <id> "<summary>"`, `escalate <id> "<why>"`,
`close <id> "<note>"`. `status`, `entry` and `answer` take a body on stdin. Run
`ledger --help` for exact arguments rather than guessing them.

The script locks, stamps and commits each write, so two sessions writing at once
cannot lose each other's work — never edit `LEDGER.md` by hand.

**The ledger is shared and live. Never use it as a test fixture** — an `ask` or
`entry` written to try the plumbing shows up as real work on the other side. To
check the wrapper, use `ledger read` or `ledger items`, which write nothing.

## The four rules

**Ask, don't guess.** The TypeScript engine is the oracle, the API owns the
schema, the specs live in `learnr`. Whenever you are unsure how something is
*meant* to work — a grading rule, a figure's geometry, what an endpoint returns,
whether a behaviour is deliberate — `ledger ask ios web "..."`. A wrong guess in
the port is invisible until a digest reddens, and sometimes not even then.

**The learnr side answers.** From the engine, the contract and the specs. A
question that is open-ended — a product call, a priority call, a trade nobody
has made yet — escalates to Muzzamil rather than being invented, and the item
reads **for Muzzamil** until he rules.

**Log what the other side could contradict.** Not every commit —
`ledger entry ios <progress|direction|decision> "..."` for what changes what the
web side may assume.

**Never commit to `learnr`.** Unchanged from before, and it runs the other way
too. That prohibition is the reason this file exists.

## Writing an ask that does not block

Say in the ask what you are doing in the meantime. An ask that blocks nothing
should say so; one that blocks real work should say what is stubbed while it
waits. Then carry on with everything that does not depend on the answer.

Name exact files, endpoints and ids. "The report endpoint" is a guess on the
receiving side; `GET /reports/:childId` is not.

## When to touch each subcommand

| Situation | Call |
| --- | --- |
| Session start, or any question about the server side | `read` |
| Picking up cross-boundary work | `items` |
| This side's "Now" block has stopped being true | `status ios` (body on stdin) |
| Shipped something the web side may assume against | `entry ios progress\|direction\|decision` |
| Unsure how something is meant to work | `ask ios web` |
| An item aimed at iOS is done | `close <id> "<note>"` |

Update only the `ios` "Now" block; never touch `web`'s.

## Common mistakes

- **Answering from the local `learnr` clone.** It is a shipped snapshot. Read
  the ledger first.
- **Guessing a schema or a grading rule** because asking felt slower. The cost
  lands later and silently.
- **Writing to the ledger to test it.** `ask`/`entry` reach the other side.
  Probe with `read` or `items`; close anything raised in error, honestly.
- **Rebuilding the wrapper around `ss`.** That alias exists only in interactive
  zsh; a `bash` wrapper calling it fails. Spell out the `ssh` call.
- **Editing `LEDGER.md` directly over SSH**, bypassing the lock and the commit.
- **Logging every commit.** The log is for what the other side could contradict.
