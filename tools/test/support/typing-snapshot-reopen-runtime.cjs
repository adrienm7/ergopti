// tools/test/support/typing-snapshot-reopen-runtime.cjs

/**
 * Verify fresh Windows and Edge bootstraps of the real loaded typing page.
 * Every OS replays portable snapshots of the published shape; Windows also
 * replays the snapshots the AHK writer publishes, which needs AutoHotkey v2.
 * Native projection runs sequentially in an exclusive temporary directory.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { loadMetricsTypingPage } = require('./metrics-apps-page.cjs');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../validate-ahk-suite-manifest.cjs');

function nativeSnapshots() {
	const ahk = [
		'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
		'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe',
		'C:/Program Files (x86)/AutoHotkey/v2/AutoHotkey.exe'
	].find((candidate) => fs.existsSync(candidate));
	assert.ok(ahk, 'native snapshot verification requires AutoHotkey v2 on Windows');
	const runner = path.resolve(__dirname, '../../../static/ergopti_plus/windows/tests/run_all.ahk');
	const legacy = path.join(path.dirname(runner), 'test_results.txt');
	// The runner owns its explicit temporary receipt; prior checkout evidence is retained.
	const prior = fs.existsSync(legacy) ? fs.readFileSync(legacy) : null;
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-typing-reopen-'));
	try {
		const resultsFile = path.join(temporary, 'results.txt');
		const result = spawnSync(ahk, ['/ErrorStdOut', runner, '--only=metrics-history-reopen'], {
			windowsHide: true,
			encoding: 'utf8',
			timeout: 60000,
			maxBuffer: 16 * 1024 * 1024,
			// The fixture never reads stdin; do not keep an unused native pipe open.
			stdio: ['ignore', 'pipe', 'pipe'],
			env: {
				...process.env,
				TEMP: temporary,
				TMP: temporary,
				ERGOPTI_AHK_RESULTS_FILE: resultsFile
			}
		});
		assert.ifError(result.error);
		assert.equal(
			result.status,
			0,
			`native snapshot fixture failed: ${result.stdout}\n${result.stderr}`
		);
		const manifest = validateAhkSuiteManifest(fs.readFileSync(resultsFile, 'utf8'));
		assert.equal(manifest.complete, true, manifest.errors.join('\n'));
		assert.equal(manifest.failed, 0);
		assert.ok(manifest.executed_count > 0, 'the targeted native fixture must execute');
		const records = result.stdout
			.split(/\r?\n/)
			.filter((line) => line.startsWith('# history_snapshot'))
			.map((line) => {
				const match =
					/^# history_snapshot (live|manifest|live-cleared|manifest-cleared) (\{.*\})$/.exec(line);
				assert.ok(match, 'native snapshot receipt must have a recognized mode and JSON object');
				return { mode: match[1], blob: JSON.parse(match[2]) };
			});
		assert.deepEqual(
			records.map((record) => record.mode).sort(),
			['live', 'live-cleared', 'manifest', 'manifest-cleared'],
			'each native publication mode must supply exactly one synthetic snapshot'
		);
		return records;
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
		assert.equal(
			fs.existsSync(legacy),
			prior !== null,
			'snapshot receiving preserves checkout receipt presence'
		);
		if (prior !== null)
			assert.deepEqual(
				fs.readFileSync(legacy),
				prior,
				'snapshot receiving preserves existing checkout receipt bytes'
			);
	}
}

/**
 * Snapshots of the shape the AHK writer publishes (scan-code keyed history of
 * one typed `a`), for the OS runners that cannot execute AutoHotkey.
 * @returns {{mode: string, blob: object}[]} One record per publication mode.
 */
