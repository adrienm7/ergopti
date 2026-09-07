/**
 * tools/test/test-typing-metrics-range-supersession.cjs
 * ==============================================================================
 * MODULE: Typing Metrics Filter Request Ownership
 * DESCRIPTION:
 * Replays filter changes against the real dashboard and all native transports.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui/metrics_typing');
let passed = 0;
let failed = 0;

function fixture(host = 'macos') {
	const timers = new Map();
	let nextTimer = 0;
	const requests = [];
	const renders = [];
	const elements = { date_start: { value: '2026-09-01' }, date_end: { value: '2026-09-01' },
		metrics_table_body: { innerHTML: 'last-good' }, btn_case_sensitive: { classList: { contains: () => true } } };
	const state = { loading_data: false, range_request_sequence: 0, active_range_request_id: 0,
		range_request_watchdog: null, available_apps: ['Editor', 'Browser'], selected_apps: new Set(['Editor']),
		app_selection_mode: 'subset' };
	const context = vm.createContext({ app_state: state,
		APP_SELECTION_MODE: { ALL: 'all', NONE: 'none', SUBSET: 'subset', UNINITIALIZED: 'uninitialized' },
		document: { getElementById: (id) => elements[id] || null }, console,
		setTimeout(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; },
		clearTimeout(id) { timers.delete(id); } });
	context.window = context;
	if (host === 'windows') context.chrome = { webview: { postMessage: (raw) => requests.push(JSON.parse(raw)) } };
	if (host === 'linux') {
		context.__ergopti_host = 'linux';
		context.webkit = { messageHandlers: { metrics_typing_bridge: { postMessage: (req) => requests.push(req) } } };
	}
	context.RANGE_REQUEST_WATCHDOG_MS = Number(fs.readFileSync(path.join(root, 'state.js'), 'utf8')
		.match(/const RANGE_REQUEST_WATCHDOG_MS = ([\d_]+);/)[1].replaceAll('_', ''));
	for (const name of ['data.js', 'filters.js']) vm.runInContext(fs.readFileSync(path.join(root, name), 'utf8'), context);
	context.compute_manifest_metrics = () => {};
	context.get_source_mode_flags = () => ({ show_manual: true, show_hs: false, show_llm: false });
	context.get_local_date_string = () => '2026-09-07';
	for (const key of Object.keys(context)) {
		if (/^render_.*_kpi$/.test(key) || key === 'recompute_speed_kpi') context[key] = () => {};
	}
	context.render_current_tab = () => renders.push(Object.keys(state.data.c));
	function dispatch() {
		for (const [id, timer] of Array.from(timers)) {
			if (timer.delay === 50) { timers.delete(id); timer.fn(); }
		}
		if (host === 'macos' && context._lua_request) {
			requests.push(JSON.parse(context._lua_request));
			context._lua_request = null;
		}
	}
	function select(app, date = '2026-09-02') {
		state.selected_apps = new Set([app]);
		elements.date_start.value = elements.date_end.value = date;
		context.apply_date_app_filters();
	}
	return { context, state, timers, requests, renders, elements, dispatch, select };
}

function test(name, callback) {
	try { callback(); passed++; console.log(`ok ${name}`); }
	catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`); }
}

const payload = (key) => ({ historical: { c: { [key]: { c: 9 } } }, today: {} });

for (const host of ['macos', 'windows', 'linux']) {
	test(`${host}: changed filters revoke pending response (filter-request-ownership)`, () => {
		const f = fixture(host);
		f.context.apply_date_app_filters(); f.dispatch();
		const old = f.requests[0];
		f.select('Browser'); f.dispatch();
		assert.equal(f.requests.length, 2);
		const latest = f.requests[1];
		assert.ok(latest.request_id > old.request_id);
		assert.equal(latest.start_date, '2026-09-02');
		assert.deepEqual(Array.from(latest.apps), ['Browser']);
		assert.equal(f.context.receive_range_data(payload('old'), old.request_id), false);
		assert.equal(f.renders.length, 0);
		assert.equal(f.state.loading_data, true);
		assert.equal(f.context.receive_range_data(payload('latest'), latest.request_id), true);
		assert.deepEqual(f.renders, [['latest']]);
		assert.equal(f.state.data.c.latest.count, 9);
		assert.equal(f.state.loading_data, false);
	});
	test(`${host}: rapid changes retire old delayed dispatch and watchdog`, () => {
		const f = fixture(host);
		f.context.request_range_data();
		const oldWatchdog = f.timers.get(f.state.range_request_watchdog).fn;
		f.select('Browser'); f.select('Editor', '2026-09-03');
		const current = f.state.active_range_request_id;
		assert.equal(current, 3);
		oldWatchdog();
		assert.equal(f.state.active_range_request_id, current);
		f.dispatch();
		assert.equal(f.requests.length, 1);
		assert.equal(f.requests[0].start_date, '2026-09-03');
		assert.equal(f.context.complete_range_request(1, 'failed'), false);
		assert.equal(f.state.loading_data, true);
	});
}

test('equivalent app sets coalesce despite insertion order or selection mode', () => {
	const f = fixture();
	f.state.selected_apps = new Set(['Browser', 'Editor']);
	f.context.request_range_data(false);
	f.state.app_selection_mode = 'all';
	f.context.request_range_data(false);
	assert.equal(f.state.range_request_sequence, 1);
	f.dispatch();
	assert.equal(f.requests.length, 1);
});

test('date-only and app-only changes both acquire new ownership', () => {
	const f = fixture();
	f.context.request_range_data();
	f.select('Editor');
	assert.equal(f.state.range_request_sequence, 2);
	f.select('Browser');
	assert.equal(f.state.range_request_sequence, 3);
});

for (const loader of [true, false]) {
	test(`replacement timeout preserves last-good content with loader=${loader}`, () => {
		const f = fixture();
		f.context.request_range_data();
		f.elements.date_end.value = '2026-09-03';
		f.context.request_range_data(loader);
		assert.equal(f.state.range_request_sequence, 2);
		f.timers.get(f.state.range_request_watchdog).fn();
		assert.equal(f.elements.metrics_table_body.innerHTML, 'last-good');
		assert.equal(f.state.loading_data, false);
		f.dispatch();
		assert.equal(f.requests.length, 0);
	});
}

test('completed identical query can refresh again', () => {
	const f = fixture();
	f.context.request_range_data();
	f.context.receive_range_data(payload('first'), 1);
	f.context.request_range_data(false);
	assert.equal(f.state.range_request_sequence, 2);
});

for (const host of ['windows', 'linux']) {
	test(`${host}: replacement transport failure restores last-good view`, () => {
		const f = fixture(host);
		f.context.request_range_data(); f.dispatch();
		f.select('Browser');
		const bridge = host === 'windows' ? f.context.chrome.webview
			: f.context.webkit.messageHandlers.metrics_typing_bridge;
		bridge.postMessage = () => { throw new Error('native transport unavailable'); };
		f.dispatch();
		assert.equal(f.state.loading_data, false);
		assert.equal(f.elements.metrics_table_body.innerHTML, 'last-good');
		assert.equal(f.context.receive_range_data(payload('old'), 1), false);
		assert.equal(f.renders.length, 0);
	});
}

test('same-query background refresh preserves foreground loader and deadline', () => {
	const f = fixture();
	f.context.request_range_data();
	const watchdog = f.state.range_request_watchdog;
	const loader = f.elements.metrics_table_body.innerHTML;
	f.context.request_range_data(false);
	assert.equal(f.state.range_request_watchdog, watchdog);
	assert.equal(f.elements.metrics_table_body.innerHTML, loader);
	assert.equal(f.state.range_request_previous_table_html, 'last-good');
});

test('none selection is distinct from all available apps', () => {
	const f = fixture();
	f.state.app_selection_mode = 'all';
	f.context.request_range_data();
	f.state.app_selection_mode = 'none';
	f.context.request_range_data(); f.dispatch();
	assert.equal(f.requests.length, 1);
	assert.equal(f.requests[0].request_id, 2);
	assert.deepEqual(Array.from(f.requests[0].apps), []);
});

console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
