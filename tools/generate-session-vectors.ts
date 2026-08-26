/**
 * Generates `session-vectors.json` by running the *real* TypeScript session
 * engine.
 *
 * Third in the same family as `generate-vectors.ts` and
 * `generate-figure-vectors.ts`, and under the same rule: it imports
 * `src/lib/session/`, `src/lib/analytics/profile.ts`, `src/lib/reinforcement/`
 * and `src/lib/day.ts` from a `learnr` clone and records what they actually
 * return. It never computes an expected value of its own — a generator that
 * worked out what a strength ought to be would only prove the Swift agrees with
 * this file, which is not the property the vectors exist to establish.
 *
 * Run it from the repository root:
 *
 *     npx tsx tools/generate-session-vectors.ts [path-to-learnr] > \
 *       LearnrEngine/Tests/LearnrEngineTests/Vectors/session-vectors.json
 *
 * **Why a session vector carries a starting profile.** `session.ts` says it
 * outright: "the seed alone no longer fixes the sequence — a replay needs the
 * profile the session started from as well". Which template is drawn is the
 * reinforcement selector's call, and the selector reads the profile. So a
 * session vector records the profile it opened against and the exact script of
 * responses, and the Swift replays that script. A seed-only vector would pin
 * the first question and nothing after it.
 *
 * **Why the selector gets vectors of its own.** `weightTemplates` accumulates
 * floating-point weights and `selectTemplate` walks them with `roll -= weight`
 * until it goes negative. That is order-dependent twice over: the walk order,
 * and the per-topic template counts that form each divisor. Recording the
 * weights themselves — not just which template came back — is what turns a
 * wrong-template failure into a diagnosable one, and pins the arithmetic rather
 * than the one branch of it a draw happened to land in.
 */

import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const learnrPath = resolve(process.argv[2] ?? '../learnr');
const require_ = createRequire(resolve(learnrPath, 'package.json'));

// Loaded from the sibling clone at runtime rather than imported by path, so
// this file is valid TypeScript in a repo that has no copy of the engine.
const { createRng } = require_('./src/lib/rng.ts');
const { localDay, parseOffsetMinutes } = require_('./src/lib/day.ts');
const profileModule = require_('./src/lib/analytics/profile.ts');
const selectModule = require_('./src/lib/reinforcement/select.ts');
const { gradeAnswer } = require_('./src/lib/session/grade.ts');
const answersModule = require_('./src/lib/session/answers.ts');
const sessionModule = require_('./src/lib/session/session.ts');

const {
  emptyProfile,
  applyObservation,
  buildProfile,
  nextSkill,
  findSkill,
  skillStatus,
  hasPattern,
  recentTopics,
  reviewIntervalMs,
  reviewDueAt,
  accuracy,
  averageTimeMs,
} = profileModule;

const { weightTemplates, selectTemplate, focusTopics } = selectModule;
const { answerMode, answerOptions, formatAnswer, appendNumeric } = answersModule;
const { startSession, submitAnswer, elapsedMs, formatDuration } = sessionModule;

type Json = ReturnType<typeof JSON.parse>;

/** Deep-copies through JSON so a recorded value cannot alias engine state. */
const snap = (value: unknown): Json => JSON.parse(JSON.stringify(value ?? null));

// --- the template pool ------------------------------------------------------

/**
 * A pool with the shape the selector cares about: several topics, and an
 * uneven number of templates per topic.
 *
 * The unevenness is the point. `templatesPerTopic` divides a topic's weight by
 * how many templates carry it, and that divisor is the whole defence against
 * template count outvoting status. A pool of one template per topic would
 * exercise the division with every divisor equal to 1 — which is to say, not at
 * all.
 */
const POOL: Json = [
  {
    id: 'add-1',
    subject: 'maths',
    topic: 'addition',
    level: 'K',
    prompt: 'What is {x} + {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '1', max: '9' },
      { name: 'y', kind: 'int', min: '1', max: '9' },
    ],
    answer: 'x + y',
  },
  {
    id: 'add-2',
    subject: 'maths',
    topic: 'addition',
    level: 'K',
    prompt: 'Add {x} and {y}.',
    vars: [
      { name: 'x', kind: 'int', min: '2', max: '8' },
      { name: 'y', kind: 'int', min: '2', max: '8' },
    ],
    answer: 'x + y',
  },
  {
    id: 'add-3',
    subject: 'maths',
    topic: 'addition',
    level: 'K',
    prompt: '{x} plus {y} equals what?',
    vars: [
      { name: 'x', kind: 'int', min: '3', max: '7' },
      { name: 'y', kind: 'int', min: '1', max: '5' },
    ],
    answer: 'x + y',
  },
  {
    id: 'sub-1',
    subject: 'maths',
    topic: 'subtraction',
    level: 'K',
    prompt: 'What is the difference between {x} and {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '5', max: '10' },
      { name: 'y', kind: 'int', min: '1', max: '4' },
    ],
    answer: 'x - y',
  },
  {
    id: 'mul-1',
    subject: 'maths',
    topic: 'multiplication',
    level: 'K',
    prompt: 'What is {x} times {y}?',
    vars: [
      { name: 'x', kind: 'int', min: '2', max: '6' },
      { name: 'y', kind: 'int', min: '2', max: '6' },
    ],
    answer: 'x * y',
  },
  {
    id: 'mul-2',
    subject: 'maths',
    topic: 'multiplication',
    level: 'K',
    prompt: 'Multiply {x} by {y}.',
    vars: [
      { name: 'x', kind: 'int', min: '2', max: '5' },
      { name: 'y', kind: 'int', min: '2', max: '5' },
    ],
    answer: 'x * y',
  },
  {
    id: 'count-1',
    subject: 'maths',
    topic: 'counting',
    level: 'K',
    prompt: 'What comes after {x}?',
    vars: [{ name: 'x', kind: 'int', min: '1', max: '19' }],
    answer: 'x + 1',
  },
];

