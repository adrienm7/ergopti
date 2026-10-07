// tools/test/test-report.cjs

/**
 * ==============================================================================
 * MODULE: report.cjs parser and lifecycle self-test
 * DESCRIPTION:
 * Exercises report.cjs's format-agnostic parseResults against representative TAP
 * (AHK run_all.ahk) and Lua-runner output, so the unified reporter cannot
 * silently miscount or miss failures (which would let a red CI run look green).
 * Actual CLI subprocesses also prove complete output draining and exit status.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
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

/**
 * Exercises the actual CLI against unread pipes, not an injected output writer.
 * @returns {Promise<void>} Settles after every owned reporter has closed.
 */
async function testOutputDrain() {
	const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-reporter-drain-'));
	const reporter = path.resolve(__dirname, 'report.cjs');
	const transcript = path.join(folder, 'tap.txt');
	const runner = path.join(folder, 'runner.cjs');
	const stderrRunner = path.join(folder, 'stderr-runner.cjs');
	const stderrFile = path.join(folder, 'stderr.txt');
	const jsonPath = path.join(folder, 'receipt.json');
	const failures = Array.from(
		{ length: 12 },
		(_, index) => `owned slow-reader cause ${index + 1}: ` + 'x'.repeat(48 * 1024 - 1024)
	);
	// Exceed both POSIX pipe and Node socket buffering with independently fitting
	// causes; one short near-budget cause alone does not force a blocked writer.
	const tap =
		failures.map((failure, index) => `not ok ${index + 1} - ${failure}\n`).join('') +
		'# 7738 passed, 12 failed\n';
	const stderr = 'owned stderr: ' + 'e'.repeat(96 * 1024) + '\n';
	fs.writeFileSync(transcript, tap);
	fs.writeFileSync(
		runner,
		"const fs = require('node:fs'); process.stdout.write(fs.readFileSync(process.argv[2])); process.exitCode = Number(process.argv[3]);\n"
	);
	function collect(args) {
		return new Promise((resolve, reject) => {
			const child = spawn(process.execPath, [reporter, ...args], {
				env: { ...process.env, GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: '' }
			});
			const output = [],
				errors = [];
			child.stdout.on('data', (chunk) => output.push(chunk));
			child.stderr.on('data', (chunk) => errors.push(chunk));
			child.stdout.pause();
			// Start the slow-reader interval only once real output reaches the pipe;
			// process startup time must not consume the backpressure fixture.
			let resume;
			child.stdout.once('readable', () => {
				resume = setTimeout(() => child.stdout.resume(), 200);
			});
			let timedOut = false;
			const deadline = setTimeout(() => {
				timedOut = true;
				child.kill('SIGKILL');
			}, 4000);
			child.on('error', reject);
			child.on('close', (code, signal) => {
				clearTimeout(resume);
				clearTimeout(deadline);
				if (timedOut) return reject(new Error('Owned reporter did not settle within 4s'));
				resolve({
					code,
					signal,
					stdout: Buffer.concat(output).toString(),
					stderr: Buffer.concat(errors).toString()
				});
			});
		});
	}
	try {
		for (const mode of ['child', 'parse']) {
			const result = await collect([
				'--name',
				'slow-reader',
				'--json',
				jsonPath,
				'--',
				...(mode === 'child'
					? [process.execPath, runner, transcript, '9']
					: ['PARSE_FILE', transcript])
			]);
			check(
				'slow reader preserves exact ' + mode + ' status',
				result.code === (mode === 'child' ? 9 : 1) && result.signal === null
			);
			if (mode === 'child') {
				check('slow reader retains every original stdout byte', result.stdout.startsWith(tap));
			}
			const notice = result.stdout
				.split('\n')
				.find((line) => line.startsWith('::notice title=slow-reader all failures::'));
			check(
				'slow reader retains the complete fitting cause in its bounded notice',
				!!notice && notice.includes(failures[0]) && notice.includes('11 failure details omitted')
			);
			const annotations = result.stdout
				.split('\n')
				.filter((line) => line.startsWith('::error title=slow-reader test failed::'));
			check(
				'slow reader retains every full error annotation',
				annotations.length === failures.length &&
					annotations.every((line, index) => line.endsWith(failures[index]))
			);
			check(
				'slow reader retains the final summary',
				result.stdout.includes('[report:slow-reader]') &&
					result.stdout.includes(`(exit ${result.code}, format tap).\n`)
			);
			const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
			assert.deepStrictEqual(json.failures, failures);
			check(
				'slow reader JSON keeps exact native status',
				json.exit_code === result.code && json.failed === 12 && json.passed === 7738
			);
		}
		// Keep stream-drain proof separate from TAP parsing: simultaneous arbitrary
		// stderr text can bisect a TAP line in the reporter's combined transcript.
		// A file keeps the payload below Windows' command-line length limit.
		fs.writeFileSync(stderrFile, stderr);
		fs.writeFileSync(
			stderrRunner,
			"const fs = require('node:fs'); process.stderr.write(fs.readFileSync(process.argv[2])); process.exitCode = 7;\n"
		);
		const stderrResult = await collect([
			'--name',
			'stderr-drain',
			'--',
			process.execPath,
			stderrRunner,
			stderrFile
		]);
		check('natural failure retains every original stderr byte', stderrResult.stderr === stderr);
		check(
			'stderr failure settles with exact native status and final output',
			stderrResult.code === 7 &&
				stderrResult.signal === null &&
				stderrResult.stdout.includes('(exit 7, format unknown).\n')
		);
		fs.writeFileSync(transcript, 'ok 1 - owned success\n# 1 passed, 0 failed\n');
		const success = await collect(['--name', 'drained-success', '--', 'PARSE_FILE', transcript]);
		check(
			'natural success settles with zero status and final output',
			success.code === 0 &&
				success.signal === null &&
				success.stdout.includes('(exit 0, format tap).\n')
		);
		const refused = await collect([
			'--name',
			'spawn-refused',
			'--',
			path.join(folder, 'absent-command')
		]);
		check(
			'spawn refusal settles with status2 and its diagnostic',
			refused.code === 2 &&
				refused.signal === null &&
				refused.stderr.includes('[report:spawn-refused] failed to spawn:')
		);
		const usage = await collect([]);
		check(
			'usage refusal settles with status2 and full usage',
			usage.code === 2 && usage.signal === null && usage.stderr.endsWith('-- <cmd> [args…]\n')
		);
	} finally {
		fs.rmSync(folder, { recursive: true, force: true });
	}
}

