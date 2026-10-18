--- tests/unit/infra/scope/test_key_combinations_scope_declared_simultaneous_publication.lua

--- Actual canonical pair and parameter owners through the shared publisher.
--- File and native delivery ports are controlled; no physical input is claimed.

package.loaded["tests.support.infra.scope.key_combinations_scope_fixture"] = nil
local Fixture = require("tests.support.infra.scope.key_combinations_scope_fixture")
local helpers, Codec, path, backup, pair, binding, parameter, source, with_menu, find_menu, with_public_owner, seed_public =
	Fixture.helpers, Fixture.Codec, Fixture.path, Fixture.backup, Fixture.pair, Fixture.binding, Fixture.parameter, Fixture.source, Fixture.with_menu, Fixture.find_menu, Fixture.with_public_owner, Fixture.seed_public




helpers.describe("declared Linux simultaneous publication through original owners",function()
 helpers.it("uses declared Linux neutral values and all182 unassigned third slots",function()
  with_public_owner(function(s)
   local f=require("infra.manifest_reader")
   helpers.assert_eq(f.default_for("mod_combos.simultaneous_threshold_ms"),100)
   helpers.assert_eq(f.default_for("mod_combos.symmetric"),false)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
   local count=0;for _,entry in ipairs(s.pairs.configuration_entries()) do
    count=count+1;helpers.assert_eq(s.pairs.get_chord(entry.id),"none")
    helpers.assert_eq(f.default_for("mod_combos.config."..entry.id..".combo"),"none")
    helpers.assert_eq(f.recommended_for("mod_combos.config."..entry.id..".combo"),"none")
   end
   helpers.assert_eq(count,182);helpers.assert_eq(s.publications,0)
  end)
 end)
 helpers.it("publishes typed timing and symmetry and reverts exact source/runtime",function()
  with_public_owner(function(s)
   helpers.assert_true(s.scope.set_chord_settings({simultaneous_threshold_ms=75,combo_symmetric=true}))
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.mod_combos.simultaneous_threshold_ms,75)
   helpers.assert_eq(doc.mod_combos.symmetric,true);helpers.assert_eq(doc.unrelated.keep,42)
   helpers.assert_eq(doc.shortcuts.key_combination_taps.future_then_tab,"future")
   helpers.assert_eq(doc.category_enabled,nil);helpers.assert_eq(doc.mod_combos.enabled,nil)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=75,combo_symmetric=true})
   helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],source)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
  end)
 end)
 helpers.it("removes explicit neutral settings sparsely without changing disabled switches",function()
  with_public_owner(function(s)
   local text=source..'[mod_combos]\nenabled=false\nsimultaneous_threshold_ms=75\nsymmetric=true\n[category_enabled]\nkey_combinations=false\n'
   seed_public(s,text)
   helpers.assert_true(s.scope.set_chord_settings({simultaneous_threshold_ms=100,combo_symmetric=false}))
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.mod_combos.simultaneous_threshold_ms,nil)
   helpers.assert_eq(doc.mod_combos.symmetric,nil);helpers.assert_eq(doc.mod_combos.enabled,false)
   helpers.assert_eq(doc.category_enabled.key_combinations,false)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
   helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],text)
  end)
 end)
 helpers.it("copies fresh Linux tap leaves and preserves disabled gate and foreign records",function()
  with_public_owner(function(s)
   local text=source:gsub('caps_lock_then_tab = "open_url"','caps_lock_then_tab = "copy"',1)
    ..'[mod_combos]\nenabled=false\n[mod_combos.config.caps_lock_then_tab]\ncombo="none"\ntap="paste"\nfuture=17\n'
    ..'[mod_combos.config.future_then_tab]\ncombo="foreign_action"\n'
   seed_public(s,text)
   helpers.assert_true(s.scope.copy_taps_to_chords())
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.mod_combos.enabled,false)
   helpers.assert_eq(doc.mod_combos.config[pair].combo,"copy")
   helpers.assert_eq(doc.mod_combos.config[pair].tap,"paste");helpers.assert_eq(doc.mod_combos.config[pair].future,17)
   helpers.assert_eq(doc.mod_combos.config.future_then_tab.combo,"foreign_action")
   helpers.assert_eq(doc.shortcuts.key_combination_taps.future_then_tab,"future")
   helpers.assert_eq(doc.gesture_parameters[parameter],"https://old.example")
   helpers.assert_eq(doc.mod_combos.simultaneous_threshold_ms,nil);helpers.assert_eq(doc.mod_combos.symmetric,nil)
   helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],text)
  end)
 end)
 helpers.it("refuses stale cached taps before backup instead of publishing misaligned copy",function()
  with_public_owner(function(s)
   s.bytes[path]=source:gsub('caps_lock_then_tab = "open_url"','caps_lock_then_tab = "copy"',1)
   local exact=s.bytes[path]
   helpers.assert_eq(s.scope.copy_taps_to_chords(),false)
   helpers.assert_eq(s.bytes[path],exact);helpers.assert_eq(s.bytes[backup],nil);helpers.assert_eq(s.publications,0)
   helpers.assert_true(s.scope.retry_restore())
  end)
 end)
 helpers.it("publishes only admitted known combo leaves and deletes None sparsely",function()
  with_public_owner(function(s)
   local row={section="mod_combos.config."..pair,key="combo",value="copy"}
   helpers.assert_true(s.scope.edit({row}));helpers.assert_eq(s.pairs.get_chord(pair),"copy")
   helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.config[pair].combo,"copy")
   helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],source)
  end)
  with_public_owner(function(s)
   local text=source..'[mod_combos.config.caps_lock_then_tab]\ncombo="copy"\nfuture=17\n'
   seed_public(s,text)
   helpers.assert_true(s.scope.edit({{section="mod_combos.config."..pair,key="combo",delete=true}}))
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.mod_combos.config[pair].combo,nil)
   helpers.assert_eq(doc.mod_combos.config[pair].future,17);helpers.assert_eq(s.pairs.get_chord(pair),"none")
  end)
 end)
 for _,action in ipairs({"one_shot_shift","caps_word","run_program","alt_tab_monitor","unknown_action"}) do
  helpers.it("refuses unqualified simultaneous action "..action,function()
   with_public_owner(function(s)
    helpers.assert_eq(s.scope.edit({{section="mod_combos.config."..pair,key="combo",value=action}}),false)
    helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.publications,0)
   end)
  end)
 end
 for _,values in ipairs({{simultaneous_threshold_ms=0,combo_symmetric=false},{simultaneous_threshold_ms=100,combo_symmetric="false"},
  {simultaneous_threshold_ms=100,combo_symmetric=false,extra=true}}) do
  helpers.it("refuses malformed settings before any callback or publication",function()
   with_public_owner(function(s)
    helpers.assert_eq(s.scope.set_chord_settings(values),false);helpers.assert_eq(s.changes,0)
    helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.publications,0)
   end)
  end)
 end
 helpers.it("detaches settings and edit rows before acquisition callbacks",function()
  with_public_owner(function(s)
   local values={simultaneous_threshold_ms=75,combo_symmetric=true}
   s.changed=function() values.simultaneous_threshold_ms=9;values.combo_symmetric=false;return true end
   helpers.assert_true(s.scope.set_chord_settings(values))
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=75,combo_symmetric=true})
  end)
  with_public_owner(function(s)
   local row={section="mod_combos.config."..pair,key="combo",value="copy"}
   s.changed=function() row.value="open_url";return true end
   helpers.assert_true(s.scope.edit({row}));helpers.assert_eq(s.pairs.get_chord(pair),"copy")
  end)
 end)
 helpers.it("retains genuine program-stop refusal without publication or foreign cleanup",function()
  with_public_owner(function(s)
   local stop=s.gestures.stop_programs;s.gestures.stop_programs=function() return false end
   helpers.assert_eq(s.scope.copy_taps_to_chords(),false);helpers.assert_eq(s.bytes[path],source)
   helpers.assert_eq(s.publications,0);helpers.assert_true(s.scope.pending())
   helpers.assert_eq(s.pairs.capture_runtime(),nil)
   s.gestures.stop_programs=stop;helpers.assert_true(s.scope.retry_restore())
  end)
 end)
 helpers.it("retains a foreign parameter lease while refusing the whole copy",function()
  with_public_owner(function(s)
   local foreign={};helpers.assert_true(s.gestures.acquire_parameter_configuration(foreign))
   helpers.assert_eq(s.scope.copy_taps_to_chords(),false)
   helpers.assert_true(type(s.gestures.parameter_configuration_snapshot(foreign))=="table")
   helpers.assert_eq(s.publications,0);helpers.assert_true(s.scope.pending())
   helpers.assert_true(s.gestures.release_parameter_configuration(foreign));helpers.assert_true(s.scope.retry_restore())
  end)
 end)
 helpers.it("rolls typed settings back on publication refusal and preserves exact snapshot",function()
  with_public_owner(function(s)
   s.refuse_path=path
   helpers.assert_eq(s.scope.set_chord_settings({simultaneous_threshold_ms=75,combo_symmetric=true}),false)
   helpers.assert_eq(s.bytes[path],source)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
   helpers.assert_eq(s.scope.pending(),false)
  end)
 end)
 helpers.it("holds native delivery through final callbacks and retains refused release debt",function()
  with_public_owner(function(s)
   local release=s.gestures.release_parameter_configuration
   s.gestures.release_parameter_configuration=function(token)
    helpers.assert_eq(s.pairs.capture_runtime(),nil,"native release cannot open third-slot delivery before parameter ACK")
    if token==s.scope then return false end
    return release(token)
   end
   helpers.assert_eq(s.scope.set_chord_settings({simultaneous_threshold_ms=75,combo_symmetric=true}),false)
   helpers.assert_true(s.scope.pending());helpers.assert_eq(s.pairs.capture_runtime(),nil)
   s.gestures.release_parameter_configuration=release;helpers.assert_true(s.scope.retry_restore())
   helpers.assert_eq(s.bytes[path],source)
  end)
 end)
 helpers.it("requires an explicit Linux copy section and leaves original Mac policy distinct",function()
  local Shared=require("tap_hold.key_combinations")
  local text='[shortcuts.key_combination_taps]\ncaps_lock_then_tab="copy"\n[mod_combos.config.caps_lock_then_tab]\ntap="paste"\ncombo="none"\n'
  local options={entries={{id=pair}},settings={simultaneous_threshold_ms=100,combo_symmetric=false},is_action=function(a) return a=="copy" or a=="paste" end}
  helpers.assert_eq(Shared.plan_chord_copy(text,options).rows[1].value,"paste","original Mac source is unchanged")
  options.tap_section=Shared.TAP_SECTION
  helpers.assert_eq(Shared.plan_chord_copy(text,options).rows[1].value,"copy")
  options.tap_section="shortcuts.keyboard"
  local accepted,refusal=pcall(Shared.plan_chord_copy,text,options)
  helpers.assert_eq(accepted,false,"an undeclared copy source is refused")
  helpers.assert_true(type(refusal)=="string")
  helpers.assert_true(refusal:find("copy source section must be explicitly declared",1,true)~=nil,
   "the actual copy namespace guard supplies the refusal")
 end)
