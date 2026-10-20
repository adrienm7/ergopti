// tools/test/run-js-suite.cjs

/**
 * ==============================================================================
 * MODULE: JS Validation Suite Runner
 * DESCRIPTION:
 * Single local entry point for the JavaScript/Node validation layer of CI. It
 * runs the same checks the GitHub "Validate ·" jobs run, in one command, and
 * prints a legible pass/fail summary so a contributor can reproduce and read a
 * CI failure without scrolling a multi-megabyte log or guessing which of a dozen
 * npm scripts maps to the red check.
 *
 * FEATURES & RATIONALE:
 * 1. One command: "npm run test:js" == the CI JS validation, so local and CI
 *    outcomes match. Pass --full to also run the slow property + mutation tests.
 * 2. Legible failures: each failing check prints the exact command to re-run it
 *    in isolation plus bounded opening and closing output and process status.
 * 3. Fail-fast aggregate: exits non-zero if any check fails, with a one-line
 *    summary CI annotators can surface.
 * ==============================================================================
 */

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('node:fs');
const os = require('node:os');
const { performance } = require('node:perf_hooks');
const { loadInventory, selectFeature } = require('./lib/js-feature-inventory.cjs');
const { spawnPlan } = require('./lib/js-suite-spawn.cjs');
const { SKIP_PREFIX } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
let FULL = false;
let FEATURE = null;
let LIST_FEATURES = false;
const arguments_ = process.argv.slice(2);
for (let index = 0; index < arguments_.length; index++) {
	const argument = arguments_[index];
	if (argument === '--full' && !FULL) FULL = true;
	else if (argument === '--list-features' && !LIST_FEATURES) LIST_FEATURES = true;
	else if ((argument === '--feature' || argument.startsWith('--feature=')) && FEATURE === null) {
		FEATURE = argument === '--feature' ? arguments_[++index] : argument.slice('--feature='.length);
		if (typeof FEATURE !== 'string' || FEATURE.length === 0)
			throw new Error('A nonempty --feature selector is required.');
	} else throw new Error(`Unknown or duplicate JS suite argument: ${argument}`);
}
if ((FULL && FEATURE !== null) || (LIST_FEATURES && (FULL || FEATURE !== null)))
	throw new Error('--feature, --list-features and --full are mutually exclusive.');

const inventory = loadInventory(ROOT);
const CHECKS = selectFeature(inventory, FEATURE, process.platform);
if (LIST_FEATURES) {
	console.log(
		JSON.stringify({
			features: inventory.features,
			inventory_sha256: inventory.digest,
			platform: process.platform,
			planned_count: CHECKS.length
		})
	);
	process.exit(0);
}

const SLOW_CHECKS = [
	{
		name: 'property-based tests (fast-check)',
		cmd: 'npm',
		args: ['run', '--silent', 'test:properties'],
		repro: 'npm run test:properties'
	},
	{
		name: 'mutation tests (Stryker)',
		cmd: 'npm',
		args: ['run', '--silent', 'test:mutation'],
		repro: 'npm run test:mutation'
	}
];

const checks = FULL
	? [
			...CHECKS,
			...SLOW_CHECKS.map((check, index) => ({
				...check,
				id: index === 0 ? 'slow-properties' : 'slow-mutation',
				ordinal: inventory.checks.length + index + 1
			}))
		]
	: CHECKS;
const startedAt = performance.now();
const timingDirectory = fs.mkdtempSync(
	path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'ergopti-js-suite-')
);
const timingPath = path.join(timingDirectory, 'timings.ndjson');
const milliseconds = (value) => Math.round(value * 1000) / 1000;
// Keep spawnSync's existing default bound explicit in each captured-output receipt.
const MAX_CAPTURE_BYTES = 1024 * 1024;

/** Append before proceeding so interruption retains completed work and the active check. */
function recordTiming(record) {
	fs.appendFileSync(timingPath, JSON.stringify(record) + '\n', { encoding: 'utf8', mode: 0o600 });
}

