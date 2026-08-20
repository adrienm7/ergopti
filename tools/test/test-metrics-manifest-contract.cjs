// tools/test/test-metrics-manifest-contract.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Manifest Payload Contract Test
 * DESCRIPTION:
 * Executes the real Typing and Apps manifest consumers against a payload built
 * from the shared schema. Structured reader fields must drive non-empty error,
 * burst, session, and modifier-hold results without transport-only aliases.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const contract = JSON.parse(
	read('static/ergopti_plus/_shared/data/metrics_manifest_contract.json')
);
const typingSource = read('static/ergopti_plus/_shared/ui/metrics_typing/data.js');
const appsSource = read('static/ergopti_plus/_shared/ui/metrics_apps/state.js');
const plain = (value) => JSON.parse(JSON.stringify(value));

function extractFunction(source, name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notStrictEqual(start, -1, `${name} must exist`);
	const bodyStart = source.indexOf('{', start);
	let depth = 0;
	let quote = null;
	let escaped = false;
	let lineComment = false;
	let blockComment = false;
	for (let i = bodyStart; i < source.length; i++) {
		const ch = source[i];
		const next = source[i + 1];
		if (lineComment) {
			if (ch === '\n') lineComment = false;
			continue;
		}
		if (blockComment) {
			if (ch === '*' && next === '/') {
				blockComment = false;
				i++;
			}
			continue;
		}
		if (quote) {
			if (escaped) escaped = false;
			else if (ch === '\\') escaped = true;
			else if (ch === quote) quote = null;
			continue;
		}
		if (ch === '/' && next === '/') {
			lineComment = true;
			i++;
			continue;
		}
		if (ch === '/' && next === '*') {
			blockComment = true;
			i++;
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

function compileFunction(source, name, context) {
	return vm.runInNewContext(`(${extractFunction(source, name)})`, context, {
		filename: `${name}.js`
	});
}

const appFields = contract.app_entry;
for (const field of [
	'burst_length_buckets',
	'session_durations',
	'hourly',
	'hourly_min5',
	'kc_hold'
]) {
	assert.ok(Object.hasOwn(appFields, field), `shared contract must declare ${field}`);
}
assert.deepStrictEqual(
	Object.keys(appFields.kc_hold.item_fields),
	['s', 'n', 'm', 'tap', 'hold'],
	'the shared contract must retain the exact modifier-hold vocabulary'
);

const appEntry = {
	chars: 30,
	time: 60_000,
	app_time_ms: 60_000,
	burst_count_total: 5,
	burst_max_cpm: 200,
	burst_max_chars: 10,
	burst_length_buckets: { short: 3, medium: 1, long: 4 },
	session_count_total: 4,
	session_longest_ms: 2000,
	session_longest_chars: 20,
	session_total_active_ms: 4000,
	session_durations: [500, 1000, 750, 2000],
	kc_hold: {
		16: { s: 1000, n: 5, m: 400, tap: 3, hold: 2 }
	},
	hourly: {
		'09': { c: 30, e: 5, em: 3, es: 2, e_buckets: { 250: 4, 500: 2, 1000: 4 } }
	},
	hourly_min5: {
		'09:00': { c: 15, e: 3, es: 2, e_buckets: { 250: 3, 500: 3 } }
	}
};
const manifest = { '2025-05-01': { 'editor.exe': appEntry } };

const appsContext = {
	window: {},
	manifestData: manifest,
	currentSelectedDate: '2025-05-01',
	currentPeriod: 'all',
	currentWeekdayFilter: null,
	currentCategoryFilter: null,
	currentCountAwake: true,
	parseDateKey: (date) => Date.parse(`${date}T12:00:00`),
	formatDisplayDate: (date) => date,
	getAppCategory: (_name, category) => ({ type: category || 'General', score: 0 })
};
const getAggregatedData = compileFunction(appsSource, 'getAggregatedData', appsContext);
const appsResult = getAggregatedData();
assert.deepStrictEqual(
	plain(appsResult.rich.bursts.length_buckets),
	{ short: 3, medium: 1, long: 4 },
	'the real Apps consumer must produce a non-empty burst histogram'
);
assert.deepStrictEqual(
	plain(appsResult.apps['editor.exe'].session_durations),
	[500, 1000, 750, 2000],
	'the real Apps consumer must produce a non-empty session boxplot source'
);
assert.strictEqual(
	appsResult.apps['editor.exe'].kc_hold_sum_ms,
	1000,
	'the real Apps consumer must retain modifier hold duration'
);
assert.strictEqual(
	appsResult.apps['editor.exe'].kc_hold_count,
	5,
	'the real Apps consumer must retain modifier hold count'
);
assert.deepStrictEqual(
	plain(appsResult.rich.kc_hold['16']),
	{ s: 1000, n: 5, m: 400, tap: 3, hold: 2 },
	'the real Apps consumer must retain every canonical modifier hold field'
);

const elements = new Map();
const element = (id) => {
	if (!elements.has(id)) elements.set(id, { value: '', style: {}, innerHTML: '' });
	return elements.get(id);
};
element('date_start').value = '2025-05-01';
element('date_end').value = '2025-05-01';
const typingState = {
	manifest_dates_sorted: ['2025-05-01'],
	selected_apps: new Set(['editor.exe'])
};
const typingContext = {
	window: { metrics_manifest: manifest },
	app_state: typingState,
	document: { getElementById: element },
	get_source_mode_flags: () => ({
		show_manual: true,
		show_hs: true,
		show_llm: true,
		mpm_include_hs: true,
		mpm_include_llm: true
	}),
	format_number: (value) => String(value),
	get_trend_svg: () => '',
	_t: (key) => key,
	INFO_SVG: '',
	render_charts: () => {}
};
const computeManifestMetrics = compileFunction(
	typingSource,
	'compute_manifest_metrics',
	typingContext
);
computeManifestMetrics();
assert.deepStrictEqual(
	plain(typingState.hourly_series['09'].e_buckets),
	{ 250: 4, 500: 2, 1000: 4 },
	'the real Typing consumer must produce non-empty hourly error buckets'
);
assert.deepStrictEqual(
	plain(typingState.minute5_series['09:00'].e_buckets),
	{ 250: 3, 500: 3 },
	'the real Typing consumer must produce non-empty five-minute error buckets'
);
assert.deepStrictEqual(
	plain(typingState.time_series['2025-05-01'].daily_e_buckets),
	{ 250: 4, 500: 2, 1000: 4 },
	'the precision chart must receive the same canonical threshold buckets'
);

console.log('PASS test-metrics-manifest-contract');
