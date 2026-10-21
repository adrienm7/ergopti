// tools/test/test-ci-pipeline.cjs

/**
 * ==============================================================================
 * MODULE: CI Pipeline Loader Self-Test
 * DESCRIPTION:
 * Proves on fixtures that tools/test/ci-pipeline.cjs, which every workflow
 * contract test reads the pipeline through, refuses each layout it cannot read
 * instead of returning nothing.
 *
 * ROOT CAUSE ENCODED:
 * The loader read job keys at exactly four spaces and had no test of its own.
 * Re-indenting the macOS `test-hs` job by two spaces and adding a job-level
 * `continue-on-error: true` kept all nine contract tests green, while GitHub
 * would have let a red Lua suite leave the macOS box green: the "skipped
 * counts as green" defect the old aggregate jobs were written to catch.
 *
 * FEATURES & RATIONALE:
 * 1. Each refusal is exercised on a small fixture checkout through open(root):
 *    zero or two jobs of one id, a missing or duplicated step, a job or a step
 *    whose keys sit at another column, a quoted key, a missing or empty called
 *    workflow.
 * 2. The accepted layout is exercised too, so a loader that refused everything
 *    could not pass: lookups, needs, job and step keys, a workflow called from
 *    a box, a job key after the steps, quoted step names, and step scripts.
 *    A review found the recursion, the end of the steps list and the quote
 *    stripping could each be broken with every contract test still green.
 * 3. The real pipeline must parse under the enforced layout, with floors, and
 *    the reviewer's mutation of the real ci-macos.yml must be refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const pipeline = require('./ci-pipeline.cjs');

const ENTRY = '.github/workflows/ci.yml';
const BOX = '.github/workflows/ci-box.yml';

// The five Linux install jobs share one matrix; its 17 mandatory rows are
// pinned by test-linux-ci-evidence.cjs. Keep the loader floor at all 14 jobs.
const MIN_REAL_JOBS = 21;
const MIN_REAL_STEPS = 180;

const ENTRY_TEXT = [
	'name: CI',
	'on: push',
	'jobs:',
	'  plan:',
	'    runs-on: ubuntu-latest',
	'    steps:',
	'      - name: Compute',
	'        run: echo plan',
	'',
	'  box:',
	'    needs: [plan]',
	'    uses: ./.github/workflows/ci-box.yml',
	''
].join('\n');

const BOX_TEXT = [
	'name: Box',
	'on:',
	'  workflow_call:',
	'jobs:',
	'  # A comment between jobs belongs to neither.',
	'  test:',
	'    runs-on: ubuntu-latest',
	'    steps:',
	'      - uses: actions/checkout@v4',
	'',
	'      - name: Run tests',
	'        if: ${{ !cancelled() }}',
	'        run: |',
	'          # a shell comment inside the script',
	'          echo test',
	'',
	'  gate:',
	'    needs:',
	'      - test',
	'    if: always()',
	'    runs-on: ubuntu-latest',
	'    steps:',
	'      - name: Judge',
	'        run: echo judge',
	''
].join('\n');

const roots = [];
const failures = [];

/** Writes a fixture checkout and returns the loader bound to it. */
function fixture(overrides = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ci-pipeline-'));
	roots.push(root);
	const files = { [ENTRY]: ENTRY_TEXT, [BOX]: BOX_TEXT, ...overrides };
	for (const [rel, text] of Object.entries(files)) {
		if (text === null) continue;
		fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
		fs.writeFileSync(path.join(root, rel), text);
	}
	return pipeline.open(root);
}

/** Replaces `from` in `text`, refusing a replacement that changes nothing. */
function edit(text, from, to) {
	assert.ok(text.includes(from), `fixture edit found nothing to replace: ${from}`);
	return text.replace(from, to);
}

/** Asserts that `run` throws a loader error matching `pattern`. */
function refuses(run, pattern) {
	assert.throws(run, (error) => {
		assert.match(error.message, /^\[ci-pipeline\] /);
		assert.match(error.message, pattern);
		return true;
	});
}

