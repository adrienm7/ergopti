--- tests/unit/ui/menu/test_physical_shortcut_scope.lua

local helpers=require('tests.helpers');local Fixture=require('tests.support.physical_shortcut_scope_fixture');local Codec=require('toml_codec')
local source='[shortcuts]\nenabled = true\nkeyboard = { foreign = 17 }\n[gestures]\naction_parameters = { tap_4__open_url="https://apple.com", future={keep=9} }\n[future]\nkeep=7\n'
local rows={{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text'},{section='gestures.action_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}}
helpers.describe('Mac actual physical scope edits',function()
 helpers.it('(physical-entry-scope) candidate Unicode cannot emit before source acknowledgement',function()
  Fixture.run(function(f)
   f.controls.during_write=function(path)
    if path=='config' then helpers.assert_eq(f.controls.physical_input(),false,'Native candidate stays inert inside actual publisher') end
   end
   local committed,detail=f.owner.edit(rows);helpers.assert_eq(committed,true,detail)
   local decoded=Codec.decode(f.files.config)
   helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,'send_text')
   helpers.assert_eq(decoded.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,'★')
   helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url,'https://apple.com')
   helpers.assert_eq(decoded.gestures.action_parameters.future.keep,9)
   helpers.assert_eq(decoded.shortcuts.keyboard.foreign,17)
   helpers.assert_eq(f.controls.physical_input(),true,'Only committed source opens physical delivery')
   f.controls.deliver_physical()
   hs.timer.__fire_all()
   helpers.assert_eq(f.controls.executions,{{action="send_text",binding="keyboard__physical_none_KeyJ"}},"Actual action executor called")
   helpers.assert_eq(f.controls.errors,{},"Action delivery acknowledged")
   helpers.assert_eq(f.controls.unicode_posts,{"★","★"},"Actual action emits literal Unicode down/up through the controlled native port")
  end,source)
 end)
 helpers.it('(physical-entry-scope) refused edit restores source parameters and exact fence',function()
  Fixture.run(function(f)
   f.controls.refuse_write=true
   local committed=f.owner.edit(rows);helpers.assert_eq(committed,false)
   helpers.assert_eq(f.files.config,source)
   helpers.assert_eq(f.keyboard.get_action('physical_none_KeyJ'),'none')
   helpers.assert_eq(f.gestures.get_action_parameter('keyboard__physical_none_KeyJ','send_text'),'')
   helpers.assert_eq(f.owner.pending(),false)
   helpers.assert_eq(f.controls.physical_input(),false)
  end,source)
 end)
 helpers.it('(physical-entry-scope) Remove owns actual None and its physical parameter inventory',function()
  local initial='[shortcuts]\nenabled=true\nkeyboard={physical_none_KeyJ="none",foreign=17}\n[gestures]\naction_parameters={keyboard__physical_none_KeyJ__send_text="★",tap_4__open_url="https://apple.com"}\n'
  Fixture.run(function(f)
   local committed,detail=f.owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',delete=true},{section='gestures.action_parameters',key='keyboard__physical_none_KeyJ__send_text',delete=true}})
   helpers.assert_eq(committed,true,detail)
   local decoded=Codec.decode(f.files.config)
   helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,nil)
   helpers.assert_eq(decoded.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,nil)
   helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url,'https://apple.com')
   helpers.assert_eq(f.keyboard.physical_assignments(),{})
  end,initial)
 end)
 helpers.it('(physical-entry-scope) explicit None is durable sparse intent',function()
  Fixture.run(function(f)
   local committed,detail=f.owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}})
   helpers.assert_eq(committed,true,detail)
   helpers.assert_eq(Codec.decode(f.files.config).shortcuts.keyboard.physical_none_KeyJ,'none')
   helpers.assert_eq(#f.keyboard.physical_assignments(),1)
   helpers.assert_eq(f.controls.physical_input(),false)
  end,source)
 end)

 for _, seam in ipairs({'source_snapshot','native_read','transient_publisher','parameter_change','private_source_replace'}) do
  helpers.it('(physical-reentry) actual consumer cancels after '..seam,function()
   Fixture.run(function(f)
    local committed,detail=f.owner.edit(rows);helpers.assert_eq(committed,true,detail)
    helpers.assert_eq(f.controls.physical_input(),true,'queue an admitted committed frame')
    local token,entered={},false
    local snapshot=f.prefs.source_snapshot
    local files=package.loaded['adapters.file_system'];local read=files.read_with_status
    local function reenter()
     if entered then return end;entered=true
     if seam=='parameter_change' then helpers.assert_eq(f.gestures.set_action_parameter('keyboard__physical_none_KeyJ','send_text','changed'),true)
     elseif seam=='private_source_replace' then
      local source=snapshot('config');helpers.assert_eq(f.prefs.replace_source('config',source,{status=source.status,content=source.content}),true)
     else
      helpers.assert_eq(f.keyboard.acquire_physical_publication(token),true)
      if seam=='transient_publisher' then helpers.assert_eq(f.keyboard.release_physical_publication(token),true) end
     end
    end
    if seam=='native_read' then files.read_with_status=function(path) local content,status=read(path);reenter();return content,status end
    else f.prefs.source_snapshot=function(path) local source=snapshot(path);reenter();return source end end
    f.controls.deliver_physical();hs.timer.__fire_all()
    helpers.assert_eq(entered,true,'controlled read executed the reentrant owner')
    helpers.assert_eq(f.controls.executions,{},'old frame must not reach the action owner after read reentry')
    helpers.assert_eq(f.controls.unicode_posts,{},'old frame emits no candidate Unicode')
    f.prefs.source_snapshot=snapshot;files.read_with_status=read
    if seam=='source_snapshot' or seam=='native_read' then helpers.assert_eq(f.keyboard.release_physical_publication(token),true) end
   end,source)
  end)
 end

 for _, mode in ipairs({'action_conflict','none_conflict','publication_conflict'}) do
  helpers.it('(physical-preflight) refuses '..mode..' before opening delivery',function()
   Fixture.run(function(f)
    local registrar=require('adapters.hotkey_registrar')
    local conflict=mode=='action_conflict' or mode=='none_conflict'
    registrar.has_physical_conflict=function() return conflict end
    local updates=mode=='none_conflict' and {{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}} or rows
    if mode=='publication_conflict' then f.controls.during_write=function(path) if path=='config' then conflict=true end end end
    local committed=f.owner.edit(updates)
    helpers.assert_eq(committed,false,'Conflicting candidate never opens editor fence')
    helpers.assert_eq(f.files.config,source,'Candidate source compensated byte-exact')
    helpers.assert_eq(f.owner.pending(),false,'Actual owned inverse settles')
    helpers.assert_eq(f.controls.physical_input(),false,'No conflicting candidate dispatch')
   end,source)
  end)
 end

 helpers.it('(physical-editor-frame) detached exact inventory commits through the same scope',function()
  Fixture.run(function(f)
   local inventory,receipt=f.owner.capture_editor_inventory()
   helpers.assert_true(type(inventory)=='table',tostring(receipt))
   helpers.assert_eq(inventory.assignments,{})
   helpers.assert_true(f.owner.editor_source_current(receipt))
   inventory.assignments.physical_none_KeyA='send_text'
   helpers.assert_eq(f.keyboard.get_action('physical_none_KeyA'),'none','Detached inventory cannot mutate actual input owner')
   helpers.assert_eq(f.owner.edit(rows,receipt),true)
   helpers.assert_eq(f.owner.editor_source_current(receipt),false,'Committed native/source replacement revokes old editor frame')
   local current=f.owner.capture_editor_inventory()
   helpers.assert_eq(current.assignments.physical_none_KeyJ,'send_text')
   helpers.assert_eq(current.parameters.keyboard__physical_none_KeyJ__send_text,'★')
  end,source)
 end)
 for _,mode in ipairs({'canonical_file','runtime_parameter','same_byte_private_source','forged_receipt'}) do
  helpers.it('(physical-editor-frame) refuses '..mode..' without writing',function()
   Fixture.run(function(f)
    local inventory,receipt=f.owner.capture_editor_inventory();helpers.assert_true(type(inventory)=='table',tostring(receipt))
    if mode=='canonical_file' then f.files.config=f.files.config..'# independent owner\n'
    elseif mode=='runtime_parameter' then helpers.assert_true(f.gestures.set_action_parameter('tap_key__number_row_left','send_text','unpublished'))
    elseif mode=='same_byte_private_source' then local old=f.prefs.source_snapshot('config');helpers.assert_true(f.prefs.replace_source('config',old,{status=old.status,content=old.content}))
    else receipt={} end
    local before,writes=f.files.config,f.controls.writes
    helpers.assert_eq(f.owner.editor_source_current(receipt),false)
    local committed,reason=f.owner.edit(rows,receipt);helpers.assert_eq(committed,false);helpers.assert_eq(reason,'source_changed')
    helpers.assert_eq(f.files.config,before);helpers.assert_eq(f.controls.writes,writes)
   end,source)
  end)
 end

