// tools/test/test-windows-range-transport.cjs

/** Verify the production range mount and script inside a hidden native WebView. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

if (process.platform !== 'win32') {
	console.log('Native WebView range transport requires Windows.');
	process.exit(0);
}
const ahk = ['C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
	'C:/Program Files/AutoHotkey/AutoHotkey64.exe'].find(candidate => fs.existsSync(candidate));
assert.ok(ahk, 'native WebView range transport requires AutoHotkey v2');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-webview-range-'));
const errors = [];
try {
	const fixture = path.resolve(__dirname, '../../static/ergopti_plus/windows/tests/fixtures/webview_range_transport_fixture.ahk');
	const result = spawnSync(ahk, ['/ErrorStdOut', fixture, path.join(root, 'native')], {
		windowsHide: true, encoding: 'utf8', timeout: 45000,
		env: { ...process.env, TEMP: root, TMP: root },
	});
	assert.ifError(result.error);
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(JSON.parse(result.stdout.trim()), {
		same_host: true, file_refused: true, mapped_range: true, consumed: true, removed: true,
		profile_preserved: true, profile_retired: true,
	});
} catch (error) {
	errors.push(error);
} finally {
	try { fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }); }
	catch (error) { errors.push(error); }
}
if (errors.length) throw new AggregateError(errors, 'Native WebView transport or owned cleanup failed.');
console.log('Native WebView: HTTPS range consumed; file-scheme refused; active profile preserved and retired after browser exit.');