/** A tap-answered pool member, so `answerMode` and `answerOptions` see choices. */
const CHOICE_TEMPLATE: Json = {
  id: 'shape-1',
  subject: 'maths',
  topic: 'shapes',
  level: '1',
  prompt: 'How many sides does a {name} have?',
  vars: [{ name: 'name', kind: 'pick', from: ['triangle', 'square'] }],
  answer: "name == 'triangle' ? 3 : 4",
  choices: ['3', '4', '5'],
};

const BOOLEAN_TEMPLATE: Json = {
  id: 'even-1',
  subject: 'maths',
  topic: 'odd-and-even',
  level: '1',
  prompt: 'Is {x} even?',
  vars: [{ name: 'x', kind: 'int', min: '1', max: '20' }],
  answer: 'x % 2 == 0',
  answerType: 'boolean',
};

const TEXT_TEMPLATE: Json = {
  id: 'word-1',
  subject: 'english',
  topic: 'spelling',
  level: '1',
  prompt: 'Spell the word for {x}.',
  vars: [{ name: 'x', kind: 'pick', from: ['one', 'two'] }],
  answer: 'x',
  answerType: 'text',
};

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const T0 = 1_700_000_000_000;

// --- day --------------------------------------------------------------------

interface DayVector {
  name: string;
  at: number;
  offsetMinutes: Json;
  day: number;
}

const dayVectors: DayVector[] = [];

function recordDay(name: string, at: number, offsetMinutes?: number): void {
  const day =
    offsetMinutes === undefined ? localDay(at) : localDay(at, offsetMinutes);
  dayVectors.push({ name, at, offsetMinutes: offsetMinutes ?? null, day });
}

// The boundary either side, and the negative-time floor: `localDay` is a
// `Math.floor` on a division, and floor of a negative is the trap that has
// already bitten this port twice in `round`.
recordDay('epoch', 0);
recordDay('epoch minus a millisecond', -1);
recordDay('epoch minus a day', -DAY);
recordDay('just before a day boundary', DAY - 1);
recordDay('exactly a day boundary', DAY);
recordDay('sydney evening is that evening', T0, 600);
recordDay('utc default is the same as zero', T0);
recordDay('utc explicit zero', T0, 0);
recordDay('west of utc rolls back', T0, -480);
recordDay('offset pushes over a boundary', DAY - 60_000, 600);
recordDay('offset pulls under a boundary', DAY + 60_000, -600);
recordDay('the widest real offset east', T0, 14 * 60);
recordDay('the widest real offset west', T0, -14 * 60);

interface OffsetVector {
  name: string;
  value: Json;
  parsed: Json;
}

const offsetVectors: OffsetVector[] = [];

function recordOffset(name: string, value: unknown): void {
  offsetVectors.push({ name, value: snap(value), parsed: snap(parseOffsetMinutes(value)) });
}

// The boundary normaliser refuses what would poison a stored day number.
recordOffset('zero', 0);
recordOffset('sydney', 600);
recordOffset('the eastern limit', 840);
recordOffset('the western limit', -840);
recordOffset('one past the eastern limit', 841);
recordOffset('one past the western limit', -841);
recordOffset('absurd', 100_000);
recordOffset('fractional', 60.5);
recordOffset('not a number', 'x');
recordOffset('null', null);

// --- profile ----------------------------------------------------------------

interface Observation {
  topic: string;
  level: string;
  correct: boolean;
  timeTakenMs: number;
  answeredAt: number;
  offsetMinutes?: number;
  templateId?: string;
}

interface ProfileVector {
  name: string;
  observations: Json;
  /** The folded profile, verbatim from `buildProfile`. */
  profile: Json;
  /** `hasPattern` on the result — what gates the selector into weighting at all. */
  hasPattern: boolean;
  /** Every skill's status at each of several clocks, since status is time-dependent. */
  statuses: Json;
  /** Derived read-outs, recorded so a port cannot get the fold right and these wrong. */
  derived: Json;
  recentTopics: Json;
}