/** Records one named case; a failure never hides the cases after it. */
function check(label, run) {
	try {
		run();
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
}

/**
 * Indents one job's lines by two more spaces and inserts `extra` job keys, the
 * way the review hid a job-level continue-on-error from the loader.
 */
function reindentJob(text, id, extra) {
	const lines = text.split('\n');
	const at = lines.indexOf(`  ${id}:`);
	assert.ok(at >= 0, `no job ${id} to re-indent`);
	let end = at + 1;
	while (
		end < lines.length &&
		!/^ {2}[A-Za-z0-9_-]+:\s*$/.test(lines[end]) &&
		!/^ {0,2}#/.test(lines[end])
	)
		end++;
	for (let index = at + 1; index < end; index++) {
		if (lines[index].trim() !== '') lines[index] = `  ${lines[index]}`;
	}
	lines.splice(at + 1, 0, ...extra);
	return lines.join('\n');
}

// ==========================================
// ==========================================
// ======= 1/ The Accepted Layout ===========
// ==========================================
// ==========================================

check('a workflow a box calls is loaded too, depth first', () => {
	const inner = '.github/workflows/ci-inner.yml';
	const ci = fixture({
		[BOX]: `${BOX_TEXT}  nested:\n    needs: [gate]\n    uses: ./.github/workflows/ci-inner.yml\n`,
		[inner]:
			'name: Inner\non:\n  workflow_call:\njobs:\n  deep:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Deep\n        run: echo deep\n'
	});
	assert.deepEqual(
		ci.files().map((entry) => entry.rel),
		[ENTRY, BOX, inner]
	);
	assert.equal(ci.locate('deep').file, inner);
	assert.equal(ci.findStep('Deep').job, 'deep');
	assert.deepEqual(ci.calls(BOX), [{ id: 'nested', uses: './.github/workflows/ci-inner.yml' }]);
});

check('a job key after the steps list ends the steps, and field() still reads it', () => {
	const ci = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'        run: echo judge\n',
			'        run: echo judge\n    timeout-minutes: 5\n'
		)
	});
	const gate = ci.job('gate');
	assert.equal(pipeline.field(gate, 'timeout-minutes'), '5');
	const found = pipeline.steps(gate);
	assert.deepEqual(
		found.map((candidate) => candidate.name),
		['Judge']
	);
	assert.ok(!found[0].body.includes('timeout-minutes'), 'the job key leaked into the last step');
});

check('a quoted step name is found by its text', () => {
	const ci = fixture({
		[BOX]: edit(
			edit(BOX_TEXT, '      - name: Judge\n', "      - name: 'Judge it'\n"),
			'      - name: Run tests\n',
			'      - name: "Run the tests"\n'
		)
	});
	assert.equal(pipeline.stepField(pipeline.step(ci.job('gate'), 'Judge it'), 'run'), 'echo judge');
	assert.equal(ci.findStep('Run the tests').job, 'test');
});

check('a step script is read line by line, and a failure branch by its last statement', () => {
	const ci = fixture();
	const test = ci.job('test');
	assert.deepEqual(pipeline.runOf(pipeline.step(test, 'Run tests')), [
		'# a shell comment inside the script',
		'echo test'
	]);
	assert.deepEqual(pipeline.runOf(pipeline.step(ci.job('gate'), 'Judge')), ['echo judge']);
	assert.equal(pipeline.runOf(pipeline.steps(test)[0].body), null);
	const script = [
		'if (-not $ahk) { Write-Error "missing"; exit 2 }',
		'if ($warnings) {',
		'    $warnings | ForEach-Object { Write-Host "  $_" }',
		'    Write-Error "warnings"',
		'    exit 1',
		'}',
		'if ($other) {',
		'    Write-Warning "only a warning"',
		'}',
		'if ($open) {',
		'    exit 1'
	];
	assert.ok(pipeline.blockExits(pipeline.scriptBlock(script, 'if (-not $ahk) {'), '2'));
	assert.ok(!pipeline.blockExits(pipeline.scriptBlock(script, 'if (-not $ahk) {'), '1'));
	assert.deepEqual(pipeline.scriptBlock(script, 'if ($warnings) {'), script.slice(1, 6));
	assert.ok(pipeline.blockExits(pipeline.scriptBlock(script, 'if ($warnings) {'), '1'));
	assert.ok(!pipeline.blockExits(pipeline.scriptBlock(script, 'if ($other) {'), '1'));
	refuses(
		() => pipeline.scriptBlock(script, 'if ($missing) {'),
		/expected one script line starting with 'if \(\$missing\) \{', found 0/
	);
	refuses(
		() => pipeline.scriptBlock([...script, 'if ($other) { exit 1 }'], 'if ($other) {'),
		/found 2/
	);
	refuses(() => pipeline.scriptBlock(script, 'if ($open) {'), /never closes at its own column/);
});

