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

See `learnr/docs/superpowers/specs/2026-08-26-ios-port-design.md`, whose
conformance-suite section is superseded by
`2026-08-26-fixture-generation-design.md` in the same directory.

## Layout

```
LearnrEngine/          Swift package - the ported engine
  Sources/LearnrEngine/
    Rng/               mulberry32 + FNV-1a, bit-exact with the web app
    Expr/              tokenizer, Pratt parser, evaluator, JS number semantics
    Templates/         binding, constraints, {expr} holes
    Figures/           all twelve builders
    Session/           the state machine, grading, the profile and the selector
    SpeedRun/          the second state machine, and the modes
    Api/               models, client, offline sync queue
    Contract/          the vendored openapi.yaml - wire types generate from it
  Tests/LearnrEngineTests/
    Digests/           the vendored golden corpus - the oracle
    Vectors/           the older per-case oracle data
    Packs/             the content packs the digests cover
LearnrApp/             SwiftUI app - code entry, keychain, play, speed run
  LearnrAppTests/
```

## Verification

The oracle is the TypeScript engine in `learnr`. Every fixture here was produced
by running that source, never by reimplementing it in the generator - that is
what makes it an oracle rather than a second opinion.

Verification is against the vendored digests under
`Tests/LearnrEngineTests/Digests/`, which supersede the older per-case vectors:
each set hashes a canonical form of the engine's output template by template, so
a divergence names the template it diverged on.

```bash
cd LearnrEngine && swift test
```

**Status: green.** The corpus, grading, expression, figure and profile sets all
reproduce the oracle. The profile divergence this section used to describe was
`L9`, and it is answered and fixed.

Regenerate fixtures only after an intentional engine change, in a commit that
does nothing else and says why.

## Building

The Xcode project is **generated**, not committed - a `.pbxproj` is unreviewable
in a diff and conflicts on every merge. `project.yml` is the reviewable half.

```bash
brew install xcodegen     # once
xcodegen                  # writes LearnrApp.xcodeproj
open LearnrApp.xcodeproj
```

**Once per machine**, before the first build: Xcode will not run a SwiftPM build
plugin until it has been trusted, and the engine uses one to generate the wire
types from the contract. In Xcode that is a dialog; a command-line build cannot
answer it and fails with `Validate plug-in "OpenAPIGenerator"` instead. Trust it
for good with

```bash
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
```

or pass `-skipPackagePluginValidation` to a one-off `xcodebuild`. `swift build`
and `swift test` need neither - the prompt is Xcode's alone.

Or from the command line:

```bash
xcodebuild -project LearnrApp.xcodeproj -scheme LearnrApp \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
cd LearnrEngine && swift test
```

Universal, iOS 17+, portrait only - a rotation mid-question moves every target
under the child's hand. Verified building and running on both iPad and iPhone
simulators.

### Which API a build talks to

`LEARNR_API_BASE_URL` in `project.yml` becomes `LearnrAPIBaseURL` in Info.plist,
which is what `AppConfig` reads. `project.yml` sets it to the deployed API, so
that is what a normal build talks to. To point a build at a local server:

```bash
xcodebuild ... LEARNR_API_BASE_URL='http:/$()/localhost:3001'
```

The `$()` is not a typo: a bare `//` starts a comment in a build setting, so the
scheme has to be written that way to survive substitution. Check what actually
shipped rather than trusting the setting - an unset value expands to nothing and
the key is dropped from the plist entirely:

```bash
plutil -p "$(xcrun simctl get_app_container booted com.learnr.ios)/Info.plist" | grep -i learnrapi
```

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

## The API models

The contract is complete - 32 paths, and the four endpoints this app depends on
that once declared `schema: {}` (`/me`, `/play/state`, `/speed/runs`,
`/speed/records`) all carry real schemas now. `learnr#4` is closed.

**The wire types are generated from it**, by `swift-openapi-generator` running as
a build plugin over `Sources/LearnrEngine/Contract/openapi.yaml` - a vendored
copy of `apps/api/contract/openapi.yaml`, verified byte-identical to the served
document. Nothing generated is committed, so the types cannot drift from the
contract; `Package.resolved` pins the generator so a rebuild cannot change what
they are. Types only - `ApiClient` is hand-written on purpose, because the rules
it encodes (a 503 is retryable and a 400 is not, a 304 is a success) are this
app's and are not in the document.

The models in `Api/Models.swift` are **still transcribed by hand**, and are still
what the call sites use. Six properties are nullable `$ref`s that the contract
encodes as `allOf: [{$ref}]` while also listing them in `required`, which makes
the generator emit them non-optional so they throw on a null - and two of the six
(`PlayerState.target`, `SpeedOutcome.standing`) are null on the ordinary path.
The web side has ruled the fix and it is ledger item `L24`; deleting the models
is one regeneration once it ships, which is the rest of `L1`.

## The server

The API lives in `muzzamilkhan/learnr` as the `apps/api` workspace - not in a
repository of its own, because it depends on `@learnr/core` and a `file:` path
dependency cannot resolve across two clones.

- Contract: `learnr/apps/api/contract/openapi.yaml`, regenerated with
  `npm run contract --workspace apps/api`, and served by the deployed API at
  `/openapi.json` - which is how to read it from this Mac, there being no
  `learnr` clone here
- Deployed: `https://learnr-api-syd.fly.dev`

`AppConfig.apiBaseURL` is `url(from:) ?? http://localhost:3001`. The localhost
half is a **fallback for when the plist key is missing or unsubstituted**, not
what a configured build uses: `project.yml` ships
`https://learnr-api-syd.fly.dev`, so a normal build talks to the deployed API.

The fallback is the thing to watch on a device. An unset or empty
`LEARNR_API_BASE_URL` expands to nothing, the key is dropped from the plist, and
the app quietly falls back to localhost - where App Transport Security refuses
plain HTTP and the failure arrives with nothing to read. Check what actually
shipped rather than trusting the setting.
