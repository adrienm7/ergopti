-- Audit fixture: existing native-port fixture prefix, actual public Keymap/Bridge owners.
local repo = assert(arg[1], 'repository root required')
local driver = repo .. '/static/ergopti_plus/macos'
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/tests/stubs/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local file = assert(io.open(driver .. '/tests/unit/modules/keymap/terminators/test_nav_invalidates_hotstring_buffer.lua','rb'))
local source = file:read('*a'); file:close()
local marker = '\nhelpers.describe("navigation invalidates hotstring buffer"'
local stop = assert(source:find(marker,1,true), 'fixture boundary must exist')
assert(not source:find(marker,stop+1,true), 'fixture boundary must be unique')
local factory = assert(load(source:sub(1,stop-1) .. '\nreturn load_fixture,find_tap,physical_key,drain_immediate_timers','@nav-fixture-prefix','t'))
local load_fixture, find_tap, physical_key, drain = factory()
local observations = {}
local function scenario(name, body)
 local Keymap,native,state,effects,cleanup=load_fixture()
 local ok,err=xpcall(function()
  local tap=assert(find_tap(native,native.eventtap.event.types.keyDown))
  local now=100
  native.timer.secondsSinceEpoch=function() return now end
  Keymap.set_llm_reset_on_nav(false)
  Keymap.set_idle_reset_seconds(3)
  local function press(char,code,flags,pid)
   now=now+0.01
   local event=physical_key(char,code)
   if flags then event.getFlags=function() return flags end end
   if pid then
    event.getProperty=function(_,property)
     if property==native.eventtap.event.properties.eventSourceUserData then return 0 end
     return pid
    end
   end
   return tap.fn(event)
  end
  local function word(text) for _,cp in utf8.codes(text) do press(utf8.char(cp)) end end
  local function focus(bundle,name)
   require('adapters.text_sender').focusedAppIdentity=function() return bundle,name,{} end
  end
  body({keymap=Keymap,native=native,state=state,effects=effects,press=press,word=word,focus=focus,pause=function(seconds) now=now+seconds end,settle=function() drain(native) end})
  observations[#observations+1]={name=name,hotstring=state.buffer,ai=state.llm_buffer,word_start=state.start_is_word_boundary,line_start=state.start_is_line_start}
 end,debug.traceback)
 cleanup(); if not ok then error(err,0) end
end
scenario('idle ordinary key resets',function(f)
 f.word('bonjour'); f.pause(4); f.press('x')
 assert(f.state.buffer=='x' and f.state.llm_buffer=='x')
end)
scenario('idle bare Backspace retains editable word',function(f)
 f.word('bonjour'); f.pause(4); assert(f.press('',51)==false)
 assert(f.state.buffer=='bonjou' and f.state.llm_buffer=='bonjou')
end)
for _,case in ipairs({
 {name='Option Backspace',flags={alt=true},boundary=true},
 {name='Command Backspace',flags={cmd=true},boundary=false},
 {name='Control Backspace',flags={ctrl=true},boundary=false},
}) do
 scenario(case.name,function(f)
  f.keymap.set_shortcut_resets_word(false); f.keymap.set_arrow_resets_word(false)
  f.word('bonjour'); assert(f.press('',51,case.flags)==false)
  assert(f.state.buffer=='' and f.state.start_is_word_boundary==case.boundary)
  assert(f.state.llm_buffer=='bonjour', 'keep-context navigation policy retains prior context immediately')
 end)
end
scenario('bare Backspace past observed start',function(f)
 f.press('',115); f.word('ab'); f.press('',51); f.press('',51)
 assert(f.state.buffer=='' and f.state.start_is_word_boundary==true)
 f.press('',51); assert(f.state.start_is_word_boundary==false)
end)
for _,case in ipairs({
 {name='Terminal Return',bundle='com.apple.Terminal',app='Terminal',shift=false,empty=true},
 {name='Terminal Shift Return',bundle='com.apple.Terminal',app='Terminal',shift=true,empty=false},
 {name='TextEdit Return',bundle='com.apple.TextEdit',app='TextEdit',shift=false,empty=false},
}) do
 scenario(case.name,function(f)
  f.focus(case.bundle,case.app); f.word('bonjour'); f.press('\r',36,{shift=case.shift})
  assert((f.state.buffer=='')==case.empty)
  assert(f.state.start_is_line_start==case.empty)
 end)
end
for _,case in ipairs({
 {name='TextEdit Select All',bundle='com.apple.TextEdit',app='TextEdit',character='a',empty=true},
 {name='Terminal Select All',bundle='com.apple.Terminal',app='Terminal',character='a',empty=false},
 {name='Browser Location',bundle='com.apple.Safari',app='Safari',character='l',empty=true},
 {name='TextEdit Location chord',bundle='com.apple.TextEdit',app='TextEdit',character='l',empty=false},
}) do
 scenario(case.name,function(f)
  f.focus(case.bundle,case.app); f.word('bonjour'); f.press(case.character,0,{cmd=true})
  assert(f.state.buffer=='' and f.state.start_is_line_start==case.empty)
 end)
end
scenario('foreign remapper Command Z follows shortcut policy',function(f)
 f.word('bonjour'); f.press('z',6,{cmd=true},4242)
 assert(f.state.buffer=='' and f.state.start_is_word_boundary==true)
 assert(f.state.llm_buffer=='bonjour')
end)
scenario('pause and resume revoke both contexts',function(f)
 f.word('bonjour'); assert(f.keymap.pause_processing()==true)
 assert(f.state.buffer=='' and f.state.llm_buffer=='')
 assert(f.press('x')==false and f.state.buffer=='' and f.state.llm_buffer=='')
 assert(f.keymap.resume_processing()==true)
 f.press('x'); assert(f.state.buffer=='x' and f.state.llm_buffer=='x')
end)
scenario('stop revokes both contexts',function(f)
 f.word('bonjour'); assert(f.keymap.stop()==true)
 assert(f.state.buffer=='' and f.state.llm_buffer=='')
end)
assert(#observations==16)
print(require('json').encode({cases=observations,count=#observations}))
