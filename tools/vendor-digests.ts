/**
 * Copies `fixtures/digests/` from a `learnr` clone into this repository.
 *
 * The digests are the oracle for the Swift engine: `learnr` generates them by
 * running its own TypeScript, and this port has to compute the same twelve hex
 * characters from its own output. They are vendored rather than read from a
 * sibling clone or fetched at test time so that `swift test` needs neither the
 * network nor a checkout of the other repository — the same reason the vectors
 * beside them are committed.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/vendor-digests.ts [path-to-learnr]
 *
 * The default path is `../learnr`, which is where the sibling clone lives.
 *
 * **Refreshing is its own commit that does nothing else, and says why.** The
 * digests define what "correct" means, so a change to them is a change to the
 * contract and has to be reviewable on its own. `learnr`'s own rule is the same
 * one from the other side: regenerating must not become the reflex fix for a
 * red build, or the suite stops meaning anything. When a digest moves, the
 * question to answer first is which engine moved and whether it was meant to.
 *
 * This script copies bytes. It must never compute a digest of its own — a
 * vendoring step that recomputed anything would launder a divergence into
 * agreement, which is the one failure this whole mechanism exists to prevent.
 */

import { copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';

const learnrPath = resolve(process.argv[2] ?? '../learnr');
const source = resolve(learnrPath, 'fixtures/digests');
const destination = resolve('LearnrEngine/Tests/LearnrEngineTests/Digests');

/**
 * The content packs come too, because a digest is a hash of what the engine
 * makes of a *template* and the templates are not otherwise in this repository:
 * the app fetches them from `GET /content/:subject/:level` at runtime. The
 * digest tests need the same 505 the oracle hashed, and they need them offline.
 *
 * They are copied from `src/content/packs/`, which is the artifact that ships —
 * the same files the API serves and the same ones `corpusSets` reads. Taking
 * them from anywhere else would let the port agree with a set of templates
 * nobody runs.
 */
const packSource = resolve(learnrPath, 'src/content/packs');
const packDestination = resolve('LearnrEngine/Tests/LearnrEngineTests/Packs');

let names: string[];
try {
  names = readdirSync(source).filter((name) => name.endsWith('.json'));
} catch {
  console.error(
    `No digests at ${source}.\n` +
      `Pass the path to a learnr clone, and run \`npm run fixtures:build\` there first.`,
  );
  process.exit(1);
}

if (!names.includes('manifest.json')) {
  console.error(`${source} has no manifest.json, so there is nothing to check the copy against.`);
  process.exit(1);
}

// Removed rather than overwritten, so a set deleted upstream does not linger
// here as a file nothing regenerates and every test still passes against.
rmSync(destination, { recursive: true, force: true });
mkdirSync(destination, { recursive: true });

for (const name of names) copyFileSync(resolve(source, name), resolve(destination, name));

let packNames: string[];
try {
  packNames = readdirSync(packSource).filter((name) => name.endsWith('.json'));
} catch {
  console.error(`No content packs at ${packSource}. Run \`npm run content:build\` there first.`);
  process.exit(1);
}

rmSync(packDestination, { recursive: true, force: true });
mkdirSync(packDestination, { recursive: true });
for (const name of packNames) {
  copyFileSync(resolve(packSource, name), resolve(packDestination, name));
}

const manifest = JSON.parse(readFileSync(resolve(destination, 'manifest.json'), 'utf8'));
console.log(`Vendored ${names.length} digests at manifest version ${manifest.version}.`);
console.log(`Vendored ${packNames.length} content packs.`);
console.log(`Commit this on its own, and say why the digests moved.`);
