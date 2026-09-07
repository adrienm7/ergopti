/**
 * tools/test/test-typing-metrics-mailbox-ownership.cjs
 * ==============================================================================
 * MODULE: Typing Metrics Mailbox Ownership
 * DESCRIPTION:
 * Executes actual Lua acknowledgements against the real frontend request mailbox.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../../static/ergopti_plus');
let passed = 0;
let failed = 0;

function frontend() {
	const timers = [];
	const state = { loading_data: false, range_request_sequence: 0, active_range_request_id: 0,
		cache_reset_sequence: 0, active_cache_reset_id: 0, cache_reset_watchdog: null, cache_reset_pending_range: null,
		available_apps: ['Editor'], selected_apps: new Set(['Editor']), app_selection_mode: 'all' };
	const element = { value: '2026-09-01', innerHTML: '', classList: { add() {}, toggle() {} } };
	const context = vm.createContext({ app_state: state,
		APP_SELECTION_MODE: { ALL: 'all', UNINITIALIZED: 'uninitialized' }, RANGE_REQUEST_WATCHDOG_MS: 30000,
		document: { getElementById() { return element; } },
		setTimeout(fn, delay) { timers.push({ fn, delay }); return timers.length; }, clearTimeout() {}, console });
	context.window = context;
	for (const file of ['data.js', 'filters.js']) {
		vm.runInContext(fs.readFileSync(path.join(root, '_shared/ui/metrics_typing', file), 'utf8'), context);
	}
	vm.runInContext('compute_manifest_metrics=function(){};apply_default_date_range=function(){};update_app_btn_text=function(){};', context);
	context.request_range_data(false);
	timers.find((timer) => timer.delay === 50).fn();
	assert.equal(JSON.parse(context.window._lua_request).request_id, 1);
	return context;
}

function controller(request, outcomes = [], admission = 'accepted') {
	const lua = spawnSync('lua', ['-'], { cwd: path.join(root, 'macos'), encoding: 'utf8', input: `
package.path=package.path..';../_shared/lua/?.lua;../_shared/lua/?/init.lua;./?.lua;./?/init.lua'
local json=require('json')
local poll
local dashboard,context=require('tests.support.metrics_typing_fixture')({
 after=function() return {timer={}},true end,
 every=function(_,fn) poll=fn;return {timer={}},true end,
 cancel=function(handle) handle.timer=nil;return true end})
package.loaded['hs.json'].decode=json.decode
package.loaded['hs.json'].encode=json.encode
package.loaded['modules.keylogger.sqlite_reader']={}
local reads,errors,removes=0,0,0
package.loaded['modules.keylogger.log_manager'].get_sqlite_path=function() reads=reads+1;return nil end
package.loaded['infra.logger'].error=function() errors=errors+1 end
os.remove=function() removes=removes+1;return true end
local polls,resets,codes,completions={},{},{},{}
local admission=${JSON.stringify(admission)}
context.webview.evaluateJavaScript=function(self,code,callback)
 if code=='window._lua_request' then polls[#polls+1]=callback
 elseif code:find('_lua_request',1,true) then
  codes[#codes+1]=code
  resets[#resets+1]=callback
  if admission=='sync_refused' then callback(true);return nil end
  if admission=='refused' then return nil end
 elseif code:find('window.complete_cache_reset',1,true) then
  completions[#completions+1]=code
 end
 return self
end
assert(dashboard.show())
poll();poll()
local request=${JSON.stringify(request)}
polls[1](request);polls[2](request)
local before=reads
local outcomes=json.decode(${JSON.stringify(JSON.stringify(outcomes))})
for index,outcome in ipairs(outcomes) do
 if resets[index] then
  if outcome=='error' then resets[index](nil,{message='PRIVATE_DETAIL'})
  elseif outcome=='nil' then resets[index](nil)
  else resets[index](outcome) end
  resets[index](true)
 end
end
print('RESULT='..json.encode({codes=codes,completions=completions,before=before,reads=reads,errors=errors,removes=removes}))
` });
	assert.equal(lua.status, 0, lua.stderr + lua.stdout);
	const line = lua.stdout.split(/\r?\n/).find((value) => value.startsWith('RESULT='));
	assert.ok(line, lua.stdout);
	return JSON.parse(line.slice(7));
}

function test(name, callback) {
	try { callback(); passed++; console.log(`ok ${name}`); }
	catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`); }
}

test('Reset posted after a poll read survives the old acknowledgement', () => {
	const context = frontend();
	const request = context.window._lua_request;
	const result = controller(request);
	assert.equal(result.codes.length, 2);
	context.reset_filters();
	const replacement = context.window._lua_request;
	assert.equal(JSON.parse(replacement).action, 'clear_cache');
	assert.equal(vm.runInContext(result.codes[0], context), false);
	assert.equal(context.window._lua_request, replacement);
});

test('duplicate reads of one request yield exactly one applied acknowledgement', () => {
	const context = frontend();
	const request = context.window._lua_request;
	const result = controller(request);
	const outcomes = result.codes.map((code) => vm.runInContext(code, context));
	assert.deepEqual(outcomes, [true, false]);
	assert.equal(context.window._lua_request, null);
	const completed = controller(request, outcomes);
	assert.equal(completed.before, 0, 'admission is not successful mailbox acknowledgement');
	assert.equal(completed.reads, 1, 'only the winning acknowledgement may start projection');
	assert.equal(completed.errors, 0);
});

test('a retained Reset executes once after its own successful acknowledgement', () => {
	const context = frontend();
	context.reset_filters();
	const request = context.window._lua_request;
	const result = controller(request);
	const outcomes = result.codes.map((code) => vm.runInContext(code, context));
	assert.deepEqual(outcomes, [true, false]);
	const completed = controller(request, outcomes);
	assert.equal(completed.removes, 1);
	assert.equal(completed.reads, 0);
	assert.equal(completed.errors, 0);
	assert.equal(context.app_state.active_cache_reset_id, 1,
		'mailbox consumption must not pretend that native purge has completed');
	assert.equal(completed.completions.length, 1);
	assert.equal(vm.runInContext(completed.completions[0], context), true);
	assert.equal(context.app_state.active_cache_reset_id, 0,
		'only the exact native purge completion may release the reset owner');
});

for (const outcome of [false, 'nil', 'invalid', 'error']) {
	test(`uncommitted acknowledgement cannot start projection: ${String(outcome)}`, () => {
		const result = controller(frontend().window._lua_request, [outcome, outcome]);
		assert.equal(result.before, 0);
		assert.equal(result.reads, 0);
		assert.equal(result.removes, 0);
		assert.equal(result.errors, outcome === false ? 0 : 1);
	});
}

for (const admission of ['refused', 'sync_refused']) {
	test(`native reset ${admission} cannot authorize query processing`, () => {
		const result = controller(frontend().window._lua_request, [true, true], admission);
		assert.equal(result.before, 0);
		assert.equal(result.reads, 0);
		assert.equal(result.removes, 0);
		assert.equal(result.errors, 1);
	});
}

test('acknowledgement compares the exact serialized value, including escapes', () => {
	const request = JSON.stringify({ request_id: 7, apps: ['Editor "quoted"\nC:\\private\\é'] });
	const result = controller(request);
	const context = vm.createContext({ window: { _lua_request: request } });
	assert.equal(vm.runInContext(result.codes[0], context), true);
	assert.equal(context.window._lua_request, null);
	context.window._lua_request = JSON.stringify({ request_id: 8, apps: [] });
	assert.equal(vm.runInContext(result.codes[1], context), false);
	assert.notEqual(context.window._lua_request, null);
});

console.log(`typing metrics mailbox ownership: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
