-- Actual installer invoked from an already-running uv callback; private fixtures only.
assert(jit, 'This directory-activation proof requires shipped LuaJIT native renameat2 support')
local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate()
require('tests.support.secret_service_fake').isolate()
local uv = require('luv')
local Installer = require('modules.updater.installer')
local Fixture = require('tests.support.modules.updater.installer_native_fixture')
local Budget = require('updater.install_budget')
local function now() return uv.hrtime()/1e6 end
local results = {}
for _, slow in ipairs({false, true}) do
 local f = Fixture.create(Installer)
 local function scenario()
  local payload = f.root..'/payload/bin/ergopti-hotstrings'
  Fixture.write(payload, '#!/bin/sh\n'..(slow and 'sleep 0.65\n' or '')..'exit 0\n')
  assert(uv.fs_chmod(payload,493))
  local token = assert(Budget.capture({release_install={install_timeout_ms=250}},now()))
  local reservation = {}
  local factory = {}
  function factory.install_current(r) assert(r==reservation); return Budget.admit(token,now()) end
  local function child(done,result)
   local c={}
   function c:is_settled() return true end
   function c:request_cancel() return true end
   function c:on_settled(fn) fn(); return true end
   done(result)
   return c
  end
  function factory.install_feed(r,kind,dir,done,current)
   assert(r==reservation and current())
   if kind=='extract' then return child(done,{ok=f.ops.extract(f.archive,dir)}) end
   return child(done,{ok=true,stdout=kind=='names' and 'linux/\n_shared/\nbin/\ninstall.sh\n' or 'drwxr-xr-x linux/\n-rwxr-xr-x install.sh\n'})
  end
  function factory.finish_install(r,keep,done) assert(r==reservation);return child(done,{ok=true}) end
  local ticks,last_tick,gap=0,nil,0
  local heartbeat,activation,finish=assert(uv.new_timer()),assert(uv.new_timer()),assert(uv.new_timer())
  local observed,error_message,called=nil,nil,false
  local function retire()
   for _,handle in ipairs({heartbeat,activation,finish}) do
    if not handle:is_closing() then handle:stop();handle:close() end
   end
  end
  -- Fixture construction performs synchronous I/O before the loop starts.
  uv.update_time()
  heartbeat:start(10,10,function()
   local time=now()
   if last_tick then gap=math.max(gap,time-last_tick) end
   last_tick=time;ticks=ticks+1
  end)
  activation:start(35,0,function()
   called=true
   local okay,why=xpcall(function()
    assert(ticks>=2,'heartbeat must run before installer entry')
    local before=ticks
    local callbacks,installed,detail=0,nil,nil
    local start=now()
    local operation=assert(Installer.install_owned({factory=factory,reservation=reservation,context=f.context,expected_version='1.2.3'},function(ok,reason)
     callbacks=callbacks+1;installed=ok;detail=reason
    end))
    local elapsed=now()-start
    assert(operation:is_settled() and callbacks==1)
    assert(ticks==before,'no nested event-loop pumping is expected during this original synchronous call')
    if slow then
     assert(elapsed>=600 and installed==false)
     assert(Fixture.read(f.installed..'/old.marker') and not Fixture.read(f.installed..'/linux/new.marker'))
    else assert(installed==true,detail) end
    observed={slow=slow,elapsed=elapsed,before=before,during=ticks-before,installed=installed,detail=detail}
    finish:start(40,0,function()
     local accepted,problem=xpcall(function()
      assert(ticks>before,'heartbeat must resume after installer returns')
      if slow then assert(gap>=600,'active heartbeat must observe the actual blocking interval') end
      observed.after=ticks-before;observed.gap=gap
     end,debug.traceback)
     if not accepted then error_message=problem end
     retire()
    end)
   end,debug.traceback)
   if not okay then error_message=why;retire() end
  end)
  uv.run()
  assert(called and observed and not error_message,error_message or 'installer callback never completed')
  print(string.format('ACTIVE_LOOP slow=%s elapsed_ms=%.1f budget_ms=250 ticks_before=%d ticks_during=%d ticks_after=%d max_heartbeat_gap_ms=%.1f installed=%s detail=%s',tostring(observed.slow),observed.elapsed,observed.before,observed.during,observed.after,observed.gap,tostring(observed.installed),tostring(observed.detail)))
  results[#results+1]=observed
 end
 local okay,why=xpcall(scenario,debug.traceback)
 Fixture.remove(f.root)
 assert(okay,why)
end
assert(#results==2 and results[2].elapsed>results[1].elapsed+500)
print('PASS actual default smoke ran inside active libuv callback; before/after heartbeat and bounded slow-launcher control. No desktop/input/network/systemd or user installation.')