const profileVectors: ProfileVector[] = [];

/**
 * The clocks each profile's statuses are read at. A status is a function of
 * `now`, and `secure` versus `review-due` is decided purely by how far past
 * `reviewDueAt` the clock has gone — so a single reading would pin the fold and
 * leave the interval ramp untested.
 */
const CLOCK_OFFSETS = [0, DAY, 3 * DAY, 6 * DAY, 13 * DAY, 29 * DAY];

function recordProfile(name: string, observations: Observation[]): void {
  const profile = buildProfile(observations);
  const last = observations.length
    ? Math.max(...observations.map((o) => o.answeredAt))
    : T0;

  const statuses = CLOCK_OFFSETS.map((offset) => ({
    now: last + offset,
    skills: profile.skills.map((skill: Json) => ({
      topic: skill.topic,
      level: skill.level,
      status: skillStatus(skill, last + offset),
    })),
  }));

  const derived = profile.skills.map((skill: Json) => ({
    topic: skill.topic,
    level: skill.level,
    accuracy: accuracy(skill),
    averageTimeMs: averageTimeMs(skill),
    reviewIntervalMs: reviewIntervalMs(skill),
    reviewDueAt: reviewDueAt(skill),
  }));

  profileVectors.push({
    name,
    observations: snap(observations),
    profile: snap(profile),
    hasPattern: hasPattern(profile),
    statuses: snap(statuses),
    derived: snap(derived),
    recentTopics: snap(recentTopics(observations, 3)),
  });
}

/** A run of answers on one topic, one every ten minutes from `startAt`. */
function run(
  topic: string,
  results: boolean[],
  startAt: number,
  level = 'K',
  offsetMinutes?: number,
): Observation[] {
  return results.map((correct, index) => ({
    topic,
    level,
    correct,
    timeTakenMs: 3000 + index * 250,
    answeredAt: startAt + index * 10 * 60_000,
    ...(offsetMinutes === undefined ? {} : { offsetMinutes }),
  }));
}

recordProfile('nothing answered', []);
recordProfile('one right answer', run('addition', [true], T0));
recordProfile('one wrong answer', run('addition', [false], T0));

// Under MIN_OBSERVATIONS a topic is never called weak, however it went.
recordProfile('three wrong is still new', run('addition', [false, false, false], T0));
recordProfile('four wrong is struggling', run('addition', [false, false, false, false], T0));

// The recency fold: same tally, opposite order, different strength. This is the
// single property that separates `strength` from `accuracy`.
recordProfile(
  'good then bad',
  run('addition', [true, true, true, true, false, false, false], T0),
);
recordProfile(
  'bad then good',
  run('addition', [false, false, false, true, true, true, true], T0),
);

// A run inside one sitting is never secure, however long — SECURE_DAYS is what
// makes spaced practice mean anything.
recordProfile('a long run in one sitting', run('addition', new Array(12).fill(true), T0));

// Secure needs the answers, the run, and the separate days.
recordProfile('right on two days', [
  ...run('addition', [true, true, true, true], T0),
  ...run('addition', [true, true, true, true], T0 + DAY),
]);
recordProfile('right on five days', [
  ...run('addition', [true, true], T0),
  ...run('addition', [true, true], T0 + DAY),
  ...run('addition', [true, true], T0 + 2 * DAY),
  ...run('addition', [true, true], T0 + 3 * DAY),
  ...run('addition', [true, true], T0 + 4 * DAY),
]);

// One slip after a secure run: strength dips, streak resets to zero.
recordProfile('one slip on a secure topic', [
  ...run('addition', [true, true, true, true], T0),
  ...run('addition', [true, true, true, false], T0 + DAY),
]);

// Out-of-order arrival must not inflate `correctDays` — the guard is
// `day > lastCorrectDay`, not `day !== lastCorrectDay`.
recordProfile('answers arriving out of order', [
  ...run('addition', [true], T0 + DAY),
  ...run('addition', [true], T0),
  ...run('addition', [true], T0 + 2 * DAY),
  ...run('addition', [true], T0 + DAY),
]);

// The day counted is the child's, not UTC.
recordProfile(
  'a sydney evening either side of utc midnight',
  run('addition', [true, true], T0 + 13 * HOUR, 'K', 600),
);

// Several topics and levels: one skill row per (topic, level) pair, and the
// same topic at two levels must not collapse into one row.
recordProfile('two topics', [
  ...run('addition', [true, true, true, false], T0),
  ...run('subtraction', [false, false, true, false], T0 + 5 * 60_000),
]);
recordProfile('one topic at two levels', [
  ...run('addition', [true, true, true, true], T0, 'K'),
  ...run('addition', [false, false, false, false], T0 + HOUR, '1'),
]);

