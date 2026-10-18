/**
 * MODULE: Typing Prefetch History Cases
 * DESCRIPTION: Exercise the real page bootstrap through both push bridges.
 */
'use strict';

const assert = require('node:assert/strict');
const vm = require('node:vm');

module.exports = function checkPrefetchHistory(html, data) {
	const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
		.map((match) => match[1])
		.filter((source) => source.includes('let cached_historical'));
	assert.equal(scripts.length, 1, 'exactly one actual prefetch bootstrap must run');
	for (const host of ['windows', 'linux']) {
		let listener;
		const received = [];
		const errors = [];
		const context = vm.createContext({
			app_state: { active_range_request_id: 0, range_request_watchdog: null },
			clearTimeout() {},
			location: { search: '' },
			URLSearchParams,
			console: {
				log() {},
				error(...args) {
					errors.push(args);
				}
			},
			process_manifest() {},
			apply_local_filters() {},
			createVisibilityPoller() {},
			decodeHostBridgeResponse(base64, payload) {
				assert.equal(base64, false);
				return JSON.parse(payload);
			}
		});
		context.window = context;
		vm.runInContext(data, context);
		context.process_manifest = () => {};
		context.apply_local_filters = () => {};
		const receive = context.receive_range_data;
		context.receive_range_data = (value, request) => {
			const accepted = receive(value, request);
			if (accepted) received.push(JSON.parse(JSON.stringify(value)));
			return accepted;
		};
		if (host === 'windows') {
			context.chrome = {
				webview: {
					addEventListener(type, callback) {
						assert.equal(type, 'message');
						listener = callback;
					},
					postMessage() {}
				}
			};
		} else {
			context.__ergopti_host = 'linux';
			context.webkit = { messageHandlers: { metrics_typing_bridge: { postMessage() {} } } };
		}
		vm.runInContext(scripts[0], context);
		const push = (blob) => {
			if (host === 'windows') listener({ data: JSON.stringify({ type: 'prefetch', blob }) });
			else context.__hostBridgeResponse('metrics_typing_bridge', false, JSON.stringify(blob));
			assert.equal(errors.length, 0, `${host}: bootstrap must not swallow a fixture error`);
		};
		const history = { c: { a: { c: 7 } } };
		push({ metrics_manifest: {}, _prefetch_data: { historical: history, today: {} } });
		assert.deepEqual(
			received.at(-1).historical,
			history,
			`${host}: full payload must seed history`
		);
		push({ metrics_manifest: {}, _prefetch_data: { today: { editor: { c: {} } } } });
		assert.deepEqual(
			received.at(-1).historical,
			history,
			`${host}: absent history must preserve the snapshot`
		);
		push({ metrics_manifest: {} });
		assert.equal(received.length, 2, `${host}: manifest-only push must not replace range data`);
		push({ metrics_manifest: {}, _prefetch_data: { historical: {}, today: {} } });
		assert.deepEqual(
			received.at(-1).historical,
			{},
			`${host}: explicit empty history must clear old counts`
		);
		push({ metrics_manifest: {}, _prefetch_data: { today: {} } });
		assert.deepEqual(
			received.at(-1).historical,
			{},
			`${host}: later live push must not resurrect old counts`
		);
		const state = context.app_state;
		const historyFor = (name, count) => ({ c: { [name]: { c: count } } });
		const snapshot = (name, count, request) => ({
			metrics_manifest: { [name]: { chars: count } },
			app_icons: { [name]: 'icon' },
			driver_meta: { os: host === 'windows' ? 'win' : 'linux', receipt: name },
			keycode_layout: { 1: name },
			range_request_id: request,
			_prefetch_data: { historical: historyFor(name, count), today: {} }
		});
		const visible = () =>
			JSON.parse(
				JSON.stringify({
					manifest: context.metrics_manifest,
					icons: context.app_icons,
					driver: context.driver_meta,
					layout: context.keycode_layout,
					prefetch: context._prefetch_data,
					historical: state.historical_cache
				})
			);
		state.active_range_request_id = 2;
		state.loading_data = true;
		push(snapshot('current', 2, 2));
		assert.equal(
			state.active_range_request_id,
			0,
			`${host}: current response must ACK its request`
		);
		const accepted = visible();
		context._lua_request = 'retained mailbox';
		push(snapshot('stale', 99, 1));
		assert.deepEqual(
			visible(),
			accepted,
			`${host}: rejected response must not mutate metadata or prefetch caches`
		);
		assert.equal(
			context._lua_request,
			'retained mailbox',
			`${host}: rejected response must not clear another mailbox`
		);
		push({ metrics_manifest: {}, _prefetch_data: { today: {} } });
		assert.deepEqual(
			received.at(-1).historical,
			historyFor('current', 2),
			`${host}: a live delta cannot resurrect rejected history`
		);

		state.active_range_request_id = 3;
		state.loading_data = true;
		const pending = visible();
		push(snapshot('superseded', 88, 2));
		push(snapshot('untagged-during-range', 77));
		for (const id of ['3', 0, -1, 3.5]) push(snapshot('invalid', 66, id));
		assert.equal(
			state.active_range_request_id,
			3,
			`${host}: only the exact current response can release the loader`
		);
		assert.deepEqual(
			visible(),
			pending,
			`${host}: pending ownership protects metadata and history from all rejected replies`
		);
		push(snapshot('replacement', 3, 3));
		assert.equal(state.active_range_request_id, 0);
		const replacement = visible();
		push(snapshot('duplicate', 55, 3));
		assert.deepEqual(
			visible(),
			replacement,
			`${host}: a duplicate terminal cannot rewrite the accepted snapshot`
		);
		push({ metrics_manifest: {}, _prefetch_data: { today: {} } });
		assert.deepEqual(received.at(-1).historical, historyFor('replacement', 3));

		state.active_cache_reset_id = 9;
		state.active_range_request_id = 4;
		const reset = visible();
		push(snapshot('blocked-by-reset', 44, 4));
		assert.deepEqual(
			visible(),
			reset,
			`${host}: reset ownership must also protect the bootstrap cache`
		);
		assert.equal(state.active_range_request_id, 4);
		state.active_cache_reset_id = 0;
		push(snapshot('after-reset', 4, 4));
		assert.equal(state.active_range_request_id, 0);
		assert.deepEqual(received.at(-1).historical, historyFor('after-reset', 4));
		console.log(`Typing prefetch ${host}: current/stale/live/metadata/reset ownership passed`);
	}
};