check('a well-formed pipeline is loaded in call order and sliced', () => {
	const ci = fixture();
	assert.deepEqual(
		ci.files().map((entry) => entry.rel),
		[ENTRY, BOX]
	);
	assert.equal(ci.locate('test').file, BOX);
	assert.equal(ci.locate('plan').line, 4);
	assert.deepEqual(pipeline.needsOf(ci.job('gate')), ['test']);
	assert.deepEqual(pipeline.needsOf(ci.job('box')), ['plan']);
	assert.equal(pipeline.field(ci.job('gate'), 'if'), 'always()');
	assert.equal(pipeline.field(ci.job('test'), 'if'), null);
	const run = pipeline.step(ci.job('test'), 'Run tests');
	assert.equal(pipeline.stepField(run, 'if'), '${{ !cancelled() }}');
	assert.equal(pipeline.stepField(run, 'run'), '# a shell comment inside the script echo test');
	assert.equal(pipeline.stepField(run, 'continue-on-error'), null);
	assert.equal(pipeline.steps(ci.job('test'))[0].name, '');
	assert.equal(
		pipeline.stepField(pipeline.steps(ci.job('test'))[0].body, 'uses'),
		'actions/checkout@v4'
	);
	assert.equal(ci.findStep('Judge').job, 'gate');
	assert.deepEqual(ci.calls(), [{ id: 'box', uses: './.github/workflows/ci-box.yml' }]);
	assert.ok(!ci.textWithout('test').includes('echo test'));
});

// ==========================================
// ==========================================
// ======= 2/ Lookups That Must Throw =======
// ==========================================
// ==========================================

check('a job that does not exist throws', () => {
	const ci = fixture();
	refuses(() => ci.locate('missing'), /no job 'missing' in the pipeline/);
	refuses(() => ci.job('missing'), /no job 'missing' in the pipeline/);
});

check('a job id defined twice across the pipeline throws', () => {
	const ci = fixture({ [BOX]: `${BOX_TEXT}  plan:\n    runs-on: ubuntu-latest\n` });
	refuses(() => ci.locate('plan'), /job 'plan' is defined 2 times/);
});

// A lane's stage caller keeps its stage job's id, so the lane's needs context
// names the jobs the receipt chain admits.
const STAGE = '.github/workflows/ci-box-unit.yml';
const STAGE_TEXT = [
	'name: Unit',
	'on:',
	'  workflow_call:',
	'jobs:',
	'  unit:',
	'    runs-on: ubuntu-latest',
	'    steps:',
	'      - name: Run units',
	'        run: echo units',
	''
].join('\n');
const STAGE_CALLER = '  unit:\n    uses: ./.github/workflows/ci-box-unit.yml\n';

check('a stage caller shares its id with the one job of the file it calls', () => {
	// The real view: this box mixes steps with a stage caller, which no lane may.
	const ci = fixture({ [BOX]: `${BOX_TEXT}${STAGE_CALLER}`, [STAGE]: STAGE_TEXT }).real();
	assert.equal(ci.locate('unit').file, STAGE);
	assert.ok(ci.job('unit').includes('echo units'));
	assert.equal(ci.locateCaller('unit').file, BOX);
	assert.equal(pipeline.field(ci.caller('unit'), 'uses'), './.github/workflows/ci-box-unit.yml');
	assert.equal(ci.locateCaller('box').file, ENTRY);
	assert.deepEqual(ci.laneFiles(BOX), [BOX, STAGE]);
	assert.deepEqual(
		ci.laneJobs(BOX).map((job) => `${job.file}:${job.id}`),
		[`${BOX}:test`, `${BOX}:gate`, `${STAGE}:unit`]
	);
	assert.equal(ci.findStep('Run units').file, STAGE);
	refuses(() => ci.caller('test'), /job 'test' calls no reusable workflow/);
});

