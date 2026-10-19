// tools/test/test-compact-data-sql-protocol.cjs

/** Replay native Windows duration and child failures through the actual wrapper. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const owner = path.join(__dirname, 'test-compact-data-sql.cjs');
const source = fs.readFileSync(owner, 'utf8');
// Windows run 39168988892: all 15 real tests passed in 175.412 seconds.
const observedDurationMs = 175412;
const nativeOutput = 'native Python stdout é漢\r\n';
const nativeReport = 'native Python stderr é漢\r\n\r\nRan 15 tests in 175.412s\r\n\r\nOK\r\n';

function invoke(execute) {
	const stdout = [];
	const stderr = [];
	const calls = [];
	const python = 'C:\\Program Files\\Python313\\python.exe';
	let error;
	try {
		vm.runInNewContext(
			source,
			{
				__dirname,
				require(name) {
					if (name === 'node:child_process')
						return {
							spawnSync(command, args, options) {
								calls.push({ command, args: [...args], options });
								return execute(options);
							}
						};
					if (name === '../lib/python.cjs') return { pythonExecutable: () => python };
					assert(['node:assert/strict', 'node:path'].includes(name), name);
					return require(name);
				},
				process: {
					env: { PYTHON: python },
					stdout: { write: (text) => stdout.push(text) },
					stderr: { write: (text) => stderr.push(text) }
				},
				console: { log: (text) => stdout.push(`${text}\n`) }
			},
			{ filename: owner }
		);
	} catch (failure) {
		error = failure;
	}
	return { error, calls, stdout: stdout.join(''), stderr: stderr.join('') };
}

const passed = invoke(({ timeout }) => {
	if (timeout < observedDurationMs)
		return {
			error: Object.assign(new Error('native Python exceeded the wrapper deadline'), {
				code: 'ETIMEDOUT'
			}),
			status: null,
			signal: 'SIGTERM',
			stdout: nativeOutput,
			stderr: 'native report still in progress\r\n'
		};
	return { status: 0, signal: null, stdout: nativeOutput, stderr: nativeReport };
});
assert.ifError(passed.error);
assert.equal(passed.calls.length, 1);
const invocation = passed.calls[0];
assert.equal(invocation.command, 'C:\\Program Files\\Python313\\python.exe');
assert.deepEqual(invocation.args, ['tools/test/test_compact_data_sql.py']);
assert.equal(invocation.options.cwd, path.resolve(__dirname, '..', '..'));
assert.equal(invocation.options.encoding, 'utf8');
assert.equal(invocation.options.env.PYTHONUTF8, '1');
assert.equal(invocation.options.env.PYTHONIOENCODING, 'utf-8');
assert.equal(invocation.options.env.PYTHONDONTWRITEBYTECODE, '1');
assert(Number.isSafeInteger(invocation.options.timeout));
assert(invocation.options.timeout >= observedDurationMs);
assert(invocation.options.timeout <= 510000, 'the aggregate protocol budget must remain bounded');
assert(passed.stdout.startsWith(nativeOutput), 'native stdout must precede the success report');
assert.match(passed.stdout, /PASS lossless SQL compaction: 15 native SQLite/);
assert.equal(passed.stderr, nativeReport, 'native CRLF and Unicode must reach CI unchanged');

const partialOutput = 'partial native stdout é漢\r\n';
const partialReport = 'native stderr é漢 before failure\r\n';
const controls = [
	{
		name: 'timeout',
		result: {
			error: Object.assign(new Error('native child timed out'), { code: 'ETIMEDOUT' }),
			status: null,
			signal: 'SIGTERM',
			stdout: partialOutput,
			stderr: partialReport
		}
	},
	{
		name: 'nonzero exit',
		result: { status: 1, signal: null, stdout: partialOutput, stderr: partialReport }
	},
	{
		name: 'incomplete count',
		result: {
			status: 0,
			signal: null,
			stdout: partialOutput,
			stderr: nativeReport.replace('Ran 15 tests', 'Ran 14 tests')
		}
	},
	{
		name: 'missing success footer',
		result: {
			status: 0,
			signal: null,
			stdout: partialOutput,
			stderr: nativeReport.replace('OK', '')
		}
	},
	{
		name: 'skipped native case',
		result: {
			status: 0,
			signal: null,
			stdout: partialOutput,
			stderr: nativeReport.replace('OK', 'OK (skipped=1)')
		}
	}
];
for (const control of controls) {
	const rejected = invoke(() => control.result);
	assert(rejected.error, `${control.name} must fail the wrapper`);
	assert.equal(rejected.calls.length, 1, control.name);
	assert.equal(rejected.stdout, control.result.stdout, `${control.name}: retain partial stdout`);
	assert.equal(rejected.stderr, control.result.stderr, `${control.name}: retain partial stderr`);
	assert(!rejected.stdout.includes('PASS lossless SQL compaction'), control.name);
}
console.log('PASS compaction wrapper: recorded Windows duration and five failure receipts.');
