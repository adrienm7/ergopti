-- Audit fixture: actual settings/policy/watcher/output relay, with recorded native ports.
local repository=assert(arg[1],"repository root required")
local driver=repository.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local file=assert(io.open(driver.."/tests/unit/platform/remap/watchers/test_watchers_capsword_auto_off.lua","rb"));local source=file:read("*a");file:close()
local stop=assert(source:find('\nhelpers.describe("CapsWord watcher:',1,true))
local fresh,activate,key=assert(load(source:sub(1,stop-1).."\nreturn fresh_harness,activate,key","@capsword-payload-native-fixture","t"))()
local rows={}
local function observe(name,h)
 rows[#rows+1]={name=name,active=h.active,writes=#h.writers,led_requests=#h.capslock,timers=#h.timers,idle_ms=h.settings.policy().idle_ms}
 assert(h.watchers.stop_gesture_watcher(h.watcher))
end
for _,seconds in ipairs({0,0.0001,0.001}) do
 local h=fresh({shipped=true,caps_word_idle_timeout_seconds=seconds})
 activate(h)
 if seconds==0 then assert(#h.timers==0 and h.settings.policy().idle_ms==nil)
 elseif seconds==0.0001 then
  assert(h.settings.policy().idle_ms==0 and #h.timers==1 and h.timers[1].delay==0)
  h.timers[1].callback();assert(not h.active and #h.writers==1)
 else
  assert(h.settings.policy().idle_ms==1 and h.timers[1].delay==0.001)
  h.clock=h.clock+0.002;h.timers[1].callback();assert(not h.active)
 end
 observe("idle-activation-"..tostring(seconds),h)
end
for _,case in ipairs({{"letters","abc",true},{"nbsp","\xC2\xA0",false},{"nnbsp","\xE2\x80\xAF",false},{"multi-scalar","mot\xC2\xA0;",false},{"carriage-return","\r",false},{"line-feed","\n",false},{"tab","\t",false},{"etx-payload","\3",true}}) do
 local h=fresh({shipped=true,caps_word_idle_timeout_seconds=0});activate(h);key(h,case[2]);assert(h.active==case[3]);observe("typed-"..case[1],h)
end
for _,accepted in ipairs({true,false}) do
 local h=fresh({shipped=true,caps_word_idle_timeout_seconds=0});activate(h)
 local emitted={}
 package.loaded["adapters.synthetic_input"].emit_key_strokes=function(text) emitted[#emitted+1]=text;return accepted end
 package.loaded["adapters.text_sender"]=nil
 local sender=require("tests.helpers").load_with_stubs("adapters.text_sender",{eventtap={keyStroke=function() end,keyStrokes=function() end}})
 assert(sender.send("mot\xE2\x80\xAF;",{mode="direct"})==accepted)
 assert(#emitted==1 and h.active==not accepted)
 observe("direct-text-sender-accepted-"..tostring(accepted),h)
end
local h=fresh({caps_word_idle_timeout_seconds=0});activate(h)
require("infra.capsword_output").report("")
require("infra.capsword_output").report(false)
assert(h.active and #h.writers==0)
observe("empty-invalid-output-relay-control",h)
local encoded=assert(require("adapters.json_codec").encode(rows));print(encoded)
