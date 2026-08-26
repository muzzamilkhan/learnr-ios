/**
 * Generates `figure-vectors.json` by running the *real* TypeScript figure
 * builders.
 *
 * Companion to `generate-vectors.ts`, and under the same rule: it imports
 * `src/lib/figures/build.ts` from a `learnr` clone and records what it actually
 * draws. It never computes a coordinate of its own — a generator that worked
 * out where a vertex ought to be would only prove the Swift agrees with this
 * file, which is not the property the vectors exist to establish.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/generate-figure-vectors.ts [path-to-learnr] > \
 *       LearnrEngine/Tests/LearnrEngineTests/Vectors/figure-vectors.json
 *
 * **Why a figure vector carries a scope.** A figure is built from the bound
 * variables, not from the template — `{ kind: 'angle', degrees: 'd' }` draws
 * nothing without a `d`. So each vector records the scope the spec was
 * evaluated against, and the Swift replays the spec against that same scope
 * rather than re-running generation to get one. That keeps a figure vector
 * independent of `generate.ts`: a divergence here is a figure divergence, and
 * cannot be a binding divergence wearing its clothes.
 *
 * Coordinates are comparable as written. `build.ts` rounds every one to
 * `FIGURE_PRECISION` places and normalises `-0` to `0` on the way out, for
 * exactly this reason — two figures that are the same drawing are the same
 * string — so the Swift is held to equality, not to a tolerance.
 */

import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const learnrPath = resolve(process.argv[2] ?? '../learnr');
const require_ = createRequire(resolve(learnrPath, 'package.json'));

const { buildFigure } = require_('./src/lib/figures/build.ts');
const { createRng } = require_('./src/lib/rng.ts');
const { PACKS } = require_('./src/content/packs/index.ts');
const { generate } = require_('./src/lib/templates/generate.ts');

type Json = ReturnType<typeof JSON.parse>;

interface Vector {
  name: string;
  seed: string;
  spec: Json;
  scope: Json;
  figure: Json;
}

const vectors: Vector[] = [];

/** Run the real `buildFigure` and record the drawing verbatim. */
function record(name: string, seed: string, spec: Json, scope: Json = {}): void {
  const figure = buildFigure(spec, scope, createRng(seed));
  vectors.push({ name, seed, spec, scope, figure: JSON.parse(JSON.stringify(figure)) });
}

/**
 * Hand-written cases, one mechanism at a time.
 *
 * The shipped sweep below covers what children actually see; these cover what
 * the shipped content never asks for. That gap is wide here — a template pins
 * the property its question is about and leaves the rest to jitter, so most
 * optional fields are *never* pinned in shipped content, and a port could get
 * every pinned path wrong without a single shipped template noticing.
 *
 * Both readings of every optional field are worth a case: omitted (which asks
 * for jitter) and pinned (which does not). They are different code paths, and
 * the jittered one additionally spends `Rng` draws that shift everything after.
 */
