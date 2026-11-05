-- Audit fixture composes the repository's eventtap fixture with actual Keymap,
-- Registry, Expander, RulesEngine, shared TOML catalogue and SyntheticInput.
local repo = assert(arg[1], 'repository root required')
local driver = repo .. '/static/ergopti_plus/macos'
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/tests/stubs/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local file = assert(io.open(driver .. '/tests/unit/modules/keymap/repeat/test_star_validation_beats_repeat_key.lua', 'rb'))
local source = file:read('*a'); file:close()
local marker = '\nhelpers.describe("pressing ★ validates the tooltip on every expansion branch"'
local stop = assert(source:find(marker, 1, true), 'eventtap fixture prefix must exist')
assert(not source:find(marker, stop + 1, true), 'eventtap fixture prefix must be unique')
local fixture = assert(load(source:sub(1, stop - 1) .. '\nreturn install_collaborators,find_keydown_tap,physical_key,force_normal_window,drain_immediate_timers,helpers', '@eventtap-fixture-prefix', 't'))
local install, find_tap, physical, normal, drain, helpers = fixture()
local effects = {emitted={},visible=false}
install(effects)
local publications, logs = {}, {}
require('infra.logger').debug = function(component, format, ...)
 logs[#logs+1] = {component=component,message=string.format(format,...)}
end
local Keymap = helpers.load_with_stubs('modules.keymap')
local hs_stub = _G.hs
normal()
local now = 100
hs_stub.timer.secondsSinceEpoch = function() return now end
local statistics = package.loaded['modules.keystats']
statistics.notify_synthetic = function(text, source_type, deletes, variant, echo, private)
 publications[#publications + 1] = {text=text,variant=variant,private=private == true,deletes=deletes}
end
statistics.set_buffer = function(buffer) effects.buffer = buffer end
local tap = assert(find_tap(hs_stub), 'real keymap must install its key-down tap')
local function press(text, code, elapsed, flags)
 now = now + (elapsed or 0.01)
 return tap.fn(physical(text,flags,code))
end
local function reset()
 press('',123); drain(hs_stub)
 publications = {}; effects.buffer = nil
end
local function type_word(text)
 for _, cp in utf8.codes(text) do press(utf8.char(cp)) end
end
Keymap.set_repeat_feature_enabled(true)
-- Register the actual bundled correction rows via public registry owner.
local catalogue_file = assert(io.open(repo .. '/static/layouts/registry/ergopti/hotstrings/repeatcorrections.toml','rb'))
local corrections = require('toml_codec').decode(catalogue_file:read('*a')); catalogue_file:close()
for _, row in ipairs(corrections.repeat_corrections) do
 for trigger, record in pairs(row) do Keymap.add(trigger, record.output,record) end
end
Keymap.add('poo★','NEXT_MAGIC',{auto_expand=true,is_case_sensitive=true})
Keymap.add('expand★','EXPANDED',{auto_expand=true,is_case_sensitive=true})
Keymap.add('x','z',{auto_expand=true,is_word=true,is_case_sensitive=true})
Keymap.sort_mappings()
-- Repeat output remains available to immediate further typed corrections.
type_word('po'); assert(press('★') == true)
assert(effects.buffer == 'poo')
assert(press('ê') == false, 'poo has no bundled correction; use actual cc row next')
reset(); type_word('ac'); assert(press('★') == true); assert(effects.buffer == 'acc')
assert(press('ê') == true and effects.buffer == 'accu', 'actual ccê correction must retain preceding a')
local correction = effects.buffer
reset(); type_word('po'); assert(press('★') == true)
assert(press('★') == true and effects.buffer == 'NEXT_MAGIC', 'next magic resolves actual retained repeat output')
local next_magic = effects.buffer
reset(); Keymap.set_repeat_feature_enabled(false); type_word('po'); assert(press('★') == false)
assert(#publications == 0, 'disabled repeat constructs no synthetic publication')
Keymap.set_repeat_feature_enabled(true)
reset()
local state
for index = 1, 64 do
 local name,value=debug.getupvalue(require('modules.keymap.expander').try_repeat_feature,index)
 if name == '_state' then state=value; break end
end
assert(state, 'read-only inspection requires the actual owner state')
-- Repetition must preserve midword provenance, rather than manufacture a word start.
type_word('po'); assert(press('★') == true and state.buffer == 'poo')
assert(press('x') == false and state.buffer == 'poox' and #publications == 1,
 'a word-only x rule must not fire inside the repeated word')
local repeated_word_boundary = state.buffer
reset(); type_word('poox')
assert(state.buffer == 'poox' and #publications == 0, 'manually typed control keeps the same word boundary')
local manual_word_boundary = state.buffer
reset(); assert(press('x') == true and state.buffer == 'z' and #publications == 1,
 'positive control proves actual word-only rule is enabled and reachable')
reset()
type_word('expand'); assert(press('★') == true and state.buffer == 'EXPANDED')
assert(press('',51) == false and state.buffer == 'EXPANDE' and #publications == 1,
 'Mac bare Backspace passes through and removes one emitted codepoint, not the original trigger')
local after_backspace = state.buffer
Keymap.set_shortcut_resets_word(true)
assert(press('z',6,nil,{cmd=true,ctrl=false,alt=false,shift=false}) == false and state.buffer == '' and #publications == 1,
 'host Cmd+Z remains passthrough with buffer reset; native editor receipt is unmeasured')
reset()
-- Actual personal producer and actual runtime registration (not manually tagged rule).
local rules = require('modules.dynamic_hotstrings.rules_engine')
rules.inject_data({social_security_number='2840175123456'}, '★')
assert(rules.start(Keymap) ~= false)
type_word('28401')
assert(effects.buffer == '2840175123456' and #publications == 1 and publications[1].private == true,
 'real SSN provider must register and expand its real private prefix')
assert(press('★') == true, 'public keydown must admit the fallback after actual private SSN output')
assert(#publications == 2 and publications[2].text == '6' and publications[2].private == false)
local logged_repeat = false
for _, record in ipairs(logs) do
 if record.component == 'keymap.expander' and record.message == "Repeat feature: repeated '6'." then logged_repeat = true end
end
assert(logged_repeat, 'actual Logger.debug boundary carries secret-derived scalar literally')
-- Read actual state without replacing its owner or changing admission.
assert(state and state.llm_private_mark ~= '', 'private context mark must exist')
require('modules.keymap.llm_bridge').update_preview(state.buffer)
assert(state.llm_buffer == '6', 'actual bridge exposes one secret-derived scalar after the old private prefix')
local after_private = {buffer=state.buffer,ai_context=state.llm_buffer,publications=publications,debug_literal=logged_repeat}
package.loaded['modules.keystats'] = nil
local real_statistics = require('modules.keystats')
local public_recorded = real_statistics.recorded_char(publications[2].text,publications[2].private)
local private_recorded = real_statistics.recorded_char(publications[2].text,true)
assert(public_recorded == '6' and private_recorded == utf8.char(0x2022), 'actual persistence-value owner only redacts when privacy is propagated')
print(require('json').encode({correction=correction,next_magic=next_magic,repeated_word_boundary=repeated_word_boundary,manual_word_boundary=manual_word_boundary,backspace_buffer=after_backspace,after_private=after_private,actual_recorded_char={public=public_recorded,private_control=private_recorded}}))
