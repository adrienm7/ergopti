// tools/test/validate-ahk-suite-manifest.cjs

/**
 * Validates the canonical AHK TAP transcript as an exact execution manifest.
 * A successful process or footer is insufficient: every planned ordinal must
 * have one RUNNING line and one terminal result with matching names and totals.
 * Timing is optional for legacy transcripts, but must cover every case once
 * any duration comment is present. A case the host could not run is an ok line
 * carrying NOT_EXECUTED_MARKER: it is counted apart and never as a pass.
 */

'use strict';

const fs = require('node:fs');

// test_framework.ahk (TEST_NOT_EXECUTED_MARKER) and report.cjs share this spelling.
const NOT_EXECUTED_MARKER = ' # SKIP NOT EXECUTED: ';

function validateAhkSuiteManifest(source) {
	const lines = String(source)
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/)
		.filter((line) => line !== '');
	const plans = [];
	const footers = [];
	const running = new Map();
	const results = new Map();
	const durations = new Map();
	let hasTiming = false;
	const errors = [];

	for (const line of lines) {
		let match = /^1\.\.(\d+)$/.exec(line);
		if (match) {
			plans.push(Number(match[1]));
			continue;
		}
		match = /^RUNNING (\d+)\/(\d+) - (.+)$/.exec(line);
		if (match) {
			const index = Number(match[1]);
			if (running.has(index)) errors.push(`duplicate RUNNING ordinal ${index}`);
			running.set(index, { total: Number(match[2]), name: match[3] });
			continue;
		}
		match = /^(ok|not ok) (\d+) - (.+)$/.exec(line);
		if (match) {
			const index = Number(match[2]);
			if (results.has(index)) errors.push(`duplicate result ordinal ${index}`);
			const marker = match[1] === 'ok' ? match[3].lastIndexOf(NOT_EXECUTED_MARKER) : -1;
			if (marker >= 0) {
				const reason = match[3].slice(marker + NOT_EXECUTED_MARKER.length);
				if (reason.trim() === '') errors.push(`not-executed result ${index} has no reason`);
				results.set(index, { status: 'not executed', detail: match[3].slice(0, marker), reason });
			} else results.set(index, { status: match[1], detail: match[3] });
			continue;
		}
		if (/^# duration_ms(?:\s|$)/.test(line)) {
			hasTiming = true;
			match = /^# duration_ms (\d+) (\d+(?:\.\d+)?)$/.exec(line);
			if (!match || !Number.isSafeInteger(Number(match[1])) || !Number.isFinite(Number(match[2]))) {
				errors.push(`malformed duration comment: ${line}`);
				continue;
			}
			const index = Number(match[1]);
			if (durations.has(index)) errors.push(`duplicate duration ordinal ${index}`);
			if (!results.has(index))
				errors.push(`duration ordinal ${index} precedes its terminal result`);
			durations.set(index, Number(match[2]));
			continue;
		}
		match = /^# (\d+) passed, (\d+) failed(?:, ([1-9]\d*) not executed)?\.$/.exec(line);
		if (match)
			footers.push({
				passed: Number(match[1]),
				failed: Number(match[2]),
				notExecuted: match[3] === undefined ? 0 : Number(match[3])
			});
	}

	if (plans.length !== 1) errors.push(`expected one TAP plan, found ${plans.length}`);
	if (footers.length !== 1) errors.push(`expected one terminal footer, found ${footers.length}`);
	const planned = plans.length === 1 ? plans[0] : 0;
	for (let index = 1; index <= planned; index += 1) {
		const started = running.get(index);
		if (!started) errors.push(`planned test ${index}/${planned} never started`);
		else if (started.total !== planned)
			errors.push(`RUNNING ${index} declared total ${started.total}, expected ${planned}`);
		if (!results.has(index)) errors.push(`planned test ${index}/${planned} has no terminal result`);
		else if (started) {
			const result = results.get(index);
			// Failure diagnostics follow the full name. Splitting on the delimiter
			// would truncate legitimate names that contain the same punctuation.
			const matchesName =
				result.detail === started.name ||
				(result.status === 'not ok' && result.detail.startsWith(`${started.name} — `));
			if (!matchesName)
				errors.push(
					`result ordinal ${index} does not match RUNNING name ${JSON.stringify(started.name)}`
				);
		}
		if (hasTiming && !durations.has(index))
			errors.push(`planned test ${index}/${planned} has no duration`);
	}
	for (const index of running.keys()) {
		if (index < 1 || index > planned)
			errors.push(`RUNNING ordinal ${index} is outside plan 1..${planned}`);
	}
	for (const index of results.keys()) {
		if (index < 1 || index > planned)
			errors.push(`result ordinal ${index} is outside plan 1..${planned}`);
	}
	for (const index of durations.keys()) {
		if (index < 1 || index > planned)
			errors.push(`duration ordinal ${index} is outside plan 1..${planned}`);
	}

	const observedPassed = [...results.values()].filter((entry) => entry.status === 'ok').length;
	const observedFailed = [...results.values()].filter((entry) => entry.status === 'not ok').length;
	const notExecuted = [...results.entries()]
		.filter(([, entry]) => entry.status === 'not executed')
		.sort((a, b) => a[0] - b[0])
		.map(([index, entry]) => ({ index, name: entry.detail, reason: entry.reason }));
	if (footers.length === 1) {
		const footer = footers[0];
		if (
			footer.passed !== observedPassed ||
			footer.failed !== observedFailed ||
			footer.notExecuted !== notExecuted.length
		) {
			errors.push(
				`footer ${footer.passed}/${footer.failed}/${footer.notExecuted} disagrees with results ${observedPassed}/${observedFailed}/${notExecuted.length}`
			);
		}
		const covered = footer.passed + footer.failed + footer.notExecuted;
		if (covered !== planned) errors.push(`footer covers ${covered} tests, expected ${planned}`);
	}

	const executed = [...results.entries()]
		.sort((a, b) => a[0] - b[0])
		.map(([index, result]) => ({
			index,
			name: running.has(index) ? running.get(index).name : '',
			status: result.status,
			duration_ms: durations.has(index) ? durations.get(index) : null
		}));
	return {
		complete: errors.length === 0,
		planned,
		executed_count: results.size,
		timed_count: durations.size,
		passed: observedPassed,
		failed: observedFailed,
		not_executed: notExecuted.length,
		not_executed_cases: notExecuted,
		executed,
		errors
	};
}