const cases: [string, string, Json, Json?][] = [
  // --- the frame itself: fit, bounds, the y flip, the -0 sweep ---
  // A square is the cleanest read on `fit`: uniform scale, centred, and the
  // padding left clear on all four sides.
  ['frame.square', 'sq', { kind: 'polygon', shape: "'square'" }],
  // A wide shape scales on its larger span, so the short axis is centred with
  // slack rather than stretched — a separate x and y scale would turn every
  // square into a rectangle, which is what the uniform scale exists to refuse.
  ['frame.wide-rectangle', 'rect', { kind: 'polygon', shape: "'rectangle'" }],
  // An arc is bounded by its whole circle, not its sweep, so a figure with one
  // fits differently from its visible extent.
  ['frame.arc-bounds', 'arcb', { kind: 'angle', degrees: '90' }],

  // --- polygon: every shape name in the vocabulary ---
  ...([
    'equilateral', 'isosceles', 'scalene', 'right-triangle', 'square',
    'rectangle', 'rhombus', 'parallelogram', 'trapezium', 'kite',
    'pentagon', 'hexagon', 'heptagon', 'octagon',
  ].map((shape): [string, string, Json] => [
    `polygon.shape.${shape}`,
    `poly-${shape}`,
    { kind: 'polygon', shape: `'${shape}'` },
  ])),
  // A pinned rotation, which the anchoring check refuses on a regular polygon
  // but which the *builder* must still honour exactly when asked.
  ['polygon.pinned-rotation', 'polyrot', { kind: 'polygon', shape: "'square'", rotation: '30' }],
  ['polygon.rotation-zero', 'polyrot0', { kind: 'polygon', shape: "'pentagon'", rotation: '0' }],
  // Negative and past a full turn: the builder normalises rather than refusing.
  ['polygon.rotation-negative', 'polyrotneg', { kind: 'polygon', shape: "'square'", rotation: '-45' }],
  ['polygon.rotation-over-turn', 'polyrotbig', { kind: 'polygon', shape: "'square'", rotation: '405' }],
  ['polygon.mirror-true', 'polymirt', { kind: 'polygon', shape: "'isosceles'", mirror: 'true' }],
  ['polygon.mirror-false', 'polymirf', { kind: 'polygon', shape: "'isosceles'", mirror: 'false' }],
  ['polygon.right-angles', 'polyra', { kind: 'polygon', shape: "'right-triangle'", rightAngles: 'true' }],
  ['polygon.right-angles-square', 'polyrasq', { kind: 'polygon', shape: "'square'", rightAngles: 'true' }],
  // An unknown shape name falls back to an equilateral triangle rather than
  // throwing — "something drawable" is the contract mid-session.
  ['polygon.unknown-shape', 'polyunk', { kind: 'polygon', shape: "'dodecahedron'" }],
  // An unbound variable reads as absent, and jitters, exactly like omission.
  ['polygon.unbound-shape', 'polyunb', { kind: 'polygon', shape: 'nosuchvar' }],

  // --- angle ---
  ['angle.acute', 'ang45', { kind: 'angle', degrees: '45' }],
  ['angle.right', 'ang90', { kind: 'angle', degrees: '90' }],
  ['angle.obtuse', 'ang135', { kind: 'angle', degrees: '135' }],
  ['angle.straight', 'ang180', { kind: 'angle', degrees: '180' }],
  ['angle.reflex', 'ang270', { kind: 'angle', degrees: '270' }],
  // Clamped into 1–359 rather than refused.
  ['angle.clamped-low', 'angclo', { kind: 'angle', degrees: '0' }],
  ['angle.clamped-high', 'angchi', { kind: 'angle', degrees: '360' }],
  ['angle.clamped-negative', 'angcneg', { kind: 'angle', degrees: '-30' }],
  ['angle.pinned-rotation', 'angrot', { kind: 'angle', degrees: '60', rotation: '20' }],
  // A *negative* arc angle, which is the one coordinate in a figure that can be
  // negative at all: `fit` clamps every point into [0, box] before rounding,
  // but an arc's `from`/`to` are rounded as written. It takes a pinned negative
  // rotation to produce one, so no shipped template does.
  ['angle.negative-rotation', 'angnegrot', { kind: 'angle', degrees: '90', rotation: '-30' }],
  // The same, landing on an exact rounding tie. This is the only place in the
  // whole figure module where JavaScript's round-half-toward-+Infinity and
  // Swift's round-half-away-from-zero can disagree, so without it the two are
  // indistinguishable across all 509 vectors: the oracle gives 0 here, and
  // Swift's native rounding would give -0.01.
  ['angle.negative-rotation-tie', 'angnegtie', { kind: 'angle', degrees: '90', rotation: '-0.005' }],
  ['angle.negative-rotation-tie-2', 'angnegtie2', { kind: 'angle', degrees: '45', rotation: '-2.125' }],
  // Pinned arm length makes both arms match; omitted, they are jittered
  // *separately*, which is deliberate and spends different draws.
  ['angle.pinned-arms', 'angarm', { kind: 'angle', degrees: '60', armLength: '40' }],
  ['angle.no-arc', 'angnoarc', { kind: 'angle', degrees: '60', arc: 'false' }],
  ['angle.arc-true', 'angarc', { kind: 'angle', degrees: '60', arc: 'true' }],

  // --- bar ---
  ['bar.basic', 'bar1', { kind: 'bar', values: "'3,7,5,2'" }],
  ['bar.labelled', 'bar2', { kind: 'bar', values: "'3,7,5'", labels: "'red,blue,green'" }],
  ['bar.style-column', 'barcol', { kind: 'bar', values: "'4,8,6'", style: "'column'" }],
  ['bar.style-dot', 'bardot', { kind: 'bar', values: "'4,8,6'", style: "'dot'" }],
  ['bar.style-line', 'barline', { kind: 'bar', values: "'4,8,6'", style: "'line'" }],
  ['bar.scale-pinned', 'barsc', { kind: 'bar', values: "'10,20,30'", scale: '10' }],
  ['bar.single-value', 'bar1v', { kind: 'bar', values: "'5'" }],
  ['bar.zero-value', 'bar0', { kind: 'bar', values: "'0,4,2'" }],
  // Values that are multiples of some ladder scales and not others, so the
  // preference for a scale every value lands on is a real choice rather than a
  // filter that happens to keep everything. Without one of these, dropping the
  // preference entirely changes no drawing.
  ['bar.exact-scale-preferred', 'barex', { kind: 'bar', values: "'10,20,30,40'" }],
  ['bar.inexact-values', 'barinex', { kind: 'bar', values: "'3,7,11,13'" }],
  ['bar.multiples-of-five', 'bar5s', { kind: 'bar', values: "'5,15,25'" }],
  // The discriminating pair for the exact-scale preference. Values every
  // ladder step divides look the same either way; `2,4,6` is exact only at a
  // scale of 2, and `6,12,18` at 2 and 5 but not 10 - so dropping the
  // preference changes which axis is drawn. Several draws each, since the
  // choice is a pick among whatever survives the filter.
  ...([0, 1, 2, 3].map((n): [string, string, Json] => [
    `bar.exact-forces-two#${n}`, `barex2-${n}`, { kind: 'bar', values: "'2,4,6'" },
  ])),
  ...([0, 1, 2, 3].map((n): [string, string, Json] => [
    `bar.exact-narrows#${n}`, `barexn-${n}`, { kind: 'bar', values: "'6,12,18'" },
  ])),

  // --- pictograph ---
  ['pictograph.basic', 'pic1', { kind: 'pictograph', counts: "'3,7,5'" }],
  ['pictograph.labelled', 'pic2', { kind: 'pictograph', counts: "'2,4'", labels: "'cats,dogs'" }],
  ['pictograph.key-pinned', 'pickey', { kind: 'pictograph', counts: "'10,20'", key: '10' }],
  ['pictograph.halves', 'pichalf', { kind: 'pictograph', counts: "'5,15'", key: '10', halves: 'true' }],
  ['pictograph.no-halves', 'picnohalf', { kind: 'pictograph', counts: "'10,20'", key: '10', halves: 'false' }],

  // --- spinner ---
  ['spinner.equal', 'spin1', { kind: 'spinner', sectors: "'1,1,1,1'" }],
  ['spinner.unequal', 'spin2', { kind: 'spinner', sectors: "'1,1,2'" }],
  ['spinner.fills', 'spinf', { kind: 'spinner', sectors: "'1,1,2'", fills: "'red,blue,red'" }],
  ['spinner.rotation', 'spinr', { kind: 'spinner', sectors: "'1,2,3'", rotation: '45' }],
  ['spinner.two-sectors', 'spin2s', { kind: 'spinner', sectors: "'1,3'" }],

  // --- solid: every name, and both views ---
  ...([
    'cube', 'cuboid', 'sphere', 'cone', 'cylinder', 'square-pyramid', 'triangular-prism',
  ].flatMap((solid): [string, string, Json][] => [
    [`solid.${solid}.object`, `sol-${solid}-o`, { kind: 'solid', solid: `'${solid}'`, view: "'object'" }],
    [`solid.${solid}.jittered-view`, `sol-${solid}-j`, { kind: 'solid', solid: `'${solid}'` }],
  ])),
  // A sphere cannot be unfolded: a pinned 'net' is an authoring mistake, and
  // the builder still has to draw *something*.
  ['solid.sphere-net-refused', 'solsphn', { kind: 'solid', solid: "'sphere'", view: "'net'" }],
  ...([
    'cube', 'cuboid', 'cone', 'cylinder', 'square-pyramid', 'triangular-prism',
  ].map((solid): [string, string, Json] => [
    `solid.${solid}.net`,
    `sol-${solid}-n`,
    { kind: 'solid', solid: `'${solid}'`, view: "'net'" },
  ])),
  // A pinned rotation deliberately does *not* fix a solid's orientation.
  ['solid.pinned-rotation', 'solrot', { kind: 'solid', solid: "'cube'", view: "'object'", rotation: '30' }],

  // --- number-line ---
  ['numberline.pinned-range', 'nl1', { kind: 'number-line', at: '5', from: '0', to: '10' }],
  ['numberline.picked-range', 'nl2', { kind: 'number-line', at: '7' }],
  ['numberline.step-pinned', 'nlstep', { kind: 'number-line', at: '20', from: '0', to: '100', step: '20' }],
  ['numberline.minor-ticks-true', 'nlmt', { kind: 'number-line', at: '3', from: '0', to: '10', minorTicks: 'true' }],
  ['numberline.minor-ticks-false', 'nlmf', { kind: 'number-line', at: '3', from: '0', to: '10', minorTicks: 'false' }],
  // A decimal needs tenths, so exactly one round line carries it — the one
  // documented case where the range does not vary.
  ['numberline.decimal', 'nldec', { kind: 'number-line', at: '1.1' }],
  ['numberline.negative-range', 'nlneg', { kind: 'number-line', at: '-5', from: '-10', to: '0' }],
  // Values the span grid can frame only one way, which is what `shiftedStart`
  // exists for: measured, 36 of the integers 0-100 had exactly one line before
  // it, and a child answering 11 saw the same picture every seed. Without
  // these the half-span offset is unreachable - only two number-line vectors
  // leave both ends open at all, and neither happens to shift.
  ['numberline.shifted-11', 'nl11', { kind: 'number-line', at: '11' }],
  ['numberline.shifted-13', 'nl13', { kind: 'number-line', at: '13' }],
  ['numberline.shifted-17', 'nl17', { kind: 'number-line', at: '17' }],
  ['numberline.shifted-23', 'nl23', { kind: 'number-line', at: '23' }],
  ['numberline.unshifted-7', 'nl7', { kind: 'number-line', at: '7' }],
  // The roundness guard itself: half of a span of 5 is 2.5, so a shift there
  // would grow a decimal on an endpoint and is refused rather than drawn. An
  // `at` under 10 is where the 5-wide span is in play, so these are the values
  // that tell a working guard from one that always says yes.
  ['numberline.roundness-3', 'nlr3', { kind: 'number-line', at: '3' }],
  ['numberline.roundness-4', 'nlr4', { kind: 'number-line', at: '4' }],
  ['numberline.roundness-6', 'nlr6', { kind: 'number-line', at: '6' }],
  ['numberline.roundness-8', 'nlr8', { kind: 'number-line', at: '8' }],
  ['numberline.roundness-9', 'nlr9', { kind: 'number-line', at: '9' }],
  // The arrow between two ticks: honoured when the range is pinned, because
  // estimating is a real question to ask.
  ['numberline.between-ticks', 'nlbet', { kind: 'number-line', at: '2.5', from: '0', to: '10', step: '5' }],

  // --- clock ---
  ['clock.oclock', 'clk1', { kind: 'clock', hour: '3', minute: '0' }],
  ['clock.half-past', 'clk2', { kind: 'clock', hour: '7', minute: '30' }],
  ['clock.quarter-past', 'clk3', { kind: 'clock', hour: '9', minute: '15' }],
  ['clock.quarter-to', 'clk4', { kind: 'clock', hour: '11', minute: '45' }],
  ['clock.twelve', 'clk12', { kind: 'clock', hour: '12', minute: '0' }],
  ['clock.numerals-true', 'clknt', { kind: 'clock', hour: '4', minute: '20', numerals: 'true' }],
  ['clock.numerals-false', 'clknf', { kind: 'clock', hour: '4', minute: '20', numerals: 'false' }],
  ['clock.minute-ticks-true', 'clkmt', { kind: 'clock', hour: '4', minute: '20', minuteTicks: 'true' }],
  ['clock.minute-ticks-false', 'clkmf', { kind: 'clock', hour: '4', minute: '20', minuteTicks: 'false' }],
  // The densest figure that ships: sixty minute ticks before a hand is drawn.
  ['clock.full-face', 'clkfull', { kind: 'clock', hour: '10', minute: '55', numerals: 'true', minuteTicks: 'true' }],

  // --- array ---
  ['array.rows', 'arr1', { kind: 'array', rows: '3', columns: '4', orientation: "'rows'" }],
  ['array.columns', 'arr2', { kind: 'array', rows: '3', columns: '4', orientation: "'columns'" }],
  ['array.jittered-orientation', 'arr3', { kind: 'array', rows: '2', columns: '5' }],
  ['array.square', 'arrsq', { kind: 'array', rows: '4', columns: '4', orientation: "'rows'" }],

  // --- fraction-shape ---
  ['fraction.circle', 'fr1', { kind: 'fraction-shape', numerator: '1', denominator: '4', shape: "'circle'" }],
  ['fraction.rectangle', 'fr2', { kind: 'fraction-shape', numerator: '3', denominator: '8', shape: "'rectangle'" }],
  ['fraction.strip', 'fr3', { kind: 'fraction-shape', numerator: '2', denominator: '5', shape: "'strip'" }],
  ['fraction.jittered-shape', 'fr4', { kind: 'fraction-shape', numerator: '1', denominator: '2' }],
  // Never simplified: 2/4 is drawn as quarters, not as a half.
  ['fraction.unsimplified', 'fr5', { kind: 'fraction-shape', numerator: '2', denominator: '4', shape: "'circle'" }],
  ['fraction.whole', 'fr6', { kind: 'fraction-shape', numerator: '4', denominator: '4', shape: "'circle'" }],
  ['fraction.zero', 'fr0', { kind: 'fraction-shape', numerator: '0', denominator: '3', shape: "'circle'" }],
  ['fraction.circle-rotation', 'frrot', { kind: 'fraction-shape', numerator: '1', denominator: '3', shape: "'circle'", rotation: '90' }],

  // --- grid ---
  ['grid.cell-numbers', 'gr1', { kind: 'grid', at: "'2,3'", columns: '5', rows: '5', axisLabels: "'numbers'" }],
  ['grid.cell-letters', 'gr2', { kind: 'grid', at: "'2,3'", columns: '5', rows: '5', axisLabels: "'letters'" }],
  ['grid.no-labels', 'gr3', { kind: 'grid', at: "'2,3'", columns: '5', rows: '5', axisLabels: "'none'" }],
  ['grid.on-lines', 'gr4', { kind: 'grid', at: "'2,3'", columns: '5', rows: '5', onLines: 'true', axisLabels: "'numbers'" }],
  ['grid.origin-on-lines', 'gr5', { kind: 'grid', at: "'0,0'", columns: '4', rows: '4', onLines: 'true', axisLabels: "'numbers'" }],
  ['grid.picked-extent', 'gr6', { kind: 'grid', at: "'2,3'" }],
  ['grid.rectangular', 'gr7', { kind: 'grid', at: "'3,1'", columns: '6', rows: '3', axisLabels: "'numbers'" }],
  // Past Z, where a column name wraps to two letters. No shipped grid is wider
  // than six columns, so the base-26 wrap is otherwise never drawn - and it is
  // the one place a column could silently share a name with another.
  ['grid.past-z', 'grz', { kind: 'grid', at: "'27,2'", columns: '30', rows: '2', axisLabels: "'letters'" }],
  ['grid.at-z-boundary', 'grz2', { kind: 'grid', at: "'26,1'", columns: '27', rows: '2', axisLabels: "'letters'" }],

  // --- degradation: a figure must always come back drawable ---
  // These are the paths that run when content is wrong, and they are the ones
  // no shipped template exercises by definition.
  ['degrade.unknown-kind', 'degunk', { kind: 'trapezoid-prism', shape: "'square'" }],
  ['degrade.missing-required', 'degmiss', { kind: 'angle' }],
  ['degrade.unbound-everywhere', 'degunb', { kind: 'clock', hour: 'h', minute: 'm' }],
  // NaN is a number to `typeof` and fails every comparison: the builder throws
  // it away and jitters, which is the documented trap in `fields.ts`.
  ['degrade.nan-field', 'degnan', { kind: 'angle', degrees: '0 / 0' }],
  ['degrade.infinite-field', 'deginf', { kind: 'angle', degrees: '1 / 0' }],
  ['degrade.wrong-type', 'degwt', { kind: 'angle', degrees: "'ninety'" }],
  ['degrade.malformed-expression', 'degmal', { kind: 'angle', degrees: '((' }],
  ['degrade.empty-list', 'degempty', { kind: 'bar', values: "''" }],

  // --- fields read from a bound scope, which is how real templates write them ---
  ['scope.angle-from-var', 'scang', { kind: 'angle', degrees: 'd' }, { d: 135 }],
  ['scope.polygon-from-var', 'scpoly', { kind: 'polygon', shape: 'shape' }, { shape: 'hexagon' }],
  ['scope.computed-field', 'sccomp', { kind: 'angle', degrees: 'a * 2' }, { a: 40 }],
  ['scope.clock-from-vars', 'scclk', { kind: 'clock', hour: 'h', minute: 'm' }, { h: 8, m: 25 }],
];