end)

helpers.describe('Actual shared physical editor to Mac native scope',function()
 helpers.it('(physical-editor-ui) Unicode Add and Remove publish through exact actual source-return ACK',function()
  Fixture.run(function(f)
   local Json=require('json');local file=assert(io.open(helpers.shared("data/keycodes/physical_keys.json")));local model=require('shortcuts.physical_slots').new(Json.decode(file:read('*a')));file:close()
   local callback,selected
   local editor=require('shortcuts.physical_editor').new({model=model,catalogue=f.gestures,parameter_section='gestures.action_parameters',positions={},capture=f.owner.capture_editor_inventory,current=f.owner.editor_source_current,commit=f.owner.edit,label=f.gestures.get_action_label,picker=function(_,_,confirm)callback=confirm;return true end,emit=function(value)selected=value end})
   helpers.assert_eq(#editor.open().entries,0)
   helpers.assert_eq(editor.choose({code='KeyJ',mods={},request_id=1}),true);helpers.assert_eq(callback('send_text','★'),true)
   helpers.assert_eq(f.files.config,source,'Draft never publishes scalar/assignment')
   local outcome=editor.save(selected.token);helpers.assert_eq(outcome.committed,true);helpers.assert_eq(outcome.refreshed,true)
   local config=Codec.decode(f.files.config);helpers.assert_eq(config.shortcuts.keyboard.physical_none_KeyJ,'send_text');helpers.assert_eq(config.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,'★');helpers.assert_eq(config.shortcuts.keyboard.foreign,17);helpers.assert_eq(config.gestures.action_parameters.future.keep,9)
   helpers.assert_eq(editor.remove('physical_none_KeyJ').committed,true);config=Codec.decode(f.files.config);helpers.assert_eq(config.shortcuts.keyboard.physical_none_KeyJ,nil);helpers.assert_eq(config.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,nil);helpers.assert_eq(config.gestures.action_parameters.future.keep,9)
  end,source)
 end)
 helpers.it('(physical-editor-ui) stale native private source refuses draft without overwrite',function()
  Fixture.run(function(f)
   local Json=require('json');local file=assert(io.open(helpers.shared("data/keycodes/physical_keys.json")));local model=require('shortcuts.physical_slots').new(Json.decode(file:read('*a')));file:close()
   local callback,selected
   local editor=require('shortcuts.physical_editor').new({model=model,catalogue=f.gestures,parameter_section='gestures.action_parameters',positions={},capture=f.owner.capture_editor_inventory,current=f.owner.editor_source_current,commit=f.owner.edit,label=f.gestures.get_action_label,picker=function(_,_,confirm)callback=confirm;return true end,emit=function(value)selected=value end})
   editor.open();editor.choose({code='KeyJ',mods={},request_id=1});helpers.assert_eq(callback('send_text','★'),true)
   local private=f.prefs.source_snapshot('config');helpers.assert_eq(f.prefs.replace_source('config',private,{status=private.status,content=private.content}),true)
   helpers.assert_eq(editor.save(selected.token).committed,false);helpers.assert_eq(f.files.config,source)
  end,source)
 end)
end)


-- Legacy values are author-written independent expectations, not converted effects.
local preserved_source=source..'[shortcuts.a_grave]\nenabled=true\nletter="c"\n[shortcuts.e_acute]\nenabled=false\nletter="z"\n[shortcuts.e_circ]\nenabled=true\nletter="f"\n[shortcuts.e_grave]\nenabled=true\nletter="w"\n[shortcuts.keys]\ncmd_star=true\n[hotstrings]\nmagic_key_source_char="j"\nmagic_key_source="KeyQ"\ntrigger_char="★"\n[hotstrings.magic_key.replace]\nenabled=true\n[legacy_future]\nkeep={nested="untouched"}\n'
local function assert_legacy(document)
 helpers.assert_eq(document.shortcuts.a_grave,{enabled=true,letter="c"})
 helpers.assert_eq(document.shortcuts.e_acute,{enabled=false,letter="z"})
 helpers.assert_eq(document.shortcuts.e_circ,{enabled=true,letter="f"})
 helpers.assert_eq(document.shortcuts.e_grave,{enabled=true,letter="w"})
 helpers.assert_eq(document.shortcuts.keys,{cmd_star=true})
 helpers.assert_eq(document.hotstrings,{magic_key_source_char="j",magic_key_source="KeyQ",trigger_char="★",magic_key={replace={enabled=true}}})
 helpers.assert_eq(document.legacy_future,{keep={nested="untouched"}})
 helpers.assert_eq(document.shortcuts.keyboard.foreign,17)
 helpers.assert_eq(document.gestures.action_parameters.future,{keep=9})
end
local function planner_for(actions)
 local root=helpers.driver_root():gsub('/$','')..'/../_shared/'
 local file=assert(io.open(root..'data/keycodes/physical_keys.json','rb'));local registry=require('json').decode(file:read('*a'));assert(file:close())
 return require('shortcuts.physical_entries').new(require('shortcuts.physical_slots').new(registry),actions,{parameter_section='gestures.action_parameters'})
end
helpers.describe('Mac explicit physical entries preserve unrelated legacy semantics',function()
 helpers.it('does not invent a Unicode/J entry from accent letters or legacy magic defaults',function()
  Fixture.run(function(f)
   local inventory=assert(f.owner.capture_editor_inventory())
   helpers.assert_eq(f.keyboard.physical_assignments(),{});helpers.assert_eq(f.files.config,preserved_source)
   assert_legacy(Codec.decode(f.files.config))
   local rows,reason=planner_for(f.gestures).plan({operation='remove',slot='physical_none_KeyJ'},inventory)
   helpers.assert_eq(rows,nil);helpers.assert_eq(reason,'entry_absent')
  end,preserved_source)
 end)
 helpers.it('Add/Edit/None/Remove and acknowledged latest inverse preserve every legacy field',function()
  Fixture.run(function(f)
   local planner=planner_for(f.gestures)
   for _,request in ipairs({
    {operation='add',slot='physical_none_KeyJ',action='send_text',parameter='é★💫é'},
    {operation='edit',slot='physical_none_KeyJ',action='send_text',parameter='àèçù,:.'},
    {operation='edit',slot='physical_none_KeyJ',action='none'},
    {operation='remove',slot='physical_none_KeyJ'},
   }) do
    local inventory,receipt=f.owner.capture_editor_inventory();helpers.assert_true(type(inventory)=='table')
    local committed,reason=f.owner.edit(assert(planner.plan(request,inventory)),receipt);helpers.assert_eq(committed,true,reason)
    local decoded=Codec.decode(f.files.config);assert_legacy(decoded)
    helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,request.operation=='remove' and nil or request.action)
    if request.action=='send_text' then
     helpers.assert_eq(decoded.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,request.parameter)
     helpers.assert_eq(f.gestures.get_action_parameter('keyboard__physical_none_KeyJ','send_text'),request.parameter)
     local start=#f.controls.unicode_posts
     helpers.assert_true(f.controls.physical_input());f.controls.deliver_physical();hs.timer.__fire_all()
     local observed={};for index=start+1,#f.controls.unicode_posts do observed[#observed+1]=f.controls.unicode_posts[index] end
     local expected=request.parameter=='é★💫é' and {'é','é','★','★','💫','💫','e','e','́','́'}
      or {'à','à','è','è','ç','ç','ù','ù',',',',',':',':','.','.'}
     helpers.assert_eq(observed,expected,'Actual Unicode down/up posts preserve author-written codepoints without normalization')
    end
   end
   helpers.assert_true(f.owner.revert());local reverted=Codec.decode(f.files.config);assert_legacy(reverted)
   helpers.assert_eq(reverted.shortcuts.keyboard.physical_none_KeyJ,'none')
   helpers.assert_eq(reverted.gestures.action_parameters.keyboard__physical_none_KeyJ__send_text,'àèçù,:.')
  end,preserved_source)
 end)
 helpers.it('refused explicit Unicode publication preserves the exact old canonical bytes',function()
  Fixture.run(function(f)
   local inventory,receipt=f.owner.capture_editor_inventory()
   local rows=assert(planner_for(f.gestures).plan({operation='add',slot='physical_none_KeyJ',action='send_text',parameter='★'},inventory))
   f.controls.refuse_write=true;helpers.assert_eq(f.owner.edit(rows,receipt),false)
   helpers.assert_eq(f.files.config,preserved_source);assert_legacy(Codec.decode(f.files.config))
   helpers.assert_eq(f.keyboard.physical_assignments(),{});helpers.assert_eq(f.owner.pending(),false)
  end,preserved_source)
 end)
end)

