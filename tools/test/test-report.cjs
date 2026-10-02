// tools/test/test-report.cjs

/**
 * ==============================================================================
 * MODULE: report.cjs parser self-test
 * DESCRIPTION:
 * Exercises report.cjs's format-agnostic parseResults against representative TAP
 * (AHK run_all.ahk) and Lua-runner output, so the unified reporter cannot
 * silently miscount or miss failures (which would let a red CI run look green).
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parseResults, formatCount } = require('./report.cjs');

let checks = 0;
function check(label, cond) {
	assert.ok(cond, label);
	checks++;
}

// --- TAP, all green ---
let r = parseResults(['ok 1 - alpha', 'ok 2 - beta', '1..2', '# 2 passed, 0 failed'].join('\n'));
check('tap pass: format', r.format === 'tap');
check('tap pass: counts', r.passed === 2 && r.failed === 0);
check('tap pass: no failures', r.failures.length === 0);

// --- TAP, one failure (with diagnostic tail) ---
r = parseResults(
	['ok 1 - alpha', 'not ok 2 - beta gamma - boom expected', '# 1 passed, 1 failed'].join('\n')
);
check('tap fail: counts', r.passed === 1 && r.failed === 1);
check(
	'tap fail: failure captured',
	r.failures.length === 1 && r.failures[0] === 'beta gamma - boom expected'
);

// --- Lua, all green ---
r = parseResults(
	[
		'  ok   alpha',
		'  ok   beta',
		'Passed tests:  2',
		'Failed tests:  0',
		'[OK] All Lua unit tests passed.'
	].join('\n')
);
check('lua pass: format', r.format === 'lua');
check('lua pass: counts', r.passed === 2 && r.failed === 0);
check('lua pass: no failures', r.failures.length === 0);

// --- Lua, one failure (inline FAIL + DETAILED FAILURES duplicate must dedupe) ---
r = parseResults(
	[
		'  ok   alpha',
		'  FAIL beta gamma — assertion failed: x',
		'Passed tests:  1',
		'Failed tests:  1',
		'--- DETAILED FAILURES ---',
		'[1] beta gamma'
	].join('\n')
);
check('lua fail: counts', r.passed === 1 && r.failed === 1);
check(
	'lua fail: single deduped failure',
	r.failures.length === 1 && r.failures[0] === 'beta gamma'
);

// Counts shown to people group their thousands with a narrow no-break space.
check('format: small count unchanged', formatCount(0) === '0' && formatCount(999) === '999');
check(
	'format: thousands grouped',
	formatCount(7269) === '7\u202F269' && formatCount(11507) === '11\u202F507'
);
check('format: millions grouped', formatCount(1234567) === '1\u202F234\u202F567');

// Actual workflow commands must retain every cause when GitHub accepts only
// ten error annotations from a step. The notice is independent of that quota.
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-reporter-annotations-'));
try {
	const runner = path.join(fixture, 'runner.cjs');
	const transcript = path.join(fixture, 'tap.txt');
	const receipt = path.join(fixture, 'receipt.json');
	const summary = path.join(fixture, 'summary.md');
	fs.writeFileSync(
		runner,
		"const fs = require('node:fs'); process.stdout.write(fs.readFileSync(process.argv[2], 'utf8')); process.exitCode = Number(process.argv[3]);\n"
	);
	function runReporter(failures, exitCode) {
		const tap =
			failures.map((failure, index) => `not ok ${index + 1} - ${failure}`).join('\n') +
			`\n# 7738 passed, ${failures.length} failed\n`;
		fs.writeFileSync(transcript, tap);
		fs.writeFileSync(summary, '');
		const result = spawnSync(
			process.execPath,
			[
				path.resolve(__dirname, 'report.cjs'),
				'--name',
				'windows-ahk',
				'--json',
				receipt,
				'--',
				process.execPath,
				runner,
				transcript,
				String(exitCode)
			],
			{
				encoding: 'utf8',
				env: { ...process.env, GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: summary }
			}
		);
		assert.ifError(result.error);
		check(
			'actual reporter streams the original runner bytes unchanged',
			result.stdout.startsWith(tap)
		);
		check('actual reporter preserves its native process status', result.status === exitCode);
		const json = JSON.parse(fs.readFileSync(receipt, 'utf8'));
		assert.deepStrictEqual(json.failures, failures);
		check(
			'actual reporter preserves exact JSON counts',
			json.passed === 7738 && json.failed === failures.length && json.exit_code === exitCode
		);
		return result.stdout.split('\n');
	}
	function decodeCommandData(line) {
		return line
			.slice(line.indexOf('::', 2) + 2)
			.replace(/%0A/g, '\n')
			.replace(/%0D/g, '\r')
			.replace(/%25/g, '%');
	}
	const failures = Array.from(
		{ length: 17 },
		(_, index) => `failure ${index + 1}: preserved cause — 100% ::error:: harmless text`
	);
	let commands = runReporter(failures, 9);
	const errors = commands.filter((line) => line.startsWith('::error title='));
	assert.deepStrictEqual(errors.map(decodeCommandData), failures);
	const retainedErrors = errors.slice(-10);
	check(
		'the real GitHub error quota loses seven independently named causes',
		retainedErrors.length === 10 && !retainedErrors.some((line) => line.includes('failure 1:'))
	);
	const notices = commands.filter((line) =>
		line.startsWith('::notice title=windows-ahk all failures::')
	);
	check('one aggregate notice remains outside the error quota', notices.length === 1);
	const details = decodeCommandData(notices[0]);
	for (const failure of failures)
		check('aggregate notice preserves ' + failure, details.includes(failure));
	check(
		'normal failure lists are complete, without a truncation claim',
		!details.includes('omitted')
	);
	check(
		'aggregate newline data is escaped into one real workflow command',
		notices[0].includes('%0A') && notices[0].includes('100%25') && !notices[0].includes('\r')
	);
	check(
		'step summary still retains every failure',
		failures.every((failure) => fs.readFileSync(summary, 'utf8').includes(failure))
	);
	const nearBudget = 'near budget: ' + 'x'.repeat(48 * 1024 - 80);
	commands = runReporter([nearBudget], 1);
	const fullBudget = decodeCommandData(
		commands.find((line) => line.startsWith('::notice title=windows-ahk all failures::'))
	);
	check(
		'details which actually fit are never omitted to reserve an unused footer',
		fullBudget.includes(nearBudget) && !fullBudget.includes('omitted')
	);
	commands = runReporter(['oversized cause: ' + '界%'.repeat(18000), ...failures], 7);
	const bounded = commands.find((line) =>
		line.startsWith('::notice title=windows-ahk all failures::')
	);
	check(
		'huge aggregate notice stays within the annotation message budget',
		Buffer.byteLength(bounded.slice(bounded.indexOf('::', 2) + 2), 'utf8') <= 48 * 1024
	);
	const boundedDetails = decodeCommandData(bounded);
	check(
		'huge details report their exact omitted count',
		boundedDetails.includes('1 failure detail omitted')
	);
	for (const failure of failures)
		check(
			'one oversized cause does not hide later ordinary causes',
			boundedDetails.includes(failure)
		);
	commands = runReporter([], 0);
	check(
		'successful runs emit no failure-details notice',
		!commands.some((line) => line.startsWith('::notice title=windows-ahk all failures::'))
	);
} finally {
	fs.rmSync(fixture, { recursive: true, force: true });
}

console.log(
	`\x1b[32m[OK] report.cjs parser: ${checks} assertion(s) passed (TAP + Lua formats).\x1b[0m`
);
