// tools/test/support/ahk-timing-runtime.cjs

/**
 * Exercise real runner timings, including the throwing-callback path.
 * The child has no driver includes or input hooks and intentionally exits 1.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../validate-ahk-suite-manifest.cjs');

module.exports = function checkNativeTimings() {
	if (process.platform !== 'win32') return;
	const ahk = [
		'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
		'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe',
		'C:/Program Files (x86)/AutoHotkey/v2/AutoHotkey.exe',
	].find(candidate => fs.existsSync(candidate));
	assert.ok(ahk, 'native timing verification requires AutoHotkey v2 on Windows');
	const fixture = path.resolve(__dirname, '../../../static/ergopti_plus/windows/tests/fixtures/framework_timings_fixture.ahk');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-timings-'));
	try {
		// The framework clears a sibling results file at startup. Keep even that
		// legacy side effect inside the exclusive fixture directory, not the checkout.
		const fixtureDirectory = path.join(temporary, 'fixtures');
		fs.mkdirSync(fixtureDirectory);
		const privateFixture = path.join(fixtureDirectory, path.basename(fixture));
		fs.copyFileSync(fixture, privateFixture);
		fs.copyFileSync(path.resolve(path.dirname(fixture), '../test_framework.ahk'),
			path.join(temporary, 'test_framework.ahk'));
		const resultsFile = path.join(temporary, 'results.txt');
		const result = spawnSync(ahk, ['/ErrorStdOut', privateFixture], {
			windowsHide: true, encoding: 'utf8', timeout: 15000,
			env: { ...process.env, TEMP: temporary, TMP: temporary,
				ERGOPTI_AHK_RESULTS_FILE: resultsFile },
		});
		assert.ifError(result.error);
		assert.equal(result.status, 1, `the deliberate callback failure must be reported: ${result.stdout}\n${result.stderr}`);
		assert.match(result.stdout, /# 2 passed, 1 failed\./);
		const durations = [...result.stdout.matchAll(/^# duration_ms (\d+) (\d+(?:\.\d+)?)\r?$/gm)]
			.map(match => ({ index: Number(match[1]), ms: Number(match[2]) }));
		assert.deepEqual(durations.map(row => row.index), [1, 2, 3],
			'every completed callback, including a failure, must emit its measured duration');
		assert.ok(durations.every(row => Number.isFinite(row.ms) && row.ms >= 0));
		assert.ok(durations[1].ms >= 50, 'the 80 ms sleep must be included in the measured callback');
		assert.ok(durations[2].ms >= 20, 'the throwing callback must retain its time before failure');
		const manifest = validateAhkSuiteManifest(fs.readFileSync(resultsFile, 'utf8'));
		assert.equal(manifest.complete, true, manifest.errors.join('\n'));
		assert.equal(manifest.timed_count, 3);
		assert.equal(manifest.failed, 1);
		assert.deepEqual(manifest.executed.map(row => row.duration_ms), durations.map(row => row.ms),
			'canonical TAP and stdout must carry the same native measurements');
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
};
