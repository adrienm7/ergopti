// tools/test/test-python-resolution.cjs

/**
 * ==============================================================================
 * MODULE: Actual CPython Resolution Guard
 * DESCRIPTION:
 * Independent refusal controls preserve configured interpreter ownership,
 * require validated CPython capability and reject banner/path substitutions.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { pythonExecutable } = require('../lib/python.cjs');

const actual = path.resolve('owned-cpython');
function fixture(results, file = true) {
	const calls = [];
	const native = {
		spawnSync(candidate, args, options) {
			calls.push(candidate);
			assert.deepEqual(args.slice(0, 1), ['-c']);
			assert.match(args[1], /platform\.python_implementation\(\) == "CPython"/);
			assert.match(args[1], /sys\.version_info >= \(3, 8\)/);
			assert.equal(options.timeout, 10000);
			return results.shift();
		},
		isAbsolute: path.isAbsolute,
		statSync(value) {
			assert.equal(value, actual);
			return { isFile: () => file };
		}
	};
	return { calls, native };
}

const good = () => ({ status: 0, stdout: JSON.stringify({ executable: actual }) });
let f = fixture([{ status: 1 }]);
assert.throws(() => pythonExecutable({ PYTHON: 'chosen-python' }, f.native), /Configured PYTHON/);
assert.deepEqual(f.calls, ['chosen-python'], 'configured refusal cannot try another interpreter');
f = fixture([]);
assert.throws(() => pythonExecutable({ PYTHON: '' }, f.native), /Configured PYTHON/);
assert.deepEqual(f.calls, [], 'invalid configuration refuses before process acquisition');
f = fixture([{ error: new Error('missing'), status: null }, good()]);
assert.equal(pythonExecutable({}, f.native), actual);
assert.deepEqual(f.calls, ['python3', 'python']);
for (const receipt of [
	{ status: 0, stdout: 'Python 3.12' },
	{ status: 0, stdout: JSON.stringify({ executable: 'relative-python' }) },
	{ status: 0, stdout: JSON.stringify({ executable: null }) },
	{ status: null, stdout: JSON.stringify({ executable: actual }) }
]) {
	f = fixture([receipt]);
	assert.throws(() => pythonExecutable({ PYTHON: 'chosen-python' }, f.native), /Configured PYTHON/);
	assert.deepEqual(f.calls, ['chosen-python']);
}
f = fixture([good()], false);
assert.throws(() => pythonExecutable({ PYTHON: 'chosen-python' }, f.native), /Configured PYTHON/);
f = fixture([good()]);
assert.equal(pythonExecutable({ PYTHON: 'chosen-python' }, f.native), actual);
assert.deepEqual(f.calls, ['chosen-python']);
console.log('PASS CPython resolution: 9 independent admission/refusal controls.');