for (const [name, seed, spec, scope] of cases) record(name, seed, spec, scope ?? {});

/**
 * Every shipped figure template, drawn three times.
 *
 * The scope comes from running the real `generate()` on the template, so the
 * figure is built against exactly the variables a child's question would have
 * bound. `generate` returns the figure it built too, but this deliberately
 * rebuilds from `buildFigure` on a *fresh* `Rng`: the vector is then about the
 * figure builder alone, and does not silently depend on how many draws the
 * binding before it happened to spend.
 *
 * Sorted by id so the file is stable across runs.
 */
const shipped = (PACKS as Json[])
  .flatMap((pack) => pack.templates as Json[])
  .filter((template) => template.figure)
  .sort((a, b) => String(a.id).localeCompare(String(b.id)));

for (const template of shipped) {
  for (let draw = 0; draw < 3; draw++) {
    const seed = `${template.id}:${draw}`;
    let bound: Json;
    try {
      bound = generate(template, createRng(seed), template.id).vars;
    } catch {
      // A template whose constraints could not be satisfied under this seed has
      // no scope to draw against, so there is no figure to record. Skipped
      // rather than recorded empty, which would assert a drawing nobody asked
      // for.
      continue;
    }
    record(`shipped:${template.id}#${draw}`, `${seed}:figure`, template.figure, bound);
  }
}

process.stdout.write(`${JSON.stringify(vectors, null, 2)}\n`);
