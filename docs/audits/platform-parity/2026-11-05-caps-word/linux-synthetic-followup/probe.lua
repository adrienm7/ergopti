-- CapsWord audit: actual Linux manager, settings, hook, XKB adapter, emitter and writer.
local root=assert(arg[1]);local driver=root.."/static/ergopti_plus/linux";local shared=root.."/static/ergopti_plus/_shared/lua"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..shared.."/?.lua;"..shared.."/?/init.lua;"..package.path
require("test.runner_home").isolate();require("compat.utf8").install()
local Logger=require("logger.shim");Logger.set_level("trace");Logger.set_sink(function() end)
local Sandbox=require("test.config_unused_keys_contract").sandbox
local results={}
local function scenario(name,config,body,opts)
 opts=opts or {}
 local saved={};for k,v in pairs(package.loaded) do saved[k]=v end
 local ok,err=pcall(function() Sandbox.with_config(config,function(path)
  local c={now=0,deferred={},wire={},physical={},semantic={},caps=opts.initial_caps==true}
  local OriginalPaths=require("infra.config_paths");local FixturePaths={};for key,value in pairs(OriginalPaths) do FixturePaths[key]=value end;FixturePaths.config=function() return path end;package.loaded["infra.config_paths"]=FixturePaths
  package.loaded["infra.monotonic"]={now_ms=function() return c.now end,now_sec=function() return c.now/1000 end,resolution_ms=function() return opts.resolution or 0 end}
  local Loop=require("adapters.event_loop");c.original_defer=Loop.defer
  Loop.defer=function(fn,delay) c.deferred[#c.deferred+1]={fn=fn,due=c.now+delay};return true end
  function c.run_due(now) c.now=now;local pending=c.deferred;c.deferred={};for _,e in ipairs(pending) do if e.due<=now then e.fn() else c.deferred[#c.deferred+1]=e end end end
  package.loaded["adapters.xkb_capture"]=nil;local Capture=require("adapters.xkb_capture")
  Capture._set_backend({create=function() return {caps=c.caps,shift=false} end,destroy=function() end,key_sym=function(session,k) local code=k-8;local known={[29]=0xffe3,[42]=0xffe1,[58]=0xffe5,[15]=0xff09,[28]=0xff0d,[57]=0x20};if known[code] then return known[code] end;if code==30 then return (session.caps~=session.shift) and 0x41 or 0x61 elseif code==48 then return (session.caps~=session.shift) and 0x42 or 0x62 end end,
   key_utf8=function(s,k) local code=k-8;if code==30 then return (s.caps~=s.shift) and "A" or "a" elseif code==48 then return (s.caps~=s.shift) and "B" or "b" elseif code==57 then return " " end end,
   sym_utf8=function(_,sym) if sym and sym<128 then return string.char(sym) end end,update_key=function(s,k,d) if k==66 and d==1 and opts.locks~=false then s.caps=not s.caps end;if k==50 then s.shift=d~=0 end end,
   caps_locked=function(s) return s.caps end,compose_feed=function() end,compose_status=function() return "nothing" end,compose_utf8=function() end,compose_reset=function() end})
  assert(Capture.load("keymap","C"));c.capture=Capture
  for _,k in ipairs({"adapters.keyboard_hook","adapters.uinput_writer","modules.gestures.combo_emitter","modules.shortcuts.caps_word_auto_off","modules.shortcuts.manager"}) do package.loaded[k]=nil end
  local Writer=require("adapters.uinput_writer");local Input=require("infra.input_event")
  Writer._set_backend({open=function() return 42 end,ioctl=function() return true end,write=function(_,bytes) local ev=Input.decode(bytes,Input.native_size());if ev then c.wire[#c.wire+1]={type=ev.type,code=ev.code,value=ev.value} end;return true end,close=function() return true end})
  assert(Writer.open());assert(require("adapters.modifier_broker").attach(Writer));c.writer=Writer
  c.hook=require("adapters.keyboard_hook");c.auto=require("modules.shortcuts.caps_word_auto_off");c.manager=require("modules.shortcuts.manager");c.manager.init({enabled=true});c.policy=require("caps_word.auto_off")
  function c.start() return c.manager.action_handlers().caps_word("audit-caps-word") end
  function c.drive(events,physical)
   local i=0
   return c.hook._test_drive(events,{liveXkb=true,onEmitRaw=function(code,value) c.forwarded=c.forwarded or {};c.forwarded[#c.forwarded+1]={code=code,value=value};return true end,onConsume=function(detail) if c.consume then return c.consume(detail) end;return false end,
    onPhysical=function(code,key,ch,value) i=i+1;c.now=events[i].at_ms or c.now;c.physical[#c.physical+1]={code=code,value=value,at=c.now};if physical then physical(code,value,c) end end,
    onChar=function(ch) c.semantic[#c.semantic+1]={kind="text",text=ch,at=c.now};if not c.started then c.started=true;assert(c.start()==(opts.locks~=false)) else c.manager.caps_word_observe_text(ch) end end,
    onKey=function(key,detail) c.semantic[#c.semantic+1]={kind="key",key=key,at=c.now,mods=detail and detail.mods};c.manager.caps_word_observe_control(key) end},true)
  end
  function c.seed() assert(c.drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=0}})==2) end
  c.path=path;body(c)
  c.manager.cancel_caps_word("audit scenario completed");assert(not c.hook.caps_word_lock_held());assert(Writer.close())
  Loop.defer=c.original_defer
 end) end)
 for k in pairs(package.loaded) do if saved[k]==nil then package.loaded[k]=nil end end;for k,v in pairs(saved) do package.loaded[k]=v end
 assert(ok,name..": "..tostring(err))
end
local function copy(v) if type(v)~="table" then return v end;local out={};for k,item in pairs(v) do out[k]=copy(item) end;return out end
local function row(name,c,extra)
 local r={name=name,active=c.manager.is_caps_word_active(),capture_caps=c.capture.caps_locked(),pending=#c.deferred,physical=copy(c.physical),semantic=copy(c.semantic),wire=copy(c.wire),pointer_events=copy(c.pointer_rows or {}),forwarded=copy(c.forwarded or {})};for k,v in pairs(extra or {}) do r[k]=v end;results[#results+1]=r
end
-- Follow-up only: original audit fixture reused, frozen initial proof unchanged.
local function settings(key)
 return '[shortcuts.caps_word]\nidle_timeout_seconds=0\nterminators=["'..key..'"]\n[shortcuts.caps_word.pointer]\ngesture=false\npointer_motion=false\nleft_click=false\nright_click=false\nmiddle_click=false\nother_buttons=false\n'
end
local function catalogue(c)
 local G=require("modules.gestures.manager")
 G.init({enabled=false,action_handlers=require("modules.shortcuts.action_handlers").compose({},c.manager,nil),config_path=c.path})
 assert(G.is_runnable("enter") and G.is_runnable("tab"));return G
end
local function count(c,code,value)
 value=value or 1;local n=0;for _,e in ipairs(c.wire) do if e.type==1 and e.code==code and e.value==value then n=n+1 end end;return n
end
for _,key in ipairs({"enter","tab"}) do
 local code=key=="enter" and 28 or 15
 scenario("catalogue-"..key,settings(key),function(c)
  c.seed();local G=catalogue(c);local before,count_up=count(c,code),count(c,code,0)
  assert(G.execute_action(key,"audit-direct-catalogue"));assert(count(c,code)==before+1);assert(count(c,code,0)==count_up+1)
  assert(c.manager.is_caps_word_active());assert(c.capture.caps_locked())
  row("catalogue-"..key.."-checked-but-not-observed",c,{emitted_code=code,emitted_downs=count(c,code)-before,emitted_ups=count(c,code,0)-count_up})
 end)
 scenario("logical-keyboard-slot-"..key,settings(key),function(c)
  c.seed();local G=catalogue(c);local Keyboard=require("modules.shortcuts.keyboard_shortcuts")
  assert(Keyboard.set_action("primary_a",key));assert(Keyboard.get_action("primary_a")==key)
  local claims=0
  c.consume=function(detail)
   local accepted,slot=Keyboard.consume(detail,{only_script=false,defer=function(fn)c.deferred[#c.deferred+1]={fn=fn,due=c.now};return true end,admission=function() return {master=true,paused=false,inhibited=false} end})
   if accepted then claims=claims+1;assert(slot=="primary_a") end;return accepted
  end
  local before,count_up=count(c,code),count(c,code,0)
  c.drive({{type=1,code=29,value=1,at_ms=10},{type=1,code=30,value=1,at_ms=20},{type=1,code=30,value=0,at_ms=30},{type=1,code=29,value=0,at_ms=40}})
  assert(claims==1);c.run_due(40);assert(count(c,code)==before+1);assert(count(c,code,0)==count_up+1);assert(c.manager.is_caps_word_active());assert(c.capture.caps_locked())
  c.drive({{type=1,code=48,value=1,at_ms=50},{type=1,code=48,value=0,at_ms=60}});assert(c.semantic[#c.semantic].text=="B");assert(c.manager.is_caps_word_active());row("logical-keyboard-slot-"..key.."-checked-but-not-observed",c,{emitted_code=code,emitted_downs=count(c,code)-before,emitted_ups=count(c,code,0)-count_up,binding="primary_a",consumed_chords=claims,next_text=c.semantic[#c.semantic].text})
 end)
 scenario("physical-"..key,settings(key),function(c)
  c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=code,value=1},{type=1,code=code,value=0}})
  assert(not c.manager.is_caps_word_active());row("physical-"..key.."-control",c)
 end)
 scenario("literal-injector-"..key,settings(key),function(c)
  c.seed();local text=key=="enter" and "\n" or "\t"
  local Layout=require("adapters.keyboard_layout");Layout._set_table_for_test({[text]={keycode=code,level=1,mods={}}})
  local Injector=require("modules.hotstrings.injector");Injector._set_uinput(c.writer);Injector._set_nanosleep_for_test(function() end)
  local observed=0;assert(Injector.set_output_observer(function(value) observed=observed+1;c.manager.caps_word_observe_text(value) end))
  local before,count_up=count(c,code),count(c,code,0);local result=Injector.type_directly(text)
  assert(result.ok,result.error);assert(observed==1);assert(count(c,code)==before+1);assert(count(c,code,0)==count_up+1)
  assert(not c.manager.is_caps_word_active());assert(not c.capture.caps_locked())
  row("literal-injector-"..key.."-control",c,{emitted_code=code,observer_calls=observed,emitted_downs=count(c,code)-before,emitted_ups=count(c,code,0)-count_up})
 end)
 scenario("tap-engine-"..key,settings(key),function(c)
  c.seed();local G=catalogue(c)
  local Engine=require("platform.remap.tap_hold_engine")
  
  local received={}
  c.hook.set_remapper(Engine.new({keys={left_ctrl={tap_action=key,hold_modifier="ctrl",time_activation_seconds=0.2}},tap_min_ms=0,lone_tap_max_ms=0,one_shot_timeout_ms=2000}),function(action,binding)
   received[#received+1]={action=action,binding=binding};assert(G.execute_action(action,binding))
  end)
  local before,count_up=count(c,code),count(c,code,0)
  c.drive({{type=1,code=29,value=1,at_ms=10},{type=1,code=29,value=0,at_ms=80}})
  assert(#received==0);local taps=0;for _,event in ipairs(c.forwarded or {}) do if event.code==code and event.value==1 then taps=taps+1 end end;assert(taps==1)
  assert(not c.manager.is_caps_word_active());assert(not c.capture.caps_locked())
  row("tap-engine-"..key.."-semantic-relay-control",c,{emitted_code=code,hook_emitted_downs=taps,catalogue_tap_callbacks=#received})
  c.hook.set_remapper(nil)
 end)
end
scenario("qualified-ctrl-tab-control",settings("tab"),function(c)
 assert(c.capture.modifier_role(29)=="ctrl")
 c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=29,value=1},{type=1,code=15,value=1},{type=1,code=15,value=0},{type=1,code=29,value=0}})
 assert(#c.semantic==2);assert(c.semantic[2].kind=="key" and c.semantic[2].key=="tab" and c.semantic[2].mods.ctrl==true)
 assert(not c.manager.is_caps_word_active());row("qualified-ctrl-tab-control",c)
end)
scenario("qualified-shift-idle-control",settings("enter"):gsub("idle_timeout_seconds=0","idle_timeout_seconds=10"),function(c)
 assert(c.capture.modifier_role(42)=="shift")
 c.drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=0},{type=1,code=42,value=1,at_ms=9000},{type=1,code=42,value=0,at_ms=9001}})
 assert(#c.semantic==1);c.run_due(10000);assert(not c.manager.is_caps_word_active());row("qualified-shift-idle-control",c)
end)
print("CAPS_SYNTHETIC_OBSERVATIONS="..assert(require("json").encode({qualification="Actual Linux action catalogue, tap engine, Hook, CapsWord manager and injector/emitter/writer over recorded native ports. Callback is fixture forwarding matching Main's source; full Main/native receiving are not executed.",cases=results})))
