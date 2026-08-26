/**
 * Generates `speedrun-vectors.json` by running the *real* TypeScript speed-run
 * engine.
 *
 * Fourth in the family, under the same rule as the other three: it imports
 * `src/lib/speedrun/{run,modes,records}.ts` from a `learnr` clone and records
 * what they actually return. Nothing here computes an expected value.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/generate-speedrun-vectors.ts [path-to-learnr] > \
 *       LearnrEngine/Tests/LearnrEngineTests/Vectors/speedrun-vectors.json
 *
 * **Why the specs are recorded rather than transcribed.** `modes.ts` is mostly
 * static data: twenty-six modes and the `QuestionSpec` literals behind them.
 * Hand-copying those into Swift would be a reimplementation wearing a port's
 * clothes — a typo in a bound would produce questions that are wrong in a way
 * no test could see, because the test would be reading the same typo. So
 * `specsFor` is called for every mode and its output recorded verbatim, and the
 * Swift loads these specs rather than declaring its own. What the Swift ports
 * is the *logic*: which specs a mode maps to, and the run state machine.
 *
 * This writes **two** files for that reason. The vectors go to stdout as usual;
 * the specs the engine ships are written directly to
 * `LearnrEngine/Sources/LearnrEngine/Resources/speed-modes.json`, from the same
 * `specsFor` call in the same run. Deriving the shipped copy from the vectors
 * file afterwards would make the engine's data a function of its test corpus,
 * which is backwards — they are two consumers of one oracle, not a chain.
 *
 * **Why a run vector records both slots.** `RunState` carries `current` and
 * `next`, and the screen shows the second dimmed above the first. A run that
 * advanced correctly but drew the wrong lookahead would still show the right
 * question — until the next answer, when the wrong one arrives. Recording both
 * catches it at the step where it happens.
 */

import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { writeFileSync } from 'node:fs';

const learnrPath = resolve(process.argv[2] ?? '../learnr');
const require_ = createRequire(resolve(learnrPath, 'package.json'));

const modesModule = require_('./src/lib/speedrun/modes.ts');
const runModule = require_('./src/lib/speedrun/run.ts');
const recordsModule = require_('./src/lib/speedrun/records.ts');

const {
  MODES,
  DIFFICULTIES,
  OPERATIONS,
  TABLES,
  SINGLE_TABLES,
  TABLE_BUNDLES,
  SPEED_RUN_SUBJECT,
  specsFor,
  modeKey,
  parseMode,
  parseOperation,
  modesFor,
  modeLabel,
  modeHardness,
  isSingleTable,
  operationLabel,
  operationNoun,
  operationGlyph,
} = modesModule;

const {
  SPEED_RUN_MS,
  COUNTDOWN_MS,
  startRun,
  answerRun,
  judgeEntry,
  isOver,
  remainingMs,
  runResult,
  pulseFor,
} = runModule;

const { isRecord, resultTone } = recordsModule;

type Json = ReturnType<typeof JSON.parse>;
const snap = (value: unknown): Json => JSON.parse(JSON.stringify(value ?? null));

// --- modes ------------------------------------------------------------------

/**
 * Every mode, with the specs it draws from and every derived read-out.
 *
 * The specs are the payload: the Swift decodes these and generates from them,
 * so a divergence in a bound is impossible rather than untested.
 */
const modeVectors = MODES.map((mode: Json) => ({
  mode: snap(mode),
  key: modeKey(mode),
  specs: snap(specsFor(mode)),
  label: modeLabel(mode),
  hardness: modeHardness(mode),
  isSingleTable: isSingleTable(mode),
  operationLabel: operationLabel(mode.op),
  operationNoun: operationNoun(mode.op),
  operationGlyph: operationGlyph(mode.op),
}));

/**
 * The specs the engine ships, keyed by mode key.
 *
 * Written from the same `specsFor` calls the vectors above record, so the
 * engine's data and the corpus that checks it are siblings rather than one
 * derived from the other.
 */
writeFileSync(
  resolve(
    import.meta.dirname,
    '../LearnrEngine/Sources/LearnrEngine/Resources/speed-modes.json',
  ),
  `${JSON.stringify(
    Object.fromEntries(MODES.map((mode: Json) => [modeKey(mode), snap(specsFor(mode))])),
    null,
    2,
  )}\n`,
);

