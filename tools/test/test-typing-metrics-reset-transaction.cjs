/**
 * tools/test/test-typing-metrics-reset-transaction.cjs
 * ==============================================================================
 * MODULE: Typing Metrics Reset Delivery
 * DESCRIPTION:
 * Verifies Reset priority and real purge acknowledgement before selected-range delivery.
 * Windows and Linux sent their Reset without an id and never heard its outcome:
 * a failed purge was told to nobody (MET-19). Every host now answers the id.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { frontend, bootstrapFrontend, actualPurge } = require('./support/typing-reset-fixture.cjs');
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

const payload = { historical: { c: { old: { c: 9 } } }, today: {} };

for (const host of ['linux', 'windows']) {
	const manifest = {
		'2026-09-01': { Editor: { chars: 9 } },
		'2026-09-03': { Editor: { chars: 3 } }
	};
	const blob = (history = 'initial') => ({
		metrics_manifest: manifest,
		_prefetch_data: { historical: { c: { [history]: { c: 3 } } }, today: {} }
	});
	test(`${host}: idle first paint retains defaults and consumes prefetch without another round trip`, () => {
		const f = bootstrapFrontend(host);
		f.push(blob());
		assert.equal(f.context.get_source_mode_flags().show_hs, true);
		assert.equal(f.context.get_source_mode_flags().show_llm, true);
		assert.equal(f.elements.btn_case_sensitive.classList.contains('active'), true);
		assert.equal(f.elements.pause_threshold.value, '5000');
		assert.equal(f.elements.date_start.value, '2026-09-01');
		assert.equal(f.elements.date_end.value, '2026-09-07');
		assert.equal(f.state.app_selection_mode, 'all');
		assert.equal(f.state.active_range_request_id, 0);
		assert.equal(f.state.historical_cache.c.initial.c, 3);
		f.dispatch();
		assert.equal(f.requests.filter((request) => request.action === 'range').length, 0);
	});
	test(`${host}: first tagged reply retains the user's original date and request owner`, () => {
		const f = bootstrapFrontend(host);
		f.select('2026-09-03');
		f.dispatch();
		const original = f.requests.find((request) => request.action === 'range');
		f.push(blob()); // The untagged initial ready cannot displace the user's query.
		assert.equal(f.state.active_range_request_id, original.request_id);
		f.push({ ...blob('selected'), range_request_id: original.request_id });
		assert.equal(f.elements.date_start.value, '2026-09-03');
		assert.equal(f.elements.date_end.value, '2026-09-03');
		assert.equal(f.state.range_request_sequence, original.request_id);
		assert.equal(f.state.active_range_request_id, 0);
		assert.equal(f.state.historical_cache.c.selected.c, 3);
		f.dispatch();
		assert.equal(f.requests.filter((request) => request.action === 'range').length, 1);
	});
	for (const edited of ['start', 'end', 'both']) {
		test(`${host}: pre-blur ${edited} date edits retain each bound and require their own projection`, () => {
			const f = bootstrapFrontend(host);
			// Native date inputs need not dispatch change until blur. Verify the actual
			// HTML seam, then leave its handler undispatched while editing the DOM.
			assert.equal(
				f.dateChangeHandler('date_start'),
				'app_state.hour_window = null; apply_date_app_filters()'
			);
			assert.equal(
				f.dateChangeHandler('date_end'),
				'app_state.hour_window = null; apply_date_app_filters()'
			);
			if (edited !== 'end') f.elements.date_start.value = '2026-09-02';
			if (edited !== 'start') f.elements.date_end.value = '2026-09-04';
			assert.equal(f.state.range_request_sequence, 0);
			f.push(blob());
			assert.equal(f.elements.date_start.value, edited === 'end' ? '2026-09-01' : '2026-09-02');
			assert.equal(f.elements.date_end.value, edited === 'start' ? '2026-09-07' : '2026-09-04');
			assert.ok(
				f.state.active_range_request_id > 0,
				'default history must not ACK the edited range'
			);
			assert.equal(f.state.historical_cache, null);
			f.dispatch();
			const ranges = f.requests.filter((request) => request.action === 'range');
			assert.equal(ranges.length, 1);
			assert.equal(ranges[0].start_date, f.elements.date_start.value);
			assert.equal(ranges[0].end_date, f.elements.date_end.value);
			f.push({ ...blob('edited'), range_request_id: ranges[0].request_id });
			assert.equal(f.state.active_range_request_id, 0);
			assert.equal(f.state.historical_cache.c.edited.c, 3);
		});
	}
	for (const [id, action] of [
		['btn_toggle_hs', 'toggle_hs_source'],
		['btn_toggle_llm', 'toggle_llm_source'],
		['btn_case_sensitive', 'toggle_filter'],
		['pause_threshold', 'pause']
	])
		test(`${host}: ${id} intent before ready survives initialization`, () => {
			const f = bootstrapFrontend(host);
			if (action === 'pause') f.changePause('1000');
			else {
				// Exercise the real handler even if the old document starts inactive.
				f.context[action](id);
				if (f.elements[id].classList.contains('active')) f.context[action](id);
			}
			f.push(blob());
			if (action === 'pause') assert.equal(f.elements.pause_threshold.value, '1000');
			else assert.equal(f.elements[id].classList.contains('active'), false);
			assert.equal(
				f.state.active_range_request_id,
				0,
				'local-only filter keeps default prefetch fast path'
			);
			assert.equal(f.state.historical_cache.c.initial.c, 3);
			f.dispatch();
			assert.equal(f.requests.filter((value) => value.action === 'range').length, 0);
		});
	for (const selection of ['none', 'subset', 'all']) {
		test(`${host}: app modal ${selection} intent before ready is preserved before close`, () => {
			const f = bootstrapFrontend(host);
			f.state.available_apps.push('Browser');
			f.state.selected_apps = new Set(['Browser', 'Editor']);
			f.state.app_selection_mode = 'all';
			if (selection === 'all') f.context.select_all_apps();
			if (selection === 'none') f.context.deselect_all_apps();
			if (selection === 'subset')
				f.context.toggle_app_selection({ value: 'Browser', checked: false });
			const expected = [...f.state.selected_apps];
			f.push({ ...blob(), metrics_manifest: { '2026-09-01': { Editor: {}, Browser: {} } } });
			assert.deepEqual([...f.state.selected_apps].sort(), expected.sort());
			if (selection === 'all') assert.equal(f.state.active_range_request_id, 0);
			else {
				assert.ok(
					f.state.active_range_request_id > 0,
					'modal subset is not ACKed by default prefetch'
				);
				assert.equal(f.state.historical_cache, null);
			}
			f.context.close_app_modal();
			f.dispatch();
			const ranges = f.requests.filter((request) => request.action === 'range');
			assert.equal(ranges.length, 1);
			assert.deepEqual([...ranges[0].apps].sort(), expected.sort());
			f.push({ ...blob('own'), range_request_id: ranges[0].request_id });
			assert.equal(f.state.active_range_request_id, 0);
			assert.equal(f.state.historical_cache.c.own.c, 3);
		});
	}
	test(`${host}: first manifest expanding ALL cannot retag history or seed a rejected cache`, () => {
		const f = bootstrapFrontend(host);
		f.state.app_selection_mode = 'all';
		f.select('2026-09-03');
		f.dispatch();
		const original = f.requests.find((request) => request.action === 'range');
		const expanded = { '2026-09-03': { Editor: {}, Browser: {} } };
		f.push({
			...blob('wrongScope'),
			metrics_manifest: expanded,
			range_request_id: original.request_id
		});
		const latest = f.state.active_range_request_id;
		assert.ok(latest > original.request_id, 'discovered app needs a fresh scope');
		assert.equal(f.state.historical_cache, null);
		f.dispatch();
		const requests = f.requests.filter((request) => request.action === 'range');
		assert.equal(requests.length, 2);
		assert.deepEqual([...requests[1].apps].sort(), ['Browser', 'Editor']);
		// A real terminal permits later live deltas; rejected history must stay absent.
		assert.equal(f.context.complete_range_request(latest, 'failed'), true);
		f.push({ metrics_manifest: expanded, _prefetch_data: { today: {} } });
		assert.deepEqual(Object.keys(f.state.historical_cache), []);
	});
}

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
	f.select('2026-09-02');
	f.select('2026-09-03');
	f.dispatch();
	assert.equal(f.context._lua_request, clear);
	const reset = JSON.parse(clear);
	assert.ok(reset.reset_id > 0);
	assert.equal(f.context.complete_cache_reset(reset.reset_id, true), true);
	const range = JSON.parse(f.context._lua_request);
	assert.equal(range.start_date, '2026-09-03');
	assert.equal(range.request_id, f.state.active_range_request_id);
});

test('CAS consumption is not purge completion', () => {
	const f = frontend();
	f.context.reset_filters();
	const reset = JSON.parse(f.context._lua_request);
	f.context._lua_request = null;
	f.select('2026-09-04');
	f.dispatch();
	assert.equal(f.context._lua_request, null);
	f.context.complete_cache_reset(reset.reset_id, true);
	assert.equal(JSON.parse(f.context._lua_request).start_date, '2026-09-04');
});

test('new Reset fences old completion and old range responses', () => {
	const f = frontend();
	f.context.reset_filters();
	f.dispatch();
	const first = JSON.parse(f.context._lua_request);
	const oldRange = f.state.active_range_request_id;
	f.context.reset_filters();
	f.dispatch();
	const latest = f.context._lua_request;
	assert.equal(f.context.complete_cache_reset(first.reset_id, true), false);
	assert.equal(f.context._lua_request, latest);
	assert.equal(f.context.receive_range_data(payload, oldRange), false);
	assert.equal(f.renders.length, 0);
	assert.equal(f.context.complete_cache_reset(JSON.parse(latest).reset_id, true), true);
});

test('purge failure restores last-good table and sends no pending range', () => {
	const f = frontend();
	f.context.reset_filters();
	f.dispatch();
	const reset = JSON.parse(f.context._lua_request);
	assert.equal(f.context.complete_cache_reset(reset.reset_id, false), true);
	assert.equal(f.state.loading_data, false);
	assert.equal(f.elements.metrics_table_body.innerHTML, 'last-good');
	assert.equal(f.context._lua_request, null);
	f.dispatch();
	assert.equal(f.context._lua_request, null);
});

test('lost purge completion has a finite owner-safe watchdog', () => {
	const f = frontend();
	f.context.reset_filters();
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
	const f = frontend();
	f.context.reset_filters();
	const clear = f.context._lua_request;
	f.context._prefetch_data = payload;
	f.context.process_manifest();
	f.dispatch();
	assert.equal(f.context._lua_request, clear);
	assert.equal(f.renders.length, 0);
	assert.equal(f.state.loading_data, true);
});

const EN = JSON.parse(
	fs.readFileSync(
		path.resolve(__dirname, '../../static/ergopti_plus/_shared/core/i18n/data/locales/en.json'),
		'utf8'
	)
);

/** The range status line the page writes its outcomes into, in English. */
function withStatus(f) {
	f.elements.range_status = { textContent: '' };
	f.context._i18n_strings = EN;
	return f.elements.range_status;
}

