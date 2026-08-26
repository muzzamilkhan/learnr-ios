# LearnR iOS

The native child client for LearnR, and the Swift port of its question engine.

Children only: a parent uses the web app. The only way in is the four-character
code a parent hands over, so this app has no Google sign-in and needs no Sign in
with Apple.

## Why the engine is ported rather than served

Play works offline. That means questions are generated on the device, which
means the engine exists twice - once in TypeScript for the web, once here. The
two are kept in step by fixtures generated from the TypeScript engine, which is
the oracle: it defines what correct means, and this port is verified against it.

See `learnr/docs/superpowers/specs/2026-08-26-ios-port-design.md`.

## Layout

```
LearnrEngine/          Swift package - the ported engine
  Sources/LearnrEngine/
    Rng/               mulberry32 + FNV-1a, bit-exact with the web app
    Expr/              the sandboxed expression language
    Api/               generated from contract/openapi.yaml
  Tests/
    Vectors/           oracle data generated from the TypeScript engine
```

## Verification

Every vector under `Tests/LearnrEngineTests/Vectors/` was produced by running
the real TypeScript source under `tsx`, never by reimplementing it in the
generator. That is what makes it an oracle rather than a second opinion.

Regenerate after an intentional engine change, in a commit that does nothing
else and says why:

```bash
cd ../learnr && npx tsx scripts/vectors.mts   # not yet written; see build order
```

## Layout, as built

```
LearnrEngine/          Swift package, 36 tests
  Sources/LearnrEngine/
    Rng/               mulberry32 + FNV-1a
    Expr/              tokenizer, Pratt parser, evaluator, JS number semantics
    Api/               models, client, offline sync queue
LearnrApp/             SwiftUI app - no Xcode project yet, see below
```

## Status

**Done and verified:** the RNG, the JavaScript number semantics, the whole
expression language, the API client, and the offline sync queue.

**Not started:** template generation, the eleven figure builders, the session
and speed-run state machines. Those need the content pack, which is build-order
step 2 and has not happened - so the app cannot generate a question yet, and
`HomeView` says so rather than offering a button that cannot work.

**No Xcode project yet.** `LearnrApp/` holds the sources and they compile
against the package, but the `.xcodeproj` still needs creating - File > New >
Project, then add `LearnrEngine` as a local package dependency.

## The traps this port had to reproduce

Four places where a reasonable Swift implementation silently diverges from the
JavaScript the content was authored against:

| | JavaScript | Swift's default |
| --- | --- | --- |
| `round(-2.5)` | `-2` | `-3` |
| `String(2.0)` | `"2"` | `"2.0"` |
| `-2 ^ 2` | `-4` | - |
| `1 && 2` | `true` | - |

The first two change what a child sees or scores, and **no test in the web app
covers a negative half** - nothing there would have caught a wrong port. That is
the argument for the oracle vectors, demonstrated rather than asserted.

## Known gaps on the server side

Thirteen of the API's 28 endpoints declare an untyped success response
(`schema: {}`), including `/me`, `/speed/runs`, `/speed/records` and
`/play/state`, so several of this app's models are transcribed by hand rather
than generated. Tracked as [muzzamilkhan/learnr#4]; when it is fixed those
models should be regenerated and the hand-written ones deleted.

## The server

The API lives in `muzzamilkhan/learnr` as the `apps/api` workspace - not in a
repository of its own, because it depends on `@learnr/core` and a `file:` path
dependency cannot resolve across two clones.

- Contract: `learnr/apps/api/contract/openapi.yaml`, regenerated with
  `npm run contract --workspace apps/api`
- Deployed: `https://learnr-api-syd.fly.dev`

`AppConfig.apiBaseURL` defaults to `http://localhost:3001` for the simulator
against a local server. A build on a device needs the deployed URL set in
Info.plist as `LearnrAPIBaseURL`, and it must be the `https` one - App Transport
Security refuses plain HTTP, so the localhost default cannot work off-simulator.