/** `parseMode` on every real key and a spread of keys that are not. */
const parseVectors = [
  ...MODES.map((mode: Json) => modeKey(mode)),
  // Retired and never-existed keys, which must come back null rather than being
  // assembled from the parts of the string.
  'multiply.10',
  'multiply.10-12',
  'multiply.1',
  'multiply.13',
  'multiply.all-of-them',
  'add.trivial',
  'add',
  'add.',
  '.easy',
  '',
  'ADD.EASY',
  'add.easy ',
  'divide.Easy',
  '__proto__',
  'constructor',
  'toString',
  'multiply.2-5.extra',
].map((key) => ({ key, mode: snap(parseMode(key)) }));

const operationVectors = [
  ...OPERATIONS,
  'ADD',
  'plus',
  '',
  '__proto__',
  'toString',
].map((op: string) => ({ op, parsed: snap(parseOperation(op)) }));

const modesForVectors = OPERATIONS.map((op: string) => ({
  op,
  keys: modesFor(op).map((mode: Json) => modeKey(mode)),
}));

// --- runs -------------------------------------------------------------------

interface RunStep {
  response: string;
  now: number;
  /** What `judgeEntry` made of it against the question then on screen. */
  verdict: string;
  advanced: boolean;
  state: Json;
}

interface RunVector {
  name: string;
  mode: Json;
  seed: string;
  startedAt: number;
  opening: Json;
  steps: RunStep[];
  result: Json;
}

const runVectors: RunVector[] = [];

/** The parts of a run state a port must reproduce. */
function stateSnapshot(state: Json): Json {
  return {
    draw: state.draw,
    correct: state.correct,
    current: snap(state.current),
    next: snap(state.next),
  };
}

/**
 * Plays a scripted run and records every intermediate state.
 *
 * `script` is a list of (response, now) pairs. A response of `null` means "the
 * right answer", read off the question then on screen — the sequence cannot be
 * predicted without running the engine, so a literal script could not advance a
 * run at all past the first question.
 */
function recordRun(
  name: string,
  mode: Json,
  seed: string,
  startedAt: number,
  script: [string | null, number][],
): void {
  let state = startRun({ mode, seed, startedAt });
  const opening = stateSnapshot(state);
  const steps: RunStep[] = [];

  for (const [scripted, now] of script) {
    const response = scripted ?? String(state.current.answer);
    const verdict = judgeEntry(state, response);
    const before = state.draw;
    state = answerRun(state, response, now);
    steps.push({
      response,
      now,
      verdict,
      advanced: state.draw !== before,
      state: stateSnapshot(state),
    });
  }

  runVectors.push({
    name,
    mode: snap(mode),
    seed,
    startedAt,
    opening,
    steps,
    result: snap(runResult(state)),
  });
}

const T0 = 1_700_000_000_000;

/** Right answers, evenly spaced. */
const rightAnswers = (count: number, step = 2000): [string | null, number][] =>
  new Array(count).fill(null).map((_, i) => [null, T0 + (i + 1) * step]);

// One run per mode, so every spec is generated from and every mode's draw
// sequence is pinned.
for (const mode of MODES) {
  recordRun(`mode:${modeKey(mode)}`, mode, `run:${modeKey(mode)}`, T0, rightAnswers(12));
}

// A mixed mode at length: four specs, picked between by the same rng before
// generating, so this is the only shape where `rng.pick(specs)` runs.
recordRun('mixed at length', { op: 'mixed', difficulty: 'hard' }, 'long', T0, rightAnswers(40, 1500));

// Wrong answers change nothing at all: no draw, no count, no clock.
recordRun('wrong answers do not advance', { op: 'add', difficulty: 'easy' }, 'wrong', T0, [
  ['999999', T0 + 1000],
  ['0', T0 + 2000],
  ['', T0 + 3000],
  ['abc', T0 + 4000],
  [null, T0 + 5000],
  ['-1', T0 + 6000],
  [null, T0 + 7000],
]);

// The clock. An answer on the last millisecond counts; one after does not.
recordRun('an answer exactly on the buzzer', { op: 'add', difficulty: 'easy' }, 'buzzer', T0, [
  [null, T0 + SPEED_RUN_MS - 1],
  [null, T0 + SPEED_RUN_MS],
  [null, T0 + SPEED_RUN_MS + 1],
  [null, T0 + SPEED_RUN_MS + 5000],
]);

