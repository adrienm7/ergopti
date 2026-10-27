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
	vm.runInContext(read('metrics_calendar.js'), context);
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
		vm.runInContext(read('metrics_calendar.js'), context);
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
function publishLoadedAppsData(page, host, manifest, icons = {}, revision = 1, categories = {}) {
	const blob = { metrics_manifest: manifest, user_categories: categories, app_icons: icons };
	if (host === 'windows') {
		assert.equal(Object.keys(icons).length, 0, 'the actual Windows producer emits empty icon maps');
		const listener = page.messageListeners.find((entry) => entry.name === 'message');
		assert.ok(listener, 'the actual Windows prefetch handler must be installed');
		listener.callback({
			data: {
				type: 'prefetch',
				blob
			}
		});
	} else if (host === 'linux') {
		page.context.__hostBridgeResponse(
			'metrics_apps_bridge',
			false,
			encodeURIComponent(JSON.stringify(blob))
		);
	} else {
		page.context.publishMetricsAppsData(manifest, categories, icons, {
			manifest_revision: revision,
			categories_revision: 1
		});
	}
}
const streakCases = [
	{
		name: 'Havana midnight spring',
		zone: 'America/Havana',
		dates: ['2026-03-07', '2026-03-08', '2026-03-09'],
		expected: 3,
		lastDayHours: 23
	},
	{
		name: 'Santiago midnight spring',
		zone: 'America/Santiago',
		dates: ['2026-09-05', '2026-09-06', '2026-09-07'],
		expected: 3,
		lastDayHours: 23
	},
	{
		name: 'Apia archived skipped date',
		zone: 'Pacific/Apia',
		dates: ['2011-12-29', '2011-12-30', '2011-12-31'],
		expected: 3,
		lastDayHours: 0
	},
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
						`(() => { const localMidnight = key => { const [y,m,d] = key.split('-').map(Number); return new Date(y,m-1,d).getTime(); }; return (localMidnight(${JSON.stringify(latest)}) - localMidnight(${JSON.stringify(previous)})) / 3600000; })()`,
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
assert.equal(streakCases.length, 13, 'all local-calendar vectors must remain registered');
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
	{ name: 'Havana midnight transition', zone: 'America/Havana', date: '2026-03-08' },
	{ name: 'Santiago midnight transition', zone: 'America/Santiago', date: '2026-09-06' },
	{ name: 'Apia archived skipped date', zone: 'Pacific/Apia', date: '2011-12-31' },
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
					// These are independent input rows, one per recorded Gregorian calendar
					// date, with different focus totals so a shifted comparator is visible.
					const rows = Array.from({ length: 760 }, (_, index) => {
						const day = new Date(Date.UTC(year, month - 1, date));
						day.setUTCDate(day.getUTCDate() - index);
						const key = `${day.getUTCFullYear()}-${String(day.getUTCMonth() + 1).padStart(2, '0')}-${String(day.getUTCDate()).padStart(2, '0')}`;
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
assert.equal(periodAnchors.length, 7, 'every calendar boundary vector must execute');
assert.equal(passed, 162, 'all prior and calendar-period page controls must execute');

const goalCases = [
	{
		name: 'latest accepted goal',
		answers: ['60', '90', { accept: true }],
		defaults: [120, 60, 90],
		goals: [60, 90, 90]
	},
	{
		name: 'cancelled prompt',
		answers: ['60', null, { accept: true }],
		defaults: [120, 60, 60],
		goals: [60, 60, 60]
	},
	{
		name: 'unchanged input bounds',
		answers: ['0', '1440', '60', '-1', { accept: true }],
		defaults: [120, 120, 120, 60, 60],
		goals: [120, 120, 60, 60, 60]
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of goalCases) {
		test(`${host} daily goal prompt retains ${vector.name}`, () => {
			const page = loadMetricsAppsPage(host);
			const goal = page.context.document.createElement('div');
			const listeners = new Map();
			goal.addEventListener = (name, callback) => {
				const callbacks = listeners.get(name) || [];
				callbacks.push(callback);
				listeners.set(name, callbacks);
			};
			page.elements.set('kpi-goal-value', goal);
			page.elements.set('kpi-goal-progress', page.context.document.createElement('div'));
			const proposed = [];
			// This is the native prompt boundary, including pressing Enter on
			// the actual proposed value. The real click owner validates and stores it.
			page.context.prompt = (question, defaultValue) => {
				const response = vector.answers[proposed.length];
				proposed.push(defaultValue);
				return response && typeof response === 'object' ? defaultValue : response;
			};
			publishLoadedAppsData(page, host, {
				'2026-10-26': {
					Editor: { category: 'Productivity', app_time_ms: 60000, time: 60000, chars: 1 }
				}
			});
			assert.equal(
				goal.textContent,
				'120 min',
				'the existing daily-goal default remains unchanged'
			);
			assert.equal(
				listeners.get('click').length,
				1,
				'the real page must bind one persistent click owner'
			);
			const projection = page.context.getAggregatedData();
			for (const [index, expectedGoal] of vector.goals.entries()) {
				listeners.get('click')[0]();
				assert.equal(
					proposed[index],
					String(vector.defaults[index]),
					'each actual prompt must propose the current window-owned goal'
				);
				assert.equal(
					goal.textContent,
					`${expectedGoal} min`,
					'accepting the current proposal cannot reset the goal to its initial default'
				);
				assert.equal(page.elements.get('kpi-goal-progress').textContent, `1 / ${expectedGoal} min`);
				assert.equal(
					listeners.get('click').length,
					1,
					'repainting must not duplicate the real click handler'
				);
				assert.strictEqual(
					page.context.getAggregatedData(),
					projection,
					'a display-only goal change must reuse the accepted data query'
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
assert.equal(goalCases.length, 3, 'every daily-goal lifecycle vector must execute');
assert.equal(passed, 171, 'all query, calendar and daily-goal controls must execute');

const civilZones = ['Pacific/Apia', 'America/Havana', 'America/Santiago', 'America/Los_Angeles'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const zone of civilZones) {
		test(`${host} recorded day identity survives ${zone}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = zone;
			try {
				const page = loadMetricsAppsPage(host);
				page.elements.set('ribbon_container', page.context.document.createElement('div'));
				vm.runInContext(
					"currentSelectedDate='2011-12-30'; currentPeriod='day'; currentWeekdayFilter=new Set([4]);",
					page.context
				);
				publishLoadedAppsData(
					page,
					host,
					Object.fromEntries(
						['29', '30', '31'].map((day, i) => [
							`2011-12-${day}`,
							{
								Editor: {
									category: 'Productivity',
									chars: 2 ** i,
									app_time_ms: 60000,
									hourly: { '09': { app_time_ms: 60000, chars: 2 ** i } }
								}
							}
						])
					)
				);
				const agg = page.context.getAggregatedData();
				assert.deepEqual(Object.keys(agg.rich.by_date), ['2011-12-30']);
				assert.equal(agg.rich.by_weekday[4].chars, 2);
				assert.equal(page.context.formatDisplayDate('2011-12-30'), '30/12/2011');
				assert.equal(page.context.formatDisplayDate('30/12/2011'), '30/12/2011');
				assert.ok(page.elements.get('ribbon_container').innerHTML.includes('Ven 30/12'));
				for (const key of ['0001-01-01', '0099-12-31', '2011-12-30'])
					assert.equal(page.context.formatMetricsDateKey(page.context.parseDateKey(key)), key);
				for (const instant of [1767227400000, '1767227400', 'Thu, 01 Jan 2026 00:30:00 GMT']) {
					const native = new Date(
						typeof instant === 'string' && /^\d+$/.test(instant) ? Number(instant) * 1000 : instant
					);
					const expected = `${String(native.getDate()).padStart(2, '0')}/${String(native.getMonth() + 1).padStart(2, '0')}/${native.getFullYear()}`;
					assert.equal(
						page.context.formatDisplayDate(instant),
						expected,
						'legacy instants retain their local displayed day'
					);
				}
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
const annualCases = [
	{ zone: 'America/Havana', now: '2026-03-09T17:00:00Z', today: '9/3/2026', future: '10/3/2026' },
	{
		zone: 'Pacific/Apia',
		now: '2011-12-31T00:00:00Z',
		today: '31/12/2011',
		future: '1/1/2012',
		archived: '30/12/2011'
	},
	{
		zone: 'America/Los_Angeles',
		now: '2026-01-01T00:30:00Z',
		today: '31/12/2025',
		future: '1/1/2026'
	},
	{ zone: 'Pacific/Kiritimati', now: '2025-12-31T12:00:00Z', today: '1/1/2026', future: '2/1/2026' }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of annualCases) {
		test(`${host} annual calendar ends on local today in ${vector.zone}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone;
			try {
				const page = loadMetricsAppsPage(host);
				page.elements.set(
					'activity_calendar_container',
					page.context.document.createElement('div')
				);
				const fixedNow = Date.parse(vector.now);
				// Freeze only the browser clock; date parsing, calendar arithmetic
				// and native timezone rules remain the real Date implementation.
				page.context.Date = class ClockPort extends Date {
					constructor(...args) {
						super(...(args.length ? args : [fixedNow]));
					}
					static now() {
						return fixedNow;
					}
				};
				publishLoadedAppsData(page, host, {
					'2011-12-30': { Editor: { category: 'Productivity', chars: 2, app_time_ms: 60000 } }
				});
				const html = page.elements.get('activity_calendar_container').innerHTML;
				assert.equal((html.match(/<title>/g) || []).length, 365);
				assert.ok(
					html.includes(`<title>${vector.today} — `),
					'local today must remain in the rendered year'
				);
				assert.ok(
					!html.includes(`<title>${vector.future} — `),
					'a UTC date change must not insert tomorrow'
				);
				if (vector.archived) assert.ok(html.includes(`<title>${vector.archived} — 2 car.</title>`));
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(civilZones.length, 4);
assert.equal(annualCases.length, 4);
assert.equal(passed, 195, 'all recorded-date, real-clock and timezone controls must execute');
const replacementDateCases = [
	{
		name: 'removed selected day',
		initial: ['2026-10-26'],
		replacement: ['2026-10-27'],
		expected: '2026-10-27'
	},
	{
		name: 'retained historical selection',
		initial: ['2026-10-26'],
		replacement: ['2026-10-26', '2026-10-27'],
		expected: '2026-10-26'
	},
	{ name: 'empty replacement', initial: ['2026-10-26'], replacement: [], expected: null },
	{
		name: 'first recorded day after empty state',
		initial: [],
		replacement: ['2026-10-27'],
		expected: '2026-10-27'
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of replacementDateCases) {
		test(`${host} full snapshot reconciles ${vector.name}`, () => {
			const page = loadMetricsAppsPage(host);
			const manifest = (dates) =>
				Object.fromEntries(
					dates.map((date, i) => [
						date,
						{ Editor: { category: 'Productivity', chars: 23 + i, app_time_ms: 60000 } }
					])
				);
			const publish = (data, revision) => {
				if (host === 'linux') {
					// Native Linux polls merge dates rather than replacing snapshots.
					// Exercise the same public full-snapshot owner explicitly.
					page.context.bootstrapMetricsAppsData(data, {}, {});
				} else publishLoadedAppsData(page, host, data, {}, revision);
			};
			publish(manifest(vector.initial), 1);
			vm.runInContext("currentPeriod='day'; renderDashboard();", page.context);
			publish(manifest(vector.replacement), 2);
			const selected = vm.runInContext('currentSelectedDate', page.context);
			assert.equal(selected, vector.expected);
			if (vector.expected !== null)
				assert.equal(page.elements.get('date-select').value, vector.expected);
			assert.deepEqual(
				page.elements.get('date-select').children.map((option) => option.value),
				[...vector.replacement].sort().reverse()
			);
			const agg = page.context.getAggregatedData();
			assert.deepEqual(Object.keys(agg.rich.by_date), vector.expected ? [vector.expected] : []);
			const expectedChars = vector.expected ? 23 + vector.replacement.indexOf(vector.expected) : 0;
			assert.equal(agg.rich.typing.chars, expectedChars);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(replacementDateCases.length, 4);
assert.equal(passed, 207, 'all full-snapshot selection lifecycle controls must execute');
const timelineCases = [
	{
		name: 'same month/day across years',
		period: 'all',
		dates: ['2026-01-01', '2025-01-01'],
		labels: ['01/01/2025', '01/01/2026']
	},
	{
		name: 'weekly year boundary',
		period: 'week',
		dates: ['2026-01-01', '2025-12-31'],
		labels: ['31/12/2025', '01/01/2026']
	},
	{ name: 'hourly day view', period: 'day', dates: ['2026-01-01'], labels: ['09h', '10h'] }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of timelineCases) {
		test(`${host} chart preserves distinct dates for ${vector.name}`, () => {
			const page = loadMetricsAppsPage(host);
			const charts = [];
			page.elements.set('timeline_chart_title', page.context.document.createElement('div'));
			const canvas = page.context.document.createElement('canvas');
			canvas.getContext = () => ({ owner: 'timeline' });
			page.elements.set('timeline_stacked_chart', canvas);
			page.context.Chart = class ChartPort {
				constructor(port, config) {
					assert.equal(port.owner, 'timeline');
					charts.push(config);
				}
				destroy() {}
			};
			vm.runInContext(
				`currentPeriod=${JSON.stringify(vector.period)};currentSelectedDate='2026-01-01';`,
				page.context
			);
			const manifest = Object.fromEntries(
				vector.dates.map((date, i) => [
					date,
					{
						Editor: {
							category: 'Productivity',
							chars: 2,
							app_time_ms: (i + 1) * 3600000,
							hourly: { '09': { c: 1, time_ms: 600000 }, 10: { c: 1, time_ms: 1200000 } }
						}
					}
				])
			);
			publishLoadedAppsData(page, host, manifest);
			const chart = charts.at(-1);
			assert.deepEqual(Array.from(chart.data.labels), vector.labels);
			assert.deepEqual(
				Array.from(chart.data.datasets[0].data),
				vector.period === 'day' ? [0.17, 0.33] : [2, 1]
			);
			assert.equal(page.context.getAggregatedData().rich.date_range.days, vector.dates.length);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(timelineCases.length, 3);
assert.equal(passed, 216, 'all chronological timeline and hourly controls must execute');
const windowTitleCases = ['constructor', 'toString', '__proto__', 'Ordinary document'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const title of windowTitleCases) {
		test(`${host} native window title retains dictionary key ${title}`, () => {
			const page = loadMetricsAppsPage(host);
			page.elements.set('top_windows_tbody', page.context.document.createElement('tbody'));
			vm.runInContext("currentPeriod='all';", page.context);
			const manifest = Object.fromEntries(
				['2026-10-26', '2026-10-27'].map((date, i) => [
					date,
					{
						Editor: {
							category: 'Productivity',
							app_time_ms: 60000,
							chars: 1,
							win_titles: Object.fromEntries([[title, { c: 3 + i, ms: (i + 1) * 60000 }]])
						}
					}
				])
			);
			assert.equal(
				vm.runInContext(
					"Object.hasOwn(Object.prototype, 'c') || Object.hasOwn(Object.prototype, 'ms')",
					page.context
				),
				false
			);
			publishLoadedAppsData(page, host, manifest);
			const titles = page.context.getAggregatedData().apps.Editor.win_titles;
			assert.deepEqual(
				Object.keys(titles),
				[title],
				'valid native title strings must remain own dictionary entries'
			);
			assert.equal(titles[title].c, 7);
			assert.equal(titles[title].ms, 180000);
			assert.equal(
				vm.runInContext(
					"Object.hasOwn(Object.prototype, 'c') || Object.hasOwn(Object.prototype, 'ms')",
					page.context
				),
				false,
				'data keys must never mutate shared object prototypes'
			);
			const html = page.elements.get('top_windows_tbody').innerHTML;
			assert.ok(html.includes(`title="${title}"`));
			assert.ok(html.includes('>7</td>'));
			assert.ok(html.includes('>3m</td>'));
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(windowTitleCases.length, 4);
assert.equal(passed, 228, 'all native title dictionary and rendering controls must execute');
const { loadMetricsTypingPage } = require('./support/metrics-apps-page.cjs');
function publishTypingPage(page, host, manifest) {
	assert.equal(
		page.scripts.filter((name) => name === '../metrics_calendar.js').length,
		1,
		'both pages load one canonical calendar owner'
	);
	assert.ok(
		page.scripts.indexOf('../metrics_calendar.js') < page.scripts.indexOf('format.js'),
		'the shared calendar owner loads before typing consumers'
	);
	const initial = { historical: {}, today: {} };
	if (host === 'macos') {
		page.context.publishTypingMetricsData(
			{ manifest, initial_data: initial, app_icons: {}, kc_layout: {} },
			{ manifest_revision: 1, assets_revision: 1 }
		);
	} else {
		const blob = {
			metrics_manifest: manifest,
			_prefetch_data: initial,
			app_icons: {},
			keycode_layout: {},
			driver_meta: { os: host, heatmap_id: 'sc' }
		};
		if (host === 'windows')
			page.messageListeners
				.filter((entry) => entry.name === 'message')
				.at(-1)
				.callback({ data: { type: 'prefetch', blob } });
		else
			page.context.__hostBridgeResponse(
				'metrics_typing_bridge',
				false,
				encodeURIComponent(JSON.stringify(blob))
			);
	}
}
function freezePageClock(page, timestamp) {
	const fixedNow = Date.parse(timestamp);
	page.context.Date = class ClockPort extends Date {
		constructor(...args) {
			super(...(args.length ? args : [fixedNow]));
		}
		static now() {
			return fixedNow;
		}
	};
}
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of streakCases) {
		test(`${host} loaded typing streak retains ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone;
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, vector.dates.slice().sort().at(-1) + 'T12:00:00Z');
				const manifest = Object.fromEntries(
					vector.dates.map((date) => [
						date,
						{
							Editor: {
								chars: vector.empty || vector.ineligible === date ? 0 : 10,
								time: 10000,
								wpm_chars: 10
							}
						}
					])
				);
				publishTypingPage(page, host, manifest);
				assert.equal(
					page.elements.get('records_streak').innerHTML,
					vector.expected ? `${vector.expected} jour${vector.expected > 1 ? 's' : ''}` : '—'
				);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false,
					'real declared scripts and native-handler ingress must finish without fixture errors'
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
	for (const vector of annualCases) {
		test(`${host} loaded typing calendar preserves civil days in ${vector.zone}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone;
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, vector.now);
				publishTypingPage(page, host, {
					'2011-12-30': { Editor: { chars: 20, time: 10000, hourly: { '09': { c: 20 } } } }
				});
				const svg = page.elements.get('activity_calendar_container').innerHTML;
				const label = (key) => {
					const [day, month, year] = key.split('/').map(Number);
					const date = new Date(0);
					date.setUTCFullYear(year, month - 1, day);
					return date.toLocaleDateString('fr-FR', {
						weekday: 'long',
						day: 'numeric',
						month: 'long',
						year: 'numeric',
						timeZone: 'UTC'
					});
				};
				assert.ok(
					svg.includes(`<title>${label(vector.today)} — `),
					'the real local today remains visible'
				);
				assert.ok(
					!svg.includes(`<title>${label(vector.future)} — `),
					'UTC conversion must not insert local tomorrow'
				);
				if (vector.archived) {
					assert.ok(
						svg.includes(`<title>${label(vector.archived)} — 20 `),
						'archived skipped dates remain distinct cells'
					);
					assert.ok(page.elements.get('records_best_day').innerHTML.includes('30 déc. 11'));
					assert.ok(
						page.elements
							.get('hour_weekday_heatmap_container')
							.innerHTML.includes(
								`<title>${page.context._t('ui_typing.heatmap_day_fri')} 09h — 20 `
							),
						'archived dates retain their recorded Gregorian weekday'
					);
				}
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
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
	279,
	'all apps controls and full loaded typing-page calendar controls must execute'
);

const typingGridDates = ['2026-10-26T12:00:00Z', '2026-10-25T12:00:00Z', '2026-10-28T12:00:00Z'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const now of typingGridDates) {
		test(`${host} typing calendar packs consecutive weeks at ${now.slice(0, 10)}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = 'UTC';
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, now);
				publishTypingPage(page, host, { '2026-10-20': { Editor: { chars: 10, time: 10000 } } });
				const html = page.elements.get('activity_calendar_container').innerHTML;
				const cells = Array.from(
					html.matchAll(/<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)"/g),
					(match) => ({ x: +match[1], y: +match[2], width: +match[3], height: +match[4] })
				);
				assert.ok(
					cells.length >= 365 && cells.length <= 371,
					'the real calendar renders a year and its leading week alignment'
				);
				const xs = [...new Set(cells.map((cell) => cell.x))].sort((a, b) => a - b);
				const ys = [...new Set(cells.map((cell) => cell.y))].sort((a, b) => a - b);
				assert.equal(ys.length, 7);
				const step = ys[1] - ys[0];
				assert.ok(step > cells[0].height);
				assert.equal(xs.length, Math.ceil(cells.length / ys.length));
				for (let index = 1; index < xs.length; index++)
					assert.equal(
						xs[index] - xs[index - 1],
						step,
						'weeks use the same cell gap as consecutive weekdays'
					);
				const svgWidth = Number(html.match(/<svg width="(\d+)"/)[1]);
				assert.equal(
					svgWidth,
					xs[0] + xs.length * step,
					'the SVG width includes exactly the visible week columns'
				);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingGridDates.length, 3);
assert.equal(passed, 288, 'all weekday-boundary calendar grid controls must execute');
const typingWindowCases = [
	{ name: 'older archive', extra: '2020-01-01' },
	{ name: 'future day', extra: '2026-10-29' },
	{ name: 'leading week padding', extra: '2025-10-28' },
	{ name: 'first included day', extra: '2025-10-29', included: true },
	{ name: 'local today', extra: '2026-10-28', included: true },
	{ name: 'invalid recorded key', extra: 'not-a-recorded-date' },
	{
		name: 'local tomorrow before UTC midnight',
		zone: 'America/Los_Angeles',
		now: '2026-01-01T00:30:00Z',
		recent: '2025-12-30',
		extra: '2026-01-01'
	},
	{
		name: 'Apia archived date identity',
		zone: 'Pacific/Apia',
		now: '2011-12-31T00:00:00Z',
		recent: '2011-12-30',
		extra: '2010-01-01'
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingWindowCases) {
		test(`${host} typing annual normalization scopes ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone || 'UTC';
			try {
				const paint = (extra) => {
					const page = loadMetricsTypingPage(host);
					freezePageClock(page, vector.now || '2026-10-28T12:00:00Z');
					publishTypingPage(page, host, {
						[vector.recent || '2026-10-20']: { Editor: { chars: 20, time: 10000 } },
						...extra
					});
					assert.equal(
						page.diagnostics.some((entry) => entry.level === 'error'),
						false
					);
					const html = page.elements.get('activity_calendar_container').innerHTML;
					const cells = Array.from(
						html.matchAll(/<rect[^>]*fill="([^"]+)"[^>]*><title>([^<]+)<\/title>/g)
					);
					const recentColour = cells.find((match) => match[2].includes(' — 20 '))?.[1];
					assert.ok(recentColour, 'the baseline recorded day has a real rendered cell');
					return { page, html, recentColour };
				};
				const baseline = paint({});
				const withOutlier = paint({ [vector.extra]: { Editor: { chars: 100000, time: 10000 } } });
				if (vector.included) {
					assert.notEqual(withOutlier.recentColour, baseline.recentColour);
					assert.ok(
						withOutlier.html.includes(
							`2 ${withOutlier.page.context._t('ui_typing.calendar_active_days')} · ${withOutlier.page.context.format_number(100020)} ${withOutlier.page.context._t('ui_typing.calendar_chars')}`
						),
						'included boundaries contribute to the actual annual summary'
					);
				} else {
					assert.equal(
						withOutlier.recentColour,
						baseline.recentColour,
						'out-of-window rows cannot flatten visible calendar intensity'
					);
					assert.equal(
						withOutlier.html,
						baseline.html,
						'out-of-window rows cannot change the annual summary or padding cells'
					);
				}
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingWindowCases.length, 8);
assert.equal(passed, 312, 'all annual summary, normalization and date-edge controls must execute');
const typingMonthCases = [
	{
		name: 'three months into ordinary February',
		now: '2026-05-31T12:00:00Z',
		preset: '3m',
		start: '2026-02-28',
		end: '2026-05-31'
	},
	{
		name: 'six months into ordinary February',
		now: '2026-08-31T12:00:00Z',
		preset: '6m',
		start: '2026-02-28',
		end: '2026-08-31'
	},
	{
		name: 'three months into leap February',
		now: '2024-05-31T12:00:00Z',
		preset: '3m',
		start: '2024-02-29',
		end: '2024-05-31'
	},
	{
		name: 'six months across the year boundary',
		now: '2026-03-31T12:00:00Z',
		preset: '6m',
		start: '2025-09-30',
		end: '2026-03-31'
	},
	{
		name: 'three months into a thirty-day month',
		now: '2026-07-31T12:00:00Z',
		preset: '3m',
		start: '2026-04-30',
		end: '2026-07-31'
	},
	{
		name: 'valid day retained across months',
		now: '2026-03-30T12:00:00Z',
		preset: '3m',
		start: '2025-12-30',
		end: '2026-03-30'
	},
	{
		name: 'local month end after UTC midnight',
		zone: 'America/Los_Angeles',
		now: '2026-06-01T00:30:00Z',
		preset: '3m',
		start: '2026-02-28',
		end: '2026-05-31'
	},
	{
		name: 'local month end before UTC midnight',
		zone: 'Pacific/Kiritimati',
		now: '2026-05-30T13:00:00Z',
		preset: '3m',
		start: '2026-02-28',
		end: '2026-05-31'
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingMonthCases) {
		test(`${host} quick date range retains ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone || 'UTC';
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, vector.now);
				publishTypingPage(page, host, { '2020-01-01': { Editor: { chars: 10, time: 10000 } } });
				page.elements.get('quick_range').value = vector.preset;
				const tag = page.html.match(/<select\b[^>]*\bid="quick_range"[^>]*>/)[0];
				const handler = tag.match(/\bonchange="([^"]+)"/)[1];
				assert.ok(handler, 'the real HTML owns the quick-range change handler');
				vm.runInContext(handler, page.context);
				assert.equal(page.elements.get('date_start').value, vector.start);
				assert.equal(page.elements.get('date_end').value, vector.end);
				const selection = JSON.parse(
					vm.runInContext('app_state.range_request_selection', page.context)
				);
				assert.deepEqual(
					selection,
					[vector.start, vector.end, ['Editor']],
					'the actual native query owns the clamped local date interval'
				);
				assert.equal(vm.runInContext('app_state.hour_window', page.context), null);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingMonthCases.length, 8);
assert.equal(passed, 336, 'all quick-range month boundary controls must execute');
const quickRangeTag = read('metrics_typing/index.html').match(
	/<select\b[^>]*\bid="quick_range"[^>]*>([\s\S]*?)<\/select>/
)[0];
const quickPresets = Array.from(
	quickRangeTag.matchAll(/<option\b[^>]*\bvalue="([^"]*)"/g),
	(match) => match[1]
).filter(Boolean);
function runTypingControlChange(page, id) {
	const tag = page.html.match(new RegExp('<(?:select|input)\\b[^>]*\\bid="' + id + '"[^>]*>'))?.[0];
	assert.ok(tag, `the real page declares control ${id}`);
	const handler = tag.match(/\bonchange="([^"]+)"/)?.[1];
	assert.ok(handler, `the real HTML owns control ${id}'s change handler`);
	vm.runInContext(handler, page.context);
}
for (const host of ['windows', 'macos', 'linux']) {
	for (const preset of quickPresets) {
		test(`${host} quick preset ${preset} releases its action selection`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = 'UTC';
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, '2026-10-28T12:00:00Z');
				publishTypingPage(page, host, { '2020-01-01': { Editor: { chars: 10, time: 10000 } } });
				const quick = page.elements.get('quick_range');
				quick.value = preset;
				runTypingControlChange(page, 'quick_range');
				const start = page.elements.get('date_start').value;
				const cutoff = JSON.parse(
					vm.runInContext('JSON.stringify(app_state.hour_window)', page.context)
				);
				assert.equal(
					quick.value,
					'',
					'a completed quick action returns to the actual placeholder option'
				);
				page.elements.get('date_start').value = '2026-10-01';
				runTypingControlChange(page, 'date_start');
				assert.equal(quick.value, '', 'manual date edits cannot retain a false preset label');
				quick.value = preset;
				runTypingControlChange(page, 'quick_range');
				assert.equal(quick.value, '');
				assert.equal(
					page.elements.get('date_start').value,
					start,
					'the same action remains selectable after a manual date edit'
				);
				assert.equal(page.elements.get('date_end').value, '2026-10-28');
				assert.deepEqual(
					JSON.parse(vm.runInContext('JSON.stringify(app_state.hour_window)', page.context)),
					cutoff
				);
				assert.deepEqual(
					JSON.parse(vm.runInContext('app_state.range_request_selection', page.context)),
					[start, '2026-10-28', ['Editor']]
				);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
	test(`${host} empty quick placeholder does not issue a query`, () => {
		const page = loadMetricsTypingPage(host);
		freezePageClock(page, '2026-10-28T12:00:00Z');
		publishTypingPage(page, host, { '2020-01-01': { Editor: { chars: 10, time: 10000 } } });
		const before = vm.runInContext('app_state.range_request_sequence', page.context);
		const start = page.elements.get('date_start').value;
		page.elements.get('quick_range').value = '';
		runTypingControlChange(page, 'quick_range');
		assert.equal(vm.runInContext('app_state.range_request_sequence', page.context), before);
		assert.equal(page.elements.get('date_start').value, start);
		assert.equal(
			page.diagnostics.some((entry) => entry.level === 'error'),
			false
		);
	});
}
assert.equal(quickPresets.length, 8, 'all actual quick actions must participate');
assert.equal(passed, 363, 'all quick-action, manual-edit and placeholder controls must execute');
const typingHourWindows = [
	{
		name: 'UTC year midnight',
		now: '2026-01-01T00:30:00Z',
		start: '2025-12-31',
		first: '23:35',
		end: '2026-01-01',
		second: '00:05'
	},
	{
		name: 'UTC month midnight',
		now: '2026-05-01T00:30:00Z',
		start: '2026-04-30',
		first: '23:35',
		end: '2026-05-01',
		second: '00:05'
	},
	{
		name: 'first full hour of the day',
		now: '2026-01-01T01:30:00Z',
		start: '2026-01-01',
		first: '00:35',
		end: '2026-01-01',
		second: '01:05'
	},
	{
		name: 'same-day detailed hour',
		now: '2026-01-01T12:30:00Z',
		start: '2026-01-01',
		first: '11:35',
		end: '2026-01-01',
		second: '12:05'
	},
	{
		name: 'Los Angeles local midnight',
		zone: 'America/Los_Angeles',
		now: '2026-01-01T08:30:00Z',
		start: '2025-12-31',
		first: '23:35',
		end: '2026-01-01',
		second: '00:05'
	},
	{
		name: 'Kiritimati local midnight',
		zone: 'Pacific/Kiritimati',
		now: '2025-12-31T10:30:00Z',
		start: '2025-12-31',
		first: '23:35',
		end: '2026-01-01',
		second: '00:05'
	},
	{
		name: 'Havana midnight DST',
		zone: 'America/Havana',
		now: '2026-03-08T05:30:00Z',
		start: '2026-03-07',
		first: '23:35',
		end: '2026-03-08',
		second: '01:05'
	},
	{
		name: 'Paris skipped spring hour',
		zone: 'Europe/Paris',
		now: '2026-03-29T01:30:00Z',
		start: '2026-03-29',
		first: '01:35',
		end: '2026-03-29',
		second: '03:05'
	},
	{
		name: 'Apia skipped local date',
		zone: 'Pacific/Apia',
		now: '2011-12-30T10:30:00Z',
		start: '2011-12-29',
		first: '23:35',
		end: '2011-12-31',
		second: '00:05'
	}
];
function typingChartPage(host, now, owners = ['wpm_chart', 'precision_chart']) {
	const page = loadMetricsTypingPage(host);
	freezePageClock(page, now);
	page.elements.get('pause_threshold').value = '1000';
	const charts = [];
	for (const id of owners) {
		const canvas = page.context.document.createElement('canvas');
		canvas.getContext = () => ({ owner: id });
		page.elements.set(id, canvas);
	}
	page.dayTickPlugin = page.context.Chart.registry.plugins.get('day_tick_renderer');
	page.linearScale = page.context.Chart.registry.getScale('linear');
	const chartDefaults = page.context.Chart.defaults;
	page.context.Chart = class ChartPort {
		constructor(port, config) {
			charts.push({ owner: port.owner, config });
		}
		destroy() {}
	};
	page.context.Chart.defaults = chartDefaults;
	page.lastChart = (owner) => charts.filter((chart) => chart.owner === owner).at(-1).config;
	return page;
}
function typingHourManifest(vector) {
	const manifest = {};
	for (const [date, bucket, chars, errors] of [
		[vector.start, vector.first, 7, 1],
		[vector.end, vector.second, 3, 0]
	]) {
		const app = ((manifest[date] ||= {}).Editor ||= {
			chars: 0,
			time: 0,
			hourly: {},
			hourly_min5: {}
		});
		app.chars += chars;
		app.time += chars * 1000;
		const hour = bucket.slice(0, 2);
		app.hourly[hour] = { c: chars, e_buckets: { 1000: errors } };
		app.hourly_min5[bucket] = { c: chars, e_buckets: { 1000: errors } };
	}
	// A date-qualified window must not merge yesterday's same-clock bucket
	// into today's point, or expose later clock buckets from imported data.
	if (vector.start !== vector.end) {
		const app = manifest[vector.start].Editor;
		app.hourly_min5[vector.second] = { c: 999, e_buckets: { 1000: 999 } };
		app.chars += 999;
		app.time += 999000;
	}
	const later = manifest[vector.end].Editor;
	later.hourly_min5['23:55'] = { c: 997, e_buckets: { 1000: 997 } };
	later.chars += 997;
	later.time += 997000;
	return manifest;
}
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingHourWindows) {
		test(`${host} last-hour query and chart preserve ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.zone || 'UTC';
			try {
				const page = typingChartPage(host, vector.now);
				publishTypingPage(page, host, typingHourManifest(vector));
				const oldRequest = vm.runInContext('app_state.range_request_sequence', page.context);
				page.elements.get('quick_range').value = 'last_hour';
				runTypingControlChange(page, 'quick_range');
				const selection = JSON.parse(
					vm.runInContext('app_state.range_request_selection', page.context)
				);
				assert.deepEqual(
					selection,
					[vector.start, vector.end, ['Editor']],
					'the native range admits both date-qualified hours'
				);
				page.timers.at(-1)(); // The actual paced native dispatch, after its UI loader turn.
				const rawRequest = host === 'macos' ? page.context._lua_request : page.posts.at(-1);
				const request = typeof rawRequest === 'string' ? JSON.parse(rawRequest) : rawRequest;
				if (host === 'macos')
					assert.equal(
						Object.hasOwn(request, 'action'),
						false,
						'the actual macOS poll mailbox keeps its native request shape'
					);
				else assert.equal(request.action, 'range');
				assert.equal(request.start_date, vector.start);
				assert.equal(request.end_date, vector.end);
				const activity = page.lastChart('wpm_chart');
				const precision = page.lastChart('precision_chart');
				const expectedTimes = [
					new Date(`${vector.start}T${vector.first}:00`).getTime(),
					new Date(`${vector.end}T${vector.second}:00`).getTime()
				];
				assert.deepEqual(
					Array.from(activity.data.datasets[0].data, (point) => point.x.getTime()),
					expectedTimes
				);
				assert.deepEqual(
					Array.from(activity.data.datasets[0].data, (point) => point.y),
					[7, 3]
				);
				assert.deepEqual(
					Array.from(precision.data.datasets[0].data, (point) => point.x.getTime()),
					expectedTimes
				);
				assert.deepEqual(
					Array.from(precision.data.datasets[0].data, (point) => point.y),
					[600 / 7, 100]
				);
				assert.equal(
					page.elements.get('wpm_chart_title').textContent,
					page.context._t('ui_typing.chart_title_activity_5min')
				);
				assert.equal(activity.options.scales.x.time.unit, 'minute');
				assert.ok(activity.options.scales.x.min.getTime() <= expectedTimes[0]);
				assert.ok(activity.options.scales.x.max.getTime() >= expectedTimes[1]);
				const retainedHistory = vm.runInContext(
					'JSON.stringify(app_state.historical_cache)',
					page.context
				);
				const stale = { historical: { c: { stale: { count: 999 } } }, today: {} };
				if (host === 'windows')
					page.messageListeners
						.filter((entry) => entry.name === 'message')
						.at(-1)
						.callback({ data: { type: 'range_data', request_id: oldRequest, payload: stale } });
				else if (host === 'linux')
					page.context.__hostBridgeResponse(
						'metrics_typing_bridge',
						false,
						encodeURIComponent(
							JSON.stringify({
								metrics_manifest: {},
								_prefetch_data: stale,
								range_request_id: oldRequest
							})
						)
					);
				else assert.equal(page.context.receive_range_data(stale, oldRequest), false);
				assert.equal(
					vm.runInContext('JSON.stringify(app_state.historical_cache)', page.context),
					retainedHistory,
					'a late older query cannot change the selected hour window data'
				);
				assert.equal(page.lastChart('wpm_chart'), activity);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
	test(`${host} last-hour ownership clears for ordinary date modes`, () => {
		const previousTimezone = process.env.TZ;
		process.env.TZ = 'UTC';
		try {
			const page = typingChartPage(host, typingHourWindows[0].now);
			publishTypingPage(page, host, typingHourManifest(typingHourWindows[0]));
			const choose = (preset) => {
				page.elements.get('quick_range').value = preset;
				runTypingControlChange(page, 'quick_range');
			};
			choose('last_hour');
			choose('today');
			assert.equal(vm.runInContext('app_state.hour_window', page.context), null);
			assert.equal(
				page.elements.get('wpm_chart_title').textContent,
				page.context._t('ui_typing.h3_activity_hourly')
			);
			choose('last_hour');
			page.elements.get('date_start').value = '2026-01-01';
			runTypingControlChange(page, 'date_start');
			assert.equal(vm.runInContext('app_state.hour_window', page.context), null);
			assert.equal(
				page.elements.get('wpm_chart_title').textContent,
				page.context._t('ui_typing.h3_activity_hourly')
			);
			choose('last_hour');
			choose('week');
			assert.equal(vm.runInContext('app_state.hour_window', page.context), null);
			assert.equal(
				page.elements.get('wpm_chart_title').textContent,
				page.context._t('ui_typing.h3_speed')
			);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		} finally {
			if (previousTimezone === undefined) delete process.env.TZ;
			else process.env.TZ = previousTimezone;
		}
	});
}
assert.equal(typingHourWindows.length, 9);
assert.equal(
	passed,
	393,
	'all date-qualified hour-window, precision and stale-response controls must execute'
);

function deliverTypingManifest(page, host, manifest, { revision = 2, range, requestId } = {}) {
	if (host === 'macos') {
		const admitted = page.context.publishTypingMetricsData(
			{ manifest },
			{ manifest_revision: revision }
		);
		if (admitted && range !== undefined) {
			const id = vm.runInContext('app_state.active_range_request_id', page.context);
			assert.equal(page.context.receive_range_data(range, id), true);
		}
		return admitted;
	}
	const blob = { metrics_manifest: manifest };
	if (range !== undefined) blob._prefetch_data = range;
	if (requestId !== undefined) blob.range_request_id = requestId;
	if (host === 'windows')
		page.messageListeners
			.filter((entry) => entry.name === 'message')
			.at(-1)
			.callback({ data: { type: 'prefetch', blob } });
	else
		page.context.__hostBridgeResponse(
			'metrics_typing_bridge',
			false,
			encodeURIComponent(JSON.stringify(blob))
		);
}
function liveTypingApp(chars) {
	return {
		chars,
		wpm_chars: chars,
		time: 60000,
		hourly: { 12: { c: chars, e_buckets: { 1000: chars / 10 } } },
		hourly_min5: { '12:05': { c: chars, e_buckets: { 1000: chars / 10 } } }
	};
}
const typingLiveCases = [
	'manifest-only update',
	'new recorded day',
	'new application',
	'cleared manifest',
	'live range update',
	'retained hour window',
	'explicit NONE selection',
	'retained subset selection'
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const scenario of typingLiveCases) {
		test(`${host} admitted live manifest refreshes ${scenario}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = 'UTC';
			try {
				const page = typingChartPage(host, '2026-01-01T12:30:00Z');
				const initial = {
					[scenario === 'new recorded day' ? '2025-12-31' : '2026-01-01']: {
						Editor: liveTypingApp(30)
					}
				};
				publishTypingPage(page, host, initial);
				if (scenario === 'explicit NONE selection')
					vm.runInContext(
						"app_state.app_selection_mode='none'; app_state.selected_apps=new Set(); apply_date_app_filters();",
						page.context
					);
				if (scenario === 'retained subset selection')
					vm.runInContext(
						"app_state.app_selection_mode='subset'; app_state.selected_apps=new Set(['Editor']); apply_date_app_filters();",
						page.context
					);
				if (scenario === 'retained hour window') {
					page.elements.get('quick_range').value = 'last_hour';
					runTypingControlChange(page, 'quick_range');
				}
				const beforeSequence = vm.runInContext('app_state.range_request_sequence', page.context);
				const beforeOwner = vm.runInContext('app_state.active_range_request_id', page.context);
				const beforeWindow = vm.runInContext('app_state.hour_window', page.context);
				const beforeSelection = vm.runInContext('app_state.range_request_selection', page.context);
				let updated = { '2026-01-01': { Editor: liveTypingApp(70) } };
				let expectedPoints = [70],
					expectedTotal = 70;
				if (scenario === 'new recorded day') {
					updated['2025-12-31'] = { Editor: liveTypingApp(30) };
					expectedPoints = [6, 14];
					expectedTotal = 100;
				}
				if (scenario === 'new application')
					updated['2026-01-01'] = { Editor: liveTypingApp(30), NewApp: liveTypingApp(40) };
				if (scenario === 'retained subset selection')
					updated['2026-01-01'].NewApp = liveTypingApp(40);
				if (scenario === 'cleared manifest') {
					updated = {};
					expectedPoints = [];
					expectedTotal = 0;
				}
				if (scenario === 'explicit NONE selection') {
					expectedPoints = [];
					expectedTotal = 0;
				}
				const range =
					scenario === 'live range update'
						? { historical: {}, today: { Editor: { c: { a: { c: 1, o: 1, t: 1000 } } } } }
						: undefined;
				deliverTypingManifest(page, host, updated, { range });
				assert.deepEqual(
					Array.from(page.lastChart('wpm_chart').data.datasets[0].data, (point) => point.y),
					expectedPoints,
					'the visible chart must use the admitted manifest rather than first-paint data'
				);
				assert.ok(
					page.elements.get('global_details').innerHTML.includes(`>${expectedTotal}</strong>`),
					'the displayed raw-character KPI and chart share the admitted manifest'
				);
				assert.deepEqual(
					JSON.parse(
						vm.runInContext('JSON.stringify(app_state.manifest_dates_sorted)', page.context)
					),
					Object.keys(updated).sort()
				);
				if (host !== 'macos')
					assert.equal(
						vm.runInContext('app_state.range_request_sequence', page.context),
						beforeSequence,
						'metadata refresh cannot create a new loader/query'
					);
				assert.equal(vm.runInContext('app_state.hour_window', page.context), beforeWindow);
				if (beforeOwner) {
					assert.equal(
						vm.runInContext('app_state.active_range_request_id', page.context),
						beforeOwner
					);
					assert.equal(
						vm.runInContext('app_state.range_request_selection', page.context),
						beforeSelection
					);
					const retainedManifest = JSON.stringify(page.context.metrics_manifest);
					deliverTypingManifest(
						page,
						host,
						{ '2026-01-01': { Editor: liveTypingApp(999) } },
						{ revision: 1, range: { historical: {}, today: {} }, requestId: beforeOwner - 1 }
					);
					assert.equal(
						JSON.stringify(page.context.metrics_manifest),
						retainedManifest,
						'an older tagged/native revision cannot replace the fresh manifest'
					);
					assert.deepEqual(
						Array.from(page.lastChart('wpm_chart').data.datasets[0].data, (point) => point.y),
						expectedPoints
					);
				}
				if (scenario === 'new application')
					assert.deepEqual(
						JSON.parse(
							vm.runInContext(
								'JSON.stringify(Array.from(app_state.selected_apps).sort())',
								page.context
							)
						),
						['Editor', 'NewApp']
					);
				if (scenario === 'retained subset selection')
					assert.deepEqual(
						JSON.parse(
							vm.runInContext('JSON.stringify(Array.from(app_state.selected_apps))', page.context)
						),
						['Editor']
					);
				if (scenario === 'explicit NONE selection')
					assert.equal(vm.runInContext('app_state.app_selection_mode', page.context), 'none');
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingLiveCases.length, 8);
assert.equal(
	passed,
	417,
	'all fresh-manifest chart, metadata and native-query ownership controls must execute'
);

const typingHeatmapCases = [
	{ name: 'ALL selection', action: 'all', monday: 23 },
	{ name: 'editor subset and Unknown policy', action: 'editor', monday: 12 },
	{ name: 'browser subset and Unknown policy', action: 'browser', monday: 16 },
	{ name: 'explicit NONE selection', action: 'none', monday: 0 },
	{ name: 'ALL restored after NONE', action: 'restore', monday: 23 },
	{ name: 'date and app selection together', action: 'date-editor', monday: 12 }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingHeatmapCases) {
		test(`${host} hour-weekday heatmap retains ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = 'UTC';
			try {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, '2026-01-06T12:00:00Z');
				const app = (chars) => ({ chars, time: 60000, hourly: { '09': { c: chars } } });
				const manifest = { '2026-01-05': { Editor: app(7), Browser: app(11), Unknown: app(5) } };
				if (vector.action === 'date-editor')
					manifest['2026-01-06'] = { Editor: app(13), Browser: app(17), Unknown: app(19) };
				publishTypingPage(page, host, manifest);
				if (['editor', 'browser', 'date-editor'].includes(vector.action)) {
					const checkbox = page.context.document.createElement('input');
					checkbox.value = vector.action === 'browser' ? 'Editor' : 'Browser';
					checkbox.checked = false;
					page.context.toggle_app_selection(checkbox);
				} else if (vector.action === 'none') page.context.deselect_all_apps();
				else if (vector.action === 'restore') {
					page.context.deselect_all_apps();
					page.context.select_all_apps();
				}
				if (vector.action === 'date-editor') {
					page.elements.get('date_start').value = '2026-01-05';
					page.elements.get('date_end').value = '2026-01-05';
					runTypingControlChange(page, 'date_start');
				}
				page.context.close_app_modal();
				const heatmap = page.elements.get('hour_weekday_heatmap_container').innerHTML;
				assert.equal(
					(heatmap.match(/<title>/g) || []).length,
					7 * 24,
					'the production heatmap renders its complete real grid'
				);
				const mondayCount = vector.monday
					? `${vector.monday} ${page.context._t('ui_typing.heatmap_hour_chars_abbrev')}`
					: page.context._t('ui_typing.heatmap_hour_no_keystrokes');
				assert.ok(
					heatmap.includes(
						`<title>${page.context._t('ui_typing.heatmap_day_mon')} 09h — ${mondayCount}</title>`
					),
					'selected-scope cells follow the canonical app selection policy'
				);
				assert.ok(
					heatmap.includes(
						`<title>${page.context._t('ui_typing.heatmap_day_tue')} 09h — ${page.context._t('ui_typing.heatmap_hour_no_keystrokes')}</title>`
					),
					'a different or excluded date cannot populate the selected cell'
				);
				assert.ok(
					heatmap.includes(`${vector.monday} ${page.context._t('ui_typing.heatmap_hour_total')}`)
				);
				assert.ok(
					page.elements.get('global_details').innerHTML.includes(`>${vector.monday}</strong>`),
					'the raw-character KPI and heatmap agree on the selected apps/dates'
				);
				assert.equal(page.elements.get('app_modal').style.display, 'none');
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingHeatmapCases.length, 6);
assert.equal(passed, 435, 'all app-modal, Unknown-policy and scoped heatmap controls must execute');

const typingDailyDateCases = [
	{
		name: 'archived skipped civil day',
		timezone: 'Pacific/Apia',
		dates: ['2011-12-29', '2011-12-30', '2011-12-31']
	},
	{
		name: 'spring daylight saving',
		timezone: 'Europe/Paris',
		dates: ['2026-03-28', '2026-03-29', '2026-03-30']
	},
	{
		name: 'fall daylight saving',
		timezone: 'America/Havana',
		dates: ['2026-10-31', '2026-11-01', '2026-11-02']
	},
	{
		name: 'negative timezone',
		timezone: 'America/Los_Angeles',
		dates: ['2026-01-01', '2026-01-02', '2026-01-04']
	},
	{
		name: 'positive timezone',
		timezone: 'Pacific/Kiritimati',
		dates: ['2026-01-01', '2026-01-02', '2026-01-04']
	},
	{ name: 'UTC control', timezone: 'UTC', dates: ['2026-01-01', '2026-01-02', '2026-01-04'] },
	{
		name: 'accepted early Gregorian year',
		timezone: 'Pacific/Apia',
		dates: ['0001-01-01', '0001-01-02', '0001-01-03']
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingDailyDateCases) {
		test(`${host} daily charts retain ${vector.name}`, () => {
			const previousTimezone = process.env.TZ;
			process.env.TZ = vector.timezone;
			try {
				const owners = [
					'wpm_chart',
					'precision_chart',
					'delegation_chart',
					'hs_sparkline',
					'llm_sparkline'
				];
				const page = typingChartPage(host, `${vector.dates.at(-1)}T12:00:00Z`, owners);
				const manifest = Object.fromEntries(
					vector.dates.map((date, i) => [date, { Editor: liveTypingApp((i + 1) * 20) }])
				);
				publishTypingPage(page, host, manifest);
				for (const owner of owners) {
					const config = page.lastChart(owner);
					const points = config.data.datasets[0].data;
					const expected = vector.dates.map((date) => Date.parse(`${date}T00:00:00Z`));
					assert.deepEqual(
						Array.from(points, (point) => Number(point.x)),
						expected,
						'recorded day identities must retain distinct canonical civil-day coordinates'
					);
					const axis = config.options.scales.x;
					assert.equal(
						axis.type,
						'linear',
						'daily ticks must not pass through the local-time adapter'
					);
					if (['wpm_chart', 'precision_chart'].includes(owner)) {
						assert.equal(Number(axis.min), expected[0]);
						assert.equal(Number(axis.max), expected.at(-1));
					}
					const scale = new page.linearScale({
						id: 'x',
						type: 'linear',
						ctx: {},
						chart: { getContext: () => ({}) }
					});
					scale.width = 640;
					scale.min = expected[0];
					scale.max = expected.at(-1);
					scale.options = {
						...axis,
						axis: 'x',
						bounds: 'data',
						min: expected[0],
						max: expected.at(-1),
						ticks: {
							...axis.ticks,
							setContext() {
								return { font: { size: 12, lineHeight: 14 } };
							}
						}
					};
					const ticks = scale.buildTicks();
					const dayCount = (expected.at(-1) - expected[0]) / 86400000 + 1;
					assert.deepEqual(
						Array.from(ticks, (tick) => tick.value),
						Array.from({ length: dayCount }, (_, i) => expected[0] + i * 86400000),
						'the shipped Chart.js scale generates one distinct tick per civil day'
					);
					const drawn = [];
					const drawing = {
						save() {},
						restore() {},
						fillText(text) {
							drawn.push(text);
						}
					};
					const chart = {
						canvas: { id: owner },
						ctx: drawing,
						scales: {
							x: {
								type: 'linear',
								top: 0,
								options: axis,
								ticks,
								getPixelForTick: (i) => i * 10
							}
						}
					};
					page.dayTickPlugin.afterDraw(chart);
					assert.equal(drawn.length, ticks.length * 2);
					for (let i = 0; i < ticks.length; i++) {
						const date = new Date(ticks[i].value);
						const day = page.context._t(`ui_typing.day_${date.getUTCDay()}`);
						assert.equal(drawn[i * 2], day);
						assert.equal(
							drawn[i * 2 + 1],
							`${date.getUTCDate()} ${page.context.months_fr()[date.getUTCMonth()]}`
						);
						assert.deepEqual(
							Array.from(axis.ticks.callback(ticks[i].value)),
							drawn.slice(i * 2, i * 2 + 2)
						);
						assert.equal(
							config.options.plugins.tooltip.callbacks.title([{ parsed: { x: ticks[i].value } }]),
							`${day} ${String(date.getUTCDate()).padStart(2, '0')}/${String(date.getUTCMonth() + 1).padStart(2, '0')}/${date.getUTCFullYear()}`
						);
					}
					chart.scales.x.type = 'time';
					drawn.length = 0;
					page.dayTickPlugin.afterDraw(chart);
					assert.equal(
						drawn.length,
						0,
						'hourly and five-minute instant labels must not be reinterpreted as UTC days'
					);
				}
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			} finally {
				if (previousTimezone === undefined) delete process.env.TZ;
				else process.env.TZ = previousTimezone;
			}
		});
	}
}
assert.equal(typingDailyDateCases.length, 7);
assert.equal(
	passed,
	456,
	'all archived-day, daylight-saving and timezone daily chart controls must execute'
);

const ribbonCategoryCases = [
	{
		name: 'plain control',
		label: 'Research',
		escaped: 'Research'
	},
	{
		name: 'literal ampersand',
		label: 'Research & Development',
		escaped: 'Research &amp; Development'
	},
	{
		name: 'balanced SVG markup',
		label: 'Label </title><rect data-category-marker="1"/><title>',
		escaped: 'Label &lt;/title&gt;&lt;rect data-category-marker=&quot;1&quot;/&gt;&lt;title&gt;'
	},
	{
		name: 'literal attribute quotes',
		label: '"quoted" & \'apostrophe\'',
		escaped: '&quot;quoted&quot; &amp; &#039;apostrophe&#039;'
	},
	{
		name: 'Unicode category',
		label: 'Développement 🧪',
		escaped: 'Développement 🧪'
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of ribbonCategoryCases) {
		test(`${host} native category remains literal ribbon text: ${vector.name}`, () => {
			const page = loadMetricsAppsPage(host);
			for (const id of ['ribbon_container', 'ribbon_legend'])
				page.elements.set(id, page.context.document.createElement('div'));
			const manifest = {
				'2026-10-27': {
					Editor: {
						app_time_ms: 60000,
						chars: 10,
						time: 1000,
						hourly: { '09': { c: 10, time_ms: 60000 } }
					}
				}
			};
			publishLoadedAppsData(page, host, manifest, {}, 1, {
				Editor: { type: vector.label, score: 0 }
			});
			const svg = page.elements.get('ribbon_container').innerHTML;
			assert.equal(
				(svg.match(/<rect /g) || []).length,
				24,
				'one native day renders its24 real hourly cells'
			);
			assert.ok(
				svg.includes(`09h — ${vector.escaped} (`),
				'custom native categories remain escaped literal tooltip text'
			);
			assert.ok(page.elements.get('ribbon_legend').innerHTML.includes(vector.escaped));
			assert.equal(
				svg.includes('<rect data-category-marker='),
				false,
				'native text cannot introduce SVG elements'
			);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(ribbonCategoryCases.length, 5);
assert.equal(passed, 471, 'all native ribbon category literal-text controls must execute');

/** Supplies DOM traversal/mutation ports over text from the actual native app table. */
function typingFindPage(host) {
	const page = loadMetricsTypingPage(host);
	freezePageClock(page, '2026-10-27T12:00:00Z');
	const document = page.context.document;
	const createElement = document.createElement;
	const body = document.body;
	body.tagName = 'DIV';
	body.closest = () => null;
	const reparent = () => {
		for (const child of body.children) {
			child.parentNode = body;
			child.parentElement = body;
		}
	};
	body.replaceChild = (replacement, node) => {
		const index = body.children.indexOf(node);
		assert.notEqual(index, -1, 'production may only replace an attached text or highlight node');
		body.children.splice(
			index,
			1,
			...(replacement.fragment ? replacement.children : [replacement])
		);
		reparent();
	};
	body.normalize = () => {
		const normalized = [];
		for (const node of body.children) {
			if (node.nodeType === 3 && normalized.at(-1)?.nodeType === 3)
				normalized.at(-1).textContent += node.textContent;
			else normalized.push(node);
		}
		body.children = normalized;
		reparent();
	};
	document.createElement = (tag) => {
		const node = createElement(tag);
		node.tagName = tag.toUpperCase();
		const classes = new Set();
		node.classList = {
			add: (name) => classes.add(name),
			remove: (name) => classes.delete(name),
			contains: (name) => classes.has(name),
			toggle(name, force) {
				const next = force === undefined ? !classes.has(name) : force;
				if (next) classes.add(name);
				else classes.delete(name);
				return next;
			}
		};
		node.scrollIntoView = () => {};
		return node;
	};
	document.createTextNode = (text) => ({ nodeType: 3, textContent: text });
	document.createDocumentFragment = () => ({
		fragment: true,
		children: [],
		appendChild(node) {
			this.children.push(node);
		}
	});
	document.querySelectorAll = (selector) =>
		selector === 'span.find-highlight'
			? body.children.filter((node) => node.className === 'find-highlight')
			: [];
	document.contains = (node) => body.children.includes(node);
	page.context.NodeFilter = { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 };
	page.findScans = 0;
	document.createTreeWalker = (root, show, filter) => {
		assert.strictEqual(root, body);
		assert.equal(show, page.context.NodeFilter.SHOW_TEXT);
		page.findScans++;
		let index = 0;
		const nodes = body.children.filter(
			(node) => node.nodeType === 3 && filter.acceptNode(node) === 1
		);
		return { nextNode: () => nodes[index++] || null };
	};
	page.admitTableText = () => {
		const html = page.elements.get('apps_table_container').innerHTML;
		// These vectors use plain app names. Only the browser's text-node boundary
		// is supplied; native publication and app-table projection run unchanged.
		const text = Array.from(html.matchAll(/<tr><td>([^<]*)<\/td>/g), (match) => match[1]).join(' ');
		body.children = [document.createTextNode(text)];
		reparent();
		return text;
	};
	page.highlights = () =>
		body.children
			.filter((node) => node.className === 'find-highlight')
			.map((node) => node.textContent);
	return page;
}
const typingFindRecoveryCases = [
	'new native row',
	'repeated missing search',
	'stale match then missing',
	'backward recovery'
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const scenario of typingFindRecoveryCases) {
		test(`${host} unchanged find query recovers after ${scenario}`, () => {
			const page = typingFindPage(host);
			const manifest = (include) => ({
				'2026-10-27': {
					'Editor.exe': liveTypingApp(20),
					...(include ? { 'RemoteTarget.exe': liveTypingApp(30) } : {})
				}
			});
			let revision = 1;
			publishTypingPage(page, host, manifest(scenario === 'stale match then missing'));
			page.elements.get('find_input').value = 'RemoteTarget';
			page.admitTableText();
			page.context.find_in_page(true);
			if (scenario === 'stale match then missing') {
				assert.deepEqual(page.highlights(), ['RemoteTarget']);
				deliverTypingManifest(page, host, manifest(false), {
					revision: ++revision,
					range: { historical: {}, today: {} }
				});
				page.admitTableText();
				page.context.find_in_page(true);
			}
			assert.equal(
				page.elements.get('find_status').textContent,
				page.context._t('ui_typing.not_found')
			);
			if (scenario === 'repeated missing search') page.context.find_in_page(true);
			deliverTypingManifest(page, host, manifest(true), {
				revision: ++revision,
				range: { historical: {}, today: {} }
			});
			assert.ok(
				page.admitTableText().includes('RemoteTarget'),
				'the actual newly admitted native table contains the sought row'
			);
			const scansBeforeRecovery = page.findScans;
			page.context.find_in_page(scenario !== 'backward recovery');
			assert.equal(
				page.findScans,
				scansBeforeRecovery + 1,
				'an empty match cache must be rescanned against the current DOM'
			);
			assert.equal(page.elements.get('find_status').textContent, '1\u202f/\u202f1');
			assert.deepEqual(page.highlights(), ['RemoteTarget']);
			page.context.find_in_page(true);
			assert.equal(page.elements.get('find_status').textContent, '1\u202f/\u202f1');
			assert.deepEqual(
				page.highlights(),
				['RemoteTarget'],
				'normal repeated navigation does not duplicate highlights'
			);
			page.elements.get('find_input').value = '';
			page.context.find_in_page(true);
			assert.equal(page.elements.get('find_status').textContent, '');
			assert.deepEqual(page.highlights(), []);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(typingFindRecoveryCases.length, 4);
assert.equal(
	passed,
	483,
	'all missing-search, stale-DOM and navigation recovery controls must execute'
);

const typingFindUnicodeCases = [
	{
		name: 'one expanded prefix',
		app: 'İTarget.exe',
		query: 'Target',
		matches: ['Target']
	},
	{
		name: 'two expanded prefixes',
		app: 'İİTarget.exe',
		query: 'target',
		matches: ['Target']
	},
	{
		name: 'expansion after match',
		app: 'Targetİ.exe',
		query: 'TARGET',
		matches: ['Target']
	},
	{
		name: 'multiple later matches',
		app: 'İTargetTarget.exe',
		query: 'target',
		matches: ['Target', 'Target']
	},
	{
		name: 'full expanded fold query',
		app: 'İTarget.exe',
		query: 'i̇',
		matches: ['İ']
	},
	{
		name: 'partial expanded fold query',
		app: 'İTarget.exe',
		query: 'i',
		matches: ['İ']
	},
	{
		name: 'contextual Greek lowercasing',
		app: 'İΟΣ-Target.exe',
		query: 'ος',
		matches: ['ΟΣ']
	},
	{
		name: 'surrogate pair prefix control',
		app: '🧪Target.exe',
		query: 'Target',
		matches: ['Target']
	}
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingFindUnicodeCases) {
		test(`${host} find preserves source offsets for ${vector.name}`, () => {
			const page = typingFindPage(host);
			publishTypingPage(page, host, { '2026-10-27': { [vector.app]: liveTypingApp(30) } });
			assert.equal(
				page.admitTableText(),
				vector.app,
				'the actual native table retains the valid Unicode process name'
			);
			page.elements.get('find_input').value = vector.query;
			page.context.find_in_page(true);
			assert.deepEqual(
				page.highlights(),
				vector.matches,
				'case-folded match positions must map back to original text spans'
			);
			assert.equal(
				page.elements.get('find_status').textContent,
				`1\u202f/\u202f${vector.matches.length}`
			);
			assert.equal(
				page.context.document.body.children.map((node) => node.textContent).join(''),
				vector.app,
				'highlighting preserves every original character'
			);
			page.context.find_in_page(true);
			assert.equal(
				page.elements.get('find_status').textContent,
				`${vector.matches.length === 1 ? 1 : 2}\u202f/\u202f${vector.matches.length}`
			);
			assert.deepEqual(page.highlights(), vector.matches);
			page.context.close_find_bar();
			assert.deepEqual(page.highlights(), []);
			assert.equal(
				page.context.document.body.children.map((node) => node.textContent).join(''),
				vector.app
			);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(typingFindUnicodeCases.length, 8);
assert.equal(
	passed,
	507,
	'all Unicode expansion, context and unchanged-offset controls must execute'
);

const typingHeaderSearchCases = [
	{ query: 'A', sensitive: false, key: 'a', count: 12 },
	{ query: 'a', sensitive: false, key: 'a', count: 12 },
	{ query: 'É', sensitive: false, key: 'é', count: 6 },
	{ query: 'é', sensitive: false, key: 'é', count: 6 },
	{ query: 'A', sensitive: true, key: 'A', count: 5 },
	{ query: 'a', sensitive: true, key: 'a', count: 7 },
	{ query: 'Z', sensitive: false, key: null },
	{ query: 'É', sensitive: true, key: null }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const vector of typingHeaderSearchCases) {
		test(`${host} table search honors case mode for ${vector.query}/${vector.sensitive}`, () => {
			const page = loadMetricsTypingPage(host);
			freezePageClock(page, '2026-10-27T12:00:00Z');
			const manifest = { '2026-10-26': { 'Editor.exe': { chars: 18, time: 1800 } } };
			publishTypingPage(page, host, manifest);
			deliverTypingManifest(page, host, manifest, {
				range: {
					historical: { c: { a: { c: 7, t: 700 }, A: { c: 5, t: 500 }, é: { c: 6, t: 600 } } },
					today: {}
				}
			});
			// The browser toggle changes the projected rows before searching them.
			if (vector.sensitive) page.elements.get('btn_case_sensitive').classList.add('active');
			else page.elements.get('btn_case_sensitive').classList.remove('active');
			page.context.apply_local_filters();
			assert.ok(vm.runInContext('app_state.rendered_list.length', page.context) >= 2);
			page.elements.get('search_input').value = vector.query;
			page.context.handle_search();
			page.timers.at(-1)();
			const html = page.elements.get('metrics_table_body').innerHTML;
			assert.equal(
				vm.runInContext('app_state.search_query', page.context),
				vector.query,
				'the input and retained query preserve the user text'
			);
			if (vector.key === null) {
				assert.ok(html.includes(page.context._t('ui_typing.no_data')));
				assert.equal(page.elements.get('total_rows').innerHTML, '');
			} else {
				assert.ok(
					html.includes(`<span class="mono-space">${vector.key}</span>`),
					'the actual table must render the matching native character'
				);
				assert.ok(html.includes(`<td>${vector.count}</td>`));
				assert.equal(page.elements.get('total_rows').innerHTML, '1 ligne');
			}
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(typingHeaderSearchCases.length, 8);
assert.equal(passed, 531, 'all case-mode, Unicode and absent-query table controls must execute');

const nativeWordTokens = ['ordinary', 'constructor', 'toString', '__proto__', 'hasOwnProperty'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const source of ['historical', 'today']) {
		for (const sensitive of [true, false]) {
			for (const token of nativeWordTokens) {
				test(`${host} ${source} words retain literal ${token}/${sensitive}`, () => {
					const page = loadMetricsTypingPage(host);
					freezePageClock(page, '2026-10-27T12:00:00Z');
					const manifest = {
						[source === 'historical' ? '2026-10-26' : '2026-10-27']: {
							'Editor.exe': { chars: token.length * 7, time: 7000 }
						}
					};
					publishTypingPage(page, host, manifest);
					if (sensitive) page.elements.get('btn_case_sensitive').classList.add('active');
					else page.elements.get('btn_case_sensitive').classList.remove('active');
					const prototypeShape = () =>
						vm.runInContext(
							`JSON.stringify(
						Object.getOwnPropertyNames(Object.prototype).map(key => [key,
							typeof Object.prototype[key] === 'function'
								? Object.getOwnPropertyNames(Object.prototype[key]) : []]))`,
							page.context
						);
					const beforePrototype = prototypeShape();
					const words = { w: Object.fromEntries([[token, { c: 7, t: 0 }]]) };
					deliverTypingManifest(page, host, manifest, {
						range:
							source === 'historical'
								? { historical: words, today: {} }
								: { historical: {}, today: { 'Editor.exe': words } }
					});
					const key = sensitive ? token : token.toLowerCase();
					assert.deepEqual(
						Array.from(vm.runInContext('Object.keys(app_state.data.w)', page.context)),
						[key],
						'every native word remains an own dictionary entry'
					);
					assert.equal(
						vm.runInContext(`app_state.data.w[${JSON.stringify(key)}].count`, page.context),
						7
					);
					assert.equal(
						prototypeShape(),
						beforePrototype,
						'native text must never mutate prototypes or inherited built-in functions'
					);
					const projection = vm.runInContext('app_state.data', page.context);
					page.context.apply_local_filters();
					assert.strictEqual(
						vm.runInContext('app_state.data', page.context),
						projection,
						'the retained projection keeps valid token keys on cache hits'
					);
					vm.runInContext("app_state.current_tab = 'w';", page.context);
					page.context.render_current_tab();
					page.timers.at(-1)();
					const html = page.elements.get('metrics_table_body').innerHTML;
					assert.ok(html.includes(`<span class="mono-space">${key}</span>`));
					assert.ok(html.includes('<td>7</td>'));
					assert.ok(
						page.context.build_searchable_key('[BS]', false).includes('backspace'),
						'declared control markers retain their actual search aliases'
					);
					assert.equal(
						page.context.build_searchable_key(token, sensitive),
						key,
						'ordinary word text cannot acquire inherited control-key aliases'
					);
					page.elements.get('search_input').value = token;
					page.context.handle_search();
					page.timers.at(-1)();
					assert.ok(
						page.elements
							.get('metrics_table_body')
							.innerHTML.includes(`<span class="mono-space">${key}</span>`)
					);
					assert.equal(
						page.diagnostics.some((entry) => entry.level === 'error'),
						false
					);
				});
			}
		}
	}
}
assert.equal(nativeWordTokens.length, 5);
assert.equal(
	passed,
	591,
	'all historical/live native token identity and prototype controls must execute'
);

const typingTokenPresentationCases = [
	{ tab: 'w_bg', token: 'one two', words: ['one', 'two'], modifiers: 0, controls: 0, arrows: 1 },
	{
		tab: 'w_bg',
		token: 'ctrl shift',
		words: ['ctrl', 'shift'],
		modifiers: 0,
		controls: 0,
		arrows: 1
	},
	{ tab: 'w_bg', token: 'été œuf', words: ['été', 'œuf'], modifiers: 0, controls: 0, arrows: 1 },
	{
		tab: 'w_bg',
		token: 'fish&chips served',
		words: ['fish&amp;chips', 'served'],
		modifiers: 0,
		controls: 0,
		arrows: 1
	},
	{ tab: 'sc', token: 'Ctrl+C', words: [], modifiers: 1, controls: 0, arrows: 0 },
	{ tab: 'sc', token: 'Ctrl+Enter', words: [], modifiers: 1, controls: 1, arrows: 0 },
	{ tab: 'sc_bg', token: 'Ctrl+C→Ctrl+V', words: [], modifiers: 2, controls: 0, arrows: 1 },
	{ tab: 'mods', token: 'Ctrl+C', words: [], modifiers: 1, controls: 0, arrows: 0 }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const source of ['historical', 'today']) {
		for (const vector of typingTokenPresentationCases) {
			test(`${host} ${source} table renders native ${vector.tab}/${vector.token}`, () => {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, '2026-10-27T12:00:00Z');
				const manifest = {
					[source === 'historical' ? '2026-10-26' : '2026-10-27']: {
						'Editor.exe': { chars: 70, time: 7000 }
					}
				};
				publishTypingPage(page, host, manifest);
				const tokenData = {
					[vector.tab === 'mods' ? 'sc' : vector.tab]: {
						[vector.token]: { c: 7, t: 0 }
					}
				};
				deliverTypingManifest(page, host, manifest, {
					range:
						source === 'historical'
							? { historical: tokenData, today: {} }
							: { historical: {}, today: { 'Editor.exe': tokenData } }
				});
				vm.runInContext(`app_state.current_tab = ${JSON.stringify(vector.tab)};`, page.context);
				page.context.render_current_tab();
				page.timers.at(-1)();
				const html = page.elements.get('metrics_table_body').innerHTML;
				assert.equal(
					vm.runInContext('app_state.rendered_list.length', page.context),
					1,
					'the real native range must reach the selected table'
				);
				assert.ok(html.includes('<td>7</td>'));
				assert.equal(
					(html.match(/class="mono-space"/g) || []).length,
					vector.words.length,
					'word sequences keep one literal chip per recorded word'
				);
				for (const word of vector.words)
					assert.ok(html.includes(`<span class="mono-space">${word}</span>`));
				assert.equal(
					(html.match(/class="shortcut-chip shortcut-mod-/g) || []).length,
					vector.modifiers,
					'only actual shortcut modifiers receive modifier chips'
				);
				assert.equal(
					(html.match(/class="shortcut-chip shortcut-key-control"/g) || []).length,
					vector.controls
				);
				assert.equal((html.match(/>→<\/span>/g) || []).length, vector.arrows);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			});
		}
	}
}
assert.equal(typingTokenPresentationCases.length, 8);
assert.equal(
	passed,
	639,
	'all native word, shortcut and modifier presentation controls must execute'
);

const ordinaryControlWords = ['space', 'enter', 'Tab', 'return', 'escape', 'left'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const source of ['historical', 'today']) {
		for (const sensitive of [true, false]) {
			for (const word of ordinaryControlWords) {
				test(`${host} ${source} words distinguish literal ${word}/${sensitive}`, () => {
					const page = loadMetricsTypingPage(host);
					freezePageClock(page, '2026-10-27T12:00:00Z');
					const manifest = {
						[source === 'historical' ? '2026-10-26' : '2026-10-27']: {
							'Editor.exe': { chars: (word.length + 1) * 7, time: 7000 }
						}
					};
					publishTypingPage(page, host, manifest);
					if (sensitive) page.elements.get('btn_case_sensitive').classList.add('active');
					else page.elements.get('btn_case_sensitive').classList.remove('active');
					const chars = Object.fromEntries(
						Array.from(new Set(word + ' '), (char) => [
							char,
							{
								c: Array.from(word + ' ').filter((value) => value === char).length * 7,
								t: 0
							}
						])
					);
					const tokenData = { w: { [word]: { c: 7, t: 0 } }, c: chars };
					deliverTypingManifest(page, host, manifest, {
						range:
							source === 'historical'
								? { historical: tokenData, today: {} }
								: { historical: {}, today: { 'Editor.exe': tokenData } }
					});
					vm.runInContext("app_state.current_tab = 'w';", page.context);
					page.context.render_current_tab();
					page.timers.at(-1)();
					const key = sensitive ? word : word.toLowerCase();
					const html = page.elements.get('metrics_table_body').innerHTML;
					assert.equal(vm.runInContext('app_state.rendered_list.length', page.context), 1);
					assert.ok(
						html.includes(`<span class="mono-space">${key}</span>`),
						'ordinary words keep literal text instead of a keyboard control label'
					);
					assert.ok(html.includes('<td>7</td>'));
					assert.equal(
						page.context.build_searchable_key(word, sensitive),
						key,
						'words do not acquire keyboard-only aliases'
					);
					page.elements.get('search_input').value = word;
					page.context.handle_search();
					page.timers.at(-1)();
					assert.ok(
						page.elements
							.get('metrics_table_body')
							.innerHTML.includes(`<span class="mono-space">${key}</span>`)
					);
					const controlCase = word[0].toUpperCase() + word.slice(1).toLowerCase();
					const differentCase = word === controlCase ? word.toLowerCase() : controlCase;
					page.elements.get('search_input').value = differentCase;
					page.context.handle_search();
					page.timers.at(-1)();
					const searched = page.elements.get('metrics_table_body').innerHTML;
					assert.equal(
						searched.includes(page.context._t('ui_typing.no_data')),
						sensitive,
						'word searches follow only the selected case mode'
					);
					// The same real range also contains the physical spaces ending these words.
					vm.runInContext(
						"app_state.current_tab = 'c'; app_state.search_query = '';",
						page.context
					);
					page.context.render_current_tab();
					page.timers.at(-1)();
					assert.ok(
						page.elements
							.get('metrics_table_body')
							.innerHTML.includes('shortcut-key-control">Space</span>'),
						'the characters tab retains the actual keyboard Space marker'
					);
					assert.ok(page.context.build_searchable_key(' ', true).includes('Space'));
					assert.equal(
						page.diagnostics.some((entry) => entry.level === 'error'),
						false
					);
				});
			}
		}
	}
}
assert.equal(ordinaryControlWords.length, 6);
assert.equal(
	passed,
	711,
	'all literal-word versus physical-control display and search controls must execute'
);

const typingReplacementAppScopes = [
	{ name: 'empty history', apps: null, names: [] },
	{ name: 'system-only day', apps: { _system: { awake_ms: 1000 } }, names: [] },
	{
		name: 'retained selected app',
		apps: { 'Editor.exe': { chars: 9, time: 900 } },
		names: ['Editor.exe']
	},
	{ name: 'new app only', apps: { 'Fresh.exe': { chars: 9, time: 900 } }, names: ['Fresh.exe'] }
];
for (const host of ['windows', 'macos', 'linux']) {
	for (const mode of ['all', 'none', 'subset']) {
		for (const vector of typingReplacementAppScopes) {
			test(`${host} ${mode} app scope reconciles ${vector.name}`, () => {
				const page = loadMetricsTypingPage(host);
				freezePageClock(page, '2026-10-27T12:00:00Z');
				page.elements.get('app_search').focus = () => {};
				publishTypingPage(page, host, {
					'2026-10-27': {
						'Editor.exe': { chars: 5, time: 500 },
						'Browser.exe': { chars: 6, time: 600 }
					}
				});
				if (mode !== 'all') {
					page.context.open_app_modal();
					page.context.deselect_all_apps();
					if (mode === 'subset')
						page.context.toggle_app_selection({ checked: true, value: 'Editor.exe' });
					page.context.close_app_modal();
				}
				assert.equal(vm.runInContext('app_state.app_selection_mode', page.context), mode);
				const replacement = vector.apps === null ? {} : { '2026-10-27': vector.apps };
				deliverTypingManifest(page, host, replacement);
				const selected =
					mode === 'all'
						? vector.names
						: mode === 'subset' && vector.names.includes('Editor.exe')
							? ['Editor.exe']
							: [];
				const expectedMode = mode === 'subset' && selected.length === 0 ? 'none' : mode;
				assert.deepEqual(
					Array.from(vm.runInContext('app_state.available_apps', page.context)),
					vector.names,
					'a full native replacement retires every unavailable app identity'
				);
				assert.deepEqual(
					Array.from(vm.runInContext('[...app_state.selected_apps]', page.context)),
					selected
				);
				assert.equal(vm.runInContext('app_state.app_selection_mode', page.context), expectedMode);
				assert.deepEqual(
					Array.from(page.context.get_app_selection_request_apps()),
					selected,
					'future native queries use only the reconciled application scope'
				);
				page.context.open_app_modal();
				const list = page.elements.get('app_list').innerHTML;
				for (const retired of [
					'Browser.exe',
					...(!vector.names.includes('Editor.exe') ? ['Editor.exe'] : [])
				])
					assert.equal(list.includes(`value="${retired}"`), false);
				for (const available of vector.names) assert.ok(list.includes(`value="${available}"`));
				page.context.close_app_modal();
				deliverTypingManifest(
					page,
					host,
					{
						'2026-10-27': { 'Future.exe': { chars: 10, time: 1000 } }
					},
					{ revision: 3 }
				);
				assert.deepEqual(Array.from(vm.runInContext('app_state.available_apps', page.context)), [
					'Future.exe'
				]);
				assert.deepEqual(
					Array.from(page.context.get_app_selection_request_apps()),
					mode === 'all' ? ['Future.exe'] : [],
					'ALL follows new apps while explicit NONE and subset intent remain restrictive'
				);
				assert.equal(
					page.diagnostics.some((entry) => entry.level === 'error'),
					false
				);
			});
		}
	}
}
assert.equal(typingReplacementAppScopes.length, 4);
assert.equal(
	passed,
	747,
	'all native empty/replaced app-scope and later discovery controls must execute'
);

const typingEmptySelectionStarts = ['empty', 'application', 'system-only'];
for (const host of ['windows', 'macos', 'linux']) {
	for (const initial of typingEmptySelectionStarts) {
		test(`${host} app-filter caption follows explicit selection after ${initial}`, () => {
			const page = loadMetricsTypingPage(host);
			freezePageClock(page, '2026-10-27T12:00:00Z');
			page.elements.get('app_search').focus = () => {};
			const manifest =
				initial === 'empty'
					? {}
					: {
							'2026-10-27':
								initial === 'application'
									? { 'Editor.exe': { chars: 5, time: 500 } }
									: { _system: { awake_ms: 1000 } }
						};
			publishTypingPage(page, host, manifest);
			const button = page.elements.get('app_filter_btn');
			const choose = (all) => {
				page.context.open_app_modal();
				if (all) page.context.select_all_apps();
				else page.context.deselect_all_apps();
				page.context.close_app_modal();
			};
			const assertCaption = (all) => {
				assert.equal(
					button.innerText,
					page.context._t(all ? 'ui_typing.apps_all' : 'ui_typing.apps_none'),
					'the native filter caption distinguishes explicit NONE from ALL at zero apps'
				);
				assert.equal(button.classList.contains('active'), all);
				assert.equal(
					vm.runInContext('app_state.app_selection_mode', page.context),
					all ? 'all' : 'none'
				);
			};
			assertCaption(true);
			choose(false);
			assertCaption(false);
			assert.deepEqual(Array.from(page.context.get_app_selection_request_apps()), []);
			choose(true);
			assertCaption(true);
			deliverTypingManifest(page, host, {
				'2026-10-27': {
					'Fresh.exe': { chars: 8, time: 800 },
					'Other.exe': { chars: 9, time: 900 }
				}
			});
			assertCaption(true);
			page.context.open_app_modal();
			page.context.toggle_app_selection({ value: 'Other.exe', checked: false });
			page.context.close_app_modal();
			assert.ok(button.innerText.includes('(1/2)'), 'nonempty subset captions retain their count');
			assert.equal(button.classList.contains('active'), false);
			choose(false);
			assertCaption(false);
			deliverTypingManifest(page, host, {}, { revision: 3 });
			assert.deepEqual(Array.from(vm.runInContext('app_state.available_apps', page.context)), []);
			assertCaption(false);
			choose(true);
			assertCaption(true);
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(typingEmptySelectionStarts.length, 3);
assert.equal(
	passed,
	756,
	'all explicit empty NONE/ALL, subset and native-clear caption controls must execute'
);

// This browser port links the two real DOM text properties and declared attributes.
function typingAppFilterLocalePorts(page) {
	const button = page.elements.get('app_filter_btn');
	let caption = button.innerText || button.textContent || '';
	for (const property of ['innerText', 'textContent']) {
		Object.defineProperty(button, property, {
			get: () => caption,
			set: (value) => {
				caption = String(value);
			},
			configurable: true
		});
	}
	const declaration = page.html.match(/<button\b([^>]*\bid="app_filter_btn"[^>]*)>/);
	assert.ok(declaration, 'the actual page declares its application filter control');
	const key = declaration[1].match(/data-i18n="([^"]+)"/)?.[1] || null;
	button.getAttribute = (name) => (name === 'data-i18n' ? key : null);
	page.context.document.querySelectorAll = (selector) =>
		selector === '[data-i18n]' && key ? [button] : [];
	page.context.CustomEvent = class CustomEvent {
		constructor(type) {
			this.type = type;
		}
	};
	page.context.document.dispatchEvent = (event) => {
		for (const listener of page.listeners.filter((entry) => entry.name === event.type))
			listener.callback(event);
		return true;
	};
	return button;
}
const typingCaptionLocaleRoot = path.resolve(root, '../data/locales');
const typingCaptionCatalogues = fs
	.readdirSync(typingCaptionLocaleRoot)
	.filter((name) => name.endsWith('.json'))
	.sort()
	.map((name) => ({
		name,
		strings: JSON.parse(fs.readFileSync(path.join(typingCaptionLocaleRoot, name), 'utf8'))
	}));
assert.ok(typingCaptionCatalogues.some((locale) => locale.name === 'en.json'));
assert.ok(typingCaptionCatalogues.some((locale) => locale.name === 'fr.json'));
let typingCaptionLocaleApplications = 0;
for (const host of ['windows', 'macos', 'linux']) {
	for (const mode of ['none', 'all', 'subset']) {
		test(`${host} ${mode} app-filter caption survives every locale application`, () => {
			const page = loadMetricsTypingPage(host);
			freezePageClock(page, '2026-10-27T12:00:00Z');
			const button = typingAppFilterLocalePorts(page);
			page.elements.get('app_search').focus = () => {};
			publishTypingPage(page, host, {
				'2026-10-27': {
					'Editor.exe': { chars: 5, time: 500 },
					'Browser.exe': { chars: 6, time: 600 }
				}
			});
			if (mode !== 'all') {
				page.context.open_app_modal();
				page.context.deselect_all_apps();
				if (mode === 'subset')
					page.context.toggle_app_selection({ value: 'Editor.exe', checked: true });
				page.context.close_app_modal();
			}
			assert.equal(vm.runInContext('app_state.app_selection_mode', page.context), mode);
			const selection = JSON.stringify(Array.from(page.context.get_app_selection_request_apps()));
			const posts = page.posts.length;
			for (const locale of typingCaptionCatalogues) {
				for (const key of ['ui_typing.apps_none', 'ui_typing.apps_all'])
					assert.equal(
						typeof locale.strings[key],
						'string',
						`${locale.name} declares the existing dynamic key`
					);
				page.context._i18n_locale = locale.name.slice(0, -5);
				page.context.i18n_apply(locale.strings);
				if (mode === 'subset') assert.ok(button.innerText.includes('(1/2)'));
				else
					assert.equal(
						button.innerText,
						locale.strings[mode === 'all' ? 'ui_typing.apps_all' : 'ui_typing.apps_none'],
						`${locale.name} keeps the real native selection in the visible caption`
					);
				assert.equal(button.classList.contains('active'), mode === 'all');
				assert.equal(vm.runInContext('app_state.app_selection_mode', page.context), mode);
				assert.equal(
					JSON.stringify(Array.from(page.context.get_app_selection_request_apps())),
					selection
				);
				assert.equal(
					page.posts.length,
					posts,
					'a locale repaint must not restart a native range query'
				);
				typingCaptionLocaleApplications++;
			}
			assert.equal(
				page.diagnostics.some((entry) => entry.level === 'error'),
				false
			);
		});
	}
}
assert.equal(typingCaptionLocaleApplications, typingCaptionCatalogues.length * 9);
assert.equal(passed, 765, 'all native app-filter modes and every locale transition must execute');

const nativeWordProjection = JSON.parse(
	fs.readFileSync(
		path.resolve(root, '../../windows/tests/fixtures/metrics_word_projection.json'),
		'utf8'
	)
);
assert.equal(nativeWordProjection.cases.length, 10);
for (const host of ['windows', 'macos', 'linux']) {
	for (const source of ['historical', 'today']) {
		for (const sensitive of [false, true]) {
			for (const vector of nativeWordProjection.cases) {
				test(`${host} ${source} completed word ${vector.id}, case-sensitive ${sensitive}`, () => {
					const page = loadMetricsTypingPage(host);
					freezePageClock(
						page,
						source === 'historical' ? '2026-10-27T12:00:00' : '2026-10-26T12:00:00'
					);
					publishTypingPage(page, host, vector.snapshot.manifest);
					if (sensitive) page.elements.get('btn_case_sensitive').classList.add('active');
					else page.elements.get('btn_case_sensitive').classList.remove('active');
					const raw = vector.snapshot.range.historical;
					deliverTypingManifest(page, host, vector.snapshot.manifest, {
						range:
							source === 'historical'
								? vector.snapshot.range
								: {
										historical: {},
										today: { [nativeWordProjection.app]: raw }
									}
					});
					page.context.apply_local_filters();
					const caption = page.elements.get('wpm_words_sub').innerHTML;
					assert.ok(
						caption.includes(`>${vector.snapshot.expected_words}</strong>`),
						'total words includes every completed word, including corrected completions'
					);
					assert.ok(caption.includes(page.context._t('ui_typing.unit_words_typed')));
					const expected = vector.expected_rows[sensitive ? 'case_sensitive' : 'case_folded'];
					for (const tab of ['w', 'w_bg']) {
						vm.runInContext(`app_state.current_tab = ${JSON.stringify(tab)}`, page.context);
						page.context.render_current_tab();
						page.timers.at(-1)();
						const rows = JSON.parse(
							vm.runInContext(
								'JSON.stringify(app_state.rendered_list.map(row => ({key: row.key, count: row.count, accuracy: row.acc})))',
								page.context
							)
						);
						const sort = (items) => items.sort((a, b) => a.key.localeCompare(b.key));
						assert.deepEqual(sort(rows), sort(structuredClone(expected[tab])));
					}
					for (const tab of ['c', 'bg', 'tg', 'qg', 'pg', 'hx', 'hp']) {
						const counts = new Map();
						for (const [key, value] of Object.entries(raw[tab] || {})) {
							const folded = sensitive ? key : key.toLowerCase();
							counts.set(folded, (counts.get(folded) || 0) + value.c);
						}
						const projected = vm.runInContext(
							`app_state.data[${JSON.stringify(tab)}]`,
							page.context
						);
						for (const [key, count] of counts)
							if (count > 0)
								assert.equal(
									projected[key]?.count,
									count,
									'character occurrence counts never add error counts'
								);
					}
					assert.equal(
						page.diagnostics.some((entry) => entry.level === 'error'),
						false
					);
				});
			}
		}
	}
}
assert.equal(
	passed,
	885,
	'all native completed-word histories, case modes and host ingress paths must execute'
);

console.log(`${passed} passed, 0 failed.`);
