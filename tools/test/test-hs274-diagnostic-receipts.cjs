// tools/test/test-hs274-diagnostic-receipts.cjs

/** Replays the real aggregate runner over owned executable child fixtures. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const vm = require('node:vm');

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-hs274-receipts-'));
const runner = 'run-hs274-diagnostics-tests.cjs';
const cause = 'AssertionError: independent middle persistence failure é🙂';
const suites = ['hs274_000_before_test.py', 'hs274_100_failure_test.py', 'hs274_200_after_test.py'];
const cpp = ['hs274-raw-capture-test.cpp', 'hs274-stream-session-test.cpp'];
const prefix = 'HS274_FAILURE_RECEIPT ';
const fixtures = [];

/** Creates an actual executable; the production runner gets no test-only option. */
function executable(file, source) {
	fs.writeFileSync(file, '#!' + process.execPath + '\n' + source, { mode: 0o700 });
}

/** Runs the unchanged CLI contract against private discovery and real child processes. */
function run(mode, options = {}) {
	const directory = fs.mkdtempSync(path.join(temporary, 'fixture-'));
	fixtures.push(directory);
	const diagnostics = path.join(directory, 'tools/diagnostics');
	const tests = path.join(directory, 'tools/test');
	fs.mkdirSync(diagnostics, { recursive: true });
	fs.mkdirSync(tests, { recursive: true });
	fs.copyFileSync(path.join(__dirname, runner), path.join(tests, runner));
	for (const name of [
		...suites,
		...cpp,
		'hs274_helper_environment_test.py',
		'hs274_shutdown_test.py'
	]) {
		fs.writeFileSync(path.join(diagnostics, name), 'Independent inert discovery fixture.\n');
	}
	const journal = path.join(directory, 'children.ndjson');
	const python = path.join(directory, 'python-fixture');
	const compiler = path.join(directory, 'compiler-fixture');
	const common = String.raw`const fs = require('node:fs');
const journal = ${JSON.stringify(journal)};
const record = value => fs.appendFileSync(journal, JSON.stringify(value) + '\n');
const healthy = label => process.stderr.write(Array.from({length:40}, (_, index) => label + index + '\n').join(''));
`;
	executable(
		python,
		common +
			String.raw`
const args = process.argv.slice(2);
const suite = args[args.indexOf('-p') + 1];
record({kind:'python', args, suite});
if (suite === ${JSON.stringify(suites[1])} && ${JSON.stringify(mode)} !== 'healthy') {
 process.stdout.write('independent failed-child context\n');
 const diagnostic = ${JSON.stringify(mode)} === 'overflow' ? 'x'.repeat(2 * 1024 * 1024) : ${JSON.stringify(mode)} === 'long' ? ${JSON.stringify(cause)} + '\n' + '🙂é'.repeat(5000) + '\nindependent terminal detail\n' : ${JSON.stringify(cause)} + '\n';
 process.stderr.write(diagnostic, () => {
  if (${JSON.stringify(mode)} === 'signal') process.kill(process.pid, 'SIGTERM');
  else process.exit(7);
 });
} else healthy(suite);
`
	);
	const binarySource =
		common +
		String.raw`
record({kind:'binary', name:require('node:path').basename(process.argv[1])});
healthy('independent healthy C++ output');
`;
	executable(
		compiler,
		common +
			String.raw`
const args = process.argv.slice(2);
const binary = args[args.indexOf('-o') + 1];
record({kind:'compiler', args});
fs.writeFileSync(binary, ${JSON.stringify('#!' + process.execPath + '\n' + binarySource)}, {mode:0o700});
healthy('independent compiler output');
`
	);
	const result = spawnSync(process.execPath, [path.join(tests, runner)], {
		cwd: directory,
		env: {
			...process.env,
			PYTHON: options.missingPython ? path.join(directory, 'absent-python') : python,
			CXX: compiler
		},
		encoding: 'utf8',
		maxBuffer: 8 * 1024 * 1024,
		timeout: 30000
	});
	assert.ifError(result.error);
	assert.equal(result.signal, null, 'the aggregate runner must finish normally');
	assert.ok(fs.existsSync(journal), result.stderr);
	const children = fs.readFileSync(journal, 'utf8').trim().split('\n').map(JSON.parse);
	assert.equal(
		children.filter((row) => row.kind === 'compiler').length,
		cpp.length,
		'every portable C++ source still compiles'
	);
	assert.deepEqual(
		children.filter((row) => row.kind === 'binary').map((row) => row.name),
		cpp.map((name) => name.replace(/\.cpp$/, '')),
		'every compiled C++ test still runs'
	);
	if (!options.missingPython) {
		assert.deepEqual(
			children.filter((row) => row.kind === 'python').map((row) => row.suite),
			suites,
			'discovery excludes only the same two native or separately owned suites'
		);
	}
	return result;
}

