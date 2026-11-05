-- Audit fixture: actual KeVariables and watcher owners over recorded native ports.
local repository=assert(arg[1],"repository root required")
local driver=repository.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local file=assert(io.open(driver.."/tests/unit/platform/remap/ke_lifecycle/test_ke_variables_serialized_batches.lua","rb"))
local source=file:read("*a");file:close()
local stop=assert(source:find("\nhelpers.describe(",1,true))
local fresh_bridge,task_values=assert(load(source:sub(1,stop-1).."\nreturn fresh_bridge,task_values","@capsword-real-writer-native-fixture","t"))()
local helpers=require("tests.helpers")
local TOKEN="0123456789abcdef0123456789abcdef"
local TYPES={mouseMoved=1,scrollWheel=2,gesture=3,leftMouseDown=4,rightMouseDown=5,otherMouseDown=6,keyDown=7}
local observations={}
local function fixture()
 local ke,h=fresh_bridge()
 h.clock=1000;h.capslock={}
 package.loaded["infra.logger"].done=function() end
 package.loaded["infra.logger"].success=function() end
 package.loaded["infra.capsword_auto_off"]=nil
 local settings=require("infra.capsword_auto_off")
 local state=settings.current_values();state.caps_word_idle_timeout_seconds=0
 assert(settings.apply_state(state))
 local scheduler=package.loaded["adapters.timer_scheduler"]
 scheduler.now_ns=function() return h.clock*1000000000 end
 local logger=package.loaded["infra.logger"]
 logger.pcall=function(module,fn,...)
  local results=table.pack(pcall(fn,...))
  if not results[1] then logger.error(module,"Exception: %s",tostring(results[2])) end
  return table.unpack(results,1,results.n)
 end
 package.loaded["adapters.key_state"]={set_capslock=function(value) h.capslock[#h.capslock+1]=value end}
 package.loaded["modules.keymap.control_sentinels"]=nil
 package.loaded["adapters.synthetic_input"]={defer_after_callback=function(_label,fn) fn();return true end}
 h.sentinels=require("modules.keymap.control_sentinels")
 h.watchers=helpers.load_with_stubs("platform.remap.watchers",{eventtap={new=function(types,callback) h.callback=callback;return {start=function() return true end,stop=function() return true end} end,event={types=TYPES,properties={mouseEventButtonNumber=3}}}})
 h.watcher=assert(h.watchers.start_gesture_watcher(nil,TOKEN))
 h.ke=ke
 return h
end
local function activate(h)
 assert(h.sentinels.claim_key(90,true,{ctrl=true,alt=true,shift=true})==true)
 assert(h.ke.capsword_known_active())
 h.engine["ergopti_capsword_"..TOKEN]=1
end
local function event(h,kind,button)
 h.callback({getType=function() return kind end,getProperty=function() return button end,getCharacters=function() return " " end})
end
local function record(h,name)
 for _,line in ipairs(h.logs) do assert(line.level~="error",line.message) end
 observations[#observations+1]={name=name,active=h.ke.capsword_known_active(),writer_tasks=#h.tasks,led_writes=#h.capslock,clock=h.clock}
 assert(h.watchers.stop_gesture_watcher(h.watcher))
end
for _,kind in ipairs({TYPES.leftMouseDown,TYPES.rightMouseDown,TYPES.otherMouseDown,TYPES.gesture,TYPES.scrollWheel}) do
 local h=fixture()
 event(h,TYPES.mouseMoved)
 assert(#h.tasks==0 and not h.ke.capsword_known_active())
 h.clock=1000.01;activate(h)
 h.clock=1000.05;event(h,kind,2)
 assert(h.ke.capsword_known_active() and #h.tasks==0 and #h.capslock==0)
 record(h,"inactive-motion-then-activation-then-early-pointer-"..kind)
end
local h=fixture()
activate(h);h.clock=1000.05;event(h,TYPES.leftMouseDown)
assert(not h.ke.capsword_known_active() and #h.tasks==1)
h.apply(1)
assert(#h.capslock==1 and h.capslock[1]==false)
record(h,"fresh-activation-click-without-prior-motion-control")
h=fixture();event(h,TYPES.mouseMoved);h.clock=1000.01;activate(h)
h.clock=1000.1;event(h,TYPES.leftMouseDown)
assert(not h.ke.capsword_known_active() and #h.tasks==1)
h.apply(1)
record(h,"click-at-100ms-throttle-boundary-control")
h=fixture();event(h,TYPES.mouseMoved);h.clock=1000.01;activate(h)
h.clock=1000.05;event(h,TYPES.keyDown)
assert(not h.ke.capsword_known_active() and #h.tasks==1 and #h.capslock==1)
h.apply(1)
record(h,"typed-delimiter-bypasses-pointer-throttle-control")
h=fixture();activate(h);event(h,TYPES.leftMouseDown)
assert(not h.ke.capsword_known_active() and #h.tasks==1)
-- The native writer publishes zero, but its exit callback is still queued.
-- Only now does the deployed variable_unless graph permit a fresh activation.
assert(task_values(h,1)["ergopti_capsword_"..TOKEN]==0)
h.engine["ergopti_capsword_"..TOKEN]=0
h.clock=1000.2;activate(h)
assert(h.engine["ergopti_capsword_"..TOKEN]==1)
h.clock=1000.3;event(h,TYPES.keyDown)
assert(h.ke.capsword_known_active() and #h.tasks==1 and #h.capslock==0)
observations[#observations+1]={name="new-activation-delimiter-lost-while-old-clear-pending",active=h.ke.capsword_known_active(),writer_tasks=#h.tasks,led_writes=#h.capslock,clock=h.clock}
h.complete(1)
assert(h.engine["ergopti_capsword_"..TOKEN]==1)
assert(h.ke.capsword_known_active() and #h.capslock==0)
observations[#observations+1]={name="old-clear-settled-new-activation-retained-control",active=h.ke.capsword_known_active(),writer_tasks=#h.tasks,led_writes=#h.capslock}
h.clock=1000.4;event(h,TYPES.keyDown)
assert(not h.ke.capsword_known_active() and #h.tasks==2 and #h.capslock==1)
h.apply(2)
record(h,"later-delimiter-after-settlement-clears-control")
for _,row in ipairs(observations) do
 print(row.name,"active="..tostring(row.active),"tasks="..row.writer_tasks,"led_writes="..row.led_writes)
end
