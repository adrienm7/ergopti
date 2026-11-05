-- Audit fixture: existing native-port harness with actual settings/menu/watchers owners.
local repository = assert(arg[1], "repository root required")
local driver = repository .. "/static/ergopti_plus/macos"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/tests/stubs/?.lua;" .. repository .. "/static/ergopti_plus/_shared/lua/?.lua;" .. repository .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
_G.hs = require("hs")
local path = driver .. "/tests/unit/platform/remap/watchers/test_watchers_capsword_auto_off.lua"
local file = assert(io.open(path, "rb")); local source = file:read("*a"); file:close()
local marker = '\nhelpers.describe("CapsWord watcher:'
local stop = assert(source:find(marker, 1, true), "fixture boundary must exist")
local factory = assert(load(source:sub(1, stop - 1) .. "\nreturn fresh_harness, activate, key, pointer, timers_at", "@capsword-native-port-fixture", "t"))
local fresh, activate, key, pointer, timers_at = factory()
local observations = {}
local function due(h, target)
 h.clock = target
 local progress = true
 local iterations = 0
 while progress do
  progress = false
  for _,timer in ipairs(h.timers) do
   if not timer.cancelled and not timer.audit_fired and timer.audit_due <= target then
    timer.audit_fired = true
    timer.callback()
    progress = true
   end
  end
  iterations = iterations + 1
  assert(iterations < 100, "timer drain must remain bounded")
 end
end
local function fixture(initial)
 local h = fresh({ caps_word_idle_timeout_seconds = initial,
  caps_word_pointer_gesture=false,caps_word_pointer_pointer_motion=false,
  caps_word_pointer_left_click=false,caps_word_pointer_right_click=false,
  caps_word_pointer_middle_click=false,caps_word_pointer_other_buttons=false })
 for _,enabled in pairs(h.settings.policy().pointer) do assert(enabled==false) end
 local scheduler = package.loaded["adapters.timer_scheduler"]
 local original_after = scheduler.after
 scheduler.after = function(delay, callback)
  local handle, committed = original_after(delay, callback)
  handle.audit_due = h.clock + delay
  return handle, committed
 end
 h.state = h.settings.current_values()
 h.saves, h.updates = 0, 0
 package.loaded["ui.menu.menu_caps_word"] = nil
 h.menu = require("ui.menu.menu_caps_word")
 h.context = { state=h.state, state_getters={}, applyTriggerChar=function(text) return text end,
  save_prefs=function() h.saves=h.saves+1;return h.save_result ~= false end,
  updateMenu=function() h.updates=h.updates+1 end }
 h.menu_rows = assert(h.menu.build(h.context))
 activate(h)
 return h
end
local function all_rows(rows, out)
 out=out or {}
 for _,row in ipairs(rows) do
  out[#out+1]=row
  if type(row.menu)=="table" then all_rows(row.menu,out) end
 end
 return out
end
local function set_timeout(h, value)
 local i18n=require("infra.i18n")
 local label = value==0 and i18n.get("menu.caps_word.idle_timeout_never") or tostring(value) .. " " .. i18n.get("menu.caps_word.idle_timeout_unit")
 for _,row in ipairs(all_rows(h.menu_rows)) do
  if row.title==label then assert(type(row.fn)=="function"); row.fn(); return end
 end
 error("missing menu preset: " .. label)
end
local function note(name,h)
 assert(#h.logged_errors==0,table.concat(h.logged_errors," | "))
 local pending=0
 for _,timer in ipairs(h.timers) do if not timer.cancelled and not timer.audit_fired then pending=pending+1 end end
 observations[#observations+1]={name=name,active=h.active,idle_ms=h.settings.policy().idle_ms,pending_timers=pending,clear_calls=h.supersede_calls,saves=h.saves,updates=h.updates}
 assert(h.watchers.stop_gesture_watcher(h.watcher)==true)
end
local h=fixture(0)
assert(#h.timers==0)
note("zero-never-positive-control",h)
h=fixture(1)
due(h,1001)
assert(not h.active and h.supersede_calls==1)
note("one-second-positive-control",h)
h=fixture(0)
h.clock=1000.1;set_timeout(h,1)
assert(h.settings.policy().idle_ms==1000 and h.saves==1 and h.updates==1)
h.clock=1000.2;key(h,"a")
due(h,1002)
assert(h.active and h.supersede_calls==0 and #h.timers==0)
note("menu-zero-to-one-after-next-key-still-no-timer",h)
h=fixture(10)
h.clock=1000.1;set_timeout(h,1)
h.clock=1000.2;key(h,"a")
due(h,1002)
assert(h.active and h.supersede_calls==0)
observations[#observations+1]={name="menu-ten-to-one-overdue",active=h.active,clock=h.clock,last_keystroke=1000.2,clear_calls=h.supersede_calls}
due(h,1010)
assert(not h.active and h.supersede_calls==1)
note("menu-ten-to-one-finally-original-timer",h)
h=fixture(1)
h.clock=1000.1;set_timeout(h,0)
due(h,1002)
assert(h.active and h.supersede_calls==0)
note("menu-one-to-zero-takes-effect-at-existing-check",h)
h=fixture(1)
h.clock=1000.1;set_timeout(h,10)
due(h,1001)
assert(h.active and h.supersede_calls==0)
due(h,1010)
assert(not h.active and h.supersede_calls==1)
note("menu-one-to-ten-rearms-longer-check",h)
h=fixture(1)
set_timeout(h,0);due(h,1001)
set_timeout(h,1);h.clock=1001.1;key(h,"b");due(h,1003)
assert(h.active and h.supersede_calls==0)
note("menu-one-to-zero-to-one-clock-lost",h)
h=fixture(0)
h.save_result=false;set_timeout(h,1)
assert(h.settings.policy().idle_ms==nil and h.state.caps_word_idle_timeout_seconds==0 and h.updates==0)
note("menu-save-refusal-rolls-back",h)
h=fixture(0)
local comma
for _,row in ipairs(all_rows(h.menu_rows)) do if row.title==require("infra.i18n").get("terminators.label_comma") then comma=row end end
assert(comma and type(comma.fn)=="function");comma.fn()
key(h,",")
assert(not h.active and h.supersede_calls==1)
note("menu-delimiter-change-live-positive-control",h)
h=fixture(0)
set_timeout(h,1)
activate(h)
assert(#timers_at(h,1)==1)
due(h,1001)
assert(not h.active and h.supersede_calls==1)
note("next-activation-acquires-new-timeout-positive-control",h)
local encoded=assert(require("adapters.json_codec").encode(observations));print(encoded)
