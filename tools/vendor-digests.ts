/**
 * Vendors `fixtures/digests/` and `src/content/packs/` from `learnr` into this
 * repository.
 *
 * The digests are the oracle for the Swift engine: `learnr` generates them by
 * running its own TypeScript, and this port has to compute the same twelve hex
 * characters from its own output. They are vendored rather than read live so
 * that `swift test` needs neither the network nor a checkout of the other
 * repository — the same reason the vectors beside them are committed.
 *
 * The content packs come too. A digest hashes what the engine makes of a
 * *template*, and the templates are not otherwise in this repo: the app fetches
 * them from `GET /content/:subject/:level` at runtime. They are taken from
 * `src/content/packs/`, the artifact that ships, so the port cannot end up
 * agreeing with a set of templates nobody runs.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/vendor-digests.ts              # from GitHub, the default
 *     npx tsx tools/vendor-digests.ts ../learnr    # from a local clone
 *
 * **GitHub is the default because there is usually no clone here.** `learnr` is
 * worked on from `tesseract` and is public, so `raw.githubusercontent.com`
 * reaches both trees without auth — which the fixture-generation design names
 * as the intended route. A local path is still accepted, and is what to use
 * when checking a change that has not been pushed yet.
 *
 * **Refreshing is its own commit that does nothing else, and says why.** The
 * digests define what "correct" means, so a change to them is a change to the
 * contract and has to be reviewable on its own. `learnr`'s own rule is the same
 * one from the other side: regenerating must not become the reflex fix for a
 * red build, or the suite stops meaning anything. When a digest moves, the
 * question to answer first is which engine moved and whether it was meant to —
 * and the ledger is where that question gets asked.
 *
 * This script copies bytes. It must never compute a digest of its own — a
 * vendoring step that recomputed anything would launder a divergence into
 * agreement, which is the one failure this whole mechanism exists to prevent.
 */

import { copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const RAW = 'https://raw.githubusercontent.com/muzzamilkhan/learnr/master';

const source = process.argv[2];
const digestDir = resolve('LearnrEngine/Tests/LearnrEngineTests/Digests');
const packDir = resolve('LearnrEngine/Tests/LearnrEngineTests/Packs');

/**
 * The files to fetch, when there is no clone to list.
 *
 * `manifest.json` names every digest set, and each content pack is one
 * `subject.level`, so the manifest is enough to derive both lists — no second
 * place to keep in step.
 */
async function fetchJSON(path: string): Promise<string> {
  const response = await fetch(`${RAW}/${path}`);
  if (!response.ok) throw new Error(`${path}: ${response.status} ${response.statusText}`);
  return response.text();
}

async function vendorFromGitHub(): Promise<{ digests: number; packs: number; version: string }> {
  const manifestText = await fetchJSON('fixtures/digests/manifest.json');
  const manifest = JSON.parse(manifestText) as {
    version: string;
    sets: { set: string }[];
  };

  rmSync(digestDir, { recursive: true, force: true });
  mkdirSync(digestDir, { recursive: true });
  writeFileSync(resolve(digestDir, 'manifest.json'), manifestText);

  // A corpus set is `subject.level`; `expr`, `grading` and `profile` are not,
  // and have no pack behind them.
  const corpusSets = manifest.sets.map((s) => s.set).filter((s) => s.includes('.'));

  for (const set of manifest.sets) {
    writeFileSync(
      resolve(digestDir, `${set.set}.json`),
      await fetchJSON(`fixtures/digests/${set.set}.json`),
    );
  }

  rmSync(packDir, { recursive: true, force: true });
  mkdirSync(packDir, { recursive: true });
  for (const set of corpusSets) {
    writeFileSync(resolve(packDir, `${set}.json`), await fetchJSON(`src/content/packs/${set}.json`));
  }
  // The packs' own manifest, which no test reads — it is what the app fetches
  // from `GET /content/manifest` at runtime. Copied so the vendored directory
  // is the pack tree as it ships rather than the subset the digests happen to
  // need, which is the shape a clone would give.
  writeFileSync(
    resolve(packDir, 'manifest.json'),
    await fetchJSON('src/content/packs/manifest.json'),
  );

  return { digests: manifest.sets.length + 1, packs: corpusSets.length, version: manifest.version };
}

function vendorFromClone(path: string): { digests: number; packs: number; version: string } {
  const digestSource = resolve(path, 'fixtures/digests');
  const packSource = resolve(path, 'src/content/packs');

  let names: string[];
  try {
    names = readdirSync(digestSource).filter((name) => name.endsWith('.json'));
  } catch {
    console.error(
      `No digests at ${digestSource}.\n` +
        `Pass the path to a learnr clone, and run \`npm run fixtures:build\` there first.`,
    );
    process.exit(1);
  }

  if (!names.includes('manifest.json')) {
    console.error(`${digestSource} has no manifest.json, so there is nothing to check the copy against.`);
    process.exit(1);
  }

  // Removed rather than overwritten, so a set deleted upstream does not linger
  // here as a file nothing regenerates and every test still passes against.
  rmSync(digestDir, { recursive: true, force: true });
  mkdirSync(digestDir, { recursive: true });
  for (const name of names) copyFileSync(resolve(digestSource, name), resolve(digestDir, name));

  let packNames: string[];
  try {
    packNames = readdirSync(packSource).filter((name) => name.endsWith('.json'));
  } catch {
    console.error(`No content packs at ${packSource}. Run \`npm run content:build\` there first.`);
    process.exit(1);
  }

  rmSync(packDir, { recursive: true, force: true });
  mkdirSync(packDir, { recursive: true });
  for (const name of packNames) copyFileSync(resolve(packSource, name), resolve(packDir, name));

  const manifest = JSON.parse(readFileSync(resolve(digestDir, 'manifest.json'), 'utf8'));
  return { digests: names.length, packs: packNames.length, version: manifest.version };
}

// Wrapped rather than top-level `await`: tsx transforms this to CJS, where a
// top-level await is a build error rather than a runtime one.
async function main(): Promise<void> {
  const result = source ? vendorFromClone(source) : await vendorFromGitHub();

  console.log(
    `Vendored ${result.digests} digests and ${result.packs} content packs ` +
      `from ${source ?? RAW}, at manifest version ${result.version}.`,
  );
  console.log('Commit this on its own, and say why the digests moved.');
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
