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
