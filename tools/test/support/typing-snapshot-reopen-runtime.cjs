// tools/test/support/typing-snapshot-reopen-runtime.cjs

/**
 * Verify fresh Windows and Edge bootstraps against real synthetic AHK snapshots.
 * Native projection runs sequentially in an exclusive temporary directory.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../validate-ahk-suite-manifest.cjs');

function nativeSnapshots() {
	const ahk = [
		'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
		'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe',
		'C:/Program Files (x86)/AutoHotkey/v2/AutoHotkey.exe',
	].find(candidate => fs.existsSync(candidate));
	assert.ok(ahk, 'native snapshot verification requires AutoHotkey v2 on Windows');
	const runner = path.resolve(__dirname, '../../../static/ergopti_plus/windows/tests/run_all.ahk');
	// The legacy framework removes this path before reading its result override.
	assert.equal(fs.existsSync(path.join(path.dirname(runner), 'test_results.txt')), false,
		'cannot run snapshot fixture over an existing checkout results file');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-typing-reopen-'));
	try {
		const resultsFile = path.join(temporary, 'results.txt');
		const result = spawnSync(ahk, ['/ErrorStdOut', runner, '--only=metrics-history-reopen'], {
			windowsHide: true, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024,
			env: { ...process.env, TEMP: temporary, TMP: temporary,
				ERGOPTI_AHK_RESULTS_FILE: resultsFile },
		});
		assert.ifError(result.error);
		assert.equal(result.status, 0,
			`native snapshot fixture failed: ${result.stdout}\n${result.stderr}`);
		const manifest = validateAhkSuiteManifest(fs.readFileSync(resultsFile, 'utf8'));
		assert.equal(manifest.complete, true, manifest.errors.join('\n'));
		assert.equal(manifest.failed, 0);
		assert.ok(manifest.executed_count > 0, 'the targeted native fixture must execute');
		const records = result.stdout.split(/\r?\n/)
			.filter(line => line.startsWith('# history_snapshot'))
			.map(line => {
				const match = /^# history_snapshot (live|manifest|live-cleared|manifest-cleared) (\{.*\})$/.exec(line);
				assert.ok(match, 'native snapshot receipt must have a recognized mode and JSON object');
				return { mode: match[1], blob: JSON.parse(match[2]) };
			});
		assert.deepEqual(records.map(record => record.mode).sort(),
			['live', 'live-cleared', 'manifest', 'manifest-cleared'],
			'each native publication mode must supply exactly one synthetic snapshot');
		return records;
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

module.exports = async function checkSnapshotReopen(html) {
	if (process.platform !== 'win32') return;
	const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
		.map(match => match[1]).filter(source => source.includes('let cached_historical'));
	assert.equal(scripts.length, 1, 'exactly one real prefetch bootstrap must run');
	for (const { mode, blob } of nativeSnapshots()) {
		for (const host of ['windows', 'edge']) {
			let listener;
			let fetches = 0;
			const received = [];
			const errors = [];
			const sidecar = 'file:///synthetic/snapshot.json';
			const context = vm.createContext({
				console: { log() {}, error(...args) { errors.push(args); } },
				metrics_manifest: {}, process_manifest() {}, apply_local_filters() {},
				receive_range_data(value) { received.push(JSON.parse(JSON.stringify(value))); },
				URLSearchParams, location: { hash: `#prefetch=${encodeURIComponent(sidecar)}` },
				async fetch(url) {
					assert.equal(url, sidecar);
					fetches++;
					return { ok: true, async json() { return JSON.parse(JSON.stringify(blob)); } };
				},
			});
			context.window = context;
			if (host === 'windows') {
				context.chrome = { webview: {
					addEventListener(type, callback) { assert.equal(type, 'message'); listener = callback; },
					postMessage() {},
				} };
			}
			vm.runInContext(scripts[0], context);
			if (host === 'windows') {
				assert.equal(typeof listener, 'function');
				listener({ data: JSON.stringify({ type: 'prefetch', blob }) });
			}
			// Drain the actual fetch/json promise chain before asserting the fresh paint.
			await new Promise(resolve => setImmediate(resolve));
			assert.deepEqual(errors, [], `${host}/${mode}: bootstrap must not swallow a failure`);
			assert.equal(fetches, host === 'edge' ? 1 : 0);
			assert.equal(received.length, 1, `${host}/${mode}: fresh page must receive its snapshot`);
			if (mode.endsWith('-cleared')) {
				assert.deepEqual(received[0].historical.c, {}, `${host}/${mode}: deleted history must stay empty`);
			} else {
				assert.equal(received[0].historical.c.a.c, 1, `${host}/${mode}: reopening must retain historical counts`);
			}
		}
	}
};