recordTiming({
	type: 'suite',
	schema_version: 1,
	suite: 'js',
	mode: FULL ? 'full' : FEATURE === null ? 'default' : 'feature',
	feature: FEATURE,
	inventory_sha256: inventory.digest,
	planned_count: checks.length,
	platform: process.platform,
	architecture: process.arch,
	node_version: process.version,
	// This identifies a CI invocation, not a claim that a local working tree is clean.
	ci_source_sha: /^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA || '')
		? process.env.GITHUB_SHA
		: null,
	ci_run_id: /^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ID || '')
		? process.env.GITHUB_RUN_ID
		: null,
	ci_run_attempt: /^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ATTEMPT || '')
		? process.env.GITHUB_RUN_ATTEMPT
		: null
});

console.log('\nErgopti+ JS validation suite' + (FULL ? ' (full)' : '') + '\n' + '='.repeat(50));
console.log(`Timing journal: ${timingPath}\n`);

const results = [];
for (const check of checks) {
	const ordinal = results.length + 1;
	recordTiming({
		type: 'start',
		ordinal,
		check_id: check.id,
		global_ordinal: check.ordinal,
		name: check.name
	});
	console.log(`  RUNNING ${ordinal}/${checks.length} — ${check.name}`);
	const checkStartedAt = performance.now();
	let r;
	try {
		const plan = spawnPlan(check, process.execPath);
		r = spawnSync(plan.command, plan.args, {
			cwd: ROOT,
			encoding: 'utf8',
			maxBuffer: MAX_CAPTURE_BYTES,
			shell: plan.shell
		});
	} catch (error) {
		r = { status: null, error, spawnThrew: true, stderr: error?.stack || String(error) };
	}
	const durationMs = milliseconds(performance.now() - checkStartedAt);
	const ok = r.status === 0 && !r.error && !r.signal;
	recordTiming({
		type: 'result',
		ordinal,
		check_id: check.id,
		global_ordinal: check.ordinal,
		name: check.name,
		reproduce: check.repro,
		status: ok ? 'PASS' : 'FAIL',
		exit_code: r.status ?? null,
		signal: r.signal ?? null,
		error_code: r.error?.code ?? null,
		duration_ms: durationMs
	});
	console.log(`  ${ok ? 'PASS' : 'FAIL'} ${ordinal}/${checks.length} — ${check.name}`);
	// A local host may lack a capability a case needs; name it so a PASS here
	// never reads as having executed that case.
	const notExecuted = String(r.stdout || '')
		.split(/\r?\n/)
		.filter((line) => line.startsWith(SKIP_PREFIX));
	for (const line of notExecuted) console.log(`    ${line}`);
	console.log(`    duration: ${durationMs.toFixed(3)} ms (${ordinal}/${checks.length})`);
	const result = {
		...check,
		ok,
		durationMs,
		status: r.status,
		signal: r.signal,
		errorCode: r.error?.code,
		spawnError: Boolean(r.error),
		spawnThrew: r.spawnThrew === true,
		notExecuted,
		stdout: r.stdout || '',
		stderr: r.stderr || ''
	};
	results.push(result);
	if (!ok) reportFailure(result, ordinal);
}

const failed = results.filter((r) => !r.ok);
const notExecuted = results.filter((r) => r.notExecuted.length > 0);
recordTiming({
	type: 'complete',
	executed_count: results.length,
	passed: results.length - failed.length,
	failed: failed.length,
	child_duration_ms: milliseconds(results.reduce((total, result) => total + result.durationMs, 0)),
	duration_ms: milliseconds(performance.now() - startedAt)
});

console.log('\nSlowest JS checks (child wall time):');
for (const result of [...results].sort((a, b) => b.durationMs - a.durationMs).slice(0, 10)) {
	console.log(`  ${result.durationMs.toFixed(3)} ms — ${result.name}`);
	console.log(`    reproduce: ${result.repro}`);
}

