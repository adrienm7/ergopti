local base='/workspace/ergopti/static/ergopti_plus/'
package.path=base..'linux/?.lua;'..base..'linux/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
package.loaded['logger.shim']=setmetatable({}, {__index=function() return function() end end})
local runtime={ capture_runtime_response=function() return {} end, runtime_response_current=function() return true end }
package.loaded['modules.llm.prediction_engine']=runtime
local requests={}
package.loaded['adapters.http_client']={postStream=function(_,_,body,_,chunk,done)
    requests[#requests+1]={body=body,chunk=chunk,done=done}
    return true
end,cancel=function() return true end}
local api=require('modules.llm.api_ollama')
local observed={}
local function start(name,done)
    return api.chat('http://127.0.0.1:11434','fixture',{}, {stream=true},nil,function(text,err)
        observed[#observed+1]={name=name,text=text,error=err}
        if done then done(text,err) end
    end)
end
assert(start('A',function(_,err) if err=='cancelled' then assert(start('C')) end end))
assert(start('B'))
assert(#requests==3)
requests[2].chunk('{"message":{"content":"C-result"},"done":true}\n')
requests[2].done({ok=true,status=200})
requests[3].chunk('{"message":{"content":"B-result"},"done":true}\n')
requests[3].done({ok=true,status=200})
for _,row in ipairs(observed) do print('REENTRY',row.name,row.text,row.error) end
local c=0
for _,row in ipairs(observed) do if row.name=='C' then c=c+1 end end
assert(c==0,'C lost its terminal completion when B clobbered successor ownership')