// Mixed everything: the fold order across interleaved topics is what
// `buildProfile`'s sort is for.
recordProfile('a whole sitting interleaved', [
  ...run('addition', [true, false, true, true, false], T0),
  ...run('subtraction', [false, false, false, true], T0 + 3 * 60_000),
  ...run('multiplication', [true, true, true, true, true, true, true, true], T0 + 7 * 60_000),
  ...run('counting', [true, true], T0 + 11 * 60_000),
]);

/**
 * `nextSkill` on its own, one step at a time.
 *
 * `applyObservation` and `buildProfile` both go through it, but only in
 * aggregate: a vector over a folded profile pins the sum of the steps and lets
 * a compensating pair of errors through. These pin the step.
 */
interface StepVector {
  name: string;
  previous: Json;
  observation: Json;
  next: Json;
}

const stepVectors: StepVector[] = [];

function recordStep(name: string, previous: Json, observation: Observation): void {
  stepVectors.push({
    name,
    previous: snap(previous),
    observation: snap(observation),
    next: snap(nextSkill(previous ?? undefined, observation)),
  });
}

const seedSkill = (over: Json = {}): Json => ({
  topic: 'addition',
  level: 'K',
  attempts: 6,
  correct: 4,
  strength: 0.7,
  streak: 2,
  correctDays: 1,
  lastCorrectDay: localDay(T0),
  totalTimeMs: 18_000,
  lastAnsweredAt: T0,
  ...over,
});

const obs = (over: Partial<Observation> = {}): Observation => ({
  topic: 'addition',
  level: 'K',
  correct: true,
  timeTakenMs: 3000,
  answeredAt: T0 + HOUR,
  ...over,
});

recordStep('from nothing, correct', null, obs());
recordStep('from nothing, wrong', null, obs({ correct: false }));
recordStep('correct on the same day', seedSkill(), obs());
recordStep('correct on a later day', seedSkill(), obs({ answeredAt: T0 + DAY }));
recordStep('wrong resets the streak', seedSkill(), obs({ correct: false }));
recordStep(
  'wrong on a new day does not count the day',
  seedSkill(),
  obs({ correct: false, answeredAt: T0 + DAY }),
);
recordStep(
  'correct on an earlier day does not inflate',
  seedSkill(),
  obs({ answeredAt: T0 - DAY }),
);
recordStep(
  'a late answer does not move lastAnsweredAt backwards',
  seedSkill({ lastAnsweredAt: T0 + 5 * DAY }),
  obs({ answeredAt: T0 }),
);
recordStep(
  'first correct answer ever on this skill',
  seedSkill({ correct: 0, streak: 0, strength: 0, correctDays: 0, lastCorrectDay: null }),
  obs(),
);

// --- selector ---------------------------------------------------------------

interface SelectVector {
  name: string;
  templateIds: string[];
  profile: Json;
  now: number;
  recent: string[];
  /** Every template's weight and status, verbatim — the policy itself. */
  weighted: Json;
  focusTopics: Json;
  /** Which template each of these seeds draws, and the draw it spent. */
  draws: Json;
}

const selectVectors: SelectVector[] = [];

const DRAW_SEEDS = ['s:0', 's:1', 's:2', 's:3', 's:4', 's:5', 's:6', 's:7'];

function recordSelect(
  name: string,
  templates: Json,
  profile: Json,
  now: number,
  recent: string[] = [],
): void {
  const context = { profile, now, recent };

  const weighted = weightTemplates(templates, context).map((entry: Json) => ({
    id: entry.template.id,
    topic: entry.template.topic,
    status: entry.status,
    weight: entry.weight,
  }));

  const draws = DRAW_SEEDS.map((seed) => {
    const rng = createRng(seed);
    const picked = selectTemplate(templates, context, rng);
    // The next value off the same rng, so a port that spends a different number
    // of draws inside `selectTemplate` is caught even when it picks correctly.
    return { seed, id: picked.id, nextAfter: rng.next() };
  });

  selectVectors.push({
    name,
    templateIds: templates.map((t: Json) => t.id),
    profile: snap(profile),
    now,
    recent,
    weighted: snap(weighted),
    focusTopics: snap(focusTopics(templates, context)),
    draws: snap(draws),
  });
}

// No pattern yet: every weight is 1 and the draw is uniform over templates.
recordSelect('an empty profile draws at random', POOL, emptyProfile(), T0);
recordSelect(
  'three answers is still not a pattern',
  POOL,
  buildProfile(run('addition', [true, false, true], T0)),
  T0,
);

// The moment a pattern exists, weighting begins.
const strugglingAddition = buildProfile(run('addition', [false, false, false, false], T0));
recordSelect('one struggling topic', POOL, strugglingAddition, T0 + HOUR);
recordSelect(
  'one struggling topic, just asked',
  POOL,
  strugglingAddition,
  T0 + HOUR,
  ['addition'],
);
recordSelect(
  'one struggling topic, asked two ago',
  POOL,
  strugglingAddition,
  T0 + HOUR,
  ['subtraction', 'addition'],
);
recordSelect(
  'one struggling topic, asked three ago',
  POOL,
  strugglingAddition,
  T0 + HOUR,
  ['counting', 'subtraction', 'addition'],
);
recordSelect(
  'cooldown remembers only three back',
  POOL,
  strugglingAddition,
  T0 + HOUR,
  ['counting', 'subtraction', 'multiplication', 'addition'],
);

