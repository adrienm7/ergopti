/**
 * tools/test/test-typing-metrics-reset-transaction.cjs
 * ==============================================================================
 * MODULE: Typing Metrics Reset Delivery
 * DESCRIPTION:
 * Verifies Reset priority and real purge acknowledgement before selected-range delivery.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const vm = require('node:vm');
const { frontend, actualPurge } = require('./support/typing-reset-fixture.cjs');
let passed = 0;
let failed = 0;

function test(name, callback) {
	try { callback(); passed++; console.log(`ok ${name}`); }
	catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`); }
}

const payload = { historical: { c: { old: { c: 9 } } }, today: {} };

for (const host of ['macos', 'windows', 'linux']) {
	for (const prefetch of [false, true]) {
		test(`${host}: first manifest initializes without purging, prefetch=${prefetch}`, () => {
			const f = frontend(host);
			if (prefetch) f.context._prefetch_data = payload;
			f.context.process_manifest();
			assert.equal(f.requests.filter((req) => req.action === 'clear_cache').length, 0);
			assert.notEqual(JSON.parse(f.context._lua_request || 'null')?.action, 'clear_cache');
			f.dispatch();
			assert.equal(f.renders.length, prefetch ? 1 : 0);
			if (prefetch) assert.equal(f.state.active_range_request_id, 0);
		});
	}
}

test('Reset remains ahead of the latest filter request (reset-delivery)', () => {
	const f = frontend();
	f.context.reset_filters();
	const clear = f.context._lua_request;
	f.select('2026-09-02'); f.select('2026-09-03'); f.dispatch();
	assert.equal(f.context._lua_request, clear);
	const reset = JSON.parse(clear);
	assert.ok(reset.reset_id > 0);
	assert.equal(f.context.complete_cache_reset(reset.reset_id, true), true);
	const range = JSON.parse(f.context._lua_request);
	assert.equal(range.start_date, '2026-09-03');
	assert.equal(range.request_id, f.state.active_range_request_id);
});

test('CAS consumption is not purge completion', () => {
	const f = frontend(); f.context.reset_filters();
	const reset = JSON.parse(f.context._lua_request);
	f.context._lua_request = null;
	f.select('2026-09-04'); f.dispatch();
	assert.equal(f.context._lua_request, null);
	f.context.complete_cache_reset(reset.reset_id, true);
	assert.equal(JSON.parse(f.context._lua_request).start_date, '2026-09-04');
});

test('new Reset fences old completion and old range responses', () => {
	const f = frontend(); f.context.reset_filters(); f.dispatch();
	const first = JSON.parse(f.context._lua_request);
	const oldRange = f.state.active_range_request_id;
	f.context.reset_filters(); f.dispatch();
	const latest = f.context._lua_request;
	assert.equal(f.context.complete_cache_reset(first.reset_id, true), false);
	assert.equal(f.context._lua_request, latest);
	assert.equal(f.context.receive_range_data(payload, oldRange), false);
	assert.equal(f.renders.length, 0);
	assert.equal(f.context.complete_cache_reset(JSON.parse(latest).reset_id, true), true);
});

test('purge failure restores last-good table and sends no pending range', () => {
	const f = frontend(); f.context.reset_filters(); f.dispatch();
	const reset = JSON.parse(f.context._lua_request);
	assert.equal(f.context.complete_cache_reset(reset.reset_id, false), true);
	assert.equal(f.state.loading_data, false);
	assert.equal(f.elements.metrics_table_body.innerHTML, 'last-good');
	assert.equal(f.context._lua_request, null);
	f.dispatch();
	assert.equal(f.context._lua_request, null);
});

test('lost purge completion has a finite owner-safe watchdog', () => {
	const f = frontend(); f.context.reset_filters();
	const oldWatchdog = f.timers.get(f.state.cache_reset_watchdog).fn;
	f.context.reset_filters();
	const latest = f.state.active_cache_reset_id;
	oldWatchdog();
	assert.equal(f.state.active_cache_reset_id, latest);
	f.timers.get(f.state.cache_reset_watchdog).fn();
	assert.equal(f.state.active_cache_reset_id, 0);
	assert.equal(f.state.loading_data, false);
	f.dispatch();
	assert.equal(f.context._lua_request, null);
});

test('first manifest prefetch cannot complete an explicit Reset', () => {
	const f = frontend(); f.context.reset_filters();
	const clear = f.context._lua_request;
	f.context._prefetch_data = payload;
	f.context.process_manifest(); f.dispatch();
	assert.equal(f.context._lua_request, clear);
	assert.equal(f.renders.length, 0);
	assert.equal(f.state.loading_data, true);
});

for (const host of ['windows', 'linux']) {
	test(`${host}: explicit Reset uses direct clear then range messages`, () => {
		const f = frontend(host); f.context.reset_filters(); f.dispatch();
		assert.deepEqual(f.requests.map((req) => req.action), ['clear_cache', 'range']);
		assert.equal(f.context._lua_request, null);
	});
}

for (const success of [true, false]) {
	test(`actual Lua purge completion controls latest frontend range, success=${success}`, () => {
		const f = frontend(); f.context.reset_filters();
		const clear = f.context._lua_request;
		const native = actualPurge(clear, success);
		assert.equal(native.removes, 1);
		assert.equal(vm.runInContext(native.ack, f.context), true);
		f.select('2026-09-04'); f.dispatch();
		assert.equal(f.context._lua_request, null);
		vm.runInContext(native.terminal, f.context);
		if (success) {
			assert.equal(JSON.parse(f.context._lua_request).start_date, '2026-09-04');
			assert.equal(f.state.loading_data, true);
		} else {
			assert.equal(f.context._lua_request, null);
			assert.equal(f.state.loading_data, false);
			assert.equal(f.elements.metrics_table_body.innerHTML, 'last-good');
			assert.equal(native.errors, 1);
		}
	});
}

test('acknowledgement before deferred dispatch releases exactly one request', () => {
	const f = frontend(); f.context.reset_filters();
	const reset = JSON.parse(f.context._lua_request);
	f.context.complete_cache_reset(reset.reset_id, true);
	assert.equal(f.context._lua_request, null);
	f.dispatch();
	const range = f.context._lua_request;
	assert.equal(JSON.parse(range).request_id, 1);
	assert.equal(f.context.complete_cache_reset(reset.reset_id, true), false);
	assert.equal(f.context._lua_request, range);
});

test('expired Reset can be retried without reviving its old pending range', () => {
	const f = frontend(); f.context.reset_filters(); f.dispatch();
	const old = JSON.parse(f.context._lua_request);
	f.timers.get(f.state.cache_reset_watchdog).fn();
	f.context.reset_filters(); f.dispatch();
	const latest = f.context._lua_request;
	assert.equal(f.context.complete_cache_reset(old.reset_id, true), false);
	assert.equal(f.context._lua_request, latest);
	assert.equal(f.context.complete_cache_reset(JSON.parse(latest).reset_id, true), true);
	assert.equal(JSON.parse(f.context._lua_request).request_id, 2);
});

console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
