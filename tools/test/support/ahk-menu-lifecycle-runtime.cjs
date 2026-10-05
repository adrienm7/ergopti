// tools/test/support/ahk-menu-lifecycle-runtime.cjs

/** Require a clean native teardown after the real personal-menu owner tests. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../validate-ahk-suite-manifest.cjs');

module.exports = function checkNativeMenuLifecycle(ahk) {
	assert.equal(process.platform, 'win32', 'native menu lifecycle requires Windows');
	assert.ok(ahk && fs.existsSync(ahk), 'native menu lifecycle requires the actual AHK binary');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-menu-lifecycle-'));
	try {
		const runner = path.resolve(
			__dirname,
			'../../../static/ergopti_plus/windows/tests/run_all.ahk'
		);
		const resultsFile = path.join(temporary, 'results.txt');
		const result = spawnSync(
			ahk,
			['/ErrorStdOut', runner, '--only', 'hotstring-personal-menu-owner:'],
			{
				windowsHide: true,
				encoding: 'utf8',
				timeout: 120000,
				env: {
					...process.env,
					TEMP: temporary,
					TMP: temporary,
					ERGOPTI_AHK_RESULTS_FILE: resultsFile
				}
			}
		);
		assert.ifError(result.error);
		const transcript = fs.existsSync(resultsFile)
			? fs.readFileSync(resultsFile, 'utf8')
			: 'No native result transcript was produced.';
		const failures = transcript.split(/\r?\n/).filter((line) => line.startsWith('not ok '));
		const diagnostic =
			`exit=${result.status}; signal=${result.signal}; native failures=${failures.length}\n` +
			(failures.length ? failures.join('\n').slice(0, 1600) : transcript.slice(-800)) +
			`\nstderr tail: ${String(result.stderr).slice(-900)}\nstdout tail: ${String(result.stdout).slice(-900)}`;
		assert.equal(
			result.status,
			0,
			`personal-menu assertions and native teardown must succeed: ${diagnostic}`
		);
		const manifest = validateAhkSuiteManifest(fs.readFileSync(resultsFile, 'utf8'));
		assert.equal(manifest.complete, true, manifest.errors.join('\n'));
		assert.equal(manifest.failed, 0);
		assert.equal(
			manifest.passed,
			5,
			'run all four owner cases and the descendant lifecycle regression'
		);
		assert.equal(manifest.timed_count, 5);
		assert.ok(
			manifest.executed.every((row) => row.name.startsWith('hotstring-personal-menu-owner:'))
		);
		console.log('AHK personal-menu lifecycle: five native cases and clean teardown passed.');
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
};
