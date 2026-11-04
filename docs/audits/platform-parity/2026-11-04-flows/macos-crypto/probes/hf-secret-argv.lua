-- Actual HF mixin through its normal direct-operation owner; record native task acquisition only.
local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
local noop=function() end
local recorded
package.loaded['infra.logger']=setmetatable({},{__index=function() return noop end})
for _,name in ipairs({'ui.menu.menu_llm.models_manager_mlx_repo','adapters.running_application','infra.notifications','ui.ui_builder','infra.paths','adapters.timer_scheduler'}) do package.loaded[name]={} end
package.loaded['infra.i18n']={get=function(key) return key end}
package.loaded['adapters.task_lifecycle']={native=function(label,executable,done,stream,args)
 recorded={label=label,executable=executable,args=args};return {isRunning=function() return false end}
 end,start=function() return false end,terminate=function() return true end}
_G.hs={}
local obj={}
require('ui.menu.menu_llm.models_manager_mlx_hf').install{obj=obj,deps={active_tasks={}},presets={},
 begin_direct_operation=function() return {is_authorized=function() return true end,lifecycle={adopt=function() return true end,settle=function() return true end},finish=function() return true end} end}
local sentinel='hf_SYNTHETIC_ONLY_NOT_A_REAL_CREDENTIAL'
local accepted=obj._process_hf_token(sentinel,function() end)
assert(recorded and recorded.executable=='/bin/bash' and recorded.args[1]=='-c')
assert(recorded.args[2]:find(sentinel,1,true))
print('actual_hf_native_task_executable='..recorded.executable)
print('synthetic_token_in_native_argv=true; native_task_started=false; network_and_file_effects=0')
assert(accepted==false)