// Several weak topics: the share ceiling is what stops the session becoming
// nothing but the hard ones.
const severalWeak = buildProfile([
  ...run('addition', [false, false, false, false], T0),
  ...run('subtraction', [false, false, false, false], T0 + HOUR),
  ...run('multiplication', [false, false, false, false], T0 + 2 * HOUR),
]);
recordSelect('three struggling topics', POOL, severalWeak, T0 + 3 * HOUR);
recordSelect(
  'three struggling topics, one just asked',
  POOL,
  severalWeak,
  T0 + 3 * HOUR,
  ['addition'],
);

// Every topic weak: `rest` is empty, so the share machinery is skipped entirely.
const allWeak = buildProfile([
  ...run('addition', [false, false, false, false], T0),
  ...run('subtraction', [false, false, false, false], T0 + HOUR),
  ...run('multiplication', [false, false, false, false], T0 + 2 * HOUR),
  ...run('counting', [false, false, false, false], T0 + 3 * HOUR),
]);
recordSelect('every topic struggling', POOL, allWeak, T0 + 4 * HOUR);

// A secure topic, and the same one once it has faded into review.
const secureAddition = buildProfile([
  ...run('addition', [true, true, true, true], T0),
  ...run('addition', [true, true, true, true], T0 + DAY),
]);
recordSelect('a secure topic is asked less', POOL, secureAddition, T0 + DAY + HOUR);
recordSelect('a faded topic is due for review', POOL, secureAddition, T0 + 9 * DAY);

// Secure and struggling together: focus and rest both non-empty, which is the
// only shape where the share is actually rebalanced.
const secureAndWeak = buildProfile([
  ...run('addition', [true, true, true, true], T0),
  ...run('addition', [true, true, true, true], T0 + DAY),
  ...run('subtraction', [false, false, false, false], T0 + DAY + HOUR),
]);
recordSelect('one secure, one struggling', POOL, secureAndWeak, T0 + DAY + 2 * HOUR);

// Developing sits between: no focus at all, so the share is skipped the other
// way.
const developing = buildProfile(run('addition', [true, true, false, true, true, false], T0));
recordSelect('a developing topic', POOL, developing, T0 + HOUR);

// The per-topic divisor, isolated: two equally weak topics, one with three
// templates and one with a single template. Without the division the
// three-template topic gets three times the practice for the same weakness.
const UNEVEN: Json = POOL.filter((t: Json) => t.topic === 'addition' || t.topic === 'subtraction');
const bothWeak = buildProfile([
  ...run('addition', [false, false, false, false], T0),
  ...run('subtraction', [false, false, false, false], T0 + HOUR),
]);
recordSelect('three templates against one, both weak', UNEVEN, bothWeak, T0 + 2 * HOUR);

// A single-template pool: `total > 0` still holds, and the walk has one step.
recordSelect('a pool of one', [POOL[0]], strugglingAddition, T0 + HOUR);

// A profile naming topics the pool does not have — every status falls back to
// `new` via an undefined skill.
recordSelect(
  'a profile about other topics entirely',
  POOL,
  buildProfile(run('geometry', [false, false, false, false], T0)),
  T0 + HOUR,
);

// A level mismatch: same topic name, different level, so `findSkill` misses.
recordSelect(
  'the profile is about another level',
  POOL,
  buildProfile(run('addition', [false, false, false, false], T0, '6')),
  T0 + HOUR,
);

// --- grade ------------------------------------------------------------------

interface GradeVector {
  name: string;
  question: Json;
  response: string;
  grade: Json;
}

const gradeVectors: GradeVector[] = [];

function recordGrade(name: string, question: Json, response: string): void {
  gradeVectors.push({
    name,
    question: snap(question),
    response,
    grade: snap(gradeAnswer(question, response)),
  });
}

const numberQ = (answer: unknown): Json => ({
  templateId: 'q',
  subject: 'maths',
  topic: 'addition',
  level: 'K',
  prompt: 'p',
  answer,
  answerType: 'number',
});
const boolQ = (answer: boolean): Json => ({ ...numberQ(answer), answerType: 'boolean' });
const textQ = (answer: unknown): Json => ({ ...numberQ(answer), answerType: 'text' });

