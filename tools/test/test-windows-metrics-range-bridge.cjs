// tools/test/test-windows-metrics-range-bridge.cjs

/**
 * ============================================================================== 
 * MODULE: Windows Metrics Selected-Range Bridge Test
 * DESCRIPTION:
 * Static cross-layer regression gate for the WebView2 request/response contract
 * used when a typing-dashboard date or application filter changes.
 * ============================================================================== 
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

const data = read('static/ergopti_plus/_shared/ui/metrics_typing/data.js');
const html = read('static/ergopti_plus/_shared/ui/metrics_typing/index.html');
const main = read('static/ergopti_plus/_shared/ui/metrics_typing/main.js');
const state = read('static/ergopti_plus/_shared/ui/metrics_typing/state.js');
const host = read('static/ergopti_plus/windows/modules/keylogger/keylogger_webview.ahk');
const worker = read('static/ergopti_plus/windows/modules/keylogger/keylogger_prefetch.ahk');
const macos = read('static/ergopti_plus/macos/ui/metrics_typing/init.lua');
const linux = read('static/ergopti_plus/linux/ui/metrics_typing/bridge.lua');

function extractFunction(source, name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notStrictEqual(start, -1, `${name} must exist`);
	const bodyStart = source.indexOf('{', start);
	let depth = 0;
	let quote = null;
	let escaped = false;
	for (let i = bodyStart; i < source.length; i++) {
		const ch = source[i];
		if (quote) {
			if (escaped) escaped = false;
			else if (ch === '\\') escaped = true;
			else if (ch === quote) quote = null;
			continue;
		}
		if (ch === "'" || ch === '"' || ch === '`') {
			quote = ch;
			continue;
		}
		if (ch === '{') depth++;
		else if (ch === '}' && --depth === 0) return source.slice(start, i + 1);
	}
	assert.fail(`unterminated ${name} function`);
}

assert.match(data, /window\.chrome\?\.webview/,
	'Windows must detect the native WebView2 bridge before falling back to macOS polling');
assert.match(data, /postMessage\(JSON\.stringify\(\{ action: 'range', \.\.\.req \}\)\)/,
	'Windows must send the selected date/app range to the native host');
assert.match(data, /const req = \{\s*request_id,/,
	'every native range backend must receive the monotonic UI request owner');
assert.match(host, /case "range"/,
	'Windows host must receive the selected-range action');
assert.match(host, /KLPF_RequestRange\(which, KLWV\.metrics_dir, query, Epoch,/,
	'Windows must dispatch range projection to the asynchronous worker after the WebView callback returns');
assert.match(host, /KLWV_OnRangeBuildTerminal\.Bind\(which, Epoch, request_id\)/,
	'Windows range terminal must bind both the dashboard epoch and UI request owner');
assert.match(host, /KLWV_OnRangeBuildTerminal\(which, Epoch, request_id, status, stage := ""\)/,
	'Windows must consume the typed worker terminal in the bound-argument order');
assert.match(host, /ExecuteScriptAsync\(js\)/,
	'Windows must let WebView read and decode the staged range payload off the keyboard thread');
assert.match(host, /envelope\["type"\] := "range_terminal"/,
	'Windows failure/cancel responses must use the namespaced typed terminal envelope');
assert.match(host, /envelope\["request_id"\] := request_id/,
	'Windows failure/cancel responses must echo the current request owner');
assert.match(host, /envelope\["status"\] := status/,
	'Windows failure/cancel responses must echo the current terminal status');
assert.match(worker, /KLPF_CompleteJob\(which, generation, status, stage\)/,
	'worker completion must route every status through the exact-once job owner');
assert.match(html, /payload\.type === 'range_terminal'/,
	'WebView2 frontend must recognise failure/cancel terminal envelopes');
assert.match(html, /window\.complete_range_request\(payload\.request_id, payload\.status\)/,
	'WebView2 terminal envelopes must release only their owning request');
assert.match(main, /window\.complete_range_request = complete_range_request/,
	'the native WebView script must be able to reach the shared terminal function');
assert.match(macos, /window\.receive_range_data\(%s,%d\).*request_id/s,
	'macOS must echo the shared request owner through its existing evaluateJavaScript response');
assert.match(linux, /range_request_id = payload\.request_id/,
	'Linux must echo the shared request owner through its existing bridge envelope');

const timeoutMatch = state.match(/const RANGE_REQUEST_WATCHDOG_MS = ([\d_]+);/);
assert.ok(timeoutMatch, 'shared state must define one finite named range watchdog');
const watchdogMs = Number(timeoutMatch[1].replaceAll('_', ''));
assert.ok(Number.isFinite(watchdogMs) && watchdogMs > 0,
	'range watchdog must be finite and positive');
const APP_SELECTION_MODE = Object.freeze({
	UNINITIALIZED: 'uninitialized',
	ALL: 'all',
	NONE: 'none',
	SUBSET: 'subset',
});
assert.match(state, /app_selection_mode:\s*APP_SELECTION_MODE\.UNINITIALIZED/,
	'app selection must start explicitly uninitialized instead of overloading an empty Set');

const timers = new Map();
let nextTimerId = 1;
const posted = [];
let applyCount = 0;
const tableBody = { innerHTML: '<tr><td>last-good</td></tr>' };
const elements = {
	date_start: { value: '2026-08-01' },
	date_end: { value: '2026-08-08' },
	metrics_table_body: tableBody,
};
const appState = {
	available_apps: ['editor.exe'],
	selected_apps: new Set(['editor.exe']),
	app_selection_mode: APP_SELECTION_MODE.ALL,
	loading_data: false,
	range_request_sequence: 0,
	active_range_request_id: 0,
	range_request_watchdog: null,
	range_request_show_loader: false,
	range_request_previous_table_html: null,
	historical_cache: { marker: 'old-historical' },
	today_live_data: { marker: 'old-today' },
};
const page = {
	_lua_request: null,
	chrome: {
		webview: {
			postMessage(message) {
				posted.push(JSON.parse(message));
			},
		},
	},
};
const context = {
	app_state: appState,
	window: page,
	document: { getElementById: (id) => elements[id] || null },
	apply_local_filters: () => { applyCount++; },
	setTimeout(callback, delay) {
		const id = nextTimerId++;
		timers.set(id, { callback, delay });
		return id;
	},
	clearTimeout(id) { timers.delete(id); },
	APP_SELECTION_MODE,
	console,
};
vm.createContext(context);
vm.runInContext(
	`const RANGE_REQUEST_WATCHDOG_MS = ${watchdogMs};\n` +
		extractFunction(data, 'complete_range_request') + '\n' +
		extractFunction(data, 'get_app_selection_request_apps') + '\n' +
		extractFunction(data, 'request_range_data') + '\n' +
		extractFunction(data, 'receive_range_data'),
	context,
	{ filename: 'metrics-range-latch.js' }
);

function fireTimer(delay) {
	const match = [...timers.entries()].find(([, timer]) => timer.delay === delay);
	assert.ok(match, `expected active timer with delay ${delay}`);
	const [id, timer] = match;
	timers.delete(id);
	timer.callback();
}

context.request_range_data();
const firstId = appState.active_range_request_id;
assert.strictEqual(firstId, 1);
assert.strictEqual(appState.loading_data, true);
fireTimer(50);
assert.strictEqual(posted.length, 1);
assert.strictEqual(posted[0].request_id, firstId,
	'WebView2 request must carry its monotonic owner');
assert.deepStrictEqual(posted[0].apps, ['editor.exe'],
	'all-app mode must serialize every available named application');
assert.strictEqual(context.complete_range_request(firstId, 'failed'), true);
assert.strictEqual(appState.loading_data, false,
	'a current failure terminal must release the latch');
assert.strictEqual(tableBody.innerHTML, '<tr><td>last-good</td></tr>',
	'a failed request must restore the last-good table instead of leaving its spinner');

context.request_range_data(false);
const secondId = appState.active_range_request_id;
assert.strictEqual(secondId, 2);
fireTimer(50);
assert.strictEqual(context.complete_range_request(firstId, 'failed'), false,
	'a duplicate/late terminal must not release a newer request');
assert.strictEqual(appState.loading_data, true);
assert.strictEqual(context.receive_range_data({ historical: { marker: 'stale' }, today: {} }, firstId), false,
	'a late payload must not overwrite the newer request');
assert.strictEqual(appState.historical_cache.marker, 'old-historical');
assert.strictEqual(context.receive_range_data(
	{ historical: { marker: 'current' }, today: { marker: 'current-today' } }, secondId
), true);
assert.strictEqual(appState.loading_data, false);
assert.strictEqual(appState.historical_cache.marker, 'current');
assert.strictEqual(applyCount, 1);
assert.strictEqual(context.complete_range_request(secondId, 'ok'), false,
	'a duplicate success terminal must be idempotent');

context.request_range_data();
const timedOutId = appState.active_range_request_id;
fireTimer(50);
fireTimer(watchdogMs);
assert.strictEqual(appState.loading_data, false,
	'the finite watchdog must recover when the native host disappears');
assert.strictEqual(context.receive_range_data(
	{ historical: { marker: 'too-late' }, today: {} }, timedOutId
), false, 'a payload arriving after watchdog recovery must be stale');
assert.strictEqual(appState.historical_cache.marker, 'current',
	'watchdog recovery must preserve the last-good payload');

page.chrome.webview.postMessage = () => { throw new Error('bridge closed'); };
context.request_range_data();
const bridgeFailureId = appState.active_range_request_id;
fireTimer(50);
assert.ok(bridgeFailureId > timedOutId);
assert.strictEqual(appState.loading_data, false,
	'a synchronous WebView2 post failure must release its latch immediately');
assert.strictEqual(page._lua_request, null,
	'a failed Windows bridge must not fall through to the macOS-only polling slot');

appState.app_selection_mode = APP_SELECTION_MODE.NONE;
appState.selected_apps = new Set(['stale.exe']);
assert.deepStrictEqual(Array.from(context.get_app_selection_request_apps()), [],
	'explicit none must serialize as empty even if a stale Set entry survives');
appState.app_selection_mode = APP_SELECTION_MODE.ALL;
appState.selected_apps = new Set();
assert.deepStrictEqual(Array.from(context.get_app_selection_request_apps()), ['editor.exe'],
	'all mode must not depend on a stale selected-app Set');
appState.app_selection_mode = APP_SELECTION_MODE.SUBSET;
appState.selected_apps.add('editor.exe');
assert.deepStrictEqual(Array.from(context.get_app_selection_request_apps()), ['editor.exe'],
	'subset mode must serialize only its explicit selection');

const manifestState = {
	available_apps: ['editor.exe', 'terminal.exe'],
	selected_apps: new Set(),
	app_selection_mode: APP_SELECTION_MODE.NONE,
	did_apply_initial_reset: true,
	manifest_dates_sorted: [],
};
const manifestPage = {
	metrics_manifest: {
		'2026-08-08': {
			'editor.exe': {},
			'terminal.exe': {},
			'new.exe': {},
			Unknown: {},
		},
	},
};
let manifestRefreshes = 0;
const manifestContext = {
	app_state: manifestState,
	window: manifestPage,
	document: {
		getElementById(id) {
			if (id === 'date_start' || id === 'date_end') return { value: '2026-08-08' };
			return null;
		},
	},
	APP_SELECTION_MODE,
	apply_default_date_range() {},
	reset_filters() {},
	update_app_btn_text() {},
	compute_manifest_metrics() {},
	request_range_data() { manifestRefreshes++; },
	ensure_live_refresh() {},
	console,
};
vm.createContext(manifestContext);
vm.runInContext(extractFunction(data, 'process_manifest'), manifestContext,
	{ filename: 'metrics-app-selection-refresh.js' });

manifestContext.process_manifest();
assert.strictEqual(manifestState.app_selection_mode, APP_SELECTION_MODE.NONE);
assert.strictEqual(manifestState.selected_apps.size, 0,
	'an explicit empty selection must survive a manifest refresh');

manifestState.available_apps = ['editor.exe', 'terminal.exe'];
manifestState.selected_apps = new Set(['editor.exe', 'terminal.exe']);
manifestState.app_selection_mode = APP_SELECTION_MODE.ALL;
manifestContext.process_manifest();
assert.deepStrictEqual([...manifestState.selected_apps].sort(),
	['editor.exe', 'new.exe', 'terminal.exe'],
	'all mode must absorb applications first seen by a refreshed manifest');

manifestState.available_apps = ['editor.exe', 'terminal.exe'];
manifestState.selected_apps = new Set(['editor.exe']);
manifestState.app_selection_mode = APP_SELECTION_MODE.SUBSET;
manifestContext.process_manifest();
assert.deepStrictEqual([...manifestState.selected_apps], ['editor.exe'],
	'a subset must neither collapse into all nor auto-select a newly seen app');
assert.strictEqual(manifestRefreshes, 3,
	'each manifest refresh must request data for the preserved selection state');

console.log('Windows metrics selected-range bridge contract: OK');
