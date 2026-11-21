// tools/test/test-metrics-view-states.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Dashboard View States (MET-13, MET-14, MET-16)
 * DESCRIPTION:
 * Runs the real dashboard pages, every script their HTML declares, in a
 * sandbox and reads what the user is left with:
 * - an empty range or app selection: each typing card said « Computing… »
 *   for good once the read had landed (MET-13);
 * - a render error on the apps page: its alert stayed after the next good
 *   render and printed the stack (MET-14);
 * - the activity calendars, heatmaps and strips of both dashboards: their
 *   per-day and per-hour values lived only in SVG <title> elements, which
 *   neither the keyboard nor a screen reader reaches (MET-16).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const vm = require('node:vm');
const { loadMetricsAppsPage, loadMetricsTypingPage } = require('./support/metrics-apps-page.cjs');

let passed = 0;
let failed = 0;

function test(name, callback) {
	try {
		callback();
		passed++;
		console.log(`ok ${name}`);
	} catch (error) {
		failed++;
		console.error(`FAIL ${name}: ${error.message}`);
	}
}

// The cards whose figures hide when the selection holds nothing for them.
const EMPTY_CARDS = [
	'ergo_bigram',
	'ergo_trigram',
	'errors',
	'roi',
	'lexical',
	'rhythm',
	'sessions',
	'records',
	'charmix',
	'apps',
	'wellness'
];

