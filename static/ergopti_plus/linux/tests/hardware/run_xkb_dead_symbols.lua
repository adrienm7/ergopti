--- tests/hardware/run_xkb_dead_symbols.lua

local Capture = require('adapters.xkb_capture')
local h=require('tests.helpers')
local function map(layout)
 return 'xkb_keymap { xkb_keycodes { include "evdev+aliases(qwerty)" }; xkb_types { include "complete" }; xkb_compatibility { include "complete" }; xkb_symbols { include "pc+'..layout..'+inet(evdev)" }; xkb_geometry { include "pc(pc105)" }; };'
end
local function rows(requests) return assert(Capture._capture_chord_sources_for_test(requests)) end
h.describe('actual libxkbcommon detached exactmodifier physical chords',function()
 h.it('translates all16 exact chord combinations in bothCaps regimes from independent US expectations',function()
  assert(Capture.load(map('us'),'C.UTF-8'))
  local requests={}
  for mask=0,15 do
   local mods={};for i,role in ipairs({'ctrl','alt','shift','super'}) do mods[role]=math.floor(mask/2^(i-1))%2==1 end
   requests[#requests+1]={code=36,mods=mods}
  end
  local facts=rows(requests);h.assert_eq(#facts,32)
  for i,r in ipairs(facts) do
   local request=requests[math.floor((i+1)/2)];local caps=i%2==0
   h.assert_eq(r.code,36);h.assert_eq(r.mods,request.mods);h.assert_eq(r.caps,caps);h.assert_eq(r.dead,false)
   h.assert_eq(r.identity,request.mods.shift~=caps and 'J' or 'j')
  end
  Capture.clear()
 end)
 for _,pair in ipairs({{'ctrl','PC_CONTROL_LEVEL2'},{'alt','PC_ALT_LEVEL2'},{'super','PC_SUPER_LEVEL2'}}) do
  h.it('uses the actual native named '..pair[1]..' mask to select an independent alternate level',function()
   local source=map('us'):gsub('include "pc%+us%+inet%(evdev%)"','include "pc+us+inet(evdev)" key <AC07> { type[Group1]="'..pair[2]..'", symbols[Group1]=[j, colon] };')
   assert(Capture.load(source,'C.UTF-8'));local facts=rows({{code=36,mods={[pair[1]]=true}}})
   h.assert_eq(facts[1].identity,':');h.assert_eq(facts[2].identity,':');Capture.clear()
  end)
 end
 h.it('preserves live heldShift and live Caps while probing detached opposite modes',function()
  assert(Capture.load(map('us'),'C.UTF-8'));Capture.process(42,1)
  h.assert_eq(Capture.peek_text(36),'J')
  local facts=rows({{code=36,mods={}}});h.assert_eq(facts[1].identity,'j');h.assert_eq(facts[2].identity,'J')
  h.assert_eq(Capture.peek_text(36),'J');Capture.process(42,0);Capture.process(58,1);Capture.process(58,0)
  h.assert_eq(Capture.caps_locked(),true);h.assert_eq(Capture.peek_text(36),'J')
  facts=rows({{code=36,mods={shift=true}}});h.assert_eq(facts[1].identity,'J');h.assert_eq(facts[2].identity,'j')
  h.assert_eq(Capture.caps_locked(),true);h.assert_eq(Capture.peek_text(36),'J');Capture.clear()
 end)
 h.it('preserves actual live Compose pending deadacute while detaching unrelated chords',function()
  assert(Capture.load(map('us(intl)'),'C.UTF-8'));local text=Capture.process(40,1);h.assert_eq(text,nil);Capture.process(40,0)
  local facts=rows({{code=36,mods={ctrl=true,alt=true,shift=true,super=true}}});h.assert_eq(#facts,2)
  text=Capture.process(30,1);h.assert_eq(text,'á');Capture.process(30,0);Capture.clear()
 end)
 h.it('reports genuine French deadcircumflex and deaddiaeresis separately from literal Unicode',function()
  assert(Capture.load(map('fr'),'C.UTF-8'))
  local facts=rows({{code=26,mods={}},{code=26,mods={shift=true}}})
  h.assert_eq(#facts,4);for _,row in ipairs(facts) do h.assert_eq(row.dead,true) end
  local text=Capture.process(26,1);h.assert_eq(text,nil);Capture.process(26,0)
  text=Capture.process(16,1);h.assert_eq(text,'â');Capture.process(16,0);Capture.clear()
 end)
end)
h.describe('native dead symbol identity custody',function()
 h.it('retains distinct actual circumflex and diaeresis keysyms in both Caps regimes',function()
  assert(Capture.load(map('fr'),'C.UTF-8'))
  local facts=rows({{code=26,mods={}},{code=26,mods={shift=true}}})
  for i,value in ipairs({0xfe52,0xfe52,0xfe57,0xfe57}) do
   h.assert_eq(facts[i].keysym,value);h.assert_eq(facts[i].identity,nil);h.assert_eq(facts[i].dead,true)
  end
  Capture.clear()
 end)
end)
return h.get_results()
