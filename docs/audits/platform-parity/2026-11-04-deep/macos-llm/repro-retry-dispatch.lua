local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local helpers = require('tests.helpers')
local function set(fn, target, value)
  for i=1,100 do local name=debug.getupvalue(fn,i); if not name then break end
    if name==target then debug.setupvalue(fn,i,value); return true end
  end
  return false
end
local common = { DEFAULT_TEMPERATURE=.5, new_dedup_stats=function() return {} end,
  get_diversity_temperature=function(base) return base end,
  insert_prediction=function(results,pred) results[#results+1]=pred; return true end,
  log_prediction_summary=function() end,
  protected_call=function(cb,_,...) if type(cb)=='function' then return cb(...) end end }
for _,backend in ipairs({'ollama','remote','mlx'}) do
 local name = backend=='mlx' and 'modules.llm.api_mlx_fetch' or 'modules.llm.api_'..backend
 local m=helpers.load_with_stubs(name)
 local f=m.fetch_sequential
 assert(set(f,'ApiCommon',common))
 assert(set(f,'Profiles',{resolve_system_prompt=function() return 'system' end}))
 assert(set(f,'TimerScheduler',{now=function() return 0 end}))
 local calls,partials={},{}
 local always_fail=false
 local function post(kind,...)
   local a={...}; calls[#calls+1]={kind=kind,tokens=a[6],temp=a[5],partial=type(a[12])=='function'}
   if always_fail then a[10](); return end
   if #calls==1 then
     if type(a[12])=='function' then a[12]('old partial') end
     a[10](); return
   end
   if type(a[12])=='function' then a[12]('replacement partial from retry') end
   a[9]({{to_type='finished'}})
 end
 local plain=function(...) return post('plain',...) end
 local stream=function(...) return post('stream',...) end
 if backend=='mlx' then m.init({post_and_parse=plain,post_and_parse_streaming=stream,dedup_enabled=false})
 else assert(set(f,'post_and_parse',plain)); if backend=='ollama' then assert(set(f,'post_and_parse_streaming',stream)) end end
 local keys=backend=='remote' and {'RETRY_FAILED_PREDICTION','RETRY_FAILED_MAX_MULT','_R_EXTRA_TOKENS','_R_TEMP_STEP'}
   or {'RETRY_FAILED_PREDICTION_ENABLED','RETRY_FAILED_PREDICTION_MAX_MULTIPLIER','_RETRY_EXTRA_TOKENS','_RETRY_TEMP_STEP'}
 for i,v in ipairs({true,2,5,.18}) do assert(set(f,keys[i],v),keys[i]) end
 local success=0
 m.fetch_sequential('full','tail','model',.5,20,1,{},function() success=success+1 end,function()end,function()return 1 end,true,function(text) partials[#partials+1]=text end)
 print(backend..' retry: '..calls[1].kind..' -> '..calls[2].kind..', tokens='..calls[1].tokens..'/'..calls[2].tokens..', partial callbacks='..#partials)
 assert(#calls==2 and calls[2].tokens==25)
 if backend~='remote' then assert(calls[2].kind=='stream' and #partials==2) end
 calls={}; always_fail=true
 m.fetch_sequential('full','tail','model',.5,20,1,{},function()end,function()end,function()return 1 end,false,nil)
 print(backend..' all-failure requests for requested=1 multiplier=2: '..#calls)
 assert(#calls==4)
end