// The current Linux failure log is public, but the original reporter retains
// only test names. These independent transcripts prove the receiving CLI
// publishes the fixed fixture's exact complete assertion and rejects ambiguity.
const excerptFixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-unit-excerpt-'));
try {
	const excerptCommand = path.join(__dirname, 'linux-unit-failure-excerpt.cjs');
	const excerptLog = path.join(excerptFixture, 'linux-unit.log');
	const caseName = 'routes the Configuration restore row to the recommended hotstrings';
	const assertion = 'test_hotstrings_scope.lua:435: the restored catalogue fires — actual: false';
	const inline = `  FAIL ${caseName} — ${assertion}\n`;
	const detail = `  - ${caseName} : ${assertion}\n    replay: luajit tests/run.lua --only "${caseName}"\n`;
	const footer =
		'OVERALL RESULTS:\nTotal modules: 498\nPassed tests:  11224\nFailed tests:  1\n========================================\n';
	const reporter =
		'[report:linux-lua] \x1b[31mFAIL\x1b[0m — 11\u202F224 passed, 1 failed (exit 1, format lua).\n';
	const transcript = inline + footer + detail + reporter;
	function receiveExcerpt(log) {
		fs.writeFileSync(excerptLog, log);
		return spawnSync(process.execPath, [excerptCommand, excerptLog], { encoding: 'utf8' });
	}
	const accepted = receiveExcerpt(transcript);
	check(
		'Configuration assertion CLI receives the exact complete failure',
		accepted.status === 0 &&
			accepted.signal === null &&
			accepted.stderr === '' &&
			accepted.stdout ===
				'::notice title=linux-lua Configuration assertion::routes the Configuration restore row to the recommended hotstrings%0Atest_hotstrings_scope.lua:435: the restored catalogue fires — actual: false\n'
	);
	const multiline =
		'test_hotstrings_scope.lua:429: the Configuration row is registered:\n  expected: "function"\n    actual: "nil"';
	const escaped = receiveExcerpt(transcript.replaceAll(assertion, multiline));
	check(
		'Configuration equality assertion retains both independently known values',
		escaped.status === 0 &&
			escaped.stderr === '' &&
			escaped.stdout ===
				'::notice title=linux-lua Configuration assertion::routes the Configuration restore row to the recommended hotstrings%0Atest_hotstrings_scope.lua:429: the Configuration row is registered:%0A  expected: "function"%0A    actual: "nil"\n'
	);
	const injection = 'test_hotstrings_scope.lua:435: 50%\r\n::error::injected';
	const safe = receiveExcerpt(transcript.replaceAll(assertion, injection));
	check(
		'Configuration assertion escapes percent and every injected command line',
		safe.status === 0 &&
			safe.stderr === '' &&
			safe.stdout ===
				'::notice title=linux-lua Configuration assertion::routes the Configuration restore row to the recommended hotstrings%0Atest_hotstrings_scope.lua:435: 50%25%0D%0A::error::injected\n'
	);
	const refusedLogs = [
		['missing inline case', transcript.replace(inline, '')],
		['missing terminal case', inline + footer + reporter],
		['duplicate inline case', inline + transcript],
		['duplicate terminal case', transcript.replace(detail, detail + detail)],
		['other case name', transcript.replaceAll(caseName, 'another failing test')],
		['truncated replay', transcript.slice(0, transcript.indexOf('    replay:'))],
		['truncated reporter', transcript.slice(0, -1)],
		[
			'truncated inline assertion',
			transcript.replace(inline, `  FAIL ${caseName} — ${assertion.slice(0, -5)}\n`)
		],
		['conflicting assertion copies', transcript.replace(inline, inline.replace('false', 'nil'))],
		['duplicate footer', transcript.replace(footer, footer + footer)],
		['duplicate reporter', transcript + reporter],
		['successful runner footer', transcript.replace('Failed tests:  1', 'Failed tests:  0')],
		['successful reporter', transcript.replace('(exit 1, format lua)', '(exit 0, format lua)')],
		['inconsistent failure count', transcript.replace('Failed tests:  1', 'Failed tests:  2')],
		[
			'foreign assertion source',
			transcript.replaceAll('test_hotstrings_scope.lua', 'test_other.lua')
		],
		['control byte', transcript.replaceAll(assertion, assertion + '\x00')],
		[
			'escaped annotation exceeds budget',
			transcript.replaceAll(assertion, assertion + '%'.repeat(3000))
		],
		[
			'invalid UTF-8',
			Buffer.from(transcript.replaceAll(assertion, assertion + '\x7f')).map((byte) =>
				byte === 0x7f ? 0xff : byte
			)
		]
	];
	for (const [label, log] of refusedLogs) {
		const refusal = receiveExcerpt(log);
		check(
			`Configuration excerpt refuses ${label} without publishing detail`,
			refusal.status === 2 &&
				refusal.signal === null &&
				refusal.stdout === '' &&
				refusal.stderr.startsWith('Configuration assertion annotation refused: ') &&
				!refusal.stderr.includes(assertion)
		);
	}
	for (const args of [
		[],
		[excerptLog, excerptLog],
		[path.join(excerptFixture, 'absent')],
		[excerptFixture]
	]) {
		const refusal = spawnSync(process.execPath, [excerptCommand, ...args], { encoding: 'utf8' });
		check(
			'Configuration excerpt refuses argument or read failures without a notice',
			refusal.status === 2 &&
				refusal.signal === null &&
				refusal.stdout === '' &&
				refusal.stderr.startsWith('Configuration assertion annotation refused: ')
		);
	}
	// A removed no-follow guard must reach a valid log and publish it, so a
	// decoding refusal cannot accidentally certify symbolic-link isolation.
	fs.writeFileSync(excerptLog, transcript);
	if (process.platform !== 'win32') {
		const link = path.join(excerptFixture, 'foreign-log');
		fs.symlinkSync(excerptLog, link);
		const refusal = spawnSync(process.execPath, [excerptCommand, link], { encoding: 'utf8' });
		check(
			'Configuration excerpt refuses a symbolic log alias',
			refusal.status === 2 &&
				refusal.stdout === '' &&
				refusal.stderr.startsWith('Configuration assertion annotation refused: ')
		);
	}
	fs.truncateSync(excerptLog, 32 * 1024 * 1024 + 1);
	const oversized = spawnSync(process.execPath, [excerptCommand, excerptLog], { encoding: 'utf8' });
	check(
		'Configuration excerpt refuses oversized input before decoding',
		oversized.status === 2 &&
			oversized.stdout === '' &&
			oversized.stderr ===
				'Configuration assertion annotation refused: unit log is not a regular bounded file.\n'
	);
} finally {
	fs.rmSync(excerptFixture, { recursive: true, force: true });
}

testOutputDrain()
	.then(() => {
		console.log(
			`\x1b[32m[OK] report.cjs parser: ${checks} assertion(s) passed (TAP + Lua formats).\x1b[0m`
		);
	})
	.catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