function portableSnapshots() {
	const count = { c: 1, e: 0, hs: 0, llm: 0, o: 0, t: 120 };
	const typed = {
		c: { a: count },
		bg: {},
		tg: {},
		w: {},
		// The writer fills kc with Windows virtual keys; the page owns their translation.
		kc: { 65: { ...count, c: 5, t: 0 } },
		sc_kb: { 30: { ...count, c: 5, t: 0 } }
	};
	const cleared = { c: {}, bg: {}, tg: {}, w: {}, kc: {}, sc_kb: {} };
	const snapshot = (historical, manifest) => ({
		_prefetch_data: { historical, today: {}, today_date: '2026-11-21' },
		app_icons: {},
		driver_meta: { heatmap_id: 'sc_kb', os: 'win' },
		keycode_layout: { 30: 'A' },
		metrics_manifest: manifest
	});
	const manifest = { '2026-11-20': { 'code.exe': { chars: 1 } } };
	return [
		{ mode: 'live', blob: snapshot(typed, manifest) },
		{ mode: 'manifest', blob: snapshot(typed, manifest) },
		{ mode: 'live-cleared', blob: snapshot(cleared, {}) },
		{ mode: 'manifest-cleared', blob: snapshot(cleared, {}) }
	];
}

/**
 * Opens a fresh real page per host and snapshot and checks its first paint.
 * @param {string} html The declared typing page.
 * @param {{mode: string, blob: object}[]} records Snapshots to deliver.
 * @param {string} origin Label naming where the snapshots came from.
 */
async function checkFreshPages(html, records, origin) {
	for (const { mode, blob } of records) {
		for (const host of ['windows', 'edge']) {
			let fetches = 0;
			const sidecar = 'file:///synthetic/snapshot.json';
			const page = loadMetricsTypingPage(host, {
				hash: `#prefetch=${encodeURIComponent(sidecar)}`,
				async fetch(url) {
					assert.equal(url, sidecar);
					fetches++;
					return {
						ok: true,
						async json() {
							return JSON.parse(JSON.stringify(blob));
						}
					};
				}
			});
			assert.equal(page.html, html, 'the reopen check opens the declared page');
			const label = `${origin} ${host}/${mode}`;
			const context = page.context;
			const received = [];
			// As in the prefetch history cases, the first view's own range request
			// is isolated: this check measures the snapshot the bootstrap admits.
			context.process_manifest = () => {};
			const receive = context.receive_range_data;
			context.receive_range_data = (value, request) => {
				const accepted = receive(value, request);
				if (accepted) received.push(JSON.parse(JSON.stringify(value)));
				return accepted;
			};
			if (host === 'windows') {
				const listeners = page.messageListeners.filter((entry) => entry.name === 'message');
				assert.equal(listeners.length, 1, `${label}: the bootstrap listens to WebView2`);
				listeners[0].callback({ data: JSON.stringify({ type: 'prefetch', blob }) });
			}
			// Drain the actual fetch/json promise chain before asserting the fresh paint.
			await new Promise((resolve) => setImmediate(resolve));
			assert.deepEqual(
				page.diagnostics.filter((entry) => entry.level === 'error'),
				[],
				`${label}: bootstrap must not swallow a failure`
			);
			assert.equal(fetches, host === 'edge' ? 1 : 0);
			assert.equal(received.length, 1, `${label}: fresh page must receive its snapshot`);
			const historical = received[0].historical;
			if (mode.endsWith('-cleared')) {
				assert.deepEqual(historical.c, {}, `${label}: deleted history must stay empty`);
				assert.deepEqual(historical.kc, {}, `${label}: deleted keys must stay empty`);
			} else {
				assert.equal(historical.c.a.c, 1, `${label}: reopening must retain historical counts`);
				// heatmap_win.js replaces the virtual-key kc with the scan code's position.
				assert.deepEqual(
					Object.keys(historical.kc),
					[String(vm.runInContext('SC_TO_KC[30]', context))],
					`${label}: the scan-code heatmap must be translated on reopen`
				);
			}
		}
	}
}

module.exports = async function checkSnapshotReopen(html) {
	const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
		.map((match) => match[1])
		.filter((source) => source.includes('let cached_historical'));
	assert.equal(scripts.length, 1, 'exactly one real prefetch bootstrap must run');
	await checkFreshPages(html, portableSnapshots(), 'portable');
	// Only the AHK writer can prove what Windows really publishes, and it runs
	// on AutoHotkey v2, which exists on Windows alone.
	if (process.platform === 'win32') await checkFreshPages(html, nativeSnapshots(), 'native');
};