// A repeat-avoiding mode: multiply.2 has twelve possible questions, so the
// redraw loop runs often and its draw accounting is what the vectors pin.
recordRun('a small pool redraws', { op: 'multiply', tables: 2 }, 'small', T0, rightAnswers(30, 1000));
recordRun('the smallest pool of all', { op: 'multiply', tables: 2 }, 'tiny', T0, rightAnswers(60, 500));

// Answering at the same instant repeatedly - a child hammering the pad.
recordRun('answers at the same millisecond', { op: 'add', difficulty: 'easy' }, 'hammer', T0, [
  [null, T0], [null, T0], [null, T0], [null, T0], [null, T0],
]);

// --- judging ----------------------------------------------------------------

/**
 * `judgeEntry` character by character, which is how a speed run grades: there
 * is no Check key, so an entry is judged as it is typed.
 */
interface JudgeVector {
  name: string;
  mode: Json;
  seed: string;
  answer: string;
  entries: { entry: string; verdict: string }[];
}

const judgeVectors: JudgeVector[] = [];

function recordJudge(name: string, mode: Json, seed: string): void {
  const state = startRun({ mode, seed, startedAt: T0 });
  const answer = String(state.current.answer);

  // Every prefix of the answer, the answer itself, the answer with something
  // after it, and a few entries that cannot become it.
  const entries = [
    '',
    ...answer.split('').map((_, i) => answer.slice(0, i + 1)),
    `${answer}0`,
    `${answer}9`,
    `0${answer}`,
    '9',
    'x',
    ' ',
    `${answer} `,
  ];

  judgeVectors.push({
    name,
    mode: snap(mode),
    seed,
    answer,
    entries: entries.map((entry) => ({ entry, verdict: judgeEntry(state, entry) })),
  });
}

recordJudge('judging an addition answer', { op: 'add', difficulty: 'moderate' }, 'judge-add');
recordJudge('judging a multiplication answer', { op: 'multiply', tables: 7 }, 'judge-mul');
recordJudge('judging a division answer', { op: 'divide', difficulty: 'hard' }, 'judge-div');
recordJudge('judging a subtraction answer', { op: 'subtract', difficulty: 'easy' }, 'judge-sub');

// --- the clock --------------------------------------------------------------

const clockVectors = [
  0, 1, 1000, 5000, 5001, 15_000, 15_001, 30_000, 30_001, 45_000,
  SPEED_RUN_MS - 1, SPEED_RUN_MS, SPEED_RUN_MS + 1, SPEED_RUN_MS + 60_000,
].map((elapsed) => {
  const state = startRun({ mode: { op: 'add', difficulty: 'easy' }, seed: 'clock', startedAt: T0 });
  const now = T0 + elapsed;
  const remaining = remainingMs(state, now);
  return { elapsed, now, remaining, isOver: isOver(state, now), pulse: pulseFor(remaining) };
});

/** `pulseFor` on its own, at and either side of every threshold. */
const pulseVectors = [
  -1, 0, 1, 4999, 5000, 5001, 14_999, 15_000, 15_001,
  29_999, 30_000, 30_001, 60_000, 90_000,
].map((remaining) => ({ remaining, pulse: pulseFor(remaining) }));

// --- records ----------------------------------------------------------------

const recordVectors: Json[] = [];
for (const previousBest of [null, 0, 1, 5, 10]) {
  for (const score of [0, 1, 5, 10, 11]) {
    recordVectors.push({
      previousBest,
      score,
      isRecord: isRecord(previousBest, score),
      tone: resultTone(previousBest, score),
    });
  }
}

// --- output -----------------------------------------------------------------

process.stdout.write(
  `${JSON.stringify(
    {
      modes: modeVectors,
      parse: parseVectors,
      operations: operationVectors,
      modesFor: modesForVectors,
      runs: runVectors,
      judge: judgeVectors,
      clock: clockVectors,
      pulses: pulseVectors,
      records: recordVectors,
      constants: {
        SPEED_RUN_MS,
        COUNTDOWN_MS,
        SPEED_RUN_SUBJECT,
        DIFFICULTIES,
        OPERATIONS,
        TABLES,
        SINGLE_TABLES,
        TABLE_BUNDLES,
        MODE_COUNT: MODES.length,
      },
    },
    null,
    2,
  )}\n`,
);
