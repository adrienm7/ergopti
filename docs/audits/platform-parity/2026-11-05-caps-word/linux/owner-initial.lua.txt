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
  package.loaded["infra.config_paths"]={config=function() return path end}
  package.loaded["infra.monotonic"]={now_ms=function() return c.now end,now_sec=function() return c.now/1000 end,resolution_ms=function() return opts.resolution or 0 end}
  local Loop=require("adapters.event_loop");c.original_defer=Loop.defer
  Loop.defer=function(fn,delay) c.deferred[#c.deferred+1]={fn=fn,due=c.now+delay};return true end
  function c.run_due(now) c.now=now;local pending=c.deferred;c.deferred={};for _,e in ipairs(pending) do if e.due<=now then e.fn() else c.deferred[#c.deferred+1]=e end end end
  package.loaded["adapters.xkb_capture"]=nil;local Capture=require("adapters.xkb_capture")
  Capture._set_backend({create=function() return {caps=c.caps,shift=false} end,destroy=function() end,key_sym=function() return nil end,
   key_utf8=function(s,k) local code=k-8;if code==30 then return (s.caps~=s.shift) and "A" or "a" elseif code==48 then return (s.caps~=s.shift) and "B" or "b" elseif code==57 then return " " end end,
   sym_utf8=function() end,update_key=function(s,k,d) if k==66 and d==1 and opts.locks~=false then s.caps=not s.caps end;if k==50 then s.shift=d~=0 end end,
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
   return c.hook._test_drive(events,{liveXkb=true,onEmitRaw=function() return true end,
    onPhysical=function(code,key,ch,value) i=i+1;c.now=events[i].at_ms or c.now;c.physical[#c.physical+1]={code=code,value=value,at=c.now};if physical then physical(code,value,c) end end,
    onChar=function(ch) c.semantic[#c.semantic+1]={kind="text",text=ch,at=c.now};if not c.started then c.started=true;assert(c.start()==(opts.locks~=false)) else c.manager.caps_word_observe_text(ch) end end,
    onKey=function(key) c.semantic[#c.semantic+1]={kind="key",key=key,at=c.now};c.manager.caps_word_observe_control(key) end},true)
  end
  function c.seed() assert(c.drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=0}})==2) end
  function c.pointer(ev)
   local dispatch
   for i=1,80 do local name,value=debug.getupvalue(c.hook.pump,i);if not name then break end;if name=="_dispatch_pointer" then dispatch=value;break end end
   assert(dispatch and debug.getinfo(dispatch,"S").source=="@"..driver.."/adapters/keyboard_hook.lua")
   c.pointer_rows=c.pointer_rows or {}
   -- Recorded callback port, not Main's production closure. Main forwarding is source-audited separately.
   local function observer(kind,code,value)
    c.pointer_rows[#c.pointer_rows+1]={kind=kind,code=code,value=value}
    if kind~="frame" then c.manager.caps_word_observe_pointer_event(kind,code) end
   end
   for i=1,30 do local name=debug.getupvalue(dispatch,i);if not name then break end;if name=="_on_pointer_event" then debug.setupvalue(dispatch,i,observer) elseif name=="_on_click" then debug.setupvalue(dispatch,i,function() end) end end
   dispatch(ev,nil)
  end
  function c.menu_rows()
   require("ui.menu.builder") -- Owns the production global translation helper.
   local Menu=require("ui.menu.menu_shortcuts");local Facade=require("infra.manifest_menu")
   local original=Facade.build;local rows
   Facade.build=function(id,title,handlers,groups,...)
    if id=="shortcuts_menu" then assert(type(groups.caps_word_auto_off)=="function");rows=groups.caps_word_auto_off();return {} end
    return original(id,title,handlers,groups,...)
   end
   local called,err=pcall(Menu.build,{shortcuts=c.manager,commands={},state_getters={},on_menu_changed=function() c.menu_changes=(c.menu_changes or 0)+1 end})
   Facade.build=original;assert(called,err);assert(rows and #rows>0);return rows
  end
  function c.menu_find(rows,title)
   for _,item in ipairs(rows or {}) do if item.title==title then return item end;local got=c.menu_find(item.menu or item.items,title);if got then return got end end
  end
  c.path=path;body(c)
  c.manager.cancel_caps_word("audit scenario completed");assert(not c.hook.caps_word_lock_held());assert(Writer.close())
  Loop.defer=c.original_defer
 end) end)
 for k in pairs(package.loaded) do if saved[k]==nil then package.loaded[k]=nil end end;for k,v in pairs(saved) do package.loaded[k]=v end
 assert(ok,name..": "..tostring(err))
end
local function copy(v) if type(v)~="table" then return v end;local out={};for k,item in pairs(v) do out[k]=copy(item) end;return out end
local function row(name,c,extra)
 local r={name=name,active=c.manager.is_caps_word_active(),capture_caps=c.capture.caps_locked(),pending=#c.deferred,physical=copy(c.physical),semantic=copy(c.semantic),wire=copy(c.wire),pointer_events=copy(c.pointer_rows or {})};for k,v in pairs(extra or {}) do r[k]=v end;results[#results+1]=r
end
scenario("normal-10-second-idle",nil,function(c) c.seed();c.run_due(9999);assert(c.manager.is_caps_word_active());c.run_due(10000);assert(not c.manager.is_caps_word_active());row("normal-10-second-idle",c) end)
scenario("zero-never-idle",'[shortcuts.caps_word]\nidle_timeout_seconds=0\n',function(c)c.seed();assert(#c.deferred==0);c.run_due(100000);assert(c.manager.is_caps_word_active());row("zero-never-idle",c)end)
scenario("tiny-positive",'[shortcuts.caps_word]\nidle_timeout_seconds=0.0001\n',function(c)c.seed();assert(c.auto.policy().idle_ms==0);assert(#c.deferred==1);c.run_due(0);assert(not c.manager.is_caps_word_active());row("tiny-positive",c,{cached_idle=c.auto.policy().idle_ms})end)
scenario("one-ms-positive",'[shortcuts.caps_word]\nidle_timeout_seconds=0.001\n',function(c)c.seed();c.run_due(0);assert(c.manager.is_caps_word_active());c.run_due(1);assert(not c.manager.is_caps_word_active());row("one-ms-positive",c)end)
scenario("live-idle-zero-to-one",'[shortcuts.caps_word]\nidle_timeout_seconds=0\n',function(c)c.seed();assert(c.auto.set_idle_timeout_seconds(1));c.run_due(2000);assert(c.manager.is_caps_word_active());row("live-idle-zero-to-one",c,{cached_idle=c.auto.policy().idle_ms});assert(c.manager.toggle_caps_word());c.started=false;c.drive({{type=1,code=30,value=1,at_ms=2000},{type=1,code=30,value=0,at_ms=2000}});c.run_due(3000);assert(not c.manager.is_caps_word_active())end)
scenario("live-idle-ten-to-one",nil,function(c)c.seed();assert(c.auto.set_idle_timeout_seconds(1));c.run_due(2000);assert(c.manager.is_caps_word_active());row("live-idle-ten-to-one",c,{cached_idle=c.auto.policy().idle_ms});c.run_due(10000);assert(not c.manager.is_caps_word_active())end)
scenario("live-uncheck-space",nil,function(c)c.seed();assert(c.auto.set_terminator("space",false));assert(not c.auto.policy().keys.space);assert(c.manager.caps_word_observe_text(" "));row("live-uncheck-space",c)end)
scenario("live-uncheck-pointer",nil,function(c)c.seed();assert(c.auto.set_pointer("left_click",false));assert(not c.auto.policy().pointer.left_click);assert(c.manager.caps_word_observe_pointer("left_click"));row("live-uncheck-pointer",c)end)
scenario("modifier-does-not-wake",nil,function(c)c.drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=0},{type=1,code=42,value=1,at_ms=9000},{type=1,code=42,value=0,at_ms=9001}});assert(#c.semantic==1);c.run_due(10000);assert(not c.manager.is_caps_word_active());row("modifier-does-not-wake",c)end)
scenario("arrow-wakes",nil,function(c)c.drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=0},{type=1,code=105,value=1,at_ms=9000},{type=1,code=105,value=0,at_ms=9001}});assert(#c.semantic==2);c.run_due(10000);assert(c.manager.is_caps_word_active());row("arrow-wakes",c);c.run_due(19000);assert(not c.manager.is_caps_word_active())end)
for _,token in ipairs({" ","\194\160","\226\128\175","\t","\n",",",";",".","\194\160:","A\226\128\175!"}) do
 scenario("text-delimiter-"..token,nil,function(c)c.seed();assert(c.manager.caps_word_observe_text(token));assert(not c.capture.caps_locked());row("text-delimiter-"..token,c)end)
end
for _,token in ipairs({"-","A","9","é",""}) do
 scenario("unchecked-text-"..token,nil,function(c)c.seed();assert(not c.manager.caps_word_observe_text(token));assert(c.manager.is_caps_word_active());row("unchecked-text-"..token,c)end)
end
for _,pointer in ipairs({{code=272,kind="left_click"},{code=273,kind="right_click"},{code=274,kind="middle_click"},{code=275,kind="other_buttons"},{code=330,kind="gesture"}}) do
 scenario("pointer-checked-"..pointer.kind,nil,function(c)c.seed();c.pointer({type=1,code=pointer.code,value=1});assert(not c.manager.is_caps_word_active());row("pointer-checked-"..pointer.kind,c)end)
 scenario("pointer-unchecked-"..pointer.kind,'[shortcuts.caps_word.pointer]\n'..pointer.kind..'=false\n',function(c)c.seed();c.pointer({type=1,code=pointer.code,value=1});assert(c.manager.is_caps_word_active());row("pointer-unchecked-"..pointer.kind,c)end)
end
scenario("native-tab-checked",nil,function(c)c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=15,value=1},{type=1,code=15,value=0}});assert(not c.manager.is_caps_word_active());row("native-tab-checked",c)end)
scenario("native-enter-checked",nil,function(c)c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=28,value=1},{type=1,code=28,value=0}});assert(not c.manager.is_caps_word_active());row("native-enter-checked",c)end)
scenario("ctrl-tab-checked",nil,function(c)c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=29,value=1},{type=1,code=15,value=1},{type=1,code=15,value=0},{type=1,code=29,value=0}});assert(not c.manager.is_caps_word_active());row("ctrl-tab-checked",c)end)
scenario("native-tab-unchecked",'[shortcuts.caps_word]\nterminators=["comma"]\n',function(c)c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=15,value=1},{type=1,code=15,value=0}});assert(c.manager.is_caps_word_active());row("native-tab-unchecked",c)end)
scenario("preexisting-user-caps",nil,function(c)c.seed();assert(#c.wire==0);c.manager.cancel_caps_word("audit-user-lock");assert(c.capture.caps_locked());assert(#c.wire==0);row("preexisting-user-caps",c)end,{initial_caps=true})
scenario("nonlocking-map-refusal",nil,function(c)c.seed();assert(not c.manager.is_caps_word_active());assert(not c.capture.caps_locked());assert(#c.wire==0);row("nonlocking-map-refusal",c)end,{locks=false})
scenario("user-caps-press",nil,function(c)c.drive({{type=1,code=30,value=1},{type=1,code=30,value=0},{type=1,code=58,value=1},{type=1,code=58,value=0}});assert(not c.manager.is_caps_word_active());assert(not c.capture.caps_locked());row("user-caps-press",c)end)
for _,ending in ipairs({"stop","cancel","init","disable"}) do
 scenario("lifecycle-"..ending,nil,function(c)c.seed();if ending=="stop" then c.hook.stop() elseif ending=="cancel" then c.manager.cancel_caps_word("script paused") elseif ending=="init" then c.manager.init({enabled=true}) else assert(c.manager.disable()) end;assert(not c.manager.is_caps_word_active());assert(not c.capture.caps_locked());row("lifecycle-"..ending,c)end)
end
local no_pointer='[shortcuts.caps_word.pointer]\ngesture=false\npointer_motion=false\nleft_click=false\nright_click=false\nmiddle_click=false\nother_buttons=false\n'
scenario("public-menu-uncheck-space",no_pointer,function(c)c.seed();local item=assert(c.menu_find(c.menu_rows(),require("infra.i18n").get("terminators.label_space")));assert(item.checked==true);item.fn();assert(c.menu_changes==1);assert(not c.auto.policy().keys.space);assert(c.manager.is_caps_word_active());assert(c.manager.caps_word_observe_text(" "));row("public-menu-uncheck-space",c,{menu_changes=c.menu_changes});c.started=false;c.seed();assert(not c.manager.caps_word_observe_text(" "));assert(c.manager.is_caps_word_active());row("public-menu-space-next-session-control",c)end)
scenario("public-menu-enable-left-click",no_pointer,function(c)c.seed();local title=require("infra.i18n").get("menu.caps_word.pointer.left_click");local item=assert(c.menu_find(c.menu_rows(),title));assert(item.checked==false);item.fn();assert(c.menu_changes==1);assert(c.auto.policy().pointer.left_click);c.pointer({type=1,code=272,value=1});assert(c.manager.is_caps_word_active());local rebuilt=assert(c.menu_find(c.menu_rows(),title));assert(rebuilt.checked==true);row("public-menu-enable-left-click",c,{menu_checked=rebuilt.checked,menu_changes=c.menu_changes});assert(c.manager.toggle_caps_word());c.started=false;c.seed();c.pointer({type=1,code=272,value=1});assert(not c.manager.is_caps_word_active());row("public-menu-left-click-next-session-control",c)end)
scenario("configured-magic-star-label",'[shortcuts.caps_word]\nidle_timeout_seconds=0\nterminators=["star"]\n'..no_pointer,function(c)
 local Magic=require("modules.hotstrings.magic_key");assert(Magic.set("§"));assert(Magic.get()=="§")
 assert(require("modules.hotstrings.hotstrings_config").set_magic_key(Magic.get(),Magic.default()))
 c.seed();local label=require("infra.i18n").get("terminators.label_star"):gsub("★","§")
 local item=assert(c.menu_find(c.menu_rows(),label));assert(item.checked==true)
 assert(not c.manager.caps_word_observe_text("§"));assert(c.manager.is_caps_word_active());row("configured-magic-star-label",c,{checked_label=label,magic_key=Magic.get()})
 assert(c.manager.caps_word_observe_text("★"));assert(not c.manager.is_caps_word_active());row("literal-star-still-ends",c)
end)
scenario("absolute-pointer-motion-ignored",'[shortcuts.caps_word]\nidle_timeout_seconds=0\n[shortcuts.caps_word.pointer]\ngesture=false\npointer_motion=true\n',function(c)c.seed();c.pointer({type=1,code=330,value=1});assert(c.manager.is_caps_word_active());local Kernel={EV_ABS=0x03,ABS_X=0x00,ABS_Y=0x01}
 local Finder=require("modules.hotstrings.device_finder")
 local block='I: Bus=0011 Vendor=0002 Product=0007 Version=01b1\nN: Name="SynPS/2 Synaptics TouchPad"\nS: Sysfs=/devices/platform/i8042/input/input7\nH: Handlers=mouse1 event7\nB: EV=b\n\n'
 local accepted=Finder.select_pointers(Finder.parse_devices(block));assert(accepted[1]=="/dev/input/event7")
 c.pointer({type=Kernel.EV_ABS,code=Kernel.ABS_X,value=100});c.pointer({type=Kernel.EV_ABS,code=Kernel.ABS_Y,value=200});c.pointer({type=0,code=0,value=0})
 c.pointer({type=Kernel.EV_ABS,code=Kernel.ABS_X,value=127});c.pointer({type=Kernel.EV_ABS,code=Kernel.ABS_Y,value=212});c.pointer({type=0,code=0,value=0});assert(c.manager.is_caps_word_active());row("absolute-pointer-motion-ignored",c);c.pointer({type=2,code=0,value=1});assert(not c.manager.is_caps_word_active());row("relative-pointer-motion-control",c)end)
scenario("touch-gesture-default-control",nil,function(c)c.seed();c.pointer({type=1,code=330,value=1});assert(not c.manager.is_caps_word_active());row("touch-gesture-default-control",c)end)
print("CAPS_WORD_OBSERVATIONS="..assert(require("json").encode({qualification="Actual manager/settings/hook/emitter/writer over recorded evdev/uinput/XKB ports and controlled monotonic/event-loop; no compositor or receiving application.",cases=results})))
