// tools/test/validate-ahk-suite-manifest.cjs

/**
 * Validates the canonical AHK TAP transcript as an exact execution manifest.
 * A successful process or footer is insufficient: every planned ordinal must
 * have one RUNNING line and one terminal result with matching totals.
 */

'use strict';

const fs = require('node:fs');

function validateAhkSuiteManifest(source) {
	const lines = String(source).replace(/^\uFEFF/, '').split(/\r?\n/).filter((line) => line !== '');
	const plans = [];
	const footers = [];
	const running = new Map();
	const results = new Map();
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
			results.set(index, { status: match[1], detail: match[3] });
			continue;
		}
		match = /^# (\d+) passed, (\d+) failed\.$/.exec(line);
		if (match) footers.push({ passed: Number(match[1]), failed: Number(match[2]) });
	}

	if (plans.length !== 1) errors.push(`expected one TAP plan, found ${plans.length}`);
	if (footers.length !== 1) errors.push(`expected one terminal footer, found ${footers.length}`);
	const planned = plans.length === 1 ? plans[0] : 0;
	for (let index = 1; index <= planned; index += 1) {
		const started = running.get(index);
		if (!started) errors.push(`planned test ${index}/${planned} never started`);
		else if (started.total !== planned) errors.push(`RUNNING ${index} declared total ${started.total}, expected ${planned}`);
		if (!results.has(index)) errors.push(`planned test ${index}/${planned} has no terminal result`);
	}
	for (const index of running.keys()) {
		if (index < 1 || index > planned) errors.push(`RUNNING ordinal ${index} is outside plan 1..${planned}`);
	}
	for (const index of results.keys()) {
		if (index < 1 || index > planned) errors.push(`result ordinal ${index} is outside plan 1..${planned}`);
	}

	const observedPassed = [...results.values()].filter((entry) => entry.status === 'ok').length;
	const observedFailed = [...results.values()].filter((entry) => entry.status === 'not ok').length;
	if (footers.length === 1) {
		const footer = footers[0];
		if (footer.passed !== observedPassed || footer.failed !== observedFailed) {
			errors.push(`footer ${footer.passed}/${footer.failed} disagrees with results ${observedPassed}/${observedFailed}`);
		}
		if (footer.passed + footer.failed !== planned) {
			errors.push(`footer covers ${footer.passed + footer.failed} tests, expected ${planned}`);
		}
	}

	const executed = [...results.entries()].sort((a, b) => a[0] - b[0]).map(([index, result]) => ({
		index,
		name: running.has(index) ? running.get(index).name : '',
		status: result.status,
	}));
	return { complete: errors.length === 0, planned, executed_count: results.size, passed: observedPassed, failed: observedFailed, executed, errors };
}

function main(argv) {
	const inputIndex = argv.indexOf('--input');
	const jsonIndex = argv.indexOf('--json');
	if (inputIndex < 0 || !argv[inputIndex + 1]) {
		console.error('Usage: node validate-ahk-suite-manifest.cjs --input <tap-file> [--json <manifest-file>]');
		return 2;
	}
	const input = argv[inputIndex + 1];
	let source = '';
	try {
		source = fs.readFileSync(input, 'utf8');
	} catch (error) {
		console.error(`AHK execution manifest unavailable: ${error.message}`);
		return 2;
	}
	const manifest = validateAhkSuiteManifest(source);
	if (jsonIndex >= 0 && argv[jsonIndex + 1]) {
		fs.writeFileSync(argv[jsonIndex + 1], `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
	}
	if (!manifest.complete) {
		console.error(`AHK execution manifest incomplete (${manifest.executed_count}/${manifest.planned}).`);
		for (const error of manifest.errors.slice(0, 20)) console.error(`  - ${error}`);
		return 1;
	}
	console.log(`AHK execution manifest complete: ${manifest.executed_count}/${manifest.planned} terminal results.`);
	return 0;
}

module.exports = { validateAhkSuiteManifest };

if (require.main === module) process.exit(main(process.argv.slice(2)));
