// tools/test/test-desktop-ci-evidence.cjs

/**
 * ==============================================================================
 * MODULE: Desktop CI Verdict Regression Tests
 * DESCRIPTION:
 * Rejects missing or failed launch observations, incorrect commits and incomplete
 * matrices. Pins the parallel shared-core gate and the published-byte boundary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { verify } = require('./desktop-ci-evidence.cjs');
const pipeline = require('./ci-pipeline.cjs');

for (const platform of ['windows', 'macos']) {
	for (const release of [false, true]) {
		const jobs =
			platform === 'windows'
				? ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows']
				: ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
		const runners =
			platform === 'windows'
				? ['windows-latest']
				: release
					? ['macos-15', 'macos-15-intel']
					: ['macos-15'];
		const scenarios = platform === 'windows' ? ['startup'] : ['clean', 'upgraded'];
		const state = {
			platform,
			release,
			scenarios,
			sha: 'a'.repeat(40),
			needs: Object.fromEntries(jobs.map((job) => [job, { result: 'success' }])),
			evidence: runners.flatMap((runner) =>
				scenarios.map((scenario) => ({
					schema_version: 1,
					platform,
					runner,
					scenario,
					sha: 'a'.repeat(40),
					package_sha256: 'b'.repeat(64),
					failures: [],
					marker_seen: true,
					crashed_early: false
				}))
			)
		};
		verify(state);
		const rejects = (mutate) => {
			const changed = structuredClone(state);
			mutate(changed);
			assert.throws(() => verify(changed));
		};
		for (const job of jobs) {
			for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
				rejects((value) => {
					value.needs[job].result = status;
				});
			}
			rejects((value) => {
				delete value.needs[job];
			});
		}
		rejects((value) => value.evidence.pop());
		rejects((value) => value.evidence.push(value.evidence[0]));
		rejects((value) => {
			value.evidence[0].sha = 'c'.repeat(40);
		});
		rejects((value) => {
			value.evidence[0].failures = ['crash'];
		});
		rejects((value) => {
			value.evidence[0].scenario = 'unknown';
		});
		rejects((value) => {
			value.evidence[0].package_sha256 = '';
		});
		if (platform === 'windows') {
			rejects((value) => {
				value.evidence[0].marker_seen = false;
			});
			rejects((value) => {
				value.evidence[0].crashed_early = true;
			});
		} else {
			rejects((value) => {
				value.evidence[0].package_sha256 = 'c'.repeat(64);
			});
		}
	}
}

/** Pins a fresh shallow checkout and the exact independently gated core suites. */
function checkCore(body) {
	assert.deepEqual(pipeline.needsOf(body), ['validate']);
	assert.equal(pipeline.field(body, 'if'), null);
	assert.match(body, /^      fail-fast: false$/m);
	assert.ok(
		body.includes(
			`        suite: \${{ fromJSON(github.ref == 'refs/heads/main' && '["js","properties","mutation"]' || '["js","properties"]') }}`
		)
	);
	const steps = pipeline.steps(body);
	const checkout = steps.filter(
		(step) => pipeline.stepField(step.body, 'uses') === 'actions/checkout@v4'
	);
	assert.equal(checkout.length, 1);
	assert.equal(pipeline.stepField(checkout[0].body, 'with'), null);
	assert.doesNotMatch(body, /\bgit (?:fetch|pull|clone)\b/);
	assert.equal(
		pipeline.stepField(pipeline.step(body, 'Run shared validation suite'), 'run'),
		'npm run test:${{ matrix.suite }}'
	);
	assert.ok(steps.some((step) => pipeline.stepField(step.body, 'run') === 'npm ci'));
	assert.match(body, /sudo apt-get install -y lua5\.4 libxml2-utils/);
	for (const [name, command] of [
		['Install shared UI browsers', 'npx playwright install --with-deps chromium webkit'],
		['Test shared layer editor rendering', 'npm run test:browser:layer-editor']
	]) {
		const step = pipeline.step(body, name);
		assert.equal(pipeline.stepField(step, 'if'), "matrix.suite == 'js'");
		assert.equal(pipeline.stepField(step, 'run'), command);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	}
}

const core = pipeline.job('core');
checkCore(core);
for (const [from, to] of [
	['refs/heads/main', 'refs/heads/never'],
	['"js","properties","mutation"', '"js","properties"'],
	['"js","properties"', '"js"'],
	['fail-fast: false', 'fail-fast: true'],
	['needs: [validate]', 'needs: [macos]'],
	['run: npm run test:${{ matrix.suite }}', 'run: npm run test:${{ matrix.suite }} -- --only lint'],
	['run: npm run test:browser:layer-editor', 'run: echo skipped browser gate'],
	['npx playwright install --with-deps chromium webkit', 'npx playwright install chromium'],
	["if: matrix.suite == 'js'", "if: matrix.suite == 'never'"],
	[
		'- uses: actions/checkout@v4',
		'- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0'
	]
])
	assert.throws(() => checkCore(core.replace(from, to)), from);

for (const [job, platform] of [
	['macos-ok', 'macos'],
	['windows-ok', 'windows']
]) {
	assert.ok(
		pipeline.job(job).includes(`node tools/test/desktop-ci-evidence.cjs verify ${platform}`)
	);
}
for (const [job, name] of [
	['launch', 'Retain launch evidence'],
	['launch-windows', 'Upload mandatory launch evidence']
]) {
	const upload = pipeline.step(pipeline.job(job), name);
	assert.match(upload, /overwrite: true/);
	assert.doesNotMatch(upload, /github\.run_attempt/);
}
const launch = pipeline.job('launch-windows');
assert.match(launch, /name: assets-windows/);
assert.match(launch, /\$env:RUNNER_TEMP\\package\\ergopti_plus\\windows\\ErgoptiPlus\.exe/);
assert.doesNotMatch(launch, /build_static_bundle|Ahk2Exe/);
const profile = "${{ inputs.release && 'release' || 'ci' }}";
assert.ok(
	pipeline
		.step(pipeline.job('launch'), 'Retain launch evidence')
		.includes(`name: launch-gate-${profile}-`)
);
assert.ok(pipeline.job('macos-ok').includes(`pattern: launch-gate-${profile}-*`));
console.log(
	'[OK] Desktop verdicts reject incomplete launches; shared core gates run independently.'
);
