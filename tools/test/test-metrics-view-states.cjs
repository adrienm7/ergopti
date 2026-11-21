// tools/test/test-metrics-view-states.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Dashboard View States (MET-14)
 * DESCRIPTION:
 * Runs the real dashboard pages, every script their HTML declares, in a
 * sandbox and reads what the user is left with after a render error on the
 * apps page: its alert stayed after the next good render and printed the
 * stack (MET-14).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const vm = require('node:vm');
const { loadMetricsAppsPage } = require('./support/metrics-apps-page.cjs');

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
