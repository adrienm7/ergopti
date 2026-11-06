-- Actual public Keymap callback and one-shot adapter over recorded native ports.
local root=assert(arg[1],"Pass repository root")
local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
local file=assert(io.open(driver.."/tests/unit/modules/keymap/lifecycle/test_start_commit_transaction.lua","rb"))
local source=assert(file:read("*a"));file:close()
local stop=assert(source:find('\nhelpers.describe("keymap start:',1,true))
local load_fixture=assert(load(source:sub(1,stop-1).."\nreturn load_fixture", "@existing-keymap-native-fixture", "t"))()
local helpers=require("tests.helpers")
local SHIFT,CAPS,CMD,CTRL,ALT=0x20000,0x10000,0x100000,0x40000,0x80000
local data=assert(require("json").decode(assert(io.open(root.."/static/ergopti_plus/_shared/tap_hold/one_shot_shift.json","rb")):read("*a")))
local layout_file=assert(io.open(root.."/static/layouts/registry/ergopti_plus/ergopti_plus.keylayout","rb"))
local layout=assert(require("layouts.keylayout").parse(layout_file:read("*a")));layout_file:close()
local actions={};for _,action in ipairs(layout.actions) do for _,when in ipairs(action.whens) do if when.state=="none" then actions[action.id]=when.output or "" end end end
local maps={};for _,set in ipairs(layout.key_map_sets) do if set.id==layout.map_set then for _,map in ipairs(set.key_maps) do maps[map.index]={};for _,key in ipairs(map.keys) do maps[map.index][key.code]=key.output or actions[key.action] or "" end end end end
local function layout_translate(code,raw)
 local index=((raw&CAPS)~=0 and 1 or 0)+((raw&SHIFT)~=0 and 2 or 0)
 return maps[index][code] or ""
