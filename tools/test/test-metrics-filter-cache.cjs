/**
 * tools/test/test-metrics-filter-cache.cjs
 * ==============================================================================
 * MODULE: Metrics Filter Projection Cache Regression Tests
 * DESCRIPTION:
 * Exercises the scripts loaded by the real dashboards, including native updates.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
let passed = 0;

function test(name, callback) {
	callback();
	passed++;
	console.log(`ok ${name}`);
}

function appsFixture() {
	const context = vm.createContext({ window: {}, document: { addEventListener() {} }, console });
	const index = read('metrics_apps/index.html');
	vm.runInContext(read('host_bridge.js'), context);
	for (const name of ['helpers.js', 'state.js', 'main.js']) {
		assert.ok(index.includes(`src="${name}"`), `${name} must be loaded by the actual page`);
		vm.runInContext(read(`metrics_apps/${name}`), context);
	}
	vm.runInContext('initDashboard = () => {}; renderDashboard = () => {};', context);
	return {
		context,
		set: (code) => vm.runInContext(code, context),
		get: () => context.getAggregatedData(),
		stats: context.window.appsFilterPerformance
	};
}

const manifest = {
	'2026-10-01': {
		Editor: { category: 'development', app_time_ms: 12000, chars: 10, time: 500 },
		Browser: { category: 'productivity', app_time_ms: 8000, chars: 4 },
		_system: { awake_ms: 2000, locked_ms: 1000 }
	},
	'2026-10-02': { Editor: { category: 'development', app_time_ms: 6000, chars: 3 } }
};

test('apps reuse canonical queries and keep null distinct from empty filters', () => {
	const f = appsFixture();
	f.context.window.bootstrapMetricsAppsData(manifest, {}, {});
	f.set("currentPeriod = 'all';");
	const all = f.get();
	assert.strictEqual(f.get(), all, 'second query must reuse the retained projection');
	f.set('currentCategoryFilter = new Set();');
	assert.equal(Object.keys(f.get().apps).length, 0);
	f.set('currentCategoryFilter = null; currentWeekdayFilter = new Set([4, 3]);');
	const weekdays = f.get();
	f.set('currentWeekdayFilter = new Set([3, 4]);');
	assert.strictEqual(f.get(), weekdays);
	f.set('currentWeekdayFilter = new Set();');
	assert.equal(f.get().rich.date_range.days, 0);
	f.set('currentWeekdayFilter = null; currentCountAwake = true;');
	assert.notStrictEqual(f.get(), all);
	assert.equal(f.stats.entries, 4, 'query history must stay bounded');
});

test('apps invalidate live in-place updates, bootstrap, categories and translated labels', () => {
	const f = appsFixture();
	f.context.window.bootstrapMetricsAppsData(structuredClone(manifest), {}, {});
	f.set("currentPeriod = 'all';");
	const old = f.get();
	f.context.window.receive_live_update({ '2026-10-02': { Editor: { chars: 90 } } });
	const live = f.get();
	assert.notStrictEqual(live, old);
	assert.equal(live.apps.Editor.chars, 100);
	f.context.window.updateUserCategories({ Editor: { type: 'productivity', score: 8 } });
	assert.notStrictEqual(f.get(), live);
	const category = f.get();
	f.context.window._i18n_locale = 'en';
	assert.notStrictEqual(f.get(), category);
	const locale = f.get();
	f.context.window._i18n_strings = { 'app_category.productivity': 'Work' };
	const translated = f.get();
	assert.notStrictEqual(translated, locale);
	assert.equal(f.context.getAppCategory('Editor').type, 'Work');
	f.context.window.bootstrapMetricsAppsData({}, {}, {});
	assert.equal(Object.keys(f.get().apps).length, 0);
});

test('apps comparator anchors and periods never share the wrong projection', () => {
	const f = appsFixture();
	f.context.window.bootstrapMetricsAppsData(manifest, {}, {});
	f.set("currentSelectedDate = '2026-10-02'; currentPeriod = 'day';");
	const today = f.get();
	assert.equal(today.apps.Editor.chars, 3);
	f.set("currentSelectedDate = '2026-10-01';");
	assert.equal(f.get().apps.Editor.chars, 10);
	f.set("currentSelectedDate = '2026-10-02';");
	assert.strictEqual(f.get(), today);
	f.set("currentPeriod = 'week';");
	assert.equal(f.get().apps.Editor.chars, 13);
	for (const period of ['month', 'year', 'all', 'day', 'week']) {
		f.set(`currentPeriod = '${period}';`);
		f.get();
		assert.ok(f.stats.entries <= 4);
	}
	assert.equal(f.stats.entries, 4);
});

function typingFixture() {
	const timers = new Map();
	let nextTimer = 0;
	let today = '2026-10-02';
	let caseSensitive = true;
	let modes = { show_manual: true, show_hs: false, show_llm: false };
	let renders = 0;
	let speeds = 0;
	const elements = {
		date_start: { value: '2026-10-01' },
		date_end: { value: '2026-10-02' },
		btn_case_sensitive: { classList: { contains: () => caseSensitive } }
	};
	const state = {
		available_apps: ['Editor'],
		selected_apps: new Set(['Editor']),
		app_selection_mode: 'all',
		active_range_request_id: 0,
		active_cache_reset_id: 0,
		range_request_watchdog: null,
		cache_reset_watchdog: null,
		cache_reset_sequence: 0,
		historical_cache: { c: { A: { c: 4, hs: 2 }, a: { c: 3 } } },
		today_live_data: { Editor: { c: { a: { c: 2 } } }, Unknown: { c: { u: { c: 1 } } } }
	};
	const context = vm.createContext({
		app_state: state,
		APP_SELECTION_MODE: {
			ALL: 'all',
			NONE: 'none',
			SUBSET: 'subset',
			UNINITIALIZED: 'uninitialized'
		},
		RANGE_REQUEST_WATCHDOG_MS: 5000,
		document: { getElementById: (id) => elements[id] || null },
		console,
		setTimeout(fn) {
			const id = ++nextTimer;
			timers.set(id, fn);
			return id;
		},
		clearTimeout(id) {
			timers.delete(id);
		}
	});
	context.window = context;
	vm.runInContext(read('metrics_typing/data.js'), context);
	context.get_source_mode_flags = () => modes;
	context.get_local_date_string = () => today;
	context.update_app_btn_text = () => {};
	for (const key of Object.keys(context)) {
		if (/^render_.*_kpi$/.test(key)) context[key] = () => {};
	}
	context.recompute_speed_kpi = () => speeds++;
	context.render_current_tab = () => renders++;
	return {
		context,
		state,
		elements,
		timers,
		apply: () => context.apply_local_filters(),
		stats: context.typingFilterPerformance,
		case: (value) => {
			caseSensitive = value;
		},
		today: (value) => {
			today = value;
		},
		modes: (value) => {
			modes = value;
		},
		renders: () => renders,
		speeds: () => speeds
	};
}

test('typing retains current/previous projections but still recomputes presentation', () => {
	const f = typingFixture();
	f.apply();
	const first = f.state.data;
	const serialized = JSON.stringify(first);
	f.apply();
	assert.strictEqual(f.state.data, first);
	assert.equal(f.renders(), 2);
	assert.equal(f.speeds(), 2, 'a pause threshold refresh must recompute speed');
	f.case(false);
	f.apply();
	assert.notStrictEqual(f.state.data, first);
	f.case(true);
	f.apply();
	assert.strictEqual(f.state.data, first, 'returning to previous filter must reuse its projection');
	assert.equal(
		JSON.stringify(first),
		serialized,
		'building another query must not mutate a cached projection'
	);
	assert.equal(f.stats.misses, 2);
	assert.equal(f.stats.hits, 2);
	assert.equal(f.stats.entries, 2);
});

test('typing keys source mode, selection, dates and local midnight', () => {
	const f = typingFixture();
	f.apply();
	const first = f.state.data;
	f.modes({ show_manual: true, show_hs: true, show_llm: false });
	f.apply();
	assert.notStrictEqual(f.state.data, first);
	f.state.selected_apps.clear();
	f.apply();
	assert.equal(f.state.data.c.u.count, 1, 'Unknown remains included');
	assert.equal(f.state.data.c.a.count, 3, 'unselected live apps are excluded');
	f.elements.date_end.value = '2026-10-01';
	f.apply();
	assert.equal(f.state.data.c.u, undefined);
	const yesterday = f.state.data;
	f.today('2026-10-03');
	f.apply();
	assert.notStrictEqual(f.state.data, yesterday);
	assert.ok(f.stats.entries <= 2);
});

test('typing live discovery is keyed after ALL selection and rejects system pseudo-apps', () => {
	const f = typingFixture();
	f.state.today_live_data.New = { c: { n: { c: 9 } } };
	f.state.today_live_data._system = { c: { invalid: { c: 100 } } };
	f.apply();
	assert.ok(f.state.selected_apps.has('New'));
	assert.equal(f.state.data.c.n.count, 9);
	assert.equal(f.state.data.c.invalid, undefined);
	const first = f.state.data;
	f.apply();
	assert.strictEqual(f.state.data, first);
});

test('typing native acceptance, stale responses, in-place live pushes and Reset own invalidation', () => {
	const f = typingFixture();
	f.apply();
	const first = f.state.data;
	f.state.active_range_request_id = 7;
	assert.equal(f.context.receive_range_data({ historical: {}, today: {} }, 6), false);
	f.apply();
	assert.strictEqual(f.state.data, first, 'stale responses cannot retire current data');
	assert.equal(
		f.context.receive_range_data({ historical: { c: { x: { c: 8 } } }, today: {} }, 7),
		true
	);
	assert.equal(f.state.data.c.x.count, 8);
	assert.equal(f.state.data.c.a, undefined);
	const sameLiveObject = f.state.today_live_data;
	sameLiveObject.Editor = { c: { a: { c: 40 } } };
	f.context.receive_live_update(sameLiveObject);
	f.apply();
	assert.equal(f.state.data.c.a.count, 40, 'live invalidation must precede its debounce');
	f.context.request_cache_reset();
	assert.equal(f.stats.entries, 0);
});

console.log(`${passed} passed, 0 failed.`);