for (const host of ['windows', 'linux']) {
	test(`${host}: explicit Reset names its id and holds the range until its outcome (met-19)`, () => {
		const f = frontend(host);
		f.context.reset_filters();
		f.dispatch();
		assert.deepEqual(
			f.requests.map((req) => req.action),
			['clear_cache'],
			'the range waits for the Reset'
		);
		assert.equal(f.context._lua_request, null);
		const reset_id = f.requests[0].reset_id;
		assert.ok(Number.isSafeInteger(reset_id) && reset_id > 0, 'the host can answer this Reset');
		assert.equal(f.context.complete_cache_reset(reset_id, true), true);
		assert.deepEqual(
			f.requests.map((req) => req.action),
			['clear_cache', 'range']
		);
	});
	test(`${host}: an unreachable host fails the Reset at once (met-19)`, () => {
		const f = frontend(host);
		const status = withStatus(f);
		if (host === 'windows')
			f.context.chrome.webview.postMessage = () => {
				throw new Error('gone');
			};
		else
			f.context.webkit.messageHandlers.metrics_typing_bridge.postMessage = () => {
				throw new Error('gone');
			};
		const errors = [];
		f.context.console = { ...console, error: (...args) => errors.push(args.join(' ')) };
		f.context.reset_filters();
		// The failure lands once reset_filters has asked for its range.
		for (const [id, timer] of Array.from(f.timers))
			if (timer.delay === 0) {
				f.timers.delete(id);
				timer.fn();
			}
		f.dispatch();
		assert.equal(f.state.active_cache_reset_id, 0, 'no Reset is left waiting for its watchdog');
		assert.equal(f.state.loading_data, false, 'its range fails with it');
		assert.deepEqual(
			f.requests.filter((req) => req.action === 'range'),
			[],
			'and is not sent'
		);
		assert.equal(status.textContent, EN['ui_typing.reset_failed']);
		assert.equal(errors.length, 1, 'the failure is logged');
	});
}