// Numbers, and every way a child's typing can miss.
recordGrade('a plain right number', numberQ(7), '7');
recordGrade('a plain wrong number', numberQ(7), '8');
recordGrade('whitespace is trimmed', numberQ(7), '  7  ');
recordGrade('an empty response is never correct', numberQ(7), '');
recordGrade('whitespace only is never correct', numberQ(7), '   ');
recordGrade('a leading zero still parses', numberQ(7), '07');
recordGrade('a leading plus parses in JS', numberQ(7), '+7');
recordGrade('a trailing dot parses in JS', numberQ(7), '7.');
recordGrade('a decimal point form', numberQ(7), '7.0');
recordGrade('letters do not parse', numberQ(7), 'seven');
recordGrade('a negative answer', numberQ(-3), '-3');
recordGrade('a decimal answer', numberQ(2.5), '2.5');
recordGrade('a decimal within epsilon', numberQ(0.1 + 0.2), '0.3');
recordGrade('a decimal just outside epsilon', numberQ(2.5), '2.5000001');
recordGrade('a decimal well outside', numberQ(2.5), '2.6');
recordGrade('an integer answer typed as a decimal', numberQ(2), '2.0');
// `Number('')` is 0, `Number(' ')` is 0, `Number('Infinity')` is Infinity —
// three JS coercions that a naive Swift `Double(_:)` gets differently.
recordGrade('infinity against a real answer', numberQ(7), 'Infinity');
recordGrade('hex parses in JS', numberQ(255), '0xff');
recordGrade('exponent notation parses', numberQ(700), '7e2');
recordGrade('a comma does not parse', numberQ(1000), '1,000');

// Booleans, and the several spellings the pad and a keyboard can send.
recordGrade('true as true', boolQ(true), 'true');
recordGrade('true as yes', boolQ(true), 'yes');
recordGrade('true as t', boolQ(true), 't');
recordGrade('true as y', boolQ(true), 'y');
recordGrade('true as TRUE', boolQ(true), 'TRUE');
recordGrade('true answered false', boolQ(true), 'false');
recordGrade('false as false', boolQ(false), 'false');
recordGrade('false as no', boolQ(false), 'no');
recordGrade('false as n', boolQ(false), 'N');
recordGrade('false answered true', boolQ(false), 'true');
recordGrade('a boolean answered with nonsense', boolQ(true), 'maybe');
recordGrade('a boolean answered empty', boolQ(true), '');

// Text, which is case-insensitive and trimmed on both sides.
recordGrade('text exact', textQ('cat'), 'cat');
recordGrade('text differing in case', textQ('Cat'), 'cAt');
recordGrade('text with padding', textQ('cat'), '  cat ');
recordGrade('text wrong', textQ('cat'), 'dog');
recordGrade('text answer with its own padding', textQ('  cat  '), 'cat');

// The type is inferred from the answer when `answerType` is absent — the
// `typeof` fallbacks in `gradeAnswer`.
recordGrade('an untyped boolean answer', { ...numberQ(true), answerType: undefined }, 'true');
recordGrade('an untyped number answer', { ...numberQ(7), answerType: undefined }, '7');
recordGrade('an untyped string answer', { ...numberQ('cat'), answerType: undefined }, 'cat');
// A number answer arriving as a string still grades numerically.
recordGrade('a number answerType with a string answer', numberQ('7'), '7.0');

// --- answers ----------------------------------------------------------------

interface AnswerVector {
  name: string;
  question: Json;
  mode: string;
  options: Json;
  formatted: string;
}

const answerVectors: AnswerVector[] = [];

function recordAnswer(name: string, question: Json): void {
  answerVectors.push({
    name,
    question: snap(question),
    mode: answerMode(question),
    options: snap(answerOptions(question)),
    formatted: formatAnswer(question),
  });
}

recordAnswer('a number question', numberQ(7));
recordAnswer('a text question', textQ('cat'));
recordAnswer('a boolean question', boolQ(true));
recordAnswer('a false boolean question', boolQ(false));
recordAnswer('a question with choices', { ...numberQ(3), choices: [3, 4, 5] });
recordAnswer('choices of mixed type', { ...numberQ(3), choices: ['3', 4, 5.5] });
recordAnswer('a text question with choices', { ...textQ('cat'), choices: ['cat', 'dog'] });
// `String(2)` is "2", not "2.0" — the trap, arriving in what a child reads.
recordAnswer('a whole-number answer formats without a point', numberQ(2));
recordAnswer('a whole float answer formats without a point', numberQ(2.0));
recordAnswer('a decimal answer keeps its point', numberQ(2.5));
recordAnswer('a negative zero answer', numberQ(-0));

interface KeypadVector {
  name: string;
  entry: string;
  key: string;
  result: string;
}

const keypadVectors: KeypadVector[] = [];

function recordKeypad(name: string, entry: string, key: string): void {
  keypadVectors.push({ name, entry, key, result: appendNumeric(entry, key) });
}

