-- Audit-only: real public word-reset/TOML fixture; terminal effects are a stated native condition.
local repo=assert(arg[1], 'repository root required')
local driver=repo..'/static/ergopti_plus/macos'
package.path=driver..'/?.lua;'..driver..'/?/init.lua;'..driver..'/tests/stubs/?.lua;'..repo..'/static/ergopti_plus/_shared/lua/?.lua;'..repo..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
local file=assert(io.open(driver..'/tests/unit/modules/keymap/terminators/test_arrow_shortcut_word_reset.lua','rb'))
local source=file:read('*a');file:close()
local marker='\nhelpers.describe("word-start fixture control"'
local stop=assert(source:find(marker,1,true));assert(not source:find(marker,stop+1,true))
local with_keymap=assert(load(source:sub(1,stop-1)..'\nreturn with_keymap','@word-reset-fixture-prefix','t'))()
local observations={}
for _,case in ipairs({
 {name='main Return',code=36,chars='\r',expands=true},
 {name='keypad Enter CR spelling',code=76,chars='\r',expands=false},
 {name='keypad Enter ETX spelling',code=76,chars=string.char(3),expands=false},
}) do
 with_keymap(function(f)
  require('adapters.text_sender').focusedAppIdentity=function() return 'com.apple.Terminal','Terminal',{} end
  f.press('a');f.press(case.chars,nil,case.code)
  local after_submit={buffer=f.state.buffer,empty_line=f.state.start_is_line_start}
  f.press('a');f.press('',nil,51);f.press('',nil,51)
  local after_empty_prompt_backspaces={buffer=f.state.buffer,word_start=f.state.start_is_word_boundary,empty_line=f.state.start_is_line_start}
  f.press('r');f.settle()
  local emitted=table.concat(f.effects.emitted)
  assert((emitted=='R')==case.expands,'real word-only rule must distinguish main Return from keypad Enter')
  observations[#observations+1]={name=case.name,keycode=case.code,after_submit=after_submit,after_empty_prompt_backspaces=after_empty_prompt_backspaces,word_only_emitted=emitted}
 end)
end
local terminator_observations={}
for _,case in ipairs({
 {name='main Return',code=36,chars='\r'},
 {name='keypad Enter CR spelling',code=76,chars='\r'},
 {name='keypad Enter ETX spelling',code=76,chars=string.char(3)},
}) do
 with_keymap(function(f)
  require('adapters.text_sender').focusedAppIdentity=function() return 'com.apple.TextEdit','TextEdit',{} end
  f.keymap.add('qq','EXP',{auto_expand=false,is_word=true,is_case_sensitive=true})
  f.keymap.sort_mappings()
  f.press('q');f.press('q');f.press(case.chars,nil,case.code);f.settle()
  terminator_observations[#terminator_observations+1]={name=case.name,emitted=table.concat(f.effects.emitted),buffer=f.state.buffer}
 end)
end
assert(terminator_observations[1].emitted~='' and terminator_observations[2].emitted~='')
assert(terminator_observations[3].emitted=='', 'ETX payload has no admitted Enter terminator identity')
print(require('json').encode({cases=observations,terminator_payload_controls=terminator_observations,native_condition='The chosen terminal treats bare keypad Enter as submit and the next Backspaces occur at an empty prompt; actual native terminal receiving is not executed.'}))