end
local rows={}
local function scenario(name,callback)
 local h,calls,owner,synthetic
 local saved={};for key,value in pairs(package.loaded) do saved[key]=value end
 h=load_fixture(function(controls)
  calls={emitted={},errors={},clock=10}
  synthetic=package.loaded["adapters.synthetic_input"]
  synthetic.STALE_PHYSICAL_EVENT_MS=500
  synthetic.admission_open=function() return controls.input_open~=false end
  synthetic.enter_callback=function() return true end
  synthetic.leave_callback=function(consume) return consume end
  synthetic.abort_callback=function() return true,false end
  package.loaded["adapters.event_provenance"].classify_with_fence=function() return nil,"foreign",nil,false end
  package.loaded["infra.logger"].error=function(_,message) calls.errors[#calls.errors+1]=message end
  package.loaded["adapters.text_sender"]={}
  package.loaded["modules.llm.app_filter"]={}
  package.loaded["adapters.keyboard_geometry"]={}
  package.loaded["modules.keymap.magic_key_source"]={needs_geometry=function() return false end,owns=function() return false end,remaps=function() return false end}
  package.loaded["adapters.one_shot_shift"]=nil
  local factory=require("adapters.one_shot_shift")
  local translate=layout_translate
  calls.translate=translate
  package.loaded["adapters.one_shot_shift"]={new=function(deps)
   owner=factory.new({data=data,magic=deps.magic,event={rawFlagMasks={shift=SHIFT}},now=function() return calls.clock end,
    is_repeat=function(event) return event.repeat_flag==1 end,translate=translate,
    emit=function(text) calls.emitted[#calls.emitted+1]=text;return true end})
   return owner
  end}
  package.loaded["platform.remap"]={get_sticky_timeout=function() return 2000 end}
 end)
 local host_ns=3600*1000000000;hs.timer.absoluteTime=function() return host_ns end
 local properties=hs.eventtap.event.properties
 function h.event(code,raw,override,repeat_flag,is_up)
  raw=raw or 0;local unicode=override or calls.translate(code,raw)
  local current={repeat_flag=repeat_flag or 0}
  current.getKeyCode=function() return code end
  current.getType=function() return is_up and hs.eventtap.event.types.keyUp or hs.eventtap.event.types.keyDown end
  current.getFlags=function() return {shift=(raw&SHIFT)~=0,capslock=(raw&CAPS)~=0,cmd=(raw&CMD)~=0,ctrl=(raw&CTRL)~=0,alt=(raw&ALT)~=0} end
  current.getCharacters=function() return unicode end
  current.rawFlags=function(_,value) if value~=nil then raw=value end;return raw end
  current.setUnicodeString=function(_,value) unicode=value end
  current.timestamp=function() return host_ns-1000000 end
  current.getProperty=function(_,property) if property==properties.keyboardEventAutorepeat then return repeat_flag or 0 end;return 0 end
  return current
 end
 require("adapters.event_clock").reset();require("infra.key_event_health").reset()
 h.set_timeout=function(value) package.loaded["platform.remap"].get_sticky_timeout=function() return value end end
 local ok,err=xpcall(function()
  assert(h.keymap.start());h.down=h.taps[1].callback;h.up=h.taps[2].callback;h.owner=owner;h.calls=calls
  callback(h)
  assert(#calls.errors==0, table.concat(calls.errors,";"))
 end,debug.traceback)
 local stopped=h.keymap.stop(true);assert(stopped)
 for key in pairs(package.loaded) do if saved[key]==nil then package.loaded[key]=nil end end
 for key,value in pairs(saved) do package.loaded[key]=value end
 assert(ok,name..": "..tostring(err))
end
for _,raw in ipairs({0,SHIFT,CAPS,CAPS|SHIFT}) do
 scenario("raw-flags-"..raw,function(h)
  assert(h.keymap.arm_one_shot_shift())
  local event=h.event(0,raw);local original=event:getCharacters(false)
  local consumed=h.down(event)
  local actual=event:getCharacters(false)
  assert(actual==(raw==(CAPS|SHIFT) and "a" or "A"))
  rows[#rows+1]={name="raw-flags-"..raw,original=original,result=actual,raw=event:rawFlags(),consumed=consumed,emitted=h.calls.emitted}
 end)
end
scenario("three-key-roll",function(h)
 assert(h.keymap.arm_one_shot_shift())
 local observed={}
 for _,code in ipairs({0,17,31}) do local event=h.event(code);h.down(event);observed[#observed+1]=event:getCharacters(false) end
 assert(table.concat(observed)=="Abc")
 rows[#rows+1]={name="three-key-roll",result=table.concat(observed)}
end)
for _,code in ipairs({51,36,48,53,123,122}) do
 scenario("control-"..code,function(h)
  assert(h.keymap.arm_one_shot_shift());h.down(h.event(code,0,""))
  local nextkey=h.event(0);h.down(nextkey)
  rows[#rows+1]={name="control-"..code,next_character=nextkey:getCharacters(false),emitted=h.calls.emitted}
 end)
end
scenario("accepted-programmatic-zero-timeout",function(h)
 h.set_timeout(0)
 local ok,err=pcall(h.keymap.arm_one_shot_shift)
 assert(not ok and tostring(err):find("invalid one-shot Shift timeout",1,true))
 rows[#rows+1]={name="accepted-programmatic-zero-timeout",arm_ok=ok,error=tostring(err)}
end)
for _,code in ipairs({5,9,24,44,49}) do
 scenario("special-output-"..code,function(h)
  assert(h.keymap.arm_one_shot_shift());local e=h.event(code);local consumed=h.down(e)
  local nextkey=h.event(0);h.down(nextkey)
  rows[#rows+1]={name="special-output-"..code,consumed=consumed,emitted=h.calls.emitted,next_character=nextkey:getCharacters(false)}
 end)
end
scenario("repeat-and-release",function(h)
 assert(h.keymap.arm_one_shot_shift())
 local first=h.event(0);h.down(first)
 local repeated=h.event(0,0,nil,1);h.down(repeated)
 h.up(h.event(0,0,nil,0,true))
 local fresh=h.event(0);h.down(fresh)
 assert(first:getCharacters(false)=="A" and repeated:getCharacters(false)=="A" and fresh:getCharacters(false)=="a")
 rows[#rows+1]={name="repeat-and-release",result=first:getCharacters(false)..repeated:getCharacters(false)..fresh:getCharacters(false)}
end)
scenario("refresh-deadline",function(h)
 assert(h.keymap.arm_one_shot_shift());h.calls.clock=11.5
 assert(h.keymap.arm_one_shot_shift());h.calls.clock=12.5
 local e=h.event(0);h.down(e);assert(e:getCharacters(false)=="A")
 rows[#rows+1]={name="refresh-deadline",result=e:getCharacters(false)}
end)
scenario("expired-deadline",function(h)
 assert(h.keymap.arm_one_shot_shift());h.calls.clock=12.001
 local e=h.event(0);h.down(e);assert(e:getCharacters(false)=="a")
 rows[#rows+1]={name="expired-deadline",result=e:getCharacters(false)}
end)
scenario("public-pause-disarms",function(h)
 assert(h.keymap.arm_one_shot_shift());assert(h.keymap.pause_processing())
 assert(h.keymap.arm_one_shot_shift()==false)
 assert(h.keymap.resume_processing())
 local e=h.event(0);h.down(e);assert(e:getCharacters(false)=="a")
 rows[#rows+1]={name="public-pause-disarms",result=e:getCharacters(false)}
end)
scenario("public-command-keeps",function(h)
 assert(h.keymap.arm_one_shot_shift());local shortcut=h.event(0,CMD);h.down(shortcut)
 local e=h.event(0);h.down(e);assert(e:getCharacters(false)=="A")
 rows[#rows+1]={name="public-command-keeps",result=e:getCharacters(false)}
end)
print(assert(require("json").encode(rows)))
