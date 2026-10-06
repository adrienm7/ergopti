// tools/test/support/ahk-menu-lifecycle-runtime.cjs

/** Require a clean native teardown after the real personal-menu owner tests. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runFileBackedNative, describeNativeCapture } = require('./file-backed-native-runner.cjs');
const { validateAhkSuiteManifest } = require('../validate-ahk-suite-manifest.cjs');

module.exports = function checkNativeMenuLifecycle(ahk) {
	assert.equal(process.platform, 'win32', 'native menu lifecycle requires Windows');
	assert.ok(ahk && fs.existsSync(ahk), 'native menu lifecycle requires the actual AHK binary');
	const temporary = fs.mkdtempSync(
		path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'ergopti-ahk-menu-lifecycle-')
	);
	let accepted = false;
	try {
		const runner = path.resolve(
			__dirname,
			'../../../static/ergopti_plus/windows/tests/run_all.ahk'
		);
		const resultsFile = path.join(temporary, 'results.txt');
		const { result, captures } = runFileBackedNative(
			ahk,
			['/ErrorStdOut', runner, '--only', 'hotstring-personal-menu-owner:'],
			temporary,
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
		assert.equal(result.signal, null, 'personal-menu child must terminate without a signal');
		assert.equal(
			result.status,
			0,
			`personal-menu assertions and native teardown must succeed; full captures: ${captures.stdout}, ${captures.stderr}`
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
		accepted = true;
		console.log('AHK personal-menu lifecycle: five native cases and clean teardown passed.');
	} finally {
		if (accepted) {
			fs.rmSync(temporary, { recursive: true, force: true });
		} else {
			console.error(
				'AHK_MENU_LIFECYCLE_DIAGNOSTIC ' +
					JSON.stringify({
						directory: temporary,
						stdout: describeNativeCapture(path.join(temporary, 'native.stdout.log')),
						stderr: describeNativeCapture(path.join(temporary, 'native.stderr.log')),
						results: path.join(temporary, 'results.txt')
					})
			);
		}
	}
};