console.log('\n' + '-'.repeat(50));
if (notExecuted.length > 0) {
	const cases = notExecuted.reduce((total, r) => total + r.notExecuted.length, 0);
	console.log(`${cases} case(s) in ${notExecuted.length} check(s) were NOT EXECUTED on this host:`);
	for (const r of notExecuted) console.log(`  - ${r.name} (${r.repro})`);
	console.log('');
}
if (failed.length === 0) {
	console.log(`✅  All ${results.length} JS check(s) passed.`);
	if (!FULL)
		console.log('   (run "npm run test:js -- --full" to also run property + mutation tests)');
	console.log('');
	process.exit(0);
}

console.log(`❌  ${failed.length}/${results.length} JS check(s) FAILED:\n`);
for (const f of failed) {
	console.log(`  ✗ ${f.name}`);
	console.log(`    reproduce: ${f.repro}`);
}
process.exit(1);

/** Report the bounded failure before starting another potentially slow check. */
function reportFailure(f, ordinal) {
	if (process.env?.GITHUB_ACTIONS === 'true') {
		// Check names remain available through the API when archived log access
		// fails. Never copy command output, URLs or native receipts here.
		const name = f.name.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
		console.log(`::error title=Shared validation check failed::${name}`);
	}
	console.log(`  ✗ ${f.name}`);
	console.log(`    reproduce: ${f.repro}`);
	console.log(
		`    process: status=${f.status ?? 'none'} signal=${f.signal ?? 'none'} error=${f.errorCode ?? 'none'}`
	);
	// Stack tails often omit the actual error. Keep both ends without dumping
	// unbounded fixture output or silently hiding that a middle was removed.
	// Summarize streams separately: verbose stdout must not hide stderr's head.
	for (const stream of ['stdout', 'stderr']) {
		if (!f[stream].trim()) continue;
		const lines = f[stream].trim().split(/\r?\n/);
		const edgeLines = 12;
		const excerpt =
			lines.length <= edgeLines * 2
				? lines
				: [
						...lines.slice(0, edgeLines),
						`... ${lines.length - edgeLines * 2} lines omitted ...`,
						...lines.slice(-edgeLines)
					];
		console.log(`    ${stream}:\n    ` + excerpt.join('\n    ') + '\n');
	}
	retainFailure(f, ordinal);
}

/** Preserve returned text separately from the strict timing schema and bounded console preview. */
function retainFailure(f, ordinal) {
	const directory = path.join(timingDirectory, 'failures', f.id);
	fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
	const streams = {};
	for (const stream of ['stdout', 'stderr']) {
		const file = stream + '.txt';
		const destination = path.join(directory, file);
		fs.writeFileSync(destination, f[stream], { encoding: 'utf8', flag: 'wx', mode: 0o600 });
		streams[stream] = { file, captured_utf8_bytes: fs.statSync(destination).size };
	}
	// Publish metadata last: a failed write must not advertise a complete retained capture.
	const receipt = {
		schema_version: 1,
		ordinal,
		check_id: f.id,
		global_ordinal: f.ordinal,
		name: f.name,
		reproduce: f.repro,
		status: 'FAIL',
		exit_code: f.status ?? null,
		signal: f.signal ?? null,
		error_code: f.errorCode ?? null,
		capture: {
			encoding: 'utf8',
			max_buffer_bytes: MAX_CAPTURE_BYTES,
			spawn_error: f.spawnError,
			spawn_threw: f.spawnThrew,
			child_output_completeness: 'unknown',
			...streams
		}
	};
	fs.writeFileSync(path.join(directory, 'receipt.json'), JSON.stringify(receipt) + '\n', {
		encoding: 'utf8',
		flag: 'wx',
		mode: 0o600
	});
	console.log('    Captured failure output: ' + directory);
	console.log(
		'    Retained returned UTF-8 text or thrown spawn diagnostics only; maxBuffer=' +
			MAX_CAPTURE_BYTES +
			' bytes. Uncaptured or child-truncated output is unknown.'
	);
}
