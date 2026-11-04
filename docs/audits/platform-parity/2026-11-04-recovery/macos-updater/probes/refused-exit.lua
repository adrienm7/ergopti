local repo='/workspace/ergopti/static/ergopti_plus/'
local root=repo..'macos/'
package.path=root..'?.lua;'..root..'?/init.lua;'..repo..'_shared/lua/?.lua;'..repo..'_shared/lua/?/init.lua;'..package.path
local dir=assert(arg[1]); local pid=assert(arg[2]); local accepted=arg[3]=='accepted'
local Logger=setmetatable({}, {__index=function() return function() end end})
package.loaded['infra.logger']=Logger
package.loaded['infra.paths']={shared=function() return root..'adapters/release_stage.sh' end}
package.loaded['adapters.file_system']={read=function(p) local f=assert(io.open(p));local s=f:read('a');f:close();return s end}
package.loaded['adapters.json_codec']=require('json')
package.loaded['adapters.shell_runner']={}
local Installer=require('modules.updater.release_installer')
Installer._getenv=function(k) if k=='ERGOPTI_LAUNCHER_PID' then return pid elseif k=='ERGOPTI_LAUNCHER_EXECUTABLE' then return dir..'/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus' end end
local completion
Installer._run=function(_,_,cb) completion=cb;return true end
local Coordinator=require('infra.termination_coordinator')
local calls={exit=0,lease=0,schedule=0,admission=0}
assert(Coordinator.init({
 capture_publication_admission=function() calls.admission=calls.admission+1;if not accepted then return nil end;return {current=function() return true end,abort=function() return true end} end,
 request_lease=function(_,cb) calls.lease=calls.lease+1;return true end,
 drain_input=function(cb) cb();return true end,teardown=function() return true end,
 begin_drain=function(cb) cb(true);return true end,finalize_teardown=function() return true end,
 reload=function() error('unexpected reload') end,exit=function() calls.exit=calls.exit+1;return true end,fatal_exit=function() calls.exit=calls.exit+1;return true end,
 fatal_exit_code=70,mark_reload=function() return true end,clear_reload=function() return true end,
 schedule=function() calls.schedule=calls.schedule+1;return {stop=function() return true end} end,
 user_exit_deadline_seconds=2,reload_deadline_seconds=2,
}))
local reports={}
local session=require('updater.release_install').new({logger=Logger,
 blocked=function() return nil end,find_release=function() return {tag_name='v1'} end,
 backup=function() return {path=dir..'/private-config-backup'} end,
 resolve_asset=function() return {} end,download=function(_,_,done) done(dir..'/stage/app/ErgoptiPlus.app');return true end,
 install_async=function(staged,_,_,done) return Installer.arm_swap(staged,function(armed,detail) done(armed,nil,detail) end) end,
 restart=function() return Coordinator.request_user_exit('release_install') end,
 report=function(m) reports[#reports+1]=m.phase end,
})
assert(session.install('v1','stable'))
-- Emit exact production swap with only documented recording/native-host ports.
local script=Installer.SWAP_SCRIPT:gsub('/usr/bin/stat',function() return "'"..dir.."/stat-port'" end):gsub('/usr/bin/open',function() return "'"..dir.."/open-port'" end)
local f=assert(io.open(dir..'/swap.sh','w'));f:write(script);f:close()
print('WAITING_FOR_PHYSICAL_ARMING');io.stdout:flush()
assert(io.read('*l')=='ARMED')
completion(true,'ARMED','')
print('phases='..table.concat(reports,','))
print('busy='..tostring(session.busy())..' exit='..calls.exit..' lease='..calls.lease..' schedule='..calls.schedule..' admission='..calls.admission)
assert(calls.admission==1)
if accepted then assert(calls.exit==0 and calls.lease==1 and session.busy()) else assert(calls.exit==0 and calls.lease==0 and calls.schedule==0 and not session.busy() and reports[#reports]=='failed') end
