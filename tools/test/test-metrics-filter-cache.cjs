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
	const actualSfb = context.render_sfb_kpi;
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
		actualSfb,
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

// These cases execute the shipped data pipeline in a simulated DOM, not WebKit.
test('typing NONE excludes every historical and live n-gram family', () => {
	const f = typingFixture();
	const tabs = [
		'c',
		'bg',
		'tg',
		'qg',
		'pg',
		'hx',
		'hp',
		'w',
		'sc',
		'sc_bg',
		'sc_tg',
		'sc_qg',
		'sc_pg',
		'w_bg',
		'w_tg',
		'w_qg',
		'w_pg',
		'kc'
	];
	for (const tab of tabs) {
		f.state.historical_cache[tab] = { historical: { c: 7 } };
		f.state.today_live_data.Editor[tab] = { known: { c: 2 } };
		f.state.today_live_data.Unknown[tab] = { unknown: { c: 3 } };
	}
	f.state.app_selection_mode = 'none';
	f.state.selected_apps.clear();
	f.apply();
	assert.equal(Object.keys(f.state.data).length, 18, 'all shipped families must be exercised');
	for (const tab of tabs)
		assert.deepEqual(Object.keys(f.state.data[tab]), [], `${tab} must be empty`);
	assert.equal(
		f.context.get_app_selection_request_apps().length,
		0,
		'native empty-app request remains unchanged'
	);
});

test('typing selection modes preserve Unknown except explicit NONE', () => {
	const f = typingFixture();
	for (const mode of ['all', 'uninitialized', 'subset']) {
		f.state.app_selection_mode = mode;
		f.state.selected_apps.clear();
		f.apply();
		assert.equal(f.state.data.c.u.count, 1, `${mode} retains Unknown without a selected app`);
		assert.equal(f.state.data.c.a.count, 3, `${mode} does not admit unselected known live apps`);
		assert.equal(f.state.data.c.A.count, 2, `${mode} retains aggregated historical manual data`);
	}
	f.state.app_selection_mode = 'none';
	f.state.selected_apps.add('Editor');
	f.apply();
	assert.deepEqual(
		Object.keys(f.state.data.c),
		[],
		'explicit NONE wins even over a stale selected set'
	);
});

test('typing NONE preserves availability discovery and cache ownership', () => {
	const f = typingFixture();
	f.state.app_selection_mode = 'none';
	f.state.selected_apps.clear();
	f.state.today_live_data.New = { c: { n: { c: 9 } } };
	f.state.today_live_data._sys = { c: { invalid: { c: 100 } } };
	f.state.today_live_data._system = { c: { invalid: { c: 100 } } };
	f.apply();
	assert.ok(f.state.available_apps.includes('New'), 'discovery must continue with NONE');
	assert.equal(f.state.selected_apps.size, 0, 'discovery must not select apps under NONE');
	assert.equal(f.state.available_apps.includes('_sys'), false);
	assert.equal(f.state.available_apps.includes('_system'), false);
	const none = f.state.data;
	f.apply();
	assert.strictEqual(f.state.data, none);
	f.state.app_selection_mode = 'all';
	f.apply();
	assert.notStrictEqual(f.state.data, none, 'empty ALL and empty NONE are different queries');
	assert.equal(f.state.data.c.u.count, 1);
	assert.equal(f.state.data.c.invalid, undefined);
	f.state.app_selection_mode = 'none';
	f.apply();
	assert.strictEqual(f.state.data, none, 'returning to NONE reuses its own empty projection');
});

test('typing NONE filters historical and live per-app KPI inputs', () => {
	const f = typingFixture();
	f.state.manifest_dates_sorted = [];
	f.context.metrics_manifest = {
		'2026-10-01': { Editor: { chars: 7 }, Unknown: { chars: 3 }, _sys: { chars: 100 } },
		'2026-09-30': { Unknown: { chars: 200 } }
	};
	const visits = () => {
		const result = [];
		f.context._foreach_filtered_app((app, date, name) => result.push([date, name]));
		return result;
	};
	assert.equal(visits().length, 4, 'literal known and Unknown historical/live control');
	f.state.selected_apps.clear();
	f.state.app_selection_mode = 'subset';
	assert.equal(
		visits().length,
		2,
		'Unknown survives subset while dates and system exclusion remain'
	);
	f.state.app_selection_mode = 'none';
	assert.deepEqual(visits(), [], 'NONE refuses Unknown across both data sources');
});

test('typing NONE empties actual raw and hotstring SFB computations', () => {
	const f = typingFixture();
	// Restore the actual function captured before the fixture's presentation stubs.
	f.context.render_sfb_kpi = f.actualSfb;
	f.context.KEYCODE_NAMES = { 1: 'a' };
	f.context.SFB_COLUMNS = { 1: 'index_left' };
	f.context.FINGER_LABELS_FR = { index_left: 'Index G' };
	f.context.format_number = String;
	f.context._t = (key) => key;
	f.context.INFO_SVG = '';
	f.context.render_sfb_table = () => {};
	f.elements.sfb_pct = {};
	f.elements.sfb_avoided = {};
	f.state.historical_cache = { bg: { aa: { c: 7, hs: 2 } } };
	f.state.today_live_data = {
		Editor: { bg: { aa: { c: 2, hs: 1 } } },
		Unknown: { bg: { aa: { c: 3, hs: 1 } } }
	};
	f.context.render_sfb_kpi();
	assert.equal(f.elements.sfb_pct.innerHTML, '8 ui_typing.sfb_raw_count');
	assert.equal(f.elements.sfb_avoided.innerHTML, '4 ui_typing.sfb_avoided (50.0%)');
	f.state.selected_apps.clear();
	f.state.app_selection_mode = 'subset';
	f.context.render_sfb_kpi();
	assert.equal(f.elements.sfb_pct.innerHTML, '7 ui_typing.sfb_raw_count');
	assert.equal(f.elements.sfb_avoided.innerHTML, '3 ui_typing.sfb_avoided (42.9%)');
	f.state.app_selection_mode = 'none';
	f.context.render_sfb_kpi();
	assert.equal(f.elements.sfb_pct.innerHTML, '0 ui_typing.sfb_raw_count');
	assert.equal(f.elements.sfb_avoided.innerHTML, 'ui_typing.sfb_avoided_none');
	assert.equal(
		vm.runInContext('_sfb_data.length', f.context),
		0,
		'the actual detail data must be empty'
	);
	assert.equal(vm.runInContext('Object.keys(_sfb_heatmap_full.sfb_by_kc).length', f.context), 0);
});

assert.equal(passed, 12, 'all original seven and five selection regressions must execute');

console.log(`${passed} passed, 0 failed.`);