check('a shared id outside a stage caller and its only job throws', () => {
	const foreign = fixture({
		// The stage file is loaded through another caller, so both ids are seen.
		[BOX]: `${BOX_TEXT}${STAGE_CALLER.replace('ci-box-unit.yml', 'ci-box-other.yml')}  loader:
    uses: ./.github/workflows/ci-box-unit.yml
`,
		[STAGE]: STAGE_TEXT,
		'.github/workflows/ci-box-other.yml': STAGE_TEXT.replace('  unit:\n', '  other:\n')
	}).real();
	foreign.files();
	refuses(
		() => foreign.locate('unit'),
		/a caller may share an id only with the job of the file it calls/
	);
	const crowded = fixture({
		[BOX]: `${BOX_TEXT}${STAGE_CALLER}`,
		[STAGE]: `${STAGE_TEXT}  extra:\n    runs-on: ubuntu-latest\n`
	}).real();
	refuses(
		() => crowded.locate('unit'),
		/defines 2 jobs \(unit, extra\); a stage file defines its one job/
	);
	const twice = fixture({
		[ENTRY]: `${ENTRY_TEXT}  unit:\n    uses: ./.github/workflows/ci-box-unit.yml\n`,
		[BOX]: `${BOX_TEXT}${STAGE_CALLER}`,
		[STAGE]: STAGE_TEXT
	}).real();
	refuses(() => twice.locate('unit'), /job 'unit' is defined 3 times/);
});

