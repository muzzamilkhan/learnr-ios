/**
 * Generates `generate-vectors.json` by running the *real* TypeScript engine.
 *
 * This script imports `src/lib/templates/generate.ts` from a `learnr` clone and
 * records what it actually produces. It must never reimplement any part of that
 * module: a generator that computes its own expected answers would only prove
 * the Swift agrees with this file, which is not the property the vectors exist
 * to establish. Everything below is either a *spec* (an input) or a value that
 * came straight back from `generate()`.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/generate-vectors.ts [path-to-learnr] > \
 *       LearnrEngine/Tests/LearnrEngineTests/Vectors/generate-vectors.json
 *
 * The default path is `../learnr`, which is where the sibling clone lives.
 *
 * Regenerating is its own commit that does nothing else, and says why - the
 * vectors are the oracle, so a change to them is a change to what "correct"
 * means and has to be reviewable on its own.
 *
 * **Figures are deliberately out of scope.** `figure` is a separate module
 * (`src/lib/figures`, eleven shape kinds) and is its own port with its own
 * vectors. Every spec here is figure-free, so these vectors say nothing about
 * figures and cannot quietly appear to.
 */

import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const learnrPath = resolve(process.argv[2] ?? '../learnr');
const require_ = createRequire(resolve(learnrPath, 'package.json'));

// Loaded from the sibling clone at runtime rather than imported by path, so
// this file is valid TypeScript in a repo that has no copy of the engine.
const { generate } = require_('./src/lib/templates/generate.ts');
const { createRng } = require_('./src/lib/rng.ts');
const { PACKS } = require_('./src/content/packs/index.ts');

type Json = ReturnType<typeof JSON.parse>;

/**
 * A spec, and what the TypeScript made of it under a named seed.
 *
 * `spec` and `seed` are the inputs the Swift replays; every other field is
 * transcribed from the returned object without inspection.
 */
interface Vector {
  name: string;
  seed: string;
  spec: Json;
  question: Json;
}

const vectors: Vector[] = [];

/** Run the real `generate` and record the result verbatim. */
function record(name: string, seed: string, spec: Json): void {
  const question = generate(spec, createRng(seed), name);
  vectors.push({ name, seed, spec, question: JSON.parse(JSON.stringify(question)) });
}

/**
 * Specs written to exercise one mechanism each.
 *
 * These are hand-written rather than drawn from the packs because the shipped
 * content does not use every feature: `jitter` appears in no template at all,
 * and `weights`, `step` and `decimals` appear in three, thirty-one and five
 * respectively. A port verified only against shipped content would leave those
 * paths unmeasured until the first template to use one reached a child.
 */
