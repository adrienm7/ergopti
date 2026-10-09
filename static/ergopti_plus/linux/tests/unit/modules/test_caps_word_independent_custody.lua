--- tests/unit/modules/test_caps_word_independent_custody.lua

--- ==============================================================================
--- MODULE: Independently Authored CapsWord Residual Custody Controls
--- DESCRIPTION:
--- Retains independent reviewer assertions for cancelled-repeat ownership and
--- per-character CapsLock currency. Software models grant no native IO evidence.
--- ==============================================================================

local h=require('tests.helpers')
h.describe('Independent software custody counterfactuals',function()
h.it('retains consumed press repeat custody after explicit pointer cancellation',function()
 local Engine=require('platform.remap.tap_hold_engine')
 local engine=Engine.new({keys={},tap_min_ms=0,one_shot_timeout_ms=1000,key_text=function(code)return code==30 and 'a' or nil end,
 caps_word_plan=function(text) assert(text=='A');return {{keycode=30,mods={'shift'}}},function()return true end end})
 assert(engine:arm_caps_word(function()return true end))
 local out=assert(engine:process(30,1,0,{source='original-A'}));assert(engine:ack_caps_word(out))
 engine:activity();h.assert_nil(engine:input_arm_state())
 local repeat_out=engine:process(30,2,1,{source='original-A'})
 h.assert_eq(repeat_out,{},'a delivered uppercase press must suppress later repeat after logical cancellation')
 h.assert_eq(engine:process(30,0,2,{source='original-A'}),{},'its physical UP must still be suppressed')
end)
h.it('invalidates a published per-character guard on later CapsLock transition',function()
 local names={'adapters.caps_word','adapters.keyboard_layout','adapters.xkb_capture'}
 local saved={};for _,name in ipairs(names) do saved[name]={package.loaded[name]}end
 local inverse,receipt,chord={},{},{};local caps=false
 package.loaded['adapters.keyboard_layout']={plan=function(text)assert(text=='A');return {{keycode=30,mods={'shift'}}},nil,receipt end,
 plan_current=function(value)return value==receipt end}
 package.loaded['adapters.xkb_capture']={inverse_table=function(native)assert(native);return {},nil,inverse end,
 inverse_current=function(value)return value==inverse end,caps_locked=function()return caps end,peek_text=function()return 'a'end,
 chord_sources=function(requests)assert(#requests==2);return chord end,
 chord_source_current=function(value)return value==chord end,
 chord_source_view=function(value)assert(value==chord);return {chords={
 {code=30,caps=false,mods={},identity='a',dead=false},{code=30,caps=true,mods={},identity='A',dead=false},
 {code=30,caps=false,mods={shift=true},identity='A',dead=false},{code=30,caps=true,mods={shift=true},identity='a',dead=false}}}end}
 package.loaded['adapters.caps_word']=nil
 local ok,err=pcall(function()
  local adapter=require('adapters.caps_word');local owner=assert(adapter.capture())
  local plan,current=adapter.plan(owner,'A');assert(plan and current());caps=true
  h.assert_true(not current(),'CapsLock changes after plan publication must fence delivery even with source receipts current')
 end)
 for _,name in ipairs(names)do package.loaded[name]=saved[name][1]end
 if not ok then error(err,0)end
end)
end)

return true