/** Publishes one host's manifest and range reply the way that host does. */
function publishTyping(page, host, manifest, range) {
	if (host === 'macos') {
		page.context.publishTypingMetricsData(
			{ manifest, initial_data: range, app_icons: {}, kc_layout: {} },
			{ manifest_revision: 1, assets_revision: 1 }
		);
		return;
	}
	const blob = {
		metrics_manifest: manifest,
		_prefetch_data: range,
		app_icons: {},
		keycode_layout: {},
		driver_meta: { os: host === 'windows' ? 'win' : host, heatmap_id: 'sc' }
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

for (const host of ['macos', 'windows', 'linux']) {
	test(`${host}: an empty range shows each card's empty state, not « Computing… » (met-13)`, () => {
		const page = loadMetricsTypingPage(host);
		const card = (id) => page.elements.get(id + '_loading');
		// A late locale draws the cards again before any range has landed.
		for (const listener of page.listeners.filter((entry) => entry.name === 'i18n:applied'))
			listener.callback();
		for (const id of EMPTY_CARDS)
			assert.notEqual(
				card(id)['data-i18n'],
				'ui_typing.no_data',
				`${id} computes until the read lands`
			);
		publishTyping(
			page,
			host,
			{ '2026-09-07': { Editor: { chars: 0 } } },
			{ historical: {}, today: {} }
		);
		for (const id of EMPTY_CARDS) {
			assert.notEqual(card(id).style.display, 'none', `${id} shows its line in place of figures`);
			assert.equal(
				card(id)['data-i18n'],
				'ui_typing.no_data',
				`${id} keeps its key for a later locale`
			);
			assert.equal(
				card(id).textContent,
				page.context._t('ui_typing.no_data'),
				`${id} says it is empty`
			);
		}
		// A ratio over nothing is missing, not zero.
		assert.match(page.elements.get('rep_val').innerHTML, /^—<button/);
		assert.match(page.elements.get('sfb_val').innerHTML, /^—<button/);
		assert.equal(
			page.diagnostics.some((entry) => entry.level === 'error'),
			false,
			JSON.stringify(page.diagnostics.filter((entry) => entry.level === 'error'))
		);
	});
}

test('a good apps render retires the alert of a failed one, which names the cause only (met-14)', () => {
	const page = loadMetricsAppsPage('macos');
	const { context } = page;
	vm.runInContext(
		"var __aggregate = getAggregatedData; getAggregatedData = function () { throw new Error('boom'); };",
		context
	);
	context.renderDashboard();
	const banner = context.document.getElementById('render-error-banner');
	assert.ok(banner, 'a failed render raises its alert');
	assert.equal(banner.role, 'alert');
	assert.match(banner.textContent, /boom/);
	assert.doesNotMatch(
		banner.textContent,
		/\n|\bat\b.*:\d+/,
		'the alert names the cause, not the stack'
	);
	// The empty period returns early from the render: it is a good render too.
	vm.runInContext('getAggregatedData = __aggregate; manifestData = {};', context);
	context.renderDashboard();
	assert.equal(
		context.document.getElementById('render-error-banner'),
		null,
		'the next good render removes the alert'
	);
});

/** Unescapes the few entities the pages write into markup. */
function unescape(text) {
	return text
		.replace(/&lt;/g, '<')
		.replace(/&gt;/g, '>')
		.replace(/&quot;/g, '"')
		.replace(/&#39;/g, "'")
		.replace(/&amp;/g, '&');
}

/**
 * The problems of the drawings in one rendered container: an SVG whose marks
 * carry hover titles must name a disclosure, beside it, that lists the same
 * words (data-keyboard-equivalent, as tools/test/lib/keyboard-operability.cjs
 * reads it).
 * @returns {{drawings: number, problems: string[]}}
 */
function drawingProblems(name, html) {
	const problems = [];
	let drawings = 0;
	for (const [svg, tag] of html.matchAll(/(<svg\b[^>]*>)[\s\S]*?<\/svg>/g)) {
		const titles = [
			...svg.matchAll(/<(?:rect|path|circle|line|g)\b[^>]*><title>([\s\S]*?)<\/title>/g)
		];
		if (!titles.length) continue;
		drawings++;
		const target = /\bdata-keyboard-equivalent="#([a-z0-9_-]+)"/.exec(tag)?.[1];
		if (!target) {
			problems.push(`${name}: a drawing with hover titles names no keyboard equivalent`);
			continue;
		}
		const disclosure = new RegExp(
			`<details class="theme-chart-values"><summary id="${target}" data-i18n="common\\.chart_values">[^<]+</summary><ul>([\\s\\S]*?)</ul></details>`
		).exec(html);
		if (!disclosure) {
			problems.push(`${name}: #${target} is not a named disclosure beside the drawing`);
			continue;
		}
		const items = [...disclosure[1].matchAll(/<li>([\s\S]*?)<\/li>/g)].map((m) => unescape(m[1]));
		const words = titles.map((m) => unescape(m[1]));
		for (const word of words)
			if (!items.includes(word)) problems.push(`${name}: « ${word} » is in a hover title only`);
	}
	return { drawings, problems };
}

test('typing calendar and hour heatmap give every value to the keyboard (met-16)', () => {
	const page = loadMetricsTypingPage('macos');
	page.context._i18n_strings = { 'common.chart_values': 'Chart values' };
	publishTyping(
		page,
		'macos',
		{
			'2026-09-05': { Editor: { chars: 120, hourly: { '09': { c: 120 } } } },
			'2026-09-07': { Editor: { chars: 40, hourly: { 14: { c: 40 } } } }
		},
		{ historical: {}, today: {} }
	);
	let drawings = 0;
	for (const id of ['activity_calendar_container', 'hour_weekday_heatmap_container']) {
		const result = drawingProblems(id, page.elements.get(id).innerHTML);
		assert.deepEqual(result.problems, []);
		drawings += result.drawings;
	}
	assert.equal(drawings, 2, 'both drawings rendered with their hover titles');
	assert.match(
		page.elements.get('activity_calendar_container').innerHTML,
		/<li>[^<]+ — 120 /,
		'a typed day reads its count'
	);
});

test('apps drawings give every value to the keyboard (met-16)', () => {
	const page = loadMetricsAppsPage('macos');
	const { context } = page;
	// Every node of the page but its canvases: Chart.js drawing stays a browser port.
	for (const [, tag, id] of page.html.matchAll(/<([a-z][a-z0-9]*)\b[^>]*\bid="([^"]+)"/g))
		if (tag !== 'canvas' && !page.elements.has(id))
			page.elements.set(id, context.document.createElement(tag));
	context._i18n_strings = { ...context._i18n_strings, 'common.chart_values': 'Chart values' };
	const day = (date, shift) => ({
		Code: {
			category: 'Travail',
			app_time_ms: 3600000 + shift,
			time: 1200000,
			chars: 900 + shift,
			session_count_total: 3,
			session_durations: [600000, 1500000, 2400000],
			switches_to: { Firefox: 4 },
			hourly: { '09': { c: 300, time_ms: 1200000 }, 14: { c: 600, time_ms: 2400000 } }
		},
		Firefox: {
			category: 'Navigation',
			app_time_ms: 1800000,
			time: 300000,
			chars: 200,
			session_count_total: 2,
			session_durations: [300000, 900000],
			switches_to: { Code: 3 },
			hourly: { 10: { c: 200, time_ms: 1800000 } }
		}
	});
	vm.runInContext(
		'manifestData = ' +
			JSON.stringify({
				'2026-11-19': day('2026-11-19', 0),
				'2026-11-20': day('2026-11-20', 60000)
			}),
		context
	);
	context.renderDashboard();
	assert.equal(context.document.getElementById('render-error-banner'), null, 'the render succeeds');
	let drawings = 0;
	const problems = [];
	for (const [id, node] of page.elements) {
		const result = drawingProblems(id, node.innerHTML || '');
		drawings += result.drawings;
		problems.push(...result.problems);
	}
	assert.deepEqual(problems, []);
	assert.ok(drawings >= 4, `the drawings rendered with their hover titles (${drawings})`);
});

if (failed) {
	console.error(`metrics view states: ${failed} failure(s), ${passed} passed.`);
	process.exit(1);
}
console.log(`metrics view states: ${passed} passed.`);
