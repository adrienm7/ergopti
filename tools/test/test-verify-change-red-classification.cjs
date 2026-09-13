// tools/test/test-verify-change-red-classification.cjs

/**
 * A red result is evidence of an outcome, not automatically evidence that the
 * current diff caused it. Pin the three-way classification used by the
 * change-scoped diagnostic mode.
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');
const { createRequire } = require('node:module');

const { classifyGateResult } = require(path.resolve(__dirname, 'verify-change.cjs'));

let result = classifyGateResult('js', { status: 1 }, true);
assert.equal(result.kind, 'candidate-regression');
assert.equal(result.blockingInDiagnosis, true);

result = classifyGateResult('js', { status: 1 }, false);
assert.equal(result.kind, 'baseline-or-history');
assert.equal(result.blockingInDiagnosis, false);

result = classifyGateResult('js', { status: null, error: new Error('spawn failed') }, true);
assert.equal(result.kind, 'environment-failure');
assert.equal(result.blockingInDiagnosis, true);

result = classifyGateResult('ahk-suite', { skipped: 'interpreter absent' }, true);
assert.equal(result.kind, 'environment-deferral');
assert.equal(result.blockingInDiagnosis, false);

result = classifyGateResult('js', { status: 0 }, true);
assert.equal(result.kind, 'pass');

console.log('verify-change red classification: ok');

/**
 * Runs the actual CLI control flow with synthetic Git and child-process receipts.
 * No platform suite executes and no working tree is modified.
 * @param {string} failedScript Npm script whose child returns failure.
 * @param {boolean} full Whether to exercise full diagnostic classification.
 * @returns {object} Captured exit, commands and diagnostic output.
 */
function reportCli(failedScript, full = true) {
	const source = path.join(__dirname, 'verify-change.cjs');
	const originalRequire = createRequire(source);
	const entry = { exports: {} };
	const output = [];
	const commands = [];
	let exitCode;
	function load(name) {
		if (name === 'node:fs') return { ...fs, existsSync: () => false };
		if (name === 'node:child_process') return {
			execFileSync: (command) => {
				assert.equal(command, 'git');
				return 'docs/audits/performance/ahk/report.md\0';
			},
			spawnSync: (command, args) => {
				assert.equal(command, 'npm', 'no real driver may execute in this fixture');
				commands.push(args[1]);
				return { status: args[1] === failedScript ? 1 : 0 };
			},
		};
		return originalRequire(name);
	}
	load.main = entry;
	vm.runInNewContext(fs.readFileSync(source, 'utf8'), {
		require: load, module: entry, __dirname,
		process: {
			argv: ['node', source, '--range=fixture', ...(full ? ['--all', '--diagnose'] : [])],
			env: process.env, platform: process.platform, exit: (code) => { exitCode = code; },
		},
		console: { log: (value) => output.push(String(value)), error: (value) => output.push(String(value)) },
	});
	return { exitCode, commands, output: output.join('\n') };
}

let cli = reportCli('test:js');
assert.equal(cli.exitCode, 1, 'a covering suite failure must not become non-blocking historical debt');
assert.match(cli.output, /js: candidate-regression/);
assert.equal(cli.commands.filter((script) => script === 'test:js').length, 1);
assert(!cli.commands.includes('lint:conventions:strict'), 'full audits execute report lint through JS exactly once');
cli = reportCli('test:hs');
assert.equal(cli.exitCode, 0, 'an unrelated Hammerspoon failure remains historical for a report-only change');
assert.match(cli.output, /hs: baseline-or-history/);
cli = reportCli('lint:conventions:strict', false);
assert.equal(cli.exitCode, 1, 'standalone report lint failure must propagate to the CLI exit');
assert.deepEqual(cli.commands, ['lint:conventions:strict']);
console.log('verify-change report coverage: standalone, covering and unrelated failures classified correctly.');
