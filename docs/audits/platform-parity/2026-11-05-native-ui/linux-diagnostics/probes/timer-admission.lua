local root,b=assert(loadfile(assert(arg[1])..'/bootstrap.lua'))()
local uv=require('luv')
local mode=assert(arg[2])
local log={}
package.loaded['logger.shim']=setmetatable({}, {__index=function(_,key) return function(_,fmt,...) log[#log+1]=key..':'..string.format(fmt,...) end end})
package.loaded['infra.paths']={shared=function(rel) return b..'_shared/'..rel end,shared_root=function() return b..'_shared' end,driver_root=function() return b..'linux' end}
local attempts=0
if mode=='refused' then
 package.loaded.luv=setmetatable({new_timer=function() attempts=attempts+1;return nil,'ENOMEM: not enough memory','ENOMEM' end},{__index=uv})
elseif mode=='start-refused' then
 package.loaded.luv=setmetatable({timer_start=function() attempts=attempts+1;return nil,'EINVAL: refused start','EINVAL' end},{__index=uv})
end
local Timers=require('adapters.timer_scheduler')
local schemafile=assert(io.open(b..'_shared/modules/diagnostics/schema.json','rb'))
local schema=require('json').decode(assert(schemafile:read('*a')));assert(schemafile:close())
local published={}
local snapshot_probes=require('healthcheck.snapshot').pending_probes(schema,'linux',false)
local run=require('ui.healthcheck.probes').start(schema,{}, {},function(id,result) published[#published+1]={id=id,result=result};snapshot_probes[id]=result end,{local_only=true,overrides={features=function() return {} end,path_of=function(id) return '/owned-audit-absent/'..id end,open_fn=function() return nil,'fixture absent',2 end}})
uv.run()
assert(not uv.loop_alive())
if mode~='healthy' then
 assert(attempts==1 and #published==0 and snapshot_probes.configuration.state=='pending')
 print('ADVERSE native_timer='..mode..' callbacks=0 live_handles=0 configuration_terminal=missing snapshot=pending')
 print('VISIBILITY '..table.concat(log,' | '))
else
 assert(#published==1 and published[1].id=='configuration')
 print('HEALTHY native_timer callbacks=1 configuration='..published[1].result.state..' live_handles=0')
end
run.cancel()
