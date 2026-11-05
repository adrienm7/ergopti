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
local function run(action, reset_ai, reset_word)
 local Keymap, native, state, effects, cleanup = load_fixture()
 local ok, err = xpcall(function()
  local tap = assert(find_tap(native,native.eventtap.event.types.keyDown))
  Keymap.set_llm_reset_on_nav(reset_ai)
  assert(Keymap.set_arrow_resets_word(reset_word) == true)
  assert(Keymap.set_shortcut_resets_word(reset_word) == true)
  Keymap.set_idle_reset_seconds(0)
  local now = 100
  native.timer.secondsSinceEpoch = function() return now end
  local function press(char, code, flags)
   now = now + 0.01
   local event = physical_key(char,code)
   if flags then event.getFlags = function() return flags end end
   return tap.fn(event)
  end
  for _,cp in utf8.codes('bonjour') do press(utf8.char(cp)) end
  drain(native)
  assert(state.llm_buffer == 'bonjour' and state.buffer == 'bonjour', 'positive typing control')
  if action == 'arrow' then press('',123)
  elseif action == 'shortcut' then press('z',6,{cmd=true,ctrl=false,alt=false,shift=false})
  elseif action == 'click' then
   local mouse = assert(find_tap(native,native.eventtap.event.types.leftMouseDown))
   mouse.fn({getProperty=function() return 0 end})
   drain(native)
  elseif action == 'escape' then press('',53)
  else error('unsupported action') end
  local immediate = state.llm_buffer
  assert(immediate == (reset_ai and '' or 'bonjour'), 'navigation preference must work immediately')
  local word_after_action = state.buffer
  assert(press('x') == false)
  drain(native)
  local actual = state.llm_buffer
  local expected = (reset_ai and '' or 'bonjour') .. 'x'
  observations[#observations+1] = {action=action,reset_ai=reset_ai,reset_word=reset_word,immediate_context=immediate,hotstring_after_action=word_after_action,after_next_letter=actual,expected_policy_continuation=expected,policy_holds=actual==expected}
 end,debug.traceback)
 cleanup()
 if not ok then error(err,0) end
end
for _,action in ipairs({'arrow','shortcut'}) do
 for _,reset_ai in ipairs({false,true}) do
  for _,reset_word in ipairs({false,true}) do run(action,reset_ai,reset_word) end
 end
end
run('click',false,true)
run('click',true,true)
run('escape',false,true)
run('escape',true,true)
local mismatches = 0
for _,r in ipairs(observations) do if not r.policy_holds then mismatches=mismatches+1 end end
assert(mismatches == 5, 'two opposite preference crossovers per arrow/shortcut, plus keep-context click')
print(require('json').encode({cases=observations,policy_mismatches=mismatches}))