// A lane made only of stage callers, read back as one workflow.
const LANE = '.github/workflows/ci-lane.yml';
const LANE_UNIT = '.github/workflows/ci-lane-unit.yml';
const LANE_GATE = '.github/workflows/ci-lane-gate.yml';
const LANE_ENTRY = edit(ENTRY_TEXT, 'ci-box.yml', 'ci-lane.yml');
const RELEASE_INPUT = [
	'      release:',
	'        description: True on a release run',
	'        required: true',
	'        type: boolean'
];
const KEY_SECRET = ['      KEY:', '        description: Signing key', '        required: false'];
const LANE_TEXT = [
	'name: Lane',
	'on:',
	'  workflow_call:',
	'    inputs:',
	...RELEASE_INPUT,
	'    secrets:',
	...KEY_SECRET,
	'',
	'permissions:',
	'  contents: read',
	'',
	'jobs:',
	'  # Units first.',
	'  unit:',
	"    name: 'Unit tests'",
	'    uses: ./.github/workflows/ci-lane-unit.yml',
	'    with:',
	'      release: ${{ inputs.release }}',
	'    secrets:',
	'      KEY: ${{ secrets.KEY }}',
	'',
	'  gate:',
	"    name: 'Verdict'",
	'    needs: [unit]',
	'    if: always()',
	'    uses: ./.github/workflows/ci-lane-gate.yml',
	'    with:',
	'      release: ${{ inputs.release }}',
	'      plan: ${{ needs.unit.outputs.plan }}',
	'      predecessors: ${{ toJSON(needs) }}',
	'      predecessor_result: ${{ needs.unit.result }}',
	''
].join('\n');
const STRING_INPUT = (name) => [
	`      ${name}:`,
	`        description: ${name} from the lane`,
	'        required: true',
	'        type: string'
];
const LANE_ENV = ['env:', '  RELEASE: ${{ inputs.release }}'];
const LANE_UNIT_TEXT = [
	'name: Unit',
	'on:',
	'  workflow_call:',
	'    inputs:',
	...RELEASE_INPUT,
	'    outputs:',
	'      plan:',
	'        description: The plan',
	'        value: ${{ jobs.unit.outputs.plan }}',
	'    secrets:',
	...KEY_SECRET,
	'',
	'permissions:',
	'  contents: read',
	'',
	...LANE_ENV,
	'',
	'jobs:',
	'  unit:',
	"    name: '${{ matrix.lot }}'",
	'    runs-on: ubuntu-latest',
	'    outputs:',
	'      plan: ${{ steps.plan.outputs.plan }}',
	'    steps:',
	'      - name: Plan',
	'        id: plan',
	'        env:',
	'          KEY: ${{ secrets.KEY }}',
	'        run: echo plan',
	''
].join('\n');
const LANE_GATE_TEXT = [
	'name: Gate',
	'on:',
	'  workflow_call:',
	'    inputs:',
	...RELEASE_INPUT,
	...STRING_INPUT('plan'),
	...STRING_INPUT('predecessors'),
	...STRING_INPUT('predecessor_result'),
	'',
	'permissions:',
	'  contents: read',
	'',
	...LANE_ENV,
	'',
	'jobs:',
	'  gate:',
	"    name: 'Mandatory evidence'",
	'    runs-on: ubuntu-latest',
	'    env:',
	'      PLAN: ${{ inputs.plan }}',
	'      NEEDS: ${{ inputs.predecessors }}',
	'      PRIOR: ${{ inputs.predecessor_result }}',
	'    steps:',
	'      - name: Judge the lane',
	'        run: echo "$PLAN"',
	''
].join('\n');
const INLINED_LANE = [
	'name: Lane',
	'on:',
	'  workflow_call:',
	'    inputs:',
	...RELEASE_INPUT,
	'    secrets:',
	...KEY_SECRET,
	'',
	'permissions:',
	'  contents: read',
	'',
	...LANE_ENV,
	'',
	'jobs:',
	'  # Units first.',
	'  unit:',
	"    name: 'Unit tests'",
	'    runs-on: ubuntu-latest',
	'    outputs:',
	'      plan: ${{ steps.plan.outputs.plan }}',
	'    steps:',
	'      - name: Plan',
	'        id: plan',
	'        env:',
	'          KEY: ${{ secrets.KEY }}',
	'        run: echo plan',
	'',
	'  gate:',
	"    name: 'Verdict'",
	'    needs: [unit]',
	'    if: always()',
	'    runs-on: ubuntu-latest',
	'    env:',
	'      PLAN: ${{ needs.unit.outputs.plan }}',
	'      NEEDS: ${{ toJSON(needs) }}',
	'      PRIOR: ${{ needs.unit.result }}',
	'    steps:',
	'      - name: Judge the lane',
	'        run: echo "$PLAN"',
	''
].join('\n');

/** A fixture checkout of a lane of two stages, with `overrides` replacing files. */
function laneFixture(overrides = {}) {
	return fixture({
		[ENTRY]: LANE_ENTRY,
		[BOX]: null,
		[LANE]: LANE_TEXT,
		[LANE_UNIT]: LANE_UNIT_TEXT,
		[LANE_GATE]: LANE_GATE_TEXT,
		...overrides
	});
}

check('a lane of stage callers is read back as one workflow, byte for byte', () => {
	const ci = laneFixture();
	assert.deepEqual(
		ci.files().map((entry) => entry.rel),
		[ENTRY, LANE]
	);
	assert.equal(ci.file(LANE), INLINED_LANE);
	assert.deepEqual(pipeline.needsOf(ci.job('gate')), ['unit']);
	assert.equal(pipeline.field(ci.job('gate'), 'if'), 'always()');
	assert.equal(ci.findStep('Judge the lane').file, LANE);
	assert.deepEqual(
		ci
			.real()
			.files()
			.map((entry) => entry.rel),
		[ENTRY, LANE, LANE_UNIT, LANE_GATE]
	);
	assert.equal(ci.real().locate('gate').file, LANE_GATE);
	assert.equal(ci.real().locateCaller('gate').file, LANE);
});

