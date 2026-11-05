-- Real Linux libuv wall time around actual Lua approval state machine; no Darwin qualification.
local root=assert(arg[1]);assert(root:sub(1,1)=='/')
local mac=root..'/static/ergopti_plus/macos'
package.path=mac..'/?.lua;'..mac..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..package.path
package.loaded['infra.logger']=setmetatable({},{__index=function()return function()end end})
local uv=require('luv');local Watch=require('platform.remap.runtime_approval_watch')
-- Scaled exported configuration: 1s budget and 250ms polls/listings, rather than waiting 35 minutes.
Watch.APPROVAL_TIMEOUT_SEC=1;Watch.APPROVAL_POLL_SEC=.25
local retained={};local function later(ms,fn)
 local timer=assert(uv.new_timer());retained[timer]=true
 timer:start(ms,0,function()timer:stop();timer:close();retained[timer]=nil;fn()end)
 return timer
end
local started=uv.hrtime();local after_budget
local watch=Watch.new({listing=function(cb)later(250,function()cb('1 extension(s)\n')end)end,
 after=function(sec,fn)return later(sec*1000,fn),true end,cancel=function(t)if not t:is_closing()then t:stop();t:close();retained[t]=nil end end,
 open_settings=function()return true end,reload=function()error('no approved extension')end,version=function()return '8.5.0' end})
assert(watch.start())
later(1100,function()after_budget=watch.active();print('actual_elapsed_ms_at_checkpoint='..((uv.hrtime()-started)/1e6)..' watch_active='..tostring(after_budget))end)
uv.run()
local elapsed=(uv.hrtime()-started)/1e9
assert(after_budget==true);assert(elapsed>2 and elapsed<5);assert(not watch.active());assert(next(retained)==nil)
print('scaled_declared_budget_s=1 actual_elapsed_s='..elapsed..' loops_exhausted_without_approval=true')
