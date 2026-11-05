local root,b=assert(loadfile(assert(arg[1])..'/bootstrap.lua'))()
local fakecurl=assert(arg[2])
local uv=require('luv')
local log={}
package.loaded['logger.shim']=setmetatable({}, {__index=function(_,key) return function(_,fmt,...) log[#log+1]=key..':'..string.format(fmt,...) end end})
package.loaded['infra.paths']={shared=function(rel) return b..'_shared/'..rel end,shared_root=function() return b..'_shared' end,driver_root=function() return b..'linux' end}
local programs=require('infra.owned_programs')
local program_path=programs.path
programs.path=function(name,...) if name=='curl' then return fakecurl end return program_path(name,...) end
package.loaded['adapters.storage']={get=function(key) assert(key=='network.proxy_override');return 'direct' end}
local Http=require('adapters.http_client')
local get=Http.get
local receipts={}
local targets={}
Http.get=function(url,headers,options,callback)
 targets[#targets+1]=url
 return get(url,headers,options,function(result)
  receipts[#receipts+1]=result
  callback(result)
 end)
end
package.loaded['adapters.shell_runner']={HAS_ASYNC=false}
package.loaded['adapters.timer_scheduler']={HAS_ASYNC=false}
local schemafile=assert(io.open(b..'_shared/modules/diagnostics/schema.json','rb'))
local schema=require('json').decode(assert(schemafile:read('*a')));assert(schemafile:close())
local answers={}
local run=require('ui.healthcheck.probes').start(schema,{}, {llm={is_enabled=function() return true end,get_base_url=function() return 'http://127.0.0.1:11435' end,get_backend=function() return arg[4] or 'ollama' end}},function(id,result,sections) answers[id]={result=result,sections=sections} end)
uv.run()
assert(not uv.loop_alive(),'all native helper handles closed')
assert(#receipts==2)
local adverse=arg[3]=='partial'
local refusal=arg[3]=='refused'
for _,r in ipairs(receipts) do
 assert(r.status==(refusal and 503 or 200))
 if adverse then assert(r.ok==false and r.body=='' and r.error:find('18',1,true)) elseif refusal then assert(r.ok==false) else assert(r.ok==true) end
end
assert(answers.github_api.result.state==(refusal and 'error' or 'ok') and answers.ai_health.result.state==(refusal and 'error' or 'ok'))
print((adverse and 'ADVERSE' or (refusal and 'REFUSAL' or 'HEALTHY'))..' native_curl_ok='..tostring(receipts[1].ok)..' status='..receipts[1].status..' github='..answers.github_api.result.state..' ai='..answers.ai_health.result.state..' closed=true')
if arg[4]=='api' then
 assert(targets[2]=='http://127.0.0.1:11435/api/version' and answers.ai_health.result.state=='ok')
 print('ADVERSE AI_TARGET input_backend=api actual_target='..targets[2]..' state='..answers.ai_health.result.state)
end
if adverse then print('VISIBILITY '..table.concat(log,' | ')) end