check('an inlined lane written back is the real files, and a change reaches its stage', () => {
	const ci = laneFixture();
	const real = ci.real().files();
	assert.deepEqual(pipeline.replaceLane(real, LANE, ci.file(LANE)), real);
	const moved = pipeline.replaceLane(
		real,
		LANE,
		ci.file(LANE).replace('        run: echo "$PLAN"', '        run: echo moved')
	);
	assert.ok(moved.find((entry) => entry.rel === LANE_GATE).text.includes('run: echo moved'));
	assert.equal(moved.find((entry) => entry.rel === LANE).text, LANE_TEXT);
	const reread = pipeline.inlinePipeline(moved).find((entry) => entry.rel === LANE).text;
	assert.equal(
		reread,
		ci.file(LANE).replace('        run: echo "$PLAN"', '        run: echo moved')
	);
	const renamed = pipeline.replaceLane(
		real,
		LANE,
		ci.file(LANE).replace("name: 'Verdict'", "name: 'Gate'")
	);
	assert.ok(
		renamed.find((entry) => entry.rel === LANE).text.includes("    name: 'Gate'\n    needs: [unit]")
	);
	assert.equal(renamed.find((entry) => entry.rel === LANE_GATE).text, LANE_GATE_TEXT);
});

check('an inlined lane leaves a step output named like an input untouched', () => {
	const read = '          GIVEN: ${{ steps.native-pac-inputs.outputs.toolchain }}\n';
	const ci = laneFixture({
		[LANE_UNIT]: edit(
			LANE_UNIT_TEXT,
			'          KEY: ${{ secrets.KEY }}\n',
			`          KEY: \${{ secrets.KEY }}\n${read}`
		)
	});
	assert.ok(ci.file(LANE).includes(read));
});

for (const [label, rel, from, to, pattern] of [
	[
		'a stage input the caller does not pass',
		LANE,
		'      plan: ${{ needs.unit.outputs.plan }}\n',
		'',
		/stage caller 'gate' must pass exactly the inputs/
	],
	[
		'an output read from a job that is not a need',
		LANE,
		'${{ needs.unit.outputs.plan }}',
		'${{ needs.other.outputs.plan }}',
		/must pass plan from the same output of one of its needs/
	],
	[
		'an output read under another name',
		LANE,
		'${{ needs.unit.outputs.plan }}',
		'${{ needs.unit.outputs.matrix }}',
		/must pass plan from the same output of one of its needs/
	],
	[
		'a forged needs context',
		LANE,
		'      predecessors: ${{ toJSON(needs) }}',
		"      predecessors: '{}'",
		/must pass predecessors: \$\{\{ toJSON\(needs\) \}\}/
	],
	[
		'a plan input handed in under another form',
		LANE,
		'      release: ${{ inputs.release }}\n    secrets:',
		'      release: true\n    secrets:',
		/must pass release: \$\{\{ inputs\.release \}\}, got true/
	],
	[
		'a renamed secret',
		LANE,
		'      KEY: ${{ secrets.KEY }}',
		'      KEY: ${{ secrets.OTHER }}',
		/must pass the lane's secret KEY as is/
	],
	[
		'a stage job that sets its own needs',
		LANE_GATE,
		"    name: 'Mandatory evidence'\n",
		"    name: 'Mandatory evidence'\n    needs: [unit]\n",
		/job 'gate' sets needs; its caller owns it/
	],
	[
		'a stage job that sets its own if',
		LANE_GATE,
		"    name: 'Mandatory evidence'\n",
		"    name: 'Mandatory evidence'\n    if: false\n",
		/job 'gate' sets if; its caller owns it/
	],
	[
		'an output the stage file does not re-export',
		LANE_UNIT,
		'      plan:\n        description: The plan\n        value: ${{ jobs.unit.outputs.plan }}\n',
		'      plan:\n        description: The plan\n        value: ${{ jobs.unit.outputs.other }}\n',
		/must re-export plan as is/
	],
	[
		'a stage that grants itself more',
		LANE_UNIT,
		'permissions:\n  contents: read\n',
		'permissions:\n  contents: write\n',
		/must grant exactly the lane's permissions/
	],
	[
		'a stage whose env differs',
		LANE_GATE,
		'  RELEASE: ${{ inputs.release }}',
		'  RELEASE: true',
		/must set the same env as every stage/
	],
	[
		'a caller that owns a stage key',
		LANE,
		"    name: 'Unit tests'\n",
		"    name: 'Unit tests'\n    strategy:\n      fail-fast: false\n",
		/stage caller 'unit' sets strategy; the stage job owns them/
	],
	[
		'a caller that hands every secret to its stage',
		LANE,
		'    secrets:\n      KEY: ${{ secrets.KEY }}\n',
		'    secrets: inherit\n',
		/stage caller 'unit' must list each of its secrets on its own line/
	],
	[
		'a stage with its own concurrency group',
		LANE_GATE,
		'permissions:\n  contents: read\n',
		'concurrency:\n  group: gate\npermissions:\n  contents: read\n',
		/sets name, on, concurrency, permissions, env; a stage sets only name, on, permissions and env/
	],
	[
		'a stage with another trigger',
		LANE_GATE,
		'  workflow_call:\n',
		'  workflow_call:\n  push:\n',
		/must be triggered by workflow_call alone/
	],
	[
		'a lane job that runs steps beside its stage callers',
		LANE,
		'  # Units first.\n',
		'  # Units first.\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo lint\n',
		/mixes stage callers with other jobs/
	]
]) {
	check(`the inlined lane refuses ${label}`, () => {
		const text = { [LANE]: LANE_TEXT, [LANE_UNIT]: LANE_UNIT_TEXT, [LANE_GATE]: LANE_GATE_TEXT }[
			rel
		];
		refuses(() => laneFixture({ [rel]: edit(text, from, to) }).files(), pattern);
	});
}

