assert(jit and jit.os=='Linux', 'Run ci-bin/luajit: native directory no-replace moves require Linux renameat2 FFI; stock Lua link/unlink fallback cannot assemble candidate directories')
local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate();require('tests.support.secret_service_fake').isolate()
local uv=require('luv');local Installer=require('modules.updater.installer')
local Fixture=require('tests.support.modules.updater.installer_native_fixture')
local Budget=require('updater.install_budget')
local function now()return uv.hrtime()/1e6 end
for _,slow in ipairs({false,true})do
 local f=Fixture.create(Installer)
 local payload=f.root..'/payload/bin/ergopti-hotstrings'
 Fixture.write(payload,'#!/bin/sh\n'..(slow and 'sleep 0.65\n' or '')..'exit 0\n');assert(uv.fs_chmod(payload,493))
 local token=assert(Budget.capture({release_install={install_timeout_ms=250}},now()))
 local reservation={};local callback,detail,finished,reader=0,nil,nil,{}
 local factory={}
 function factory.install_current(r)assert(r==reservation);return Budget.admit(token,now())end
 local function child(done,result)
  local c={};function c:is_settled()return true end;function c:request_cancel()return true end
  function c:on_settled(fn)fn();return true end;done(result);return c
 end
 function factory.install_feed(r,kind,dir,done,current)
  assert(r==reservation and current())
  if kind=='extract' then return child(done,{ok=f.ops.extract(f.archive,dir)}) end
  return child(done,{ok=true,stdout=kind=='names' and 'linux/\n_shared/\nbin/\ninstall.sh\n' or 'drwxr-xr-x linux/\n-rwxr-xr-x install.sh\n'})
 end
 function factory.finish_install(r,keep,done)assert(r==reservation);return child(done,{ok=true})end
 local ticks=0;local timer=assert(uv.new_timer());timer:start(10,10,function()ticks=ticks+1 end)
 local started=now()
 local original_resume=coroutine.resume;local resume_error
 coroutine.resume=function(...)local result={original_resume(...)};if result[1]~=true then resume_error=result[2] end;return (unpack or table.unpack)(result)end
 local operation=assert(Installer.install_owned({factory=factory,reservation=reservation,context=f.context,expected_version='1.2.3'},function(ok,why)callback=callback+1;finished=ok;detail=why end))
 local elapsed=now()-started
 coroutine.resume=original_resume
 assert(operation:is_settled() and callback==1, 'installer unsettled; runtime='..tostring(jit and jit.version or _VERSION)..'; coroutine_error='..tostring(resume_error))
 if slow then assert(elapsed>=600 and finished==false and ticks==0);assert(Fixture.read(f.installed..'/old.marker'));assert(not Fixture.read(f.installed..'/linux/new.marker'))
 else assert(finished==true,tostring(detail)) end
 print(string.format('slow=%s elapsed_ms=%.1f install_budget_ms=250 uv_ticks_during_call=%d result=%s detail=%s restored_old=%s',tostring(slow),elapsed,ticks,tostring(finished),tostring(detail),tostring(Fixture.read(f.installed..'/old.marker')~=nil)))
 uv.run('nowait');if slow then assert(ticks>0)end
 timer:stop();timer:close();uv.run('nowait');Fixture.remove(f.root)
end
print('Actual install_owned transaction/default smoke + real POSIX bounded sleeper; only admitted archive-reader factory modeled. No desktop input grab or actual update/network used.')
