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
	const element = () => ({ value: '', innerHTML: 'last-good', classList: { add() {}, toggle() {}, contains: () => true } });
	const elements = Object.fromEntries(['date_start', 'date_end', 'metrics_table_body', 'btn_case_sensitive',
		'pause_threshold', 'quick_range'].map((id) => [id, element()]));
	const context = vm.createContext({ console, document: { getElementById: (id) => elements[id] || null,
		addEventListener() {} }, addEventListener() {},
		setTimeout(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; },
		clearTimeout(id) { timers.delete(id); } });
	context.window = context;
	if (host === 'windows') context.chrome = { webview: { postMessage: (raw) => requests.push(JSON.parse(raw)) } };
	if (host === 'linux') {
		context.__ergopti_host = host;
		context.webkit = { messageHandlers: { metrics_typing_bridge: { postMessage: (req) => requests.push(req) } } };
	}
	for (const file of ['_generated/keycode_data.js', 'state.js', 'data.js', 'filters.js']) {
		vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context);
	}
	const state = vm.runInContext('app_state', context);
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
			if (timer.delay === 50) { timers.delete(id); timer.fn(); }
		}
	}
	function select(date) {
		elements.date_start.value = elements.date_end.value = date;
		context.apply_date_app_filters();
	}
	return { context, state, requests, timers, elements, renders, dispatch, select };
}

function actualPurge(request, success) {
	const result = spawnSync('lua', ['-'], { cwd: path.resolve(root, '../../../macos'), encoding: 'utf8', input: `
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
 assert(removes==1 and #evaluations==3)
 print('PURGE='..json.encode({ack=evaluations[2].code,terminal=evaluations[3].code,removes=removes,errors=#errors}))
end)
` });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	const line = result.stdout.split(/\r?\n/).find((value) => value.startsWith('PURGE='));
	assert.ok(line, result.stdout);
	return JSON.parse(line.slice(6));
}

module.exports = { frontend, actualPurge };