check('a missing step throws, in a job and across the pipeline', () => {
	const ci = fixture();
	refuses(() => pipeline.step(ci.job('test'), 'Missing'), /no step named 'Missing' in this job/);
	refuses(() => ci.findStep('Missing'), /no step named 'Missing' in the pipeline/);
});

check('a step name used twice throws, in a job and across the pipeline', () => {
	const twiceInJob = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'      - name: Judge\n',
			'      - name: Judge\n        run: echo one\n      - name: Judge\n'
		)
	});
	refuses(
		() => pipeline.step(twiceInJob.job('gate'), 'Judge'),
		/step 'Judge' appears 2 times in one job/
	);
	const twiceInPipeline = fixture({
		[BOX]: edit(BOX_TEXT, '      - name: Run tests', '      - name: Judge')
	});
	refuses(() => twiceInPipeline.findStep('Judge'), /step 'Judge' appears 2 times/);
});

check('a job key set twice throws', () => {
	const ci = fixture({
		[BOX]: edit(BOX_TEXT, '    if: always()\n', '    if: always()\n    if: false\n')
	});
	refuses(() => pipeline.field(ci.job('gate'), 'if'), /job key 'if' in one job appears 2 times/);
});

check('a missing, empty or job-less called workflow throws', () => {
	refuses(
		() => fixture({ [BOX]: null }).files(),
		/ci-box\.yml \(called from \.github\/workflows\/ci\.yml\) does not exist/
	);
	refuses(() => fixture({ [BOX]: '\n' }).files(), /ci-box\.yml \(called from .*\) is empty/);
	refuses(
		() => fixture({ [BOX]: 'name: Box\n' }).files(),
		/ci-box\.yml has no top-level jobs: block/
	);
	refuses(
		() =>
			fixture({
				[ENTRY]: edit(
					ENTRY_TEXT,
					'    uses: ./.github/workflows/ci-box.yml\n',
					'    runs-on: ubuntu-latest\n'
				)
			}).files(),
		/calls no reusable workflow/
	);
});

// ===============================================
// ===============================================
// ======= 3/ Layouts The Checks Cannot Read =====
// ===============================================
// ===============================================

check('a job whose keys sit at six spaces throws, even with a hidden continue-on-error', () => {
	const ci = fixture({ [BOX]: reindentJob(BOX_TEXT, 'test', ['      continue-on-error: true']) });
	refuses(
		() => ci.jobs(BOX),
		/job 'test' starts its keys at 6 spaces; job keys must sit at exactly 4/
	);
	refuses(() => ci.locate('gate'), /job 'test' starts its keys at 6 spaces/);
});

check('a job key at an odd column throws', () => {
	const ci = fixture({ [BOX]: edit(BOX_TEXT, '  gate:\n    needs:', '  gate:\n   needs:') });
	refuses(() => ci.jobs(BOX), /expected a job key at two spaces, got 'needs:'/);
});

