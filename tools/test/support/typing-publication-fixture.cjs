/**
 * tools/test/support/typing-publication-fixture.cjs
 * ==============================================================================
 * MODULE: Typing Publication Producer Fixture
 * DESCRIPTION:
 * Captures real Lua scripts through private native and database boundaries.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../../../static/ergopti_plus');

function actualLuaPublications(empty = false) {
	const lua = spawnSync('lua', ['-'], { cwd: path.join(root, 'macos'), encoding: 'utf8', input: `
package.path=package.path..';../_shared/lua/?.lua;../_shared/lua/?/init.lua;./?.lua;./?/init.lua'
local json=require('json')
local empty=${empty ? 'true' : 'false'}
local now,rev=0,1
local timers,evaluations,publications={},{},{}
local dashboard,context=require('tests.support.metrics_typing_fixture')({
 after=function(delay,fn)
  local handle={timer={}}
  timers[#timers+1]={at=now+delay,run=function()handle.timer=nil;fn()end}
  return handle,true
 end,
 every=function()return {timer={}},true end,
 cancel=function(handle)handle.timer=nil;return true end})
package.loaded['hs.json'].encode=function(value)
 if empty and type(value)=='table' and next(value)==nil then return '[]' end
 return json.encode(value)
end
package.loaded['hs.json'].decode=json.decode
package.loaded['hs.fs'].attributes=function()return {}end
package.loaded['adapters.file_system'].read_with_status=function()return nil,'absent'end
local manager=package.loaded['modules.keylogger.log_manager']
manager.get_sqlite_path=function()return '/virtual/db'end
manager.get_db_rev=function()return rev end
package.loaded['modules.keylogger.sqlite_reader']={
 read_manifest=function()if empty then return {} end;return {['2026-09-01']={[rev==1 and 'Startup' or 'Live']={chars=rev}}}end,
 read_range_split_today=function()return {historical={},today={}}end}
dashboard._app_icon_cache={Startup=false,Live=false}
if empty then hs.keycodes.map={} end
io.open=function()local f={};function f:write()return self end;function f:close()return true end;return f end
context.webview.evaluateJavaScript=function(self,code,done)
 evaluations[#evaluations+1]={code=code,done=done}
 if not code:find('^typeof ') then publications[#publications+1]=code end
 return self
end
local function fire(index)now=timers[index].at;timers[index].run()end
local function complete_pending_probes()
 for _,evaluation in ipairs(evaluations) do
  if not evaluation.completed then
   evaluation.completed=true
   evaluation.done(evaluation.code:find('^typeof ') and 'function' or true)
  end
 end
end
assert(dashboard.show())
fire(1);fire(2)
assert(now==0.1 and evaluations[1].code:find('^typeof '))
evaluations[1].completed=true;evaluations[1].done('undefined')
assert(timers[3].at>now)
now=0.15;rev=2;assert(dashboard.push_live_update())
fire(4);complete_pending_probes()
assert(#publications==1)
fire(3);complete_pending_probes()
assert(#publications==2)
print('PUBLICATIONS='..json.encode(publications))
` });
	assert.equal(lua.status, 0, lua.stderr + lua.stdout);
	const line = lua.stdout.split(/\r?\n/).find((value) => value.startsWith('PUBLICATIONS='));
	assert.ok(line, lua.stdout);
	return JSON.parse(line.slice(13));
}

function actualLuaFallback() {
	const lua = spawnSync('lua', ['-'], { cwd: path.join(root, 'macos'), encoding: 'utf8', input: `
package.path=package.path..';../_shared/lua/?.lua;../_shared/lua/?/init.lua;./?.lua;./?/init.lua'
local json=require('json')
local now=0
local timers,evaluations,publications={},{},{}
local dashboard,context=require('tests.support.metrics_typing_fixture')({
 after=function(delay,fn)local h={timer={}};timers[#timers+1]={at=now+delay,run=function()h.timer=nil;fn()end};return h,true end,
 every=function()return {timer={}},true end,
 cancel=function(h)h.timer=nil;return true end})
local codec=package.loaded['hs.json'];codec.encode=json.encode
codec.decode=function()return {manifest='{"2026-09-01":{"Cache":{"chars":1}}}',app_icons='{}',kc_layout='{}'}end
package.loaded['adapters.file_system'].read_with_status=function()return 'cached','ok'end
package.loaded['hs.fs'].attributes=function()return {}end
local manager=package.loaded['modules.keylogger.log_manager'];manager.get_sqlite_path=function()return '/virtual/db'end;manager.get_db_rev=function()return 1 end
package.loaded['modules.keylogger.sqlite_reader']={read_manifest=function()return {['2026-09-01']={Fresh={chars=2}}}end,
 read_range_split_today=function()return {historical={},today={}}end}
dashboard._app_icon_cache={Fresh=false}
io.open=function()local f={};function f:write()return self end;function f:close()return true end;return f end
context.webview.evaluateJavaScript=function(self,code,done)
 evaluations[#evaluations+1]={code=code,done=done}
 if not code:find('^typeof ') then
  local refused=code:find('Fresh',1,true)~=nil
  publications[#publications+1]={code=code,admitted=not refused}
  if refused then return nil end
 end
 return self
end
local function fire(index)now=timers[index].at;timers[index].run()end
assert(dashboard.show());fire(1)
now=0.4;evaluations[1].done('undefined')
assert(timers[2].at<timers[3].at)
fire(2);evaluations[2].done('function')
fire(3);evaluations[#evaluations].done('function')
assert(#publications==2 and not publications[1].admitted and publications[2].admitted)
print('PUBLICATIONS='..json.encode(publications))
` });
	assert.equal(lua.status, 0, lua.stderr + lua.stdout);
	const line = lua.stdout.split(/\r?\n/).find((value) => value.startsWith('PUBLICATIONS='));
	assert.ok(line, lua.stdout);
	return JSON.parse(line.slice(13));
}

module.exports = { actualLuaPublications, actualLuaFallback };
