-- Original shared logger formatter; recorded sink, no native log transport.
local root=assert(arg[1],"Pass repository root")
package.path=root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
local logger=require("logger")
local lines={}
logger.set_sink(function(line) lines[#lines+1]=line end)
logger.timestamp_fn=function() return "recorded-time" end
logger.clock_fn=function() return 10 end
local rows={}
for _,input in ipairs({{"nan",0/0},{"positive-infinity",math.huge}}) do
 logger.reset_dedup()
 local called,result=pcall(logger.debug,"domain-probe","Sticky timeout: %d ms.",input[2])
 assert(called and type(result)=="string")
 rows[#rows+1]={name=input[1],called=called,result=result}
end
print(assert(require("json").encode(rows)))