recordKeypad('a digit onto nothing', '', '5');
recordKeypad('a digit onto a number', '12', '3');
recordKeypad('a bare dot seeds a zero', '', '.');
recordKeypad('a dot after a digit', '12', '.');
recordKeypad('a second dot is refused', '1.5', '.');
recordKeypad('a minus onto nothing', '', '-');
recordKeypad('a minus after a digit is refused', '12', '-');
recordKeypad('a minus after a minus is refused', '-', '-');
recordKeypad('a digit after a minus', '-', '7');
recordKeypad('a letter is refused', '12', 'a');
recordKeypad('a space is refused', '12', ' ');
recordKeypad('an empty key is refused', '12', '');
recordKeypad('at the length cap', '12345678', '9');
recordKeypad('a dot at the length cap', '12345678', '.');
recordKeypad('one below the cap', '1234567', '8');

// --- session ----------------------------------------------------------------

interface SessionVector {
  name: string;
  templateIds: string[];
  seed: string;
  startedAt: number;
  subject: Json;
  level: Json;
  profile: Json;
  recentTopics: Json;
  /** The opening state, before anything is answered. */
  opening: Json;
  /** One entry per answer: what was sent, and the state it produced. */
  steps: Json;
}

const sessionVectors: SessionVector[] = [];

/** Records the parts of a state a port must reproduce, minus the template pool. */
function stateSnapshot(state: Json, now: number): Json {
  return {
    subject: state.subject,
    level: state.level,
    startedAt: state.startedAt,
    questionShownAt: state.questionShownAt,
    askedCount: state.askedCount,
    draw: state.draw,
    seed: state.seed,
    current: snap(state.current),
    attempts: snap(state.attempts),
    profile: snap(state.profile),
    recentTopics: snap(state.recentTopics),
    elapsedMs: elapsedMs(state, now),
    formattedDuration: formatDuration(elapsedMs(state, now)),
  };
}

/**
 * Plays a scripted session and records every intermediate state.
 *
 * `script` is a list of (response, delayMs) pairs. The responses are literal
 * strings, exactly as a child's typing arrives, so grading, the profile fold
 * and the next draw are all exercised in the one sequence the real screen runs
 * them in.
 */
function recordSession(
  name: string,
  templates: Json,
  config: Json,
  script: [string, number][],
  answerCorrectly?: boolean,
): void {
  const full = { templates, ...config };
  let state = startSession(full);
  const opening = stateSnapshot(state, config.startedAt);

  const steps: Json[] = [];
  let now = config.startedAt;

  for (const [response, delay] of script) {
    now += delay;
    // When asked to answer correctly, read the answer off the question rather
    // than the script — a script of literal strings would grade wrong for a
    // sequence we cannot predict without running the engine.
    const sent =
      answerCorrectly === undefined
        ? response
        : answerCorrectly
          ? formatAnswer(state.current)
          : `${formatAnswer(state.current)}!`;
    const offsetMinutes = config.offsetMinutes ?? 0;
    state = submitAnswer(state, sent, now, offsetMinutes);
    steps.push({ response: sent, now, offsetMinutes, state: stateSnapshot(state, now) });
  }

  sessionVectors.push({
    name,
    templateIds: templates.map((t: Json) => t.id),
    seed: config.seed,
    startedAt: config.startedAt,
    subject: config.subject ?? null,
    level: config.level ?? null,
    profile: snap(config.profile ?? null),
    recentTopics: snap(config.recentTopics ?? null),
    opening,
    steps: snap(steps),
  });
}

const evenly = (count: number, delay = 8000): [string, number][] =>
  new Array(count).fill(null).map(() => ['', delay] as [string, number]);

// An opening state and nothing else: the first draw against an empty profile.
recordSession('opens on an empty profile', POOL, { seed: 'sess-1', startedAt: T0 }, []);

// A run of right answers. The profile builds as it goes, so the selector
// switches from uniform to weighted partway through the very same session —
// which is the behaviour the module docstring promises and nothing shorter
// exercises.
recordSession(
  'twelve right answers',
  POOL,
  { seed: 'sess-2', startedAt: T0 },
  evenly(12),
  true,
);

// A run of wrong ones, which drives topics into `struggling` mid-session.
recordSession(
  'twelve wrong answers',
  POOL,
  { seed: 'sess-3', startedAt: T0 },
  evenly(12),
  false,
);

// Literal responses, so grading sees real typing rather than a formatted
// answer: most will be wrong, and that is the point.
recordSession('literal typed answers', POOL, { seed: 'sess-4', startedAt: T0 }, [
  ['5', 4000],
  ['', 2000],
  ['  7 ', 9000],
  ['-3', 1500],
  ['2.5', 30_000],
  ['abc', 700],
]);

// The time cap. A question left overnight is not a four-hour measurement, and
// the cap is what keeps one abandoned question out of a topic's average
// forever.
recordSession('a question left for hours', POOL, { seed: 'sess-5', startedAt: T0 }, [
  ['1', 10 * 60_000],
  ['2', 4 * 60_000],
  ['3', 5 * 60_000],
  ['4', 5 * 60_000 + 1],
  ['5', 0],
]);

// Time going backwards — a clock correction mid-sitting. `Math.max(0, ...)`
// is what stops a negative duration reaching a parent's report.
recordSession('the clock jumps backwards', POOL, { seed: 'sess-6', startedAt: T0 }, [
  ['1', 5000],
  ['2', -3000],
  ['3', 1000],
]);

