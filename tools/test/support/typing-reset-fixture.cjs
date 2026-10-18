/**
 * tools/test/support/typing-reset-fixture.cjs
 * ==============================================================================
 * MODULE: Typing Reset Frontend Fixture
 * DESCRIPTION:
 * Loads real dashboard state, filters and delivery with deterministic native timers.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../../../static/ergopti_plus/_shared/ui/metrics_typing');

function frontend(host = 'macos') {
	const timers = new Map();
	let nextTimer = 0;
	const requests = [];
	const renders = [];
	const element = () => ({
		value: '',
		innerHTML: 'last-good',
		classList: { add() {}, toggle() {}, contains: () => true }
	});
	const elements = Object.fromEntries(
		[
			'date_start',
			'date_end',
			'metrics_table_body',
			'btn_case_sensitive',
			'pause_threshold',
			'quick_range'
		].map((id) => [id, element()])
	);
	const context = vm.createContext({
		console,
		document: { getElementById: (id) => elements[id] || null, addEventListener() {} },
		addEventListener() {},
		setTimeout(fn, delay) {
			const id = ++nextTimer;
			timers.set(id, { fn, delay });
			return id;
		},
		clearTimeout(id) {
			timers.delete(id);
		}
	});
	context.window = context;
	if (host === 'windows')
		context.chrome = { webview: { postMessage: (raw) => requests.push(JSON.parse(raw)) } };
	if (host === 'linux') {
		context.__ergopti_host = host;
		context.webkit = {
			messageHandlers: { metrics_typing_bridge: { postMessage: (req) => requests.push(req) } }
		};
	}
	for (const file of ['_generated/keycode_data.js', 'state.js', 'data.js', 'filters.js']) {
		vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context);
	}
	const state = vm.runInContext('app_state', context);
	const sourceFlags = context.get_source_mode_flags;
	context.compute_manifest_metrics = () => {};
	context.update_app_btn_text = () => {};
	context.get_local_date_string = () => '2026-09-07';
	context.get_source_mode_flags = () => ({ show_manual: true, show_hs: false, show_llm: false });
	for (const key of Object.keys(context)) {
		if (/^render_.*_kpi$/.test(key) || key === 'recompute_speed_kpi') context[key] = () => {};
	}
	context.render_current_tab = () => renders.push(Object.keys(state.data.c));
	context.metrics_manifest = { '2026-09-01': { Editor: { chars: 9 } } };
	state.available_apps = ['Editor'];
	function dispatch() {
		for (const [id, timer] of Array.from(timers)) {
			if (timer.delay === 50) {
				timers.delete(id);
				timer.fn();
			}
		}
	}
	function select(date) {
		elements.date_start.value = elements.date_end.value = date;
		context.apply_date_app_filters();
	}
	return { context, state, requests, timers, elements, renders, dispatch, select, sourceFlags };
}

// Real first-paint pipeline; only the DOM, timer and native transport are ports.
function bootstrapFrontend(host) {
	const f = frontend(host);
	const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
	for (const id of [
		'btn_toggle_hs',
		'btn_toggle_llm',
		'app_modal',
		'app_list',
		'app_search',
		'app_filter_btn'
	]) {
		f.elements[id] = { value: '', innerHTML: '', style: {}, focus() {} };
	}
	for (const [id, node] of Object.entries(f.elements)) {
		const tag = html.match(new RegExp('<[a-z]+\\b[^>]*\\bid="' + id + '"[^>]*>'))?.[0] || '';
		const classes = new Set((tag.match(/\bclass="([^"]*)"/)?.[1] || '').split(/\s+/));
		node.classList = {
			add(name) {
				classes.add(name);
			},
			remove(name) {
				classes.delete(name);
			},
			contains(name) {
				return classes.has(name);
			},
			toggle(name) {
				if (classes.has(name)) classes.delete(name);
				else classes.add(name);
			}
		};
	}
	f.elements.pause_threshold.value = '5000';
	f.context.get_source_mode_flags = f.sourceFlags;
	for (const file of ['../dom_utils.js', 'format.js', 'modal.js']) {
		vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), f.context, { filename: file });
	}
	f.context.get_local_date_string = () => '2026-09-07';
	let onMessage;
	if (host === 'windows')
		f.context.chrome.webview.addEventListener = (_, callback) => {
			onMessage = callback;
		};
	Object.assign(f.context, {
		URLSearchParams,
		location: { search: '', hash: '' },
		createVisibilityPoller() {},
		decodeHostBridgeResponse(_, raw) {
			return JSON.parse(raw);
		}
	});
	const bootstrap = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
		.map((match) => match[1])
		.find((source) => source.includes('let cached_historical'));
	assert.ok(bootstrap);
	vm.runInContext(bootstrap, f.context, { filename: 'typing-bootstrap.js' });
	f.push = (blob) => {
		if (host === 'windows') onMessage({ data: { type: 'prefetch', blob } });
		else f.context.__hostBridgeResponse('metrics_typing_bridge', false, JSON.stringify(blob));
	};
	f.changePause = (value) => {
		f.elements.pause_threshold.value = value;
		const handler = html.match(/id="pause_threshold"[\s\S]*?onchange="([^"]+)"/)[1];
		vm.runInContext(handler, f.context);
	};
	f.dateChangeHandler = (id) =>
		html.match(new RegExp('id="' + id + '"[\\s\\S]*?onchange="([^"]+)"'))[1];
	return f;
}

function actualPurge(request, success) {
	const result = spawnSync('lua', ['-'], {
		cwd: path.resolve(root, '../../../macos'),
		encoding: 'utf8',
		input: `
package.path=package.path..';../_shared/lua/?.lua;../_shared/lua/?/init.lua;./?.lua;./?/init.lua'
local json=require('json')
require('tests.support.typing_delivery_fixture')(function(dashboard,context,_,errors,_,evaluations)
 package.loaded['hs.json'].encode=json.encode
 package.loaded['hs.json'].decode=json.decode
 local removes=0
 os.remove=function()
  assert(#evaluations==2,'terminal must not be emitted before purge settles')
  removes=removes+1
  if ${success ? 'true' : 'false'} then return true end
  return nil,'private-native-error',13
 end
 context.poll()
 evaluations[1].done(${JSON.stringify(request)},nil)
 assert(removes==0 and #evaluations==2)
 evaluations[2].done(true,nil)
 -- One reset unlinks the snapshot and any partial save
assert(removes==2 and #evaluations==3)
 print('PURGE='..json.encode({ack=evaluations[2].code,terminal=evaluations[3].code,removes=removes,errors=#errors}))
end)
`
	});
	assert.equal(result.status, 0, result.stdout + result.stderr);
	const line = result.stdout.split(/\r?\n/).find((value) => value.startsWith('PURGE='));
	assert.ok(line, result.stdout);
	return JSON.parse(line.slice(6));
}

module.exports = { frontend, bootstrapFrontend, actualPurge };
