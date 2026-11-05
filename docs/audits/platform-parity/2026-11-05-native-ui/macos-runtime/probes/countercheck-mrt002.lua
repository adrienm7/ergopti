-- Positive real-module completion control after native timeout-timer refusal.
local root=assert(arg[1]);assert(root:sub(1,1)=='/')
local mac=root..'/static/ergopti_plus/macos'
package.path=mac..'/?.lua;'..mac..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
local errors=0
package.loaded['infra.logger']=setmetatable({},{__index=function(_,level)return function()if level=='error'then errors=errors+1 end end end})
package.loaded['infra.phase_stats']={add_ms=function()end}
package.loaded['infra.deferred_work']={after=function()error('no callback throw expected')end}
local tasks={}
hs={timer={new=function()error('injected native deadline constructor refusal')end},task={new=function(executable,callback,args)
 local t={executable=executable,callback=callback,env={},running=false,signals=0}
 function t:environment()return self.env end
 function t:setEnvironment(env)self.env=env;return self end
 function t:start()self.running=true;return self end
 function t:isRunning()return self.running end
 function t:terminate()self.signals=self.signals+1;return self end
 tasks[#tasks+1]=t;return t
end}}
package.loaded['adapters.file_system']={}
-- These four are actual production modules, not collaborator fakes.
local Shell=require('adapters.shell_runner')
local Timer=require('adapters.timer_scheduler')
local Field=require('adapters.field_check_ports')
local Install=require('platform.remap.runtime_install')
local installer=Install.new({launcher=function()return '/fixture/launcher' end,exec=Field.exec,exists=function()return true end,fetch_driver=function()error('installed driver')end})
local answers={}
installer.install(function(ok,why)answers[#answers+1]={ok,why}end)
installer.install(function(ok,why)answers[#answers+1]={ok,why}end)
assert(#tasks==1 and #answers==0 and tasks[1].signals==0)
print('BEFORE native completion: actual ShellRunner+TimerScheduler+FieldCheckPorts+Install, tasks=1 answers=0 signals=0 scheduler_errors='..errors)
local function complete(t,code,out)t.running=false;t.callback(code,out or '', '')end
complete(tasks[1],0,'OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n')
assert(#tasks==2 and #answers==0)
complete(tasks[2],0,'')
assert(#answers==2 and answers[1][1]==true and answers[2][1]==true)
assert(next(Shell._active_tasks)==nil)
complete(tasks[1],0,'duplicate late answer')
assert(#answers==2)
print('AFTER natural role and activation completion: answers=2 success=true live_task_pins=0; duplicate answer ignored')
print('PASS timer refusal removes local deadline but does not prevent eventual actual ShellRunner callback settlement')