end)




helpers.describe("public Linux simultaneous menu uses actual source and scope owners",function()
 helpers.it("adds one lazy third slot per original182 pairs without eager action catalogues",function()
  with_menu(function(s)
   local rows=s.build();local count,total=0,0
   local function walk(list) for _,row in ipairs(list or {}) do
    total=total+1
    if tostring(row.title or ''):find('  :  ',1,true) then
     count=count+1;helpers.assert_eq(#row.menu,4)
     helpers.assert_true(find_menu(row.menu,s.translate('menu.shortcuts.key_combinations_chord'):gsub('%%s',s.translate('tap_hold.tap.none')))~=nil)
    end
    if row.menu then walk(row.menu) end
   end end
   walk(rows);helpers.assert_eq(count,182);helpers.assert_true(total<1500)
   helpers.assert_eq(s.picker,nil);helpers.assert_eq(s.publications,0)
   helpers.assert_true(find_menu(rows,s.translate('menu.tapholds.symmetric'),true)~=nil)
   helpers.assert_true(find_menu(rows,s.translate('menu.tapholds.copy_tap_to_combo'),true)~=nil)
  end,true)
 end)
 helpers.it("the real combo picker publishes its exact slot and excludes undispatched native state actions",function()
  with_menu(function(s)
   local row=find_menu(s.build(),'caps_lock → tab')
   local chord=find_menu(row.menu,s.translate('menu.shortcuts.key_combinations_chord'):gsub('%%s',s.translate('tap_hold.tap.none')))
   helpers.assert_true(chord.fn());helpers.assert_eq(s.picker.binding,binding)
   for _,item in ipairs(s.picker.items) do helpers.assert_true(item.id~='one_shot_shift' and item.id~='caps_word' and item.id~='run_program' and item.id~='alt_tab_monitor') end
   helpers.assert_true(s.picker.confirm('copy'))
   helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.config[pair].combo,'copy')
   helpers.assert_eq(s.pairs.get_chord(pair),'copy');helpers.assert_eq(s.refreshes,1)
  end,true)
 end)
 helpers.it("symmetric UI routes reverse third choices to shared catalogue canonical IDs",function()
  with_menu(function(s)
   local rows=s.build();helpers.assert_true(find_menu(rows,s.translate('menu.tapholds.symmetric'),true).fn())
   helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.symmetric,true)
   local row=find_menu(s.build(),'caps_lock → tab')
   helpers.assert_true(find_menu(row.menu,s.translate('menu.shortcuts.key_combinations_chord'):gsub('%%s',s.translate('tap_hold.tap.none'))).fn())
   helpers.assert_eq(s.picker.binding,'combination__tab_then_caps_lock')
   helpers.assert_true(s.picker.confirm('copy'))
   helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.config.tab_then_caps_lock.combo,'copy')
   helpers.assert_eq(s.pairs.get_chord(pair),'copy')
  end,true)
 end)
 helpers.it("delay dialog persists typed values through original source receipt and sparse defaults",function()
  with_menu(function(s)
   local function delay_row() return find_menu(s.build(),s.translate('menu.tapholds.simultaneous_title'):gsub('%%s','')) end
   s.delay_selection='75';helpers.assert_true(delay_row().fn())
   helpers.assert_eq(s.delay_prompt,{100,100});helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.simultaneous_threshold_ms,75)
   s.delay_selection='100';helpers.assert_true(delay_row().fn())
   helpers.assert_eq(s.delay_prompt,{75,100});helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.simultaneous_threshold_ms,nil)
   helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
  end,true)
 end)
 for _,kind in ipairs({'cancel','invalid','paused','source'}) do
  helpers.it('refuses '..kind..' delay without publication',function()
   with_menu(function(s)
    s.delay_selection=kind=='invalid' and '0' or '75'
    if kind=='cancel' then s.delay_selection=nil end
    s.on_delay=function()
     if kind=='paused' then s.paused=true end
     if kind=='source' then s.bytes[path]=source..'[outside]\nchanged=true\n' end
    end
    local row=find_menu(s.build(),s.translate('menu.tapholds.simultaneous_title'):gsub('%%s',''))
    helpers.assert_eq(row.fn(),false);helpers.assert_eq(s.publications,0)
   end,true)
  end)
 end
 helpers.it("copy command and clear command publish through actual guarded scope",function()
  with_menu(function(s)
   local rows=s.build();helpers.assert_true(find_menu(rows,s.translate('menu.tapholds.copy_tap_to_combo'),true).fn())
   helpers.assert_eq(Codec.decode(s.bytes[path]).mod_combos.config[pair].combo,'open_url')
   helpers.assert_eq(s.pairs.get_chord(pair),'open_url')
   helpers.assert_true(find_menu(s.build(),s.translate('common.clear_to_system'),true).fn())
   helpers.assert_eq(s.pairs.get_chord(pair),'none');helpers.assert_eq(s.pairs.get_action(pair),'none')
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.shortcuts.key_combination_taps.future_then_tab,'future')
   helpers.assert_eq(doc.gesture_parameters[parameter],nil);helpers.assert_eq(doc.unrelated.keep,42)
  end,true)
 end)
end)




helpers.describe("unjoined third-slot native receiving is unavailable",function()
 for _,action in ipairs({"run_program","alt_tab_monitor"}) do
  helpers.it("the actual generic catalogue cannot authorize third-slot "..action,function()
   with_menu(function(s)
    helpers.assert_true(s.gestures.is_assignable(action))
    helpers.assert_true(s.pairs.validate_slot("tap",pair,action))
    helpers.assert_eq(s.pairs.validate_slot("combo",pair,action),false)
    helpers.assert_eq(s.pairs.capture_action(binding,action),nil)
    local row=find_menu(s.build(),'caps_lock → tab')
    local chord=find_menu(row.menu,s.translate('menu.shortcuts.key_combinations_chord'):gsub('%%s',s.translate('tap_hold.tap.none')))
    helpers.assert_true(chord.fn())
    for _,item in ipairs(s.picker.items) do helpers.assert_true(item.id~=action) end
    helpers.assert_eq(s.picker.confirm(action),false)
    helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.publications,0)
   end,true)
  end)
 end
end)

