// tools/test/test-macos-managed-ollama-catalogue.cjs

/** Receive portable catalogue input admission; native production has its own profile. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const result = spawnSync(
	pythonExecutable(),
	['tools/test/macos_managed_ollama_catalogue_test.py'],
	{
		cwd: path.resolve(__dirname, '../..'),
		encoding: 'utf8',
		timeout: 60000
	}
);
assert.equal(result.error, undefined, 'the catalogue receiver must start');
assert.equal(result.signal, null, 'the catalogue receiver must close within its bound');
assert.equal(result.status, 0, result.stderr || result.stdout);
assert.match(result.stderr, /Ran 18 tests in/);
assert.match(result.stderr, /\bOK\b/);
assert.doesNotMatch(result.stderr, /skipped=/);
assert.match(result.stdout, /actual native producer receiving was not requested/);
process.stdout.write(result.stdout);
process.stdout.write(result.stderr);
