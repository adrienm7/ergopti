--- macos/tests/unit/adapters/test_physical_shortcut_hook.lua

--- Independent lifecycle/provenance/reentry controls over real physical tap code.
local helpers = require("tests.helpers")
helpers.describe("physical native tap terminal ownership", function()
	helpers.it("refuses stale admission and retains exact native cleanup ownership", function()
		local saved, old_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do saved[name] = value end
		local called, detail = xpcall(function()
local passed=0
local function eq(a,b,msg) assert(a==b,msg..' ('..tostring(a)..' ~= '..tostring(b)..')');passed=passed+1 end
local Json=require('json');local f=assert(io.open(helpers.shared('data/keycodes/physical_keys.json'),'rb'));local registry=Json.decode(f:read('*a'));f:close()
local model=require('shortcuts.physical_slots').new(registry)
local tap,callback,source_callback,constructs,executed,timers,settings
local log={}
package.loaded['infra.logger']={error=function(...) log[#log+1]={...} end}
local provenance={STATUS_FOREIGN='foreign',STATUS_OWNED='owned',STATUS_UNREADABLE='unreadable'}
function provenance.classify_with_fence(event) return event.owned and {} or nil,event.status or 'foreign',event.fence end
package.loaded['adapters.event_provenance']=provenance
local Timer={}
function Timer.after(_,fn)
 local timer={fn=fn};timers[timer]=true
 if settings.early then fn() end
 if settings.schedule_pause then settings.owner.stop() end
 return timer,not settings.arm_refused
end
function Timer.onSettled(timer,fn) timer.settled=fn;return not settings.observe_refused end
function Timer.cancel(timer)
 if settings.cancel_refused then return false end
 timers[timer]=nil;if timer.settled then timer.settled() end;return true
end
package.loaded['adapters.timer_scheduler']=Timer
local Broker={}
function Broker.subscribe(_,fn) source_callback=fn;if settings.subscribe_stop then settings.owner.stop() end;return not settings.subscribe_refused end
function Broker.unsubscribe() if settings.unsubscribe_refused then return false end;source_callback=nil;return true end
package.loaded['adapters.input_source_broker']=Broker
hs={eventtap={event={types={keyDown=10}}}}
function hs.eventtap.new(_,fn)
 constructs=constructs+1;callback=fn
 tap={active=false,start=function(self) self.active=true;if settings.start_stop then settings.owner.stop() end;return self end,stop=function(self) if not settings.stop_refused then self.active=false end;return self end,isEnabled=function(self) return self.active end}
 return tap
end
local factory=assert(loadfile(helpers.driver_root() .. '/adapters/physical_shortcut_hook.lua'))()
local function fresh(rows,flags)
 settings=flags or {};tap=nil;callback=nil;source_callback=nil;constructs=0;executed=0;timers={};log={}
 local owner=factory.new(model);settings.owner=owner
 local admission=true
 local options={assignments=rows or {physical_none_KeyJ='send_text'},admitted=function() return admission end,
 action=function(slot) return (rows or {physical_none_KeyJ='send_text'})[slot] end,conflicts=function() return settings.conflict==true end,
 execute=function() executed=executed+1;return true end}
 return owner,options,function(value) admission=value end
end
local function event(flags,extra)
 local value={getKeyCode=function() return 38 end,getFlags=function() return flags or {} end}
 for k,v in pairs(extra or {}) do value[k]=v end;return value
end
local function deliver()
 local jobs={};for timer in pairs(timers) do jobs[#jobs+1]=timer end
 for _,timer in ipairs(jobs) do timer.fn();timers[timer]=nil;if timer.settled then timer.settled() end end
end
local owner,options,pause=fresh();eq(owner.start(options),true,'Stable bare physical slot starts');eq(owner.is_started(),true,'Exact tap enabled');eq(callback(event()),true,'Physical position is consumed after queue acknowledgement');eq(executed,0,'Action deferred');deliver();eq(executed,1,'One delivery')
for _,extra in ipairs({{owned=true,status='owned'},{status='unreadable'}}) do eq(callback(event({},extra)),false,'Own output and unreadable events stay native') end
eq(callback(event({ctrl=true})),false,'Exact modifier set required');eq(callback(event({fn=true})),false,'Fn unsupported');eq(callback(event({ctrl='yes'})),false,'Malformed modifier proof refused')
settings.conflict=true;eq(callback(event()),false,'Existing owner wins conflict');settings.conflict=false
pause(false);eq(callback(event()),false,'Paused owner passes native');pause(true)
eq(callback(event()),true,'Queue before pause');pause(false);deliver();eq(executed,1,'Deferred pause fence');pause(true)
eq(callback(event()),true,'Queue before source transition');source_callback();deliver();eq(executed,1,'Source transition cancels queued callback')
eq(owner.stop(),true,'Tap broker timers acknowledge stop');eq(owner.has_debt(),false,'Exact resources retired');eq(callback(event()),false,'Retired callback inert')
owner,options=fresh({});eq(owner.start(options),true,'Empty defaults start without resources');eq(constructs,0,'No native resources for empty defaults')
owner,options=fresh({physical_none_KeyJ='none'});eq(owner.start(options),true,'None reserves native behavior');eq(constructs,0,'None creates no hook')
for _,slot in ipairs({'physical_none_Backquote','physical_none_IntlBackslash','physical_none_AudioVolumeUp','physical_ctrl_ctrl_KeyJ'}) do owner,options=fresh({[slot]='send_text'});eq(owner.start(options),false,'Unavailable or malformed slot refuses whole admission');eq(constructs,0,'Refusal precedes native allocation') end
for _,flags in ipairs({{arm_refused=true},{observe_refused=true},{early=true}}) do owner,options=fresh(nil,flags);eq(owner.start(options),true,'Hook starts for scheduler refusal test');eq(callback(event()),false,'Unacknowledged queue keeps native input');deliver();eq(executed,0,'Refused queue cannot execute');eq(owner.stop(),true,'Scheduler refusal cleaned') end
for _,flags in ipairs({{start_stop=true},{subscribe_stop=true}}) do owner,options=fresh(nil,flags);eq(owner.start(options),false,'Reentrant stop prevents start commitment');eq(owner.has_debt(),false,'Outer rollback retires exact reentrant resources');eq(callback(event()),false,'Reentrant retired callback inert') end
owner,options=fresh(nil,{stop_refused=true});eq(owner.start(options),true,'Start for native retirement refusal');eq(owner.stop(),false,'Native stop refusal retains exact tap');eq(owner.has_debt(),true,'Native uncertainty retained');eq(callback(event()),false,'Retained native tap fenced');settings.stop_refused=false;eq(owner.stop(),true,'Retry retires same actual tap')
owner,options=fresh(nil,{cancel_refused=true});eq(owner.start(options),true,'Start for queued retirement refusal');eq(callback(event()),true,'Pending action exists');eq(owner.stop(),false,'Timer refusal retained');deliver();eq(executed,0,'Retained timer callback fenced');settings.cancel_refused=false;eq(owner.stop(),true,'Settlement permits retry')
owner,options=fresh(nil,{schedule_pause=true});eq(owner.start(options),true,'Start before timer allocation reentrancy');eq(callback(event()),false,'Pause during allocation prevents suppression');deliver();eq(executed,0,'Allocation pause fences queued action');eq(owner.stop(),true,'Reentrant timer cleanup settled')
owner,options=fresh();local nested
options.execute=function()
 executed=executed+1
 nested=callback(event({}, {owned=true,status='owned'}))
 return true
end
eq(owner.start(options),true,'Start for own Unicode recursion control');eq(callback(event()),true,'Real input queues output action');deliver();eq(nested,false,'Action output cannot recursively queue itself');eq(executed,1,'Synthetic action output executes once');eq(owner.stop(),true,'Recursion control retires')
owner,options=fresh();options.action=function() error('controlled action reader refusal') end;eq(owner.start(options),true,'Start for action reader refusal');eq(callback(event()),false,'Reader exception keeps input native');eq(owner.stop(),true,'Reader refusal retirement')
owner,options=fresh();eq(owner.start(options),true,'Start before deferred reader refusal');eq(callback(event()),true,'Queue while action reader acknowledged');options.action=function() error('controlled deferred reader refusal') end;deliver();eq(executed,0,'Deferred reader exception cancels delivery');eq(owner.stop(),true,'Deferred reader refusal retirement')
for _,seam in ipairs({'admitted','action','conflicts'}) do
 owner,options=fresh();local activate=false;local stop=owner.stop
 local original=options[seam]
 options[seam]=function(...) local result=original(...);if activate then activate=false;stop() end;return result end
 eq(owner.start(options),true,'Start for terminal '..seam..' callback invalidation')
 eq(callback(event()),true,'Queue before '..seam..' callback invalidation')
 activate=true;deliver();eq(executed,0,'Terminal '..seam..' callback stop cannot dispatch an old record');eq(owner.stop(),true,'Reentrant '..seam..' cleanup settled')
end
print('Independent Mac physical hook: '..passed..' passed; controlled Quartz ports, no device proof')

		end, debug.traceback)
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		_G.hs = old_hs
		if not called then error(detail, 0) end
	end)
end)