helpers.describe("Mac unqualified physical delivery admission",function()
 helpers.it("(partial-physical-admission) refuses physical output from an unqualified native owner",function()
  local initial=source:gsub('foreign = 17','physical_none_KeyJ="send_text", foreign = 17')
  Fixture.run(function(f)
   helpers.assert_eq(f.controls.native_delivery_available(),false)
   f.controls.delivery_available=false
   helpers.assert_eq(f.owner.physical_delivery_available(),false)
   helpers.assert_eq(f.controls.physical_input(),false)
   local before=#f.controls.executions
   f.controls.deliver_physical();hs.timer.__fire_all()
   helpers.assert_eq(#f.controls.executions,before)
  end,initial)
 end)
 helpers.it("(partial-physical-admission) refuses manual Save and parameter writes before publication",function()
  Fixture.run(function(f)
   f.controls.delivery_available=false
   local before=f.controls.writes
   for _,updates in ipairs({rows,{{section="gestures.action_parameters",key="keyboard__physical_none_KeyJ__send_text",value="changed"}}})do
    local accepted,reason=f.owner.edit(updates)
    helpers.assert_eq(accepted,false);helpers.assert_eq(reason,"unavailable")
   end
   helpers.assert_eq(f.files.config,source);helpers.assert_eq(f.controls.writes,before)
   helpers.assert_eq(f.owner.pending(),false)
  end,source)
 end)
 helpers.it("(partial-physical-admission) preserves acknowledged None and Delete without enabling native input",function()
  Fixture.run(function(f)
   f.controls.delivery_available=false
   local accepted,reason=f.owner.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",value="none"}})
   helpers.assert_eq(accepted,true,reason)
   helpers.assert_eq(Codec.decode(f.files.config).shortcuts.keyboard.physical_none_KeyJ,"none")
   helpers.assert_eq(f.controls.physical_input(),false)
   helpers.assert_true(f.owner.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",delete=true}}))
   local document=Codec.decode(f.files.config)
   helpers.assert_eq(document.shortcuts.keyboard.physical_none_KeyJ,nil)
   helpers.assert_eq(document.shortcuts.keyboard.foreign,17)
   helpers.assert_eq(document.gestures.action_parameters.future.keep,9)
  end,source)
 end)
 helpers.it("(partial-physical-admission) refuses standalone physical assignment without changing legacy configuration",function()
  Fixture.run(function(f)
   f.controls.delivery_available=false
   helpers.assert_eq(f.keyboard.set_action("physical_none_KeyJ","send_text"),false)
   helpers.assert_eq(f.files.config,source)
  end,source)
 end)
end)

helpers.describe("Mac detached physical admission rows",function()
 helpers.it("(physical-row-custody) admitted None cannot become active inside native menu admission",function()
  Fixture.run(function(f)
   f.controls.delivery_available=false
   local updates={{section="shortcuts.keyboard",key="physical_none_KeyJ",value="none"}}
   f.controls.before_admission=function()updates[1].value="send_text"end
   helpers.assert_true(f.owner.edit(updates))
   helpers.assert_eq(updates[1].value,"send_text","controlled native admission actually mutated caller rows")
   helpers.assert_eq(Codec.decode(f.files.config).shortcuts.keyboard.physical_none_KeyJ,"none")
   helpers.assert_eq(f.keyboard.get_action("physical_none_KeyJ"),"none")
  end,source)
 end)
end)
