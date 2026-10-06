--- tests/unit/adapters/test_xkb_chord_numeric_symbols.lua

local h=require('tests.helpers')
local function fixture(body)
 local Capture=assert(loadfile((debug.getinfo(require('adapters.xkb_capture').load, 'S').source:gsub('^@', ''))))()
 local state={group=0,generation=7,locked=2,locked_generation=9,input_generation=3,latched=0,depressed=0}
 local backend={create=function() return {identity="controlled-native-map"} end,destroy=function() end,update_key=function() end}
 backend.source_group=function()
  if state.on_group then state.on_group() end
  return state.group,state.generation
 end
 backend.chord_source_identity=function()
  if state.on_locked then state.on_locked() end
  local group, generation, locked, lock_generation=state.group,state.generation,state.locked,state.locked_generation
  local input, latched, depressed=state.input_generation,state.latched,state.depressed
  return {group=group,generation=generation,locked_mods=locked,locked_generation=lock_generation,input_generation=input,
   mods=locked+latched+depressed,latched_mods=latched,base_mods=depressed,
   observed_current=function()
    if state.on_seal then state.on_seal() end
    return state.group==group and state.generation==generation and state.locked==locked and state.locked_generation==lock_generation and state.input_generation==input and state.latched==latched and state.depressed==depressed
   end}
 end
 backend.chord_sources=function(_,requests,group,locked)
  h.assert_eq(group,0);h.assert_eq(locked,2)
  if state.on_rows then state.on_rows(requests) end
  local rows={}
  for _,r in ipairs(requests) do for _,caps in ipairs({false,true}) do
   local mods={};for k,v in pairs(r.mods) do mods[k]=v end
   rows[#rows+1]={code=r.code,mods=mods,caps=caps,identity=caps and 'J' or 'j',dead=false}
  end end
  return rows
 end
 Capture._set_backend(backend);assert(Capture.load('controlled-source','C.UTF-8'))
 local ok,err=pcall(body,Capture,state,backend);Capture._reset_backend();if not ok then error(err,0) end
end
local requests=function() return {{code=36,mods={ctrl=true,alt=false,shift=false,super=false}}} end
h.describe('native numeric chord symbol custody',function()
 h.it('keeps actual positive numeric native symbol in detached opaque views',function()
  fixture(function(c,_,b)
   local original=b.chord_sources
   b.chord_sources=function(...) local rows=original(...);for _,r in ipairs(rows) do r.keysym=0xfe52;r.dead=true;r.identity=nil end;return rows end
   local cap=assert(c.chord_sources(requests()));local first=assert(c.chord_source_view(cap))
   h.assert_eq(first.chords[1].keysym,0xfe52);h.assert_eq(first.chords[2].keysym,0xfe52)
   first.chords[1].keysym=0xfe57
   h.assert_eq(assert(c.chord_source_view(cap)).chords[1].keysym,0xfe52)
  end)
 end)
 h.it('refuses malformed optional numeric symbols without coercion or Unicode inference',function()
  for _,symbol in ipairs({0,-1,1.5,'65106',math.huge,0/0,4294967296}) do
   fixture(function(c,_,b)
    local original=b.chord_sources
    b.chord_sources=function(...) local rows=original(...);rows[1].keysym=symbol;return rows end
    local cap,reason=c.chord_sources(requests())
    h.assert_eq(cap,nil);h.assert_eq(reason,'physical-source-invalid-response')
   end)
  end
 end)
end)
