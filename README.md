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

See `learnr-api/docs/superpowers/specs/2026-08-26-ios-port-design.md`.

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

## Status

Early. The RNG and the JavaScript number semantics are ported and verified. The
expression language, template generation, figures and the session state machine
are not yet.

Content extraction and full fixture generation - build-order steps 2 and 3 -
have not happened, so nothing here can generate a real question yet.