/** Executes the actual outer failure formatter; only artifact retention is inert. */
function preview(result) {
	const source = fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8');
	const start = source.indexOf('function reportFailure(');
	const end = source.indexOf('/** Preserve returned text', start);
	assert.ok(start > 0 && end > start, 'the real bounded outer formatter is present');
	const output = [];
	vm.runInNewContext(source.slice(start, end) + '\nreportFailure(received, 1);', {
		received: {
			...result,
			name: 'Independent HS-274 aggregate',
			repro: 'owned fixture',
			errorCode: result.error?.code
		},
		process: { env: {} },
		console: { log: (value) => output.push(value) },
		retainFailure() {}
	});
	return output.join('\n');
}

function receipt(result) {
	assert.equal(result.status, 1, 'a failed native child keeps the aggregate red');
	const line = result.stderr.trim().split(/\r?\n/).at(-1);
	assert.ok(line.startsWith(prefix), 'a structured failure receipt is the final stderr line');
	return JSON.parse(line.slice(prefix.length));
}

try {
	const failed = run('failure');
	assert.equal(failed.status, 1, 'the original failure must never become green');
	assert.ok(
		preview(failed).includes(cause),
		'a middle child cause survives later healthy output in the final receipt tail'
	);
	const report = receipt(failed);
	assert.equal(report.schema, 1);
	assert.equal(report.failures.length, 1);
	const child = report.failures[0];
	assert.ok(child.label.includes(suites[1]));
	assert.equal(child.exit_code, 7);
	assert.equal(child.signal, null);
	assert.equal(child.error_code, null);
	assert.equal(child.stderr.head, cause + '\n');
	assert.equal(child.stderr.omitted_bytes, 0);
	assert.equal(child.stdout.head, 'independent failed-child context\n');
	const long = receipt(run('long'));
	const retained = long.failures[0].stderr;
	assert.ok(retained.head.includes(cause));
	assert.ok(retained.tail.includes('independent terminal detail'));
	assert.ok(retained.omitted_bytes > 0);
	assert.ok(Buffer.byteLength(retained.head + retained.tail) <= long.excerpt_limit_bytes);
	assert.ok(
		![retained.head, retained.tail].some((text) => text.includes('\ufffd')),
		'bounded UTF-8 edges do not split a character'
	);
	const signalled = receipt(run('signal')).failures[0];
	assert.equal(signalled.exit_code, null);
	assert.equal(signalled.signal, 'SIGTERM');
	assert.ok(signalled.stderr.head.includes(cause));
	const overflow = receipt(run('overflow'));
	const large = overflow.failures[0];
	assert.equal(large.error_code, 'ENOBUFS', 'bounded capture overflow remains a failure');
	assert.ok(large.stderr.omitted_bytes > 0, 'truncation is explicitly receipted');
	assert.ok(
		Buffer.byteLength(large.stderr.head + large.stderr.tail) <= overflow.excerpt_limit_bytes
	);
	const missing = receipt(run('healthy', { missingPython: true }));
	assert.equal(missing.failures.length, suites.length);
	assert.ok(missing.failures.every((row) => row.error_code === 'ENOENT' && row.exit_code === null));
	const healthy = run('healthy');
	assert.equal(healthy.status, 0);
	assert.ok(!healthy.stderr.includes(prefix), 'healthy children produce no failure receipt');
	assert.ok(healthy.stdout.includes('All 3 HS-274 Python suites and 2 C++ tests passed.'));
	console.log(
		'HS-274 actual runner receipts preserve middle failures, native status, bounded overflow and later suites.'
	);
} finally {
	for (const directory of fixtures) assert.equal(path.dirname(directory), temporary);
	fs.rmSync(temporary, { recursive: true });
}
