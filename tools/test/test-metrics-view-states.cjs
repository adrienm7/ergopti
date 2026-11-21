// tools/test/test-metrics-view-states.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Dashboard View States (MET-13, MET-14)
 * DESCRIPTION:
 * Runs the real dashboard pages, every script their HTML declares, in a
 * sandbox and reads what the user is left with:
 * - an empty range or app selection: each typing card said « Computing… »
 *   for good once the read had landed (MET-13);
 * - a render error on the apps page: its alert stayed after the next good
 *   render and printed the stack (MET-14).
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

if (failed) {
	console.error(`metrics view states: ${failed} failure(s), ${passed} passed.`);
	process.exit(1);
}
console.log(`metrics view states: ${passed} passed.`);
