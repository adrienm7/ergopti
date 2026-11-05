local root,b=assert(loadfile(assert(arg[1])..'/bootstrap.lua'))()
local fixture=assert(arg[2])
local log={}
package.loaded['infra.paths']={shared_root=function() return b..'_shared' end,shared=function(rel) return b..'_shared/'..rel end,driver_root=function() return b..'linux' end}
package.loaded['logger.shim']=setmetatable({}, {__index=function(_,key) return function(_,fmt,...) log[#log+1]=key..':'..string.format(fmt,...) end end})
package.loaded['logger']={LEVELS={INFO=1},get_level=function() return 1 end,ring_buffer_snapshot=function() return {} end,session_issues=function() return {warn_count=0,err_count=0} end}
package.loaded['infra.logger_sink']={log_dir=function() return fixture end,main_log_path=function() return fixture..'/no-log' end,errors_log_path=function() return fixture..'/no-errors' end}
package.loaded['infra.config_paths']={get_config_dir=function() return fixture end,home=function() return fixture end}
package.loaded['modules.diagnostics.crash_reporter']={get_crash_dir=function() return fixture end}
package.loaded['infra.diagnostic_snapshot']={system_facts=function() return {} end,resolve_commit=function() return '3aaaae7dd','build' end}
package.loaded['adapters.keyboard_hook']={held_modifiers=function() return {} end,caps_lock_on=function() return false end}
package.loaded['adapters.keyboard_layout']={is_ready=function() return false end}
package.loaded['adapters.uinput_writer']={UINPUT_PATH=fixture..'/no-uinput'}
package.loaded['platform.remap.manager']={owns_process=function() return false end,tap_holds_enabled=function() return false end}
package.preload['lgi']=function() error('GUI disabled in audit') end
local open=io.open
io.open=function(path,mode)
 if path:sub(1,#root+1)==root..'/' or path:sub(1,#fixture+1)==fixture..'/' then return open(path,mode) end
 return nil,'private fixture: absent',2
end
local Bridge=require('ui.healthcheck.bridge')
local enabled,backend=true,'api'
local calls=0
local llm={is_enabled=function() return enabled end,get_backend=function() calls=calls+1;return backend end,get_current_model=function() return 'CANARY_PRIVATE_MODEL_729' end}
local snap=Bridge.build_snapshot({llm=llm},false,false)
assert(snap.sections.ai.ai_enabled==true)
assert(snap.sections.ai.ai_backend=='ollama' and calls==0)
local share=require('healthcheck.share').document(snap,Bridge.config().schema,'ignored')
assert(share.snapshot.sections.ai.ai_backend=='ollama')
assert(not share.text:find('CANARY_PRIVATE_MODEL_729',1,true),'private model field excluded by closed share policy')
print('ADVERSE backend input=api snapshot='..snap.sections.ai.ai_backend..' export='..share.snapshot.sections.ai.ai_backend..' get_backend_calls='..calls)
backend='ollama'
local control=Bridge.build_snapshot({llm=llm},false,false)
assert(control.sections.ai.ai_backend==backend)
print('HEALTHY backend input=ollama snapshot=ollama')
enabled=false
local off=Bridge.build_snapshot({llm=llm},false,false)
assert(off.sections.ai.ai_enabled==nil)
local offshare=require('healthcheck.share').document(off,Bridge.config().schema,'ignored')
assert(offshare.snapshot.sections.ai.ai_enabled==nil)
local feature
for _,f in ipairs(off.sections.features.items) do if f.id=='llm' then feature=f.enabled end end
assert(feature==false)
print('ADVERSE enabled input=false ai_field=nil export_field=nil feature_field=false')
local absent=Bridge.build_snapshot({},false,false)
assert(absent.sections.ai.ai_enabled==nil)
print('REFUSAL absent llm ai_enabled=nil')
print('PRIVACY exported_private_model=false')

if arg[3] then local f=assert(open(arg[3],'wb'));assert(f:write(require('json').encode({api=snap,off=off,absent=absent})));assert(f:close()) end