// Opening against history, which is the ordinary case for a returning child:
// the very first draw is already weighted.
recordSession(
  'opens on an existing profile',
  POOL,
  {
    seed: 'sess-7',
    startedAt: T0 + 2 * DAY,
    profile: buildProfile([
      ...run('addition', [false, false, false, false], T0),
      ...run('multiplication', [true, true, true, true], T0 + HOUR),
      ...run('multiplication', [true, true, true, true], T0 + DAY),
    ]),
    recentTopics: ['counting', 'subtraction'],
  },
  evenly(8),
  true,
);

// `recentTopics` longer than RECENT_MEMORY must be trimmed on the way in.
recordSession(
  'opens with more recent topics than it remembers',
  POOL,
  {
    seed: 'sess-8',
    startedAt: T0,
    recentTopics: ['addition', 'subtraction', 'multiplication', 'counting', 'shapes'],
  },
  evenly(4),
  true,
);

// An explicit subject and level override what the first question would say.
recordSession(
  'an explicit subject and level',
  POOL,
  { seed: 'sess-9', startedAt: T0, subject: 'english', level: '3' },
  evenly(3),
  true,
);

// A non-zero offset, so the days folded into the profile are the child's.
recordSession(
  'played in sydney across utc midnight',
  POOL,
  { seed: 'sess-10', startedAt: T0 + 13 * HOUR, offsetMinutes: 600 },
  evenly(6),
  true,
);

// A single-template pool: every draw returns the one template, and the profile
// still folds.
recordSession('a pool of one template', [POOL[0]], { seed: 'sess-11', startedAt: T0 }, evenly(5), true);

// Tap and text questions in the pool, so a session grades something other than
// a typed number.
recordSession(
  'a mixed-answer pool',
  [CHOICE_TEMPLATE, BOOLEAN_TEMPLATE, TEXT_TEMPLATE, POOL[0]],
  { seed: 'sess-12', startedAt: T0 },
  evenly(10),
  true,
);
recordSession(
  'a mixed-answer pool answered wrongly',
  [CHOICE_TEMPLATE, BOOLEAN_TEMPLATE, TEXT_TEMPLATE, POOL[0]],
  { seed: 'sess-13', startedAt: T0 },
  evenly(10),
  false,
);

// A long session — long enough that several topics cross into secure and the
// share ceiling starts binding.
recordSession('a long sitting', POOL, { seed: 'sess-14', startedAt: T0 }, evenly(40, 6000), true);

/** `formatDuration` on its own, including the places a clock reads oddly. */
interface DurationVector {
  ms: number;
  formatted: string;
}

const durationVectors: DurationVector[] = [
  0, 1, 999, 1000, 1001, 59_999, 60_000, 61_000, 599_999, 600_000, 3_599_000,
  3_600_000, 3_661_000, 86_400_000,
].map((ms) => ({ ms, formatted: formatDuration(ms) }));

// --- output -----------------------------------------------------------------

process.stdout.write(
  `${JSON.stringify(
    {
      pool: POOL,
      choiceTemplate: CHOICE_TEMPLATE,
      booleanTemplate: BOOLEAN_TEMPLATE,
      textTemplate: TEXT_TEMPLATE,
      day: dayVectors,
      offsets: offsetVectors,
      profiles: profileVectors,
      steps: stepVectors,
      select: selectVectors,
      grade: gradeVectors,
      answers: answerVectors,
      keypad: keypadVectors,
      sessions: sessionVectors,
      durations: durationVectors,
      constants: {
        RECENCY: profileModule.RECENCY,
        MIN_OBSERVATIONS: profileModule.MIN_OBSERVATIONS,
        STRUGGLING_BELOW: profileModule.STRUGGLING_BELOW,
        SECURE_AT: profileModule.SECURE_AT,
        SECURE_STREAK: profileModule.SECURE_STREAK,
        SECURE_OBSERVATIONS: profileModule.SECURE_OBSERVATIONS,
        SECURE_DAYS: profileModule.SECURE_DAYS,
        REVIEW_INTERVALS_MS: profileModule.REVIEW_INTERVALS_MS,
        STATUS_WEIGHTS: selectModule.STATUS_WEIGHTS,
        MIN_FOCUS_SHARE: selectModule.MIN_FOCUS_SHARE,
        MAX_FOCUS_SHARE: selectModule.MAX_FOCUS_SHARE,
        COOLDOWN: selectModule.COOLDOWN,
        RECENT_MEMORY: selectModule.RECENT_MEMORY,
        MAX_TIME_MS: sessionModule.MAX_TIME_MS,
        MAX_NUMBER_LENGTH: answersModule.MAX_NUMBER_LENGTH,
        BOOLEAN_OPTIONS: answersModule.BOOLEAN_OPTIONS,
      },
    },
    null,
    2,
  )}\n`,
);
