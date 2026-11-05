-- Audit-only injected boundaries; production modules loaded from explicit source root.
local root = assert(arg[1], 'source root required')
assert(root:sub(1,1)=='/', 'absolute source root required')
local mac = root .. '/static/ergopti_plus/macos'
package.path = mac..'/?.lua;'..mac..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
local logs = {}
package.loaded['infra.logger'] = setmetatable({}, {__index=function(_,level) return function(scope,fmt,...) logs[#logs+1]={level,scope,string.format(fmt,...)} end end})
local function eq(a,b,msg) assert(a==b,(msg or '')..' expected '..tostring(b)..' got '..tostring(a)) end
local function line(state)
 return '1 extension(s)\n* * G43BCU2T37 org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (8.5.0/8.5.0) driver ['..state..']\n'
end
local Watch = require('platform.remap.runtime_approval_watch')
local function approval(delay, activate_at)
 local world={t=0,looks=0,reloads=0,pending=nil}
 local watch=Watch.new({listing=function(cb)
  world.looks=world.looks+1; world.t=world.t+delay
  cb(line(activate_at and world.t>=activate_at and 'activated enabled' or 'activated waiting for user'))
 end,after=function(sec,fn) world.pending=function() world.t=world.t+sec; fn() end; return {},true end,
 cancel=function()end,open_settings=function()return true end,reload=function()world.reloads=world.reloads+1 end,version=function()return '8.5.0' end})
 eq(watch.start(),true); eq(watch.start(),false)
 while watch.active() and world.t < 5000 do local fn=assert(world.pending); world.pending=nil; fn() end
 return world,watch
end
local slow=approval(4)
eq(slow.t,2104); eq(slow.looks,301); eq(slow.reloads,0)
print('MRT-001 delayed listings: timeout='..Watch.APPROVAL_TIMEOUT_SEC..' simulated_elapsed='..slow.t..'s looks='..slow.looks)
local instant=approval(0); eq(instant.t,900)
local late=approval(4,1000); eq(late.reloads,1); assert(late.t>900)
print('MRT-001 control zero-latency stops at '..instant.t..'s; activation after deadline still reloads at '..late.t..'s')
-- The deadline refusal of the actual TimerScheduler must settle the bounded command too.
package.loaded['adapters.timer_scheduler']=nil
local native_timer_calls=0
hs={timer={new=function() native_timer_calls=native_timer_calls+1; error('injected native timer construction failure') end}}
local Timer=require('adapters.timer_scheduler')
local live,terminated=true,0
package.loaded['adapters.shell_runner']={spawn=function()
 return {isSettled=function()return not live end,start=function()return true end,terminate=function()terminated=terminated+1;return false,'refused' end}
end}
package.loaded['adapters.file_system']={}
local Field=require('adapters.field_check_ports')
local callbacks=0
Field.exec('/fixture/launcher', {'--request-owned-runtime-install'},900,function() callbacks=callbacks+1 end)
eq(native_timer_calls,1); eq(callbacks,0); eq(terminated,0); eq(live,true)
print('MRT-002 native timer refusal: command_started=true callback_count='..callbacks..' terminate_attempts='..terminated)
local Install=require('platform.remap.runtime_install')
local role_calls,answers=0,0
local stuck=Install.new({launcher=function()return '/fixture/launcher' end,exists=function()return true end,fetch_driver=function()error('unused')end,
 exec=function(...)role_calls=role_calls+1; return Field.exec(...) end})
stuck.install(function()answers=answers+1 end); stuck.install(function()answers=answers+1 end)
eq(role_calls,1);eq(answers,0)
print('MRT-002 duplicate install remains queued behind unsettled request: role_calls='..role_calls..' answers='..answers)
-- Controls: successful scheduling times out and settles once; immediate command answer parses closed line.
local deadline
package.loaded['adapters.timer_scheduler']={after=function(_,fn) deadline=fn; return {},true end,cancel=function()end}
package.loaded['adapters.field_check_ports']=nil
Field=require('adapters.field_check_ports')
local count=0
Field.exec('/fixture/launcher',{},900,function(code)eq(code,nil); count=count+1 end)
assert(deadline); deadline(); eq(count,1);eq(terminated,1)
print('MRT-002 control committed timer delivers exactly one timeout callback')
-- Cache receipt mismatch: same bytes accepted by Lua cache, rejected by Swift exact-byte contract.
local Fetch=require('platform.remap.runtime_artifact_fetch')
local pin={version='16.3.0-ergopti.3',file_name='runtime.tar.gz',source_url='https://example.invalid/runtime.tar.gz',sha256=string.rep('a',64),size=1}
for _,suffix in ipairs({'\n','\nextra','\n\n',' extra\n'}) do
 local commands=0; local receipt=pin.sha256..suffix
 local fetch=Fetch.new({expand=function(p)return '/fixture' end,exists=function()return true end,read=function()return receipt end,write=function()return true end,exec=function()commands=commands+1 end})
 local answer;fetch.ensure(pin,function(ok)answer=ok end)
 eq(answer,true);eq(commands,0)
 print('receipt control/probe suffix='..string.format('%q',suffix)..' cache_success='..tostring(answer)..' commands='..commands..' swift_exact_contract='..tostring(receipt==pin.sha256..'\n'))
end
print('PASS all retained runtime probes (virtual boundary timings; not Darwin qualification)')
-- Actual read-only owner admission over an existing install with an unloaded job.
local Owner=require('platform.remap.runtime_owner')
local captured
assert(Owner.init({fs={exists=function()return true end,expand=function(p)return p end},
 launchd={loaded=function(_,cb)cb(false)end},system_extensions={listing=function(cb)cb(line('activated enabled'))end},
 coexistence={detect=function(cb)cb(0)end},artifact={pinned=function()return {virtual_hid_version='8.5.0',capture={}} end},
 capture={start=function()return true end,stop=function()return true end,status=function()return {state='stopped'} end,on_lost=function()end},
 timer={after=function()return {},true end,cancel=function()return true end}}))
assert(Owner.start({close_other_instances=true},function(ok,why)captured={ok,why}end))
eq(captured[1],false);eq(captured[2],'runtime_job_not_loaded')
local f=assert(io.open(mac..'/platform/remap/init.lua','r'));local facade=f:read('*a');f:close()
local declaration=assert(facade:match('(M%.OWNED_INSTALL_REASONS = %b{})'))
local body=assert(facade:match('(function M%.install_owned_runtime%(%s*on_done%)[%s%S]-\nend)'))
local install_calls=0
local projected={_owned={selected=function()return true end},owned_runtime_status=Owner.status}
local env=setmetatable({M=projected,Logger=package.loaded['infra.logger'],LOG='audit-projection',require=function(name)
 if name=='adapters.runtime_owner_ports' then return {install_runtime=function(cb)install_calls=install_calls+1;cb(false,'install_refused','existing Runtime') end} end
 return require(name)
end},{__index=_G})
assert(load(declaration..'\n'..body,'@'..mac..'/platform/remap/init.lua (exact public-function projection)','t',env))()
local refusal
assert(projected.install_owned_runtime(function(ok,why) refusal=why end))
eq(install_calls,1);eq(refusal,'install_refused')
print('MRT-004 real owner existing files/unloaded job => '..captured[2]..'; exact facade function projection still offers first-install request')
assert(Owner.stop()); assert(Owner.release())
print('PASS source-projected public retry join (not native helper execution)')
-- Timer firing is not child settlement: same caller can start another privileged role.
local tasks,deadlines={},{}
package.loaded['adapters.shell_runner']={spawn=function()
 local task={live=true};tasks[#tasks+1]=task
 return {isSettled=function()return not task.live end,start=function()return true end,
  terminate=function()task.signalled=true;return true,'pending' end,
  onSettled=function(fn)task.onSettled=fn end}
end}
package.loaded['adapters.timer_scheduler']={after=function(_,fn)deadlines[#deadlines+1]=fn;return {},true end,cancel=function()return true end}
package.loaded['adapters.field_check_ports']=nil
Field=require('adapters.field_check_ports')
local finished=0
local overlap=Install.new({launcher=function()return '/fixture/launcher' end,exists=function()return true end,fetch_driver=function()error('unused')end,exec=Field.exec})
overlap.install(function(ok,why)eq(ok,false);eq(why,'install_unanswered');finished=finished+1 end)
eq(#tasks,1);deadlines[1]();eq(finished,1);eq(tasks[1].live,true);eq(tasks[1].signalled,true)
overlap.install(function()end)
eq(#tasks,2);eq(tasks[1].live,true);eq(tasks[2].live,true)
print('MRT-005 timeout terminal dispatched before exact child exit; retry starts second role with two native handles physically pending')
-- Physical completion before a new request is the counterfactual control.
tasks[1].live=false;tasks[2].live=false
print('PASS native-return-contract timeout overlap probe (injected SIGTERM-pending boundary; no privileged process)')
local before=#logs
local refused_open=Watch.new({listing=function(cb)cb('1 extension(s)\n')end,after=function()return {},true end,cancel=function()return true end,
 open_settings=function()return false end,reload=function()error('not approved')end,version=function()return '8.5.0' end})
eq(refused_open.start(),true);eq(refused_open.active(),true)
local failures=0;for index=before+1,#logs do if logs[index][1]=='error' then failures=failures+1 end end
eq(failures,0)
print('MRT-006 native open_settings=false is accepted without any error diagnostic; watch_started=true errors='..failures)