for (const host of ['macos', 'windows', 'linux']) {
	test(`${host}: a failed Reset tells the page in its language (met-19)`, () => {
		const f = frontend(host);
		const status = withStatus(f);
		f.context.reset_filters();
		f.dispatch();
		const reset_id = f.state.active_cache_reset_id;
		assert.ok(reset_id > 0);
		assert.equal(f.context.complete_cache_reset(reset_id, false), true);
		assert.equal(status.textContent, EN['ui_typing.reset_failed']);
		assert.notEqual(status.textContent, 'ui_typing.reset_failed', 'the key exists');
		assert.equal(f.state.loading_data, false);
	});
}

test('windows: the host answer of a Reset reaches the page (met-19)', () => {
	const f = bootstrapFrontend('windows');
	const status = withStatus(f);
	f.context.reset_filters();
	const reset_id = f.state.active_cache_reset_id;
	f.hostMessage({ type: 'cache_reset', reset_id, ok: false });
	assert.equal(f.state.active_cache_reset_id, 0);
	assert.equal(status.textContent, EN['ui_typing.reset_failed']);
});

test('linux: a Reset reply settles the Reset before its payload (met-19)', () => {
	const f = bootstrapFrontend('linux');
	const status = withStatus(f);
	f.push({ metrics_manifest: {}, _prefetch_data: payload });
	f.context.reset_filters();
	f.dispatch();
	const reset_id = f.state.active_cache_reset_id;
	f.push({ metrics_manifest: {}, reset_id, cleared: false, _prefetch_data: payload });
	assert.equal(f.state.active_cache_reset_id, 0);
	assert.equal(status.textContent, EN['ui_typing.reset_failed']);
});

for (const success of [true, false]) {
	test(`actual Lua purge completion controls latest frontend range, success=${success}`, () => {
		const f = frontend();
		f.context.reset_filters();
		const clear = f.context._lua_request;
		const native = actualPurge(clear, success);
		assert.equal(native.removes, 2, 'the snapshot and any partial save are unlinked');
		assert.equal(vm.runInContext(native.ack, f.context), true);
		f.select('2026-09-04');
		f.dispatch();
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
	const f = frontend();
	f.context.reset_filters();
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
	const f = frontend();
	f.context.reset_filters();
	f.dispatch();
	const old = JSON.parse(f.context._lua_request);
	f.timers.get(f.state.cache_reset_watchdog).fn();
	f.context.reset_filters();
	f.dispatch();
	const latest = f.context._lua_request;
	assert.equal(f.context.complete_cache_reset(old.reset_id, true), false);
	assert.equal(f.context._lua_request, latest);
	assert.equal(f.context.complete_cache_reset(JSON.parse(latest).reset_id, true), true);
	assert.equal(JSON.parse(f.context._lua_request).request_id, 2);
});

console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
