/**
 * MODULE: Typing Prefetch History Cases
 * DESCRIPTION: Exercise the real page bootstrap through both push bridges.
 */
'use strict';

const assert = require('node:assert/strict');
const vm = require('node:vm');

module.exports = function checkPrefetchHistory(html) {
	const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
		.map(match => match[1]).filter(source => source.includes('let cached_historical'));
	assert.equal(scripts.length, 1, 'exactly one actual prefetch bootstrap must run');
	for (const host of ['windows', 'linux']) {
		let listener;
		const received = [];
		const errors = [];
		const context = vm.createContext({
			console: { log() {}, error(...args) { errors.push(args); } },
			process_manifest() {}, apply_local_filters() {},
			receive_range_data(value) { received.push(JSON.parse(JSON.stringify(value))); },
			createVisibilityPoller() {},
			decodeHostBridgeResponse(base64, payload) {
				assert.equal(base64, false);
				return JSON.parse(payload);
			}
		});
		context.window = context;
		if (host === 'windows') {
			context.chrome = { webview: {
				addEventListener(type, callback) { assert.equal(type, 'message'); listener = callback; },
				postMessage() {}
			} };
		} else {
			context.__ergopti_host = 'linux';
			context.webkit = { messageHandlers: { metrics_typing_bridge: { postMessage() {} } } };
		}
		vm.runInContext(scripts[0], context);
		const push = blob => {
			if (host === 'windows') listener({ data: JSON.stringify({ type: 'prefetch', blob }) });
			else context.__hostBridgeResponse('metrics_typing_bridge', false, JSON.stringify(blob));
			assert.equal(errors.length, 0, `${host}: bootstrap must not swallow a fixture error`);
		};
		const history = { c: { a: { c: 7 } } };
		push({ metrics_manifest: {}, _prefetch_data: { historical: history, today: {} } });
		assert.deepEqual(received.at(-1).historical, history, `${host}: full payload must seed history`);
		push({ metrics_manifest: {}, _prefetch_data: { today: { editor: { c: {} } } } });
		assert.deepEqual(received.at(-1).historical, history, `${host}: absent history must preserve the snapshot`);
		push({ metrics_manifest: {} });
		assert.equal(received.length, 2, `${host}: manifest-only push must not replace range data`);
		push({ metrics_manifest: {}, _prefetch_data: { historical: {}, today: {} } });
		assert.deepEqual(received.at(-1).historical, {}, `${host}: explicit empty history must clear old counts`);
		push({ metrics_manifest: {}, _prefetch_data: { today: {} } });
		assert.deepEqual(received.at(-1).historical, {}, `${host}: later live push must not resurrect old counts`);
	}
};
