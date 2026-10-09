--- tests/unit/adapters/test_physical_chord_source_currency.lua

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
h.describe('actual physical chord source opaque issuer and callback currency',function()
 h.it('returns detached facts only from its opaque actual issuer',function()
  fixture(function(c)
   local cap=assert(c.chord_sources(requests()));local v=assert(c.chord_source_view(cap));h.assert_eq(#v.chords,2)
   h.assert_eq(v.chords[1].identity,'j');h.assert_eq(v.chords[2].identity,'J');h.assert_eq(v.chords[2].caps,true)
   v.chords[1].mods.ctrl=false;v.chords[1].identity='forged'
   local again=assert(c.chord_source_view(cap));h.assert_eq(again.chords[1].identity,'j');h.assert_eq(again.chords[1].mods.ctrl,true)
   h.assert_eq(c.chord_source_view({}),nil)
  end)
 end)
 h.it('fails closed if native locked-source proof is unavailable',function()
  fixture(function(c,_,b) b.chord_source_identity=nil;h.assert_eq(c.chord_sources(requests()),nil) end)
 end)
 h.it('rejects backend snapshot metadata substitution and preserves caller request',function()
  fixture(function(c,s)
   local r=requests();s.on_rows=function(copy) copy[1].code=37 end
   h.assert_eq(c.chord_sources(r),nil);h.assert_eq(r[1].code,36)
  end)
 end)
 h.it('rejects source session replacement from source-group callback',function()
  fixture(function(c,s)
   s.on_group=function() s.on_group=nil;assert(c.load('controlled-source','C.UTF-8')) end
   h.assert_eq(c.chord_sources(requests()),nil)
  end)
 end)
 h.it('rejects same-source session replacement from native locked callback',function()
  fixture(function(c,s)
   s.on_locked=function() s.on_locked=nil;assert(c.load('controlled-source','C.UTF-8')) end
   h.assert_eq(c.chord_sources(requests()),nil)
  end)
 end)
 h.it('rejects an ordinary native transition during detached translation despite same map and group',function()
  fixture(function(c,s) s.on_rows=function() c.process(42,0) end;h.assert_eq(c.chord_sources(requests()),nil) end)
 end)
 h.it('rejects native locked state away-and-back during translation despite same mask',function()
  fixture(function(c,s) s.on_rows=function() s.locked_generation=s.locked_generation+2 end;h.assert_eq(c.chord_sources(requests()),nil) end)
 end)
 h.it('rejects delivered-cap view after a later native lock epoch',function()
  fixture(function(c,s) local cap=assert(c.chord_sources(requests()));s.locked_generation=s.locked_generation+2;h.assert_eq(c.chord_source_view(cap),nil) end)
 end)
 h.it('rejects native transition reentry in final locked-source view callback',function()
  fixture(function(c,s)
   local cap=assert(c.chord_sources(requests()));s.on_locked=function() c.process(42,0) end
   h.assert_eq(c.chord_source_view(cap),nil)
  end)
 end)
 h.it('rejects same-source session replacement in final locked-source view callback',function()
  fixture(function(c,s)
   local cap=assert(c.chord_sources(requests()));s.on_locked=function() s.on_locked=nil;assert(c.load('controlled-source','C.UTF-8')) end
   h.assert_eq(c.chord_source_view(cap),nil)
  end)
 end)
 h.it('refuses unknown modifiers and noncanonical native request shape',function()
  fixture(function(c)
   for _,r in ipairs({{{code=36,mods={altgr=true}}},{{code=36,mods={ctrl='yes'}}},{{code=36,mods={},source='forged'}},{{code=36.5,mods={}}},{[1]={code=36,mods={}},[3]={code=37,mods={}}}}) do h.assert_eq(c.chord_sources(r),nil) end
  end)
 end)
end)
h.describe('actual opaque source terminal observed currency seal',function()
 h.it('seals an owned receipt without another native source read',function()
  fixture(function(c,s)
   local cap=assert(c.chord_sources(requests()));s.on_group=function() error('No source read allowed') end;s.on_locked=s.on_group
   h.assert_true(c.chord_source_current(cap));h.assert_eq(c.chord_source_current({}),false)
  end)
 end)
 h.it('refuses a same-byte native session replacement after the last view',function()
  fixture(function(c) local cap=assert(c.chord_sources(requests()));assert(c.chord_source_view(cap));assert(c.load('controlled-source','C.UTF-8'));h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('refuses a process transition after the last native view',function()
  fixture(function(c) local cap=assert(c.chord_sources(requests()));assert(c.chord_source_view(cap));c.process(42,0);h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('refuses a later observed native lock epoch despite identical mask',function()
  fixture(function(c,s) local cap=assert(c.chord_sources(requests()));assert(c.chord_source_view(cap));s.locked_generation=s.locked_generation+2;h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('refuses a later observed source epoch',function()
  fixture(function(c,s) local cap=assert(c.chord_sources(requests()));s.generation=s.generation+1;h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('refuses terminal session replacement inside the observed-current callback',function()
  fixture(function(c,s) local cap=assert(c.chord_sources(requests()));s.on_seal=function() s.on_seal=nil;assert(c.load('controlled-source','C.UTF-8')) end;h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('refuses terminal process reentry inside the observed-current callback',function()
  fixture(function(c,s) local cap=assert(c.chord_sources(requests()));s.on_seal=function() s.on_seal=nil;c.process(42,0) end;h.assert_eq(c.chord_source_current(cap),false) end)
 end)
 h.it('fails closed when backend offers no observed currency seal',function()
  fixture(function(c,s,b)
   local read=b.chord_source_identity;b.chord_source_identity=function(session) local proof=read(session);proof.observed_current=nil;return proof end
   local cap=assert(c.chord_sources(requests()));h.assert_eq(c.chord_source_current(cap),false)
  end)
 end)
end)

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

h.describe('acknowledged native physical input currency',function()
 h.it('refuses nonzero native latch, depressed and unexplained effective masks',function()
  for _,field in ipairs({'latched','depressed'}) do fixture(function(c,s)
   s[field]=1;local cap,reason=c.chord_sources(requests());h.assert_eq(cap,nil);h.assert_eq(reason,'physical-input-modifiers-unsupported')
  end) end
  fixture(function(c,_,b)
   local read=b.chord_source_identity;b.chord_source_identity=function(...)local proof=read(...);proof.mods=8;return proof end
   local cap,reason=c.chord_sources(requests());h.assert_eq(cap,nil);h.assert_eq(reason,'physical-input-modifiers-unsupported')
  end)
 end)
 h.it('requires acknowledged native input fields without guessed zero',function()
  for _,field in ipairs({'input_generation','mods','latched_mods','base_mods'}) do fixture(function(c,_,b)
   local read=b.chord_source_identity;b.chord_source_identity=function(...)local proof=read(...);proof[field]=nil;return proof end
   local cap,reason=c.chord_sources(requests());h.assert_eq(cap,nil);h.assert_eq(reason,'physical-input-modifiers-unavailable')
  end) end
 end)
 h.it('refuses same-mask input epoch replacement during native chord callback',function()
  fixture(function(c,s)s.on_rows=function()s.input_generation=s.input_generation+1 end;local cap,reason=c.chord_sources(requests());h.assert_eq(cap,nil);h.assert_eq(reason,'physical-source-changed')end)
 end)
 h.it('revokes cached chord seal after equal-mask native input observation',function()
  fixture(function(c,s)local cap=assert(c.chord_sources(requests()));h.assert_eq(c.chord_source_current(cap),true);s.input_generation=s.input_generation+1;h.assert_eq(c.chord_source_current(cap),false)end)
 end)
end)