/** Emits readable local errors and escaped GitHub annotations in hosted CI. */
function manifestError(message) {
	if (process.env.GITHUB_ACTIONS === 'true') {
		const escaped = String(message)
			.replaceAll('%', '%25')
			.replaceAll('\r', '%0D')
			.replaceAll('\n', '%0A');
		// PowerShell may decorate native stderr as an ErrorRecord. Workflow
		// commands must use stdout so their leading delimiter stays intact.
		console.log(`::error::${escaped}`);
	}
	console.error(message);
}

function main(argv) {
	const inputIndex = argv.indexOf('--input');
	const jsonIndex = argv.indexOf('--json');
	if (inputIndex < 0 || !argv[inputIndex + 1]) {
		console.error(
			'Usage: node validate-ahk-suite-manifest.cjs --input <tap-file> [--json <manifest-file>]'
		);
		return 2;
	}
	const input = argv[inputIndex + 1];
	let source = '';
	try {
		source = fs.readFileSync(input, 'utf8');
	} catch (error) {
		manifestError(`AHK execution manifest unavailable: ${error.message}`);
		return 2;
	}
	const manifest = validateAhkSuiteManifest(source);
	if (jsonIndex >= 0 && argv[jsonIndex + 1]) {
		fs.writeFileSync(argv[jsonIndex + 1], `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
	}
	if (!manifest.complete) {
		manifestError(
			`AHK execution manifest incomplete (${manifest.executed_count}/${manifest.planned}).`
		);
		for (const error of manifest.errors.slice(0, 20)) manifestError(`  - ${error}`);
		return 1;
	}
	console.log(
		`AHK execution manifest complete: ${manifest.executed_count}/${manifest.planned} terminal results.`
	);
	if (manifest.not_executed > 0) {
		// Loud, and never folded into the pass count: the case did not run here.
		console.log(`AHK cases NOT EXECUTED on this host (not passed): ${manifest.not_executed}`);
		for (const entry of manifest.not_executed_cases) {
			const text = `${entry.name}: ${entry.reason}`;
			if (process.env.GITHUB_ACTIONS === 'true')
				console.log(
					`::warning title=AHK case NOT EXECUTED::${text.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')}`
				);
			console.log(`  - NOT EXECUTED ${entry.index}: ${text}`);
		}
	}
	return 0;
}

module.exports = { validateAhkSuiteManifest, NOT_EXECUTED_MARKER };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