check('a quoted or listed job-level key throws', () => {
	const quoted = fixture({
		[BOX]: edit(BOX_TEXT, '    if: always()\n', "    if: always()\n    'continue-on-error': true\n")
	});
	refuses(
		() => quoted.jobs(BOX),
		/job 'gate' has a job-level line the checks cannot read: ''continue-on-error': true'/
	);
	const listed = fixture({
		[BOX]: edit(BOX_TEXT, '    needs:\n      - test\n', '    needs:\n    - test\n')
	});
	refuses(
		() => listed.jobs(BOX),
		/job 'gate' has a job-level line the checks cannot read: '- test'/
	);
});

check('a job with no keys throws', () => {
	const ci = fixture({ [BOX]: edit(BOX_TEXT, '  gate:\n', '  empty:\n  gate:\n') });
	refuses(() => ci.jobs(BOX), /job 'empty' has no job-level key/);
});

check('a step whose keys sit at another column throws', () => {
	const wide = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'      - name: Run tests\n        if: ${{ !cancelled() }}\n        run: |\n          # a shell comment inside the script\n          echo test\n',
			'      -   name: Run tests\n          if: false\n          run: echo test\n'
		)
	});
	refuses(
		() => pipeline.steps(wide.job('test')),
		/a step must start as '- key:' at six spaces, got '-   name: Run tests'/
	);
	const bare = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'      - name: Judge\n        run: echo judge\n',
			'      -\n        name: Judge\n        run: echo judge\n'
		)
	});
	refuses(
		() => pipeline.steps(bare.job('gate')),
		/a step must start as '- key:' at six spaces, got '-'/
	);
	const shallow = fixture({
		[BOX]: edit(BOX_TEXT, '        run: echo judge\n', '       run: echo judge\n')
	});
	refuses(() => pipeline.steps(shallow.job('gate')), /a steps line at 7 spaces/);
});

check('a quoted step key throws', () => {
	const ci = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'        run: echo judge\n',
			"        run: echo judge\n        'continue-on-error': true\n"
		)
	});
	refuses(
		() => pipeline.steps(ci.job('gate')),
		/a step line the checks cannot read: ''continue-on-error': true'/
	);
});

check('a step key set twice throws', () => {
	const ci = fixture({
		[BOX]: edit(
			BOX_TEXT,
			'        run: echo judge\n',
			'        run: echo judge\n        if: false\n        if: true\n'
		)
	});
	refuses(
		() => pipeline.stepField(pipeline.step(ci.job('gate'), 'Judge'), 'if'),
		/step key 'if' in one step appears 2 times/
	);
});

// ========================================
// ========================================
// ======= 4/ The Real Pipeline ===========
// ========================================
// ========================================

check('the real pipeline parses under the enforced layout', () => {
	let jobCount = 0;
	let stepCount = 0;
	for (const entry of pipeline.files()) {
		for (const candidate of pipeline.jobs(entry.rel)) {
			jobCount++;
			stepCount += pipeline.steps(candidate.body).length;
		}
	}
	assert.ok(jobCount >= MIN_REAL_JOBS, `parsed only ${jobCount} job(s) (floor ${MIN_REAL_JOBS})`);
	assert.ok(
		stepCount >= MIN_REAL_STEPS,
		`parsed only ${stepCount} step(s) (floor ${MIN_REAL_STEPS})`
	);
});

check('the review mutation of the real macOS box is refused', () => {
	const rel = '.github/workflows/ci-macos.yml';
	const mutated = reindentJob(pipeline.file(rel), 'test-hs', ['      continue-on-error: true']);
	assert.notEqual(mutated, pipeline.file(rel));
	refuses(() => pipeline.jobsOfText(mutated, rel), /job 'test-hs' starts its keys at 6 spaces/);
});

for (const root of roots) fs.rmSync(root, { recursive: true, force: true });

if (failures.length > 0) {
	console.error('[FAIL] the CI pipeline loader accepts a layout it cannot read:');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log('[OK] the CI pipeline loader throws on every missing lookup and unreadable layout.');