const cases: [string, string, Json][] = [
  // --- int, the overwhelmingly common case (979 of 1883 shipped vars) ---
  ['int.basic', 'seed', {
    prompt: 'What is {x} + {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '1', max: '10' },
      { name: 'y', kind: 'int', min: '1', max: '10' },
    ],
    answer: 'x + y',
  }],
  // Bounds are expressions over earlier variables - the whole point of the
  // design, and the reason `min`/`max` are strings on the wire.
  ['int.dependent-bounds', 'dep', {
    prompt: 'What is {x} - {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '10', max: '20' },
      { name: 'y', kind: 'int', min: '1', max: 'x - 1' },
    ],
    answer: 'x - y',
  }],
  // `ceil` on min and `floor` on max, which is where a fractional bound lands.
  ['int.fractional-bounds', 'frac', {
    prompt: 'Pick from {x}.',
    vars: [{ name: 'x', kind: 'int', min: '1.2', max: '9.8' }],
    answer: 'x',
  }],
  // A fractional range that `ceil`/`floor` narrows: `ceil(1.6)` is 2 and
  // `floor(3.4)` is 3, so only [2, 3] is drawable, where the swapped rounding
  // gives [1, 4] and twice as many outcomes. Narrow ranges like this are what
  // tell the two roundings apart - over a wide range the swap merely widens
  // the draw and a given seed often lands in the same place regardless.
  ['int.fractional-narrow', 'fracnarrow', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '1.6', max: '3.4' }],
    answer: 'x',
  }],
  // The tightest surviving case: correct rounding leaves exactly one value, so
  // the answer is fixed at 3. The swapped rounding opens it to [2, 4] and the
  // question stops being deterministic at all.
  ['int.fractional-single', 'fracone', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '2.4', max: '3.6' }],
    answer: 'x',
  }],
  // Bounds that are computed rather than literal - the shape future content
  // will hit, since no shipped template divides inside a bound today.
  ['int.computed-fractional-bounds', 'fraccomp', {
    prompt: 'What is {x}?',
    vars: [
      { name: 'n', kind: 'int', min: '7', max: '7' },
      { name: 'x', kind: 'int', min: 'n / 2', max: 'n * 1.5' },
    ],
    answer: 'x',
  }],
  ['int.step', 'step', {
    prompt: 'Count by fives to {x}.',
    vars: [{ name: 'x', kind: 'int', min: '0', max: '100', step: 5 }],
    answer: 'x',
  }],
  // A step that does not divide the range evenly: `floor((max-min)/step)`
  // decides the top of the draw, so the maximum is not always reachable.
  ['int.step-uneven', 'stepodd', {
    prompt: 'Count by sevens to {x}.',
    vars: [{ name: 'x', kind: 'int', min: '3', max: '50', step: 7 }],
    answer: 'x',
  }],
  // `step: 1` must behave as no step at all: the guard is `step > 1`, and a
  // `step >= 1` would take the stepped branch, which spends its `int()` draw
  // on a *different* range - `[0, max-min]` rather than `[min, max]` - and so
  // shifts every value drawn afterwards.
  ['int.step-one', 'stepone', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '5', max: '25', step: 1 }],
    answer: 'x',
  }],
  ['int.negative-range', 'neg', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '-20', max: '-5' }],
    answer: 'abs(x)',
  }],
  ['int.single-value', 'one', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '7', max: '7' }],
    answer: 'x',
  }],

  // --- number: rounding to `decimals`, default 2 ---
  ['number.default-decimals', 'dec', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '0', max: '10' }],
    answer: 'x',
  }],
  ['number.explicit-decimals', 'dec1', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '0', max: '1', decimals: 1 }],
    answer: 'x',
  }],
  // decimals: 0 is not the same as `int` - it rounds a uniform draw rather
  // than drawing uniformly over integers, so the endpoints are half as likely.
  ['number.zero-decimals', 'dec0', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '0', max: '5', decimals: 0 }],
    answer: 'x',
  }],
  // Where JS rounding shows: `Math.round` breaks ties toward +Infinity, so a
  // negative .5 goes the opposite way from Swift's `rounded()`.
  ['number.negative', 'decneg', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '-5', max: '-0.5', decimals: 1 }],
    answer: 'x',
  }],
  // A *forced* tie, because a random draw never lands on one: with min == max
  // the draw is exactly -2.5 whatever the RNG returns, so `decimals: 0` has to
  // break the tie, and the two languages break it in opposite directions.
  // Without these four, `Math.round` and Swift's `rounded()` are
  // indistinguishable over every other vector in this file - which is to say
  // the trap would be undefended.
  ['number.tie-negative', 'tieneg', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '-2.5', max: '-2.5', decimals: 0 }],
    answer: 'x',
  }],
  ['number.tie-positive', 'tiepos', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '2.5', max: '2.5', decimals: 0 }],
    answer: 'x',
  }],
  ['number.tie-negative-half', 'tieneghalf', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '-0.5', max: '-0.5', decimals: 0 }],
    answer: 'x',
  }],
  // A tie one decimal place in, so the factor multiply is part of it.
  ['number.tie-decimals', 'tiedec', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'number', min: '-0.25', max: '-0.25', decimals: 1 }],
    answer: 'x',
  }],

  // --- pick, weighted and not ---
  ['pick.strings', 'pk', {
    prompt: 'Is a {x} an animal?',
    vars: [{ name: 'x', kind: 'pick', from: ['cat', 'dog', 'rock', 'tree'] }],
    answer: 'x == "cat" || x == "dog"',
  }],
  ['pick.numbers', 'pknum', {
    prompt: 'What is {x} doubled?',
    vars: [{ name: 'x', kind: 'pick', from: [2, 4, 8, 16] }],
    answer: 'x * 2',
  }],
  // Weighted picking consumes `next()` directly rather than `int()`, so it
  // advances the RNG differently - which is exactly the kind of divergence
  // that would silently reshuffle every later draw.
  ['pick.weighted', 'pkw', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'pick', from: ['a', 'b', 'c'], weights: [1, 1, 8] }],
    answer: 'x',
  }],
  ['pick.weighted-skewed', 'pkw2', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'pick', from: ['rare', 'common'], weights: [0.01, 99.99] }],
    answer: 'x',
  }],
  // A zero weight is the boundary the `roll <= 0` comparison sits on: with the
  // first weight 0, `roll` starts positive and the first subtraction leaves it
  // unchanged, so `<= 0` and `< 0` pick different values the moment `roll`
  // lands exactly on a cumulative edge. A value weighted 0 must never be
  // picked, which is the property worth pinning.
  ['pick.weighted-zero', 'pkwzero', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'pick', from: ['never', 'always'], weights: [0, 1] }],
    answer: 'x',
  }],
  // Several draws off one seed, so the walk lands at different points in the
  // cumulative sum rather than testing a single position.
  ['pick.weighted-repeated', 'pkwrep', {
    prompt: '{a}{b}{c}{d}',
    vars: [
      { name: 'a', kind: 'pick', from: ['x', 'y', 'z'], weights: [1, 2, 3] },
      { name: 'b', kind: 'pick', from: ['x', 'y', 'z'], weights: [1, 2, 3] },
      { name: 'c', kind: 'pick', from: ['x', 'y', 'z'], weights: [1, 2, 3] },
      { name: 'd', kind: 'pick', from: ['x', 'y', 'z'], weights: [1, 2, 3] },
    ],
    answer: 'a + b + c + d',
  }],

  // --- expr: derived, never random ---
  ['expr.derived', 'der', {
    prompt: 'What is {a} x {b}?',
    vars: [
      { name: 'a', kind: 'int', min: '2', max: '9' },
      { name: 'b', kind: 'int', min: '2', max: '9' },
      { name: 'product', kind: 'expr', expr: 'a * b' },
    ],
    answer: 'product',
  }],
  ['expr.string', 'derstr', {
    prompt: 'Say {greeting}.',
    vars: [
      { name: 'who', kind: 'pick', from: ['world', 'friend'] },
      { name: 'greeting', kind: 'expr', expr: '"hello " + who' },
    ],
    answer: 'greeting',
  }],

  // --- constraints, including a redraw-heavy one ---
  ['constraints.divides', 'div', {
    prompt: 'What is {x} divided by {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '10', max: '100' },
      { name: 'y', kind: 'int', min: '2', max: '9' },
    ],
    constraints: ['mod(x, y) == 0'],
    answer: 'x / y',
  }],
  // Several constraints at once, each rejecting the whole binding: the retry
  // loop runs up to 200 times and every rejected attempt still burns draws.
  ['constraints.multiple', 'multi', {
    prompt: 'What is {x} + {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '1', max: '50' },
      { name: 'y', kind: 'int', min: '1', max: '50' },
    ],
    constraints: ['x > y', 'mod(x, 2) == 0', 'x + y < 60'],
    answer: 'x + y',
  }],

  // --- choices: dedup, ordering, and the Fisher-Yates shuffle ---
  ['choices.distractors', 'ch', {
    prompt: 'What is {x} + {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '2', max: '9' },
      { name: 'y', kind: 'int', min: '2', max: '9' },
    ],
    answer: 'x + y',
    answerType: 'choice',
    choices: { count: 4, distractors: ['x + y + 1', 'x + y - 1', 'x * y'] },
  }],
  // Distractors that collide with the answer and with each other are dropped,
  // and the shortfall is made up from jitter - the path no shipped template
  // takes today, which is precisely why it needs a vector.
  ['choices.jitter-topup', 'jit', {
    prompt: 'What is {x} + {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '5', max: '15' },
      { name: 'y', kind: 'int', min: '5', max: '15' },
    ],
    answer: 'x + y',
    answerType: 'choice',
    choices: { count: 4, distractors: ['x + y'], jitter: { min: '1', max: '10' } },
  }],
  ['choices.jitter-only', 'jitonly', {
    prompt: 'What is {x} x {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '3', max: '9' },
      { name: 'y', kind: 'int', min: '3', max: '9' },
    ],
    answer: 'x * y',
    answerType: 'choice',
    choices: { count: 4, jitter: { min: '1', max: '12' } },
  }],
  ['choices.text', 'chtext', {
    prompt: 'Which word rhymes with {x}?',
    vars: [{ name: 'x', kind: 'pick', from: ['cat', 'dog'] }],
    answer: 'x == "cat" ? "hat" : "log"',
    answerType: 'choice',
    choices: { count: 3, distractors: ['"tree"', '"house"', '"car"'] },
  }],
  // `count` above MAX_CHOICES is clamped rather than rejected, because this
  // runs with a child waiting.
  ['choices.clamped', 'chclamp', {
    prompt: 'What is {x} + 1?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '20' }],
    answer: 'x + 1',
    answerType: 'choice',
    choices: { count: 9, distractors: ['x', 'x + 2', 'x + 3', 'x + 4', 'x + 5', 'x + 6'] },
  }],

  // A distractor that evaluates to a boolean is dropped rather than offered:
  // `true` and `false` are not options beside a numeric answer. No shipped
  // template writes one, so without this the drop is unverified - and a port
  // that kept them would show a child a button reading "true".
  ['choices.boolean-distractor-dropped', 'chbool', {
    prompt: 'What is {x} + 1?',
    vars: [{ name: 'x', kind: 'int', min: '5', max: '15' }],
    answer: 'x + 1',
    answerType: 'choice',
    choices: {
      count: 4,
      // The two boolean distractors are skipped, so the three numeric ones
      // after them are what fill the list - which is only true if the skip
      // does not also consume a slot.
      distractors: ['x > 0', 'x < 0', 'x', 'x + 2', 'x + 3'],
    },
  }],

  // --- boolean: overrides any declared answerType, and drops choices ---
  ['boolean.answer', 'bool', {
    prompt: 'Is {x} even?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '100' }],
    answer: 'mod(x, 2) == 0',
  }],
  // A boolean answer with `choices` declared: the choices are dropped and the
  // type is forced to boolean whatever the spec said.
  ['boolean.overrides-choices', 'boolch', {
    prompt: 'Is {x} greater than {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '1', max: '50' },
      { name: 'y', kind: 'int', min: '1', max: '50' },
    ],
    answer: 'x > y',
    answerType: 'choice',
    choices: { count: 4, distractors: ['1', '2', '3'] },
  }],
  // The same override against each of the other declared types, so the
  // precedence is pinned rather than sampled: a boolean answer is a boolean
  // question no matter what the spec claims. Testing only `choice` leaves the
  // ordering of the `isBoolean` check against `spec.answerType` undetermined.
  ['boolean.overrides-number', 'boolnum', {
    prompt: 'Is {x} even?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '40' }],
    answer: 'mod(x, 2) == 0',
    answerType: 'number',
  }],
  ['boolean.overrides-text', 'booltext', {
    prompt: 'Is {x} more than ten?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '40' }],
    answer: 'x > 10',
    answerType: 'text',
  }],

  // --- prompt and hint rendering ---
  // `{...}` holes take arbitrary expressions, not just variable names, and
  // stringify through JS's `String()` - where 2.0 renders as "2".
  ['render.expression-holes', 'rend', {
    prompt: 'What is {x} + {y}? (that is {x + y} in all)',
    vars: [
      { name: 'x', kind: 'int', min: '1', max: '9' },
      { name: 'y', kind: 'int', min: '1', max: '9' },
    ],
    answer: 'x + y',
    hint: 'Start at {x} and count on {y}.',
  }],
  ['render.whole-number-float', 'rendfloat', {
    prompt: 'What is {x / 2}?',
    vars: [{ name: 'x', kind: 'int', min: '2', max: '2' }],
    answer: 'x / 2',
    hint: 'It is {x / 2}, not {x / 2.0}.',
  }],
  ['render.string-value', 'rendstr', {
    prompt: 'The {colour} one.',
    vars: [{ name: 'colour', kind: 'pick', from: ['red', 'blue'] }],
    answer: 'colour',
    answerType: 'text',
  }],

  // --- answerType defaulting ---
  ['answertype.default-number', 'atn', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '9' }],
    answer: 'x',
  }],
  ['answertype.default-text', 'att', {
    prompt: 'What is {x}?',
    vars: [{ name: 'x', kind: 'pick', from: ['alpha', 'beta'] }],
    answer: 'x',
  }],
];

for (const [name, seed, spec] of cases) record(name, seed, spec);

/**
 * Every figure-free shipped template, drawn three times.
 *
 * The hand-written cases above cover the mechanisms; these cover the content a
 * child will actually be asked. Three seeds per template is enough to catch a
 * divergence that only shows on some bindings - a constraint that redraws, a
 * distractor that collides - without making the file enormous.
 *
 * Sorted by id so the output is stable across runs: `PACKS` order is fixed
 * today, but a vector file that reshuffles on regeneration hides real changes
 * in the diff.
 */
const shipped = (PACKS as Json[])
  .flatMap((pack) => pack.templates as Json[])
  .filter((template) => !template.figure)
  .sort((a, b) => String(a.id).localeCompare(String(b.id)));

for (const template of shipped) {
  for (let draw = 0; draw < 3; draw++) {
    record(`shipped:${template.id}#${draw}`, `${template.id}:${draw}`, template);
  }
}

process.stdout.write(`${JSON.stringify(vectors, null, 2)}\n`);
