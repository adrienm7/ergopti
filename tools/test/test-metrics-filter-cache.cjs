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
const { installHostCapabilities } = require('./support/host-capabilities.cjs');
const root = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
let passed = 0;

function test(name, callback) {
	callback();
	passed++;
	console.log(`ok ${name}`);
}

function appsFixture() {
	const context = vm.createContext({
		window: {},
		document: {
			addEventListener() {},
			getElementById() {
				return null;
			}
		},
		console
	});
	const index = read('metrics_apps/index.html');
	vm.runInContext(read('host_bridge.js'), context);
	vm.runInContext(read('_generated/metrics_general_category_aliases.js'), context);
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
	installHostCapabilities(context);
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

// Date labels are untrusted even when a manifest key cannot be parsed.
{
	test('metrics date labels remain literal at all HTML sinks', () => {
		const elements = Object.fromEntries(
			['day_timeline_container', 'top_sessions_tbody', 'top_days_tbody'].map((id) => [
				id,
				{ innerHTML: '' }
			])
		);
		const context = vm.createContext({
			window: {},
			document: { addEventListener() {}, getElementById: (id) => elements[id] || null },
			console
		});
		vm.runInContext(read('host_bridge.js'), context);
		vm.runInContext(read('dom_utils.js'), context);
		vm.runInContext(read('_generated/metrics_general_category_aliases.js'), context);
		for (const name of ['helpers.js', 'state.js', 'main.js', 'charts.js', 'modal.js']) {
			assert.ok(read('metrics_apps/index.html').includes(`src="${name}"`));
			vm.runInContext(read(`metrics_apps/${name}`), context);
		}
		vm.runInContext('initDashboard = () => {}; renderDashboard = () => {};', context);
		const hostile = '<img src=x onerror="window.pwned=true">';
		assert.equal(
			context.formatDisplayDate(hostile),
			hostile,
			'the malformed date reaches the raw fallback'
		);
		context.window.bootstrapMetricsAppsData(
			{ [hostile]: { Editor: { session_longest_ms: 1000, session_longest_chars: 3 } } },
			{},
			{}
		);
		vm.runInContext('renderDayTimeline(); renderTopSessionsTable();', context);
		context.renderTopDaysTable({ rich: { by_date: { [hostile]: { chars: 3 } } } });
		for (const [id, element] of Object.entries(elements)) {
			assert.ok(element.innerHTML.includes('&lt;img'), `${id} must preserve escaped date text`);
			assert.ok(!element.innerHTML.includes('<img'), `${id} must not create a date element`);
		}
		assert.equal(context.window.pwned, undefined);
		context.window.bootstrapMetricsAppsData(
			{ '2026-10-11': { Editor: { session_longest_ms: 1000, session_longest_chars: 3 } } },
			{},
			{}
		);
		vm.runInContext('renderDayTimeline(); renderTopSessionsTable();', context);
		context.renderTopDaysTable({ rich: { by_date: { '2026-10-11': { chars: 3 } } } });
		for (const element of Object.values(elements))
			assert.ok(element.innerHTML.includes('11/10/2026'));
	});
}
assert.equal(passed, 13, 'the twelve existing controls and the date sink chain must execute');

// Replay host data through real aggregation before inspecting its HTML display.
{
	test('metrics top days escape actual aggregate switch labels', () => {
		const context = appsFixture().context;
		vm.runInContext(read('metrics_apps/charts.js'), context);
		vm.runInContext(read('metrics_apps/modal.js'), context);
		vm.runInContext(read('dom_utils.js'), context);
		const tbody = { innerHTML: '' };
		context.document.getElementById = (id) => (id === 'top_days_tbody' ? tbody : null);
		const hostile = '<img src=x onerror="window.pwned=true">';
		const publish = (switches) => {
			context.window.bootstrapMetricsAppsData(
				{
					'2026-10-11': {
						Editor: {
							chars: 3,
							app_time_ms: 60000,
							session_count_total: 2,
							switches_to: { Browser: switches }
						}
					}
				},
				{},
				{}
			);
			vm.runInContext("currentPeriod = 'all';", context);
			return context.getAggregatedData();
		};
		const aggregate = publish(hostile);
		assert.equal(aggregate.rich.by_date['2026-10-11'].switches, '0' + hostile);
		assert.equal(aggregate.rich.by_date['2026-10-11'].sessions, 2);
		context.renderTopDaysTable(aggregate);
		assert.ok(
			tbody.innerHTML.includes('0&lt;img'),
			'the actual accumulated value stays literal text'
		);
		assert.ok(!tbody.innerHTML.includes('<img'), 'the aggregate must not create an HTML element');
		assert.equal(context.window.pwned, undefined);
		const ordinary = publish(5);
		assert.equal(ordinary.rich.by_date['2026-10-11'].switches, 5);
		context.renderTopDaysTable(ordinary);
		assert.ok(tbody.innerHTML.includes('>5</td>'));
		assert.ok(tbody.innerHTML.includes('>2</td>'));
	});
}
assert.equal(passed, 14, 'the thirteen prior controls and the aggregate sink chain must execute');

// A page script no page loads is dead code that still gets tested, linted and
// baselined (metrics_apps/script.js, a 3600-line copy of the split modules, was
// retired on 2026-10-26): every script of the dashboard must be loaded by it.
test('every script of the metrics apps dashboard is loaded by its page', () => {
	const page = read('metrics_apps/index.html');
	const scripts = fs
		.readdirSync(path.join(root, 'metrics_apps'))
		.filter((name) => name.endsWith('.js'));
	assert.ok(scripts.length >= 5, 'the dashboard scripts must be found');
	for (const name of scripts) {
		assert.ok(page.includes(`src="${name}"`), `metrics_apps/${name} is loaded by no page`);
	}
});
assert.equal(passed, 15, 'the orphan script check must execute');

// The actual page derives streaks from local calendar dates, not 24-hour buckets.
const { loadMetricsAppsPage } = require('./support/metrics-apps-page.cjs');

/** Delivers through each actual host handler; it never computes metrics. */
function publishLoadedAppsData(page, host, manifest) {
	if (host === 'windows') {
		const listener = page.messageListeners.find((entry) => entry.name === 'message');
		assert.ok(listener, 'the actual Windows prefetch handler must be installed');
		listener.callback({
			data: {
				type: 'prefetch',
				blob: { metrics_manifest: manifest, user_categories: {}, app_icons: {} }
			}
		});
	} else if (host === 'linux') {
		page.context.__hostBridgeResponse(
			'metrics_apps_bridge',
			false,
			encodeURIComponent(
				JSON.stringify({ metrics_manifest: manifest, user_categories: {}, app_icons: {} })
			)
		);
	} else {
		page.context.publishMetricsAppsData(
			manifest,
			{},
			{},
			{ manifest_revision: 1, categories_revision: 1 }
		);
	}
}
const streakCases = [
	{
		name: 'Paris DST fallback',
		zone: 'Europe/Paris',
		dates: ['2026-10-24', '2026-10-25', '2026-10-26'],
		expected: 3,
		lastDayHours: 25
	},
	{
		name: 'Paris DST spring',
		zone: 'Europe/Paris',
		dates: ['2026-03-28', '2026-03-29', '2026-03-30'],
		expected: 3,
		lastDayHours: 23
	},
	{
		name: 'UTC ordinary days',
		zone: 'UTC',
		dates: ['2026-10-24', '2026-10-25', '2026-10-26'],
		expected: 3,
		lastDayHours: 24
	},
	{
		name: 'Lord Howe half-hour fallback',
		zone: 'Australia/Lord_Howe',
		dates: ['2026-04-04', '2026-04-05', '2026-04-06'],
		expected: 3,
		lastDayHours: 24.5
	},
	{
		name: 'leap day',
		zone: 'Europe/Paris',
		dates: ['2024-02-28', '2024-02-29', '2024-03-01'],
		expected: 3
	},
	{
		name: 'year boundary',
		zone: 'Europe/Paris',
		dates: ['2025-12-31', '2026-01-01', '2026-01-02'],
		expected: 3
	},
	{
		name: 'missing calendar day',
		zone: 'Europe/Paris',
		dates: ['2026-10-22', '2026-10-24', '2026-10-25'],
		expected: 2
	},
	{
		name: 'ineligible middle day',
		zone: 'Europe/Paris',
		dates: ['2026-10-24', '2026-10-25', '2026-10-26'],
		expected: 1,
		ineligible: '2026-10-25'
	},
	{
		name: 'no eligible days',
		zone: 'Europe/Paris',
		dates: ['2026-10-24', '2026-10-25', '2026-10-26'],
		expected: 0,
		empty: true
	},
	{
		name: 'unordered local dates',
		zone: 'Europe/Paris',
		dates: ['2026-10-26', '2026-10-24', '2026-10-25'],
		expected: 3
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of streakCases) {
		test(`${host} streak preserves ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone;
			try {
				const page = loadMetricsAppsPage(host);
				for (const id of ['kpi-streak-chars', 'kpi-streak-focus'])
					page.elements.set(id, page.context.document.createElement('div'));
				const manifest = Object.fromEntries(
					vector.dates.map((day) => {
						const eligible = !vector.empty && day !== vector.ineligible;
						return [
							day,
							{
								Editor: {
									category: 'Productivity',
									app_time_ms: 3600000,
									chars: eligible ? 1000 : 999,
									time: eligible ? 1800000 : 1799999
								}
							}
						];
					})
				);
				publishLoadedAppsData(page, host, manifest);
				if (vector.lastDayHours !== undefined) {
					const [previous, latest] = vector.dates.slice(-2);
					const actualHours = vm.runInContext(
						`(parseDateKey(${JSON.stringify(latest)}) - parseDateKey(${JSON.stringify(previous)})) / 3600000`,
						page.context
					);
					assert.equal(
						actualHours,
						vector.lastDayHours,
						'the real Date owner must observe the selected timezone transition'
					);
				}
				for (const id of ['kpi-streak-chars', 'kpi-streak-focus'])
					assert.equal(
						page.elements.get(id).textContent,
						`${vector.expected} j`,
						'adjacent eligible local days must count once, including DST transitions'
					);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false,
					'the actual page must finish rendering without fixture errors'
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(
	passed,
	15 + 3 * streakCases.length,
	'all previous and local-calendar page controls must execute'
);

const drilldownCases = [
	{ name: 'weekly Monday filter', period: 'week', weekdays: [0], chars: 23, layouts: ['Monday'] },
	{ name: 'weekly Sunday filter', period: 'week', weekdays: [6], chars: 17, layouts: ['Sunday'] },
	{
		name: 'weekly unrestricted weekdays',
		period: 'week',
		weekdays: null,
		chars: 77,
		layouts: ['Sunday', 'Monday', 'Tuesday']
	},
	{ name: 'all-time Monday filter', period: 'all', weekdays: [0], chars: 23, layouts: ['Monday'] },
	{
		name: 'weekly multiple weekdays',
		period: 'week',
		weekdays: [0, 6],
		chars: 40,
		layouts: ['Sunday', 'Monday']
	},
	{ name: 'weekly empty weekday selection', period: 'week', weekdays: [], chars: 0, layouts: [] },
	{
		name: 'single local date',
		period: 'day',
		weekdays: null,
		anchor: '2026-10-26',
		chars: 23,
		layouts: ['Monday']
	},
	{
		name: 'all-time unrestricted weekdays',
		period: 'all',
		weekdays: null,
		chars: 88,
		layouts: ['OldSunday', 'Sunday', 'Monday', 'Tuesday']
	}
];
assert.equal(streakCases.length, 10, 'all local-calendar vectors must remain registered');
assert.equal(drilldownCases.length, 8, 'all modal date-selection vectors must remain registered');
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of drilldownCases) {
		test(`${host} app drilldown retains ${vector.name}`, () => {
			const page = loadMetricsAppsPage(host);
			for (const id of [
				'app_drilldown_modal',
				'app_modal_title',
				'app_modal_tiles',
				'app_modal_hourly',
				'app_modal_dests',
				'app_modal_layouts',
				'app_modal_records',
				'app_modal_assist'
			])
				page.elements.set(id, page.context.document.createElement('div'));
			const charts = [];
			// Canvas drawing is an explicit browser boundary. The real modal
			// owns every plotted value, selected date and rendered layout row.
			page.context.Chart = class ModalChartPort {
				constructor(port, config) {
					charts.push(config);
				}
				destroy() {}
			};
			page.elements.get('app_modal_hourly').getContext = () => ({ kind: 'modal' });
			vm.runInContext(
				`currentPeriod = ${JSON.stringify(vector.period)}; currentSelectedDate = ${JSON.stringify(vector.anchor || '2026-10-27')}; currentWeekdayFilter = ${vector.weekdays === null ? 'null' : `new Set(${JSON.stringify(vector.weekdays)})`};`,
				page.context
			);
			const rows = [
				['2025-10-26', 11, 'OldSunday'],
				['2026-10-25', 17, 'Sunday'],
				['2026-10-26', 23, 'Monday'],
				['2026-10-27', 37, 'Tuesday']
			];
			const manifest = Object.fromEntries(
				rows.map(([date, chars, layout]) => [
					date,
					{
						Editor: {
							category: 'Productivity',
							app_time_ms: 3600000,
							chars,
							hourly: { 12: { time_ms: 3600000, c: chars } },
							layouts_seen: { [layout]: chars }
						}
					}
				])
			);
			publishLoadedAppsData(page, host, manifest);
			const aggregate = page.context.getAggregatedData();
			assert.equal(
				aggregate.apps.Editor?.chars || 0,
				vector.chars,
				'the actual aggregate must receive the selected date scope'
			);
			assert.equal(
				charts.length,
				0,
				'the selected modal canvas must not be rendered by unrelated charts'
			);
			page.context.openAppDrilldown('Editor');
			if (vector.chars === 0) {
				assert.equal(charts.length, 0, 'a completely excluded app cannot acquire a modal chart');
			} else {
				assert.equal(page.elements.get('app_modal_title').textContent, 'Editor');
				assert.equal(page.elements.get('app_drilldown_modal').style.display, 'flex');
				assert.equal(charts.length, 1, 'the actual modal must publish one chart');
				const series = Array.from(charts[0].data.datasets[0].data);
				assert.equal(series.length, 24);
				assert.equal(
					series[12],
					vector.chars,
					'the modal chart must obey the same accepted query as its stat tiles'
				);
				assert.equal(
					series.reduce((sum, value) => sum + value, 0),
					vector.chars
				);
				const html = page.elements.get('app_modal_layouts').innerHTML;
				for (const [, , layout] of rows)
					assert.equal(
						html.includes(`<span>${layout}</span>`),
						vector.layouts.includes(layout),
						'layout rows must obey the same accepted dates as the hourly chart'
					);
			}
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false,
				'the actual page must render without fixture errors'
			);
		});
	}
}
assert.equal(
	passed,
	15 + 3 * (streakCases.length + drilldownCases.length),
	'all previous, calendar and drilldown controls must execute'
);

const periodAnchors = [
	{ name: 'ordinary UTC dates', zone: 'UTC', date: '2026-01-31' },
	{ name: 'Paris spring transition', zone: 'Europe/Paris', date: '2026-04-01' },
	{ name: 'Paris autumn transition', zone: 'Europe/Paris', date: '2026-10-27' },
	{ name: 'Lord Howe half-hour spring', zone: 'Australia/Lord_Howe', date: '2026-10-08' }
];
const expectedPeriodDays = { day: 1, week: 7, month: 30, year: 365 };
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of periodAnchors) {
		for (const [period, days] of Object.entries(expectedPeriodDays)) {
			test(`${host} ${period} calendar window retains ${vector.name}`, () => {
				const previousTimezone = process.env.TZ;
				process.env.TZ = vector.zone;
				try {
					const page = loadMetricsAppsPage(host);
					for (const id of ['compare-panel', 'compare-rows', 'compare-window'])
						page.elements.set(id, page.context.document.createElement('div'));
					const [year, month, date] = vector.date.split('-').map(Number);
					// These are independent input rows, one per real local calendar
					// date, with different focus totals so a shifted comparator is visible.
					const rows = Array.from({ length: 760 }, (_, index) => {
						const day = new Date(year, month - 1, date);
						day.setDate(day.getDate() - index);
						const key = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
						return [
							key,
							{
								Editor: {
									category: 'Productivity',
									app_time_ms: (index + 1) * 60000,
									chars: index + 1
								}
							}
						];
					});
					const manifest = Object.fromEntries(rows);
					vm.runInContext(
						`currentSelectedDate = ${JSON.stringify(vector.date)}; currentPeriod = ${JSON.stringify(period)}; currentCompareEnabled = true;`,
						page.context
					);
					publishLoadedAppsData(page, host, manifest);
					const aggregate = page.context.getAggregatedData();
					const currentRows = rows.slice(0, days);
					const previousRows = rows.slice(days, 2 * days);
					assert.equal(
						aggregate.rich.date_range.days,
						days,
						'the displayed period must own exactly its declared number of calendar dates'
					);
					assert.deepEqual(
						Object.keys(aggregate.rich.by_date),
						currentRows.map(([key]) => key),
						'the actual date scope must end at the selected local day'
					);
					const currentFocus = currentRows.reduce(
						(sum, [, data]) => sum + data.Editor.app_time_ms,
						0
					);
					const previousFocus = previousRows.reduce(
						(sum, [, data]) => sum + data.Editor.app_time_ms,
						0
					);
					assert.equal(aggregate.rich.time.focus_ms, currentFocus);
					const previousKey = previousRows[0][0];
					assert.ok(
						page.elements
							.get('compare-window')
							.textContent.includes(page.context.formatDisplayDate(previousKey)),
						'the actual comparator must shift by local calendar dates rather than elapsed hours'
					);
					const previousFormatted = page.context.formatDuration(previousFocus);
					assert.notEqual(
						previousFormatted,
						page.context.formatDuration(currentFocus),
						'the input must distinguish current and previous totals'
					);
					assert.ok(
						page.elements.get('compare-rows').innerHTML.includes(previousFormatted),
						'the actual rendered comparator must own the disjoint previous date scope'
					);
					assert.equal(
						vm.runInContext('currentSelectedDate', page.context),
						vector.date,
						'comparator rendering must return the selected query owner'
					);
					assert.equal(
						page.diagnostics.some((entry) => entry.level === 'error'),
						false,
						'the real page must render without fixture errors'
					);
				} finally {
					if (previousTimezone === undefined) delete process.env.TZ;
					else process.env.TZ = previousTimezone;
				}
			});
		}
	}
}
assert.equal(periodAnchors.length, 4, 'every calendar boundary vector must execute');
assert.equal(passed, 117, 'all prior and calendar-period page controls must execute');

console.log(`${passed} passed, 0 failed.`);
