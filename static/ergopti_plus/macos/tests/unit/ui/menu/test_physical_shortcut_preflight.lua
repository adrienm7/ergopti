--- macos/tests/unit/ui/menu/test_physical_shortcut_preflight.lua

local helpers=require('tests.helpers');local Fixture=require('tests.support.physical_shortcut_registrar_fixture');local Codec=require('toml_codec')
local source='[shortcuts]\nenabled = true\nkeyboard = { foreign = 17 }\n[gestures]\naction_parameters = { tap_4__open_url="https://apple.com", future={keep=9} }\n[future]\nkeep=7\n'
local rows={{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text'},{section='gestures.action_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}}
helpers.describe('Mac physical preflight actual all-owner registrar',function()
 for _, mode in ipairs({'foreign_none','foreign_action','logical_chord','static_chord'}) do
  helpers.it('refuses '..mode..' through actual registrar and scope',function()
   Fixture.run(function(f)
    local registrar=require('adapters.hotkey_registrar')
    local slot=(mode=='logical_chord' or mode=='static_chord') and 'physical_ctrl_KeyG' or 'physical_none_KeyJ'
    if mode=='foreign_none' or mode=='foreign_action' then
     helpers.assert_eq(registrar.replace_physical_claims('independent-owner',{{mods={},native_code=38,action=mode=='foreign_none' and 'none' or 'send_text',binding_id='independent__j'}}),true)
    end
    local committed=f.owner.edit({{section='shortcuts.keyboard',key=slot,value='send_text',intent='keyboard_assignment'},{section='gestures.action_parameters',key='keyboard__'..slot..'__send_text',value='★'}})
    helpers.assert_eq(committed,false,'Conflict is rejected through the actual registrar')
    helpers.assert_eq(f.files.config,mode=='logical_chord' and source:gsub('foreign = 17','ctrl_g = "send_text", foreign = 17') or source,'Refusal preserves the exact source')
    helpers.assert_eq(f.owner.pending(),false,'Inverse settles')
    if mode=='foreign_none' or mode=='foreign_action' then
     helpers.assert_eq(registrar.has_physical_conflict({},38,'modules.shortcuts.keyboard_shortcuts','keyboard__physical_none_KeyJ'),true,'Independent ownership survives refusal')
     helpers.assert_eq(registrar.replace_physical_claims('independent-owner',{}),true)
    end
   end,mode=='logical_chord' and source:gsub('foreign = 17','ctrl_g = "send_text", foreign = 17') or source)
  end)
 end
 helpers.it('explicit physical record can displace a conditional recommendation',function()
  Fixture.run(function(f)
   local registrar=require('adapters.hotkey_registrar')
   local conditional=registrar.bind_conditional({},38,function() end)
   helpers.assert_true(conditional~=nil,'Actual conditional native recommendation acquired')
   local committed,detail=f.owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text',intent='keyboard_assignment'},{section='gestures.action_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}})
   helpers.assert_eq(committed,true,detail)
   helpers.assert_eq(Codec.decode(f.files.config).shortcuts.keyboard.physical_none_KeyJ,'send_text'
   )
   helpers.assert_eq(registrar.unbind(conditional),true)
  end,source)
 end)

end)

helpers.describe('Mac closed physical editor refusal receipts',function()
 for _, mode in ipairs({'foreign_none','foreign_action','logical_chord','static_chord'}) do
  helpers.it('returns authoritative collision from actual native '..mode,function()
   Fixture.run(function(f)
    local registrar=require('adapters.hotkey_registrar')
    local slot=(mode=='logical_chord' or mode=='static_chord') and 'physical_ctrl_KeyG' or 'physical_none_KeyJ'
    if mode=='foreign_none' or mode=='foreign_action' then
     helpers.assert_eq(registrar.replace_physical_claims('independent-owner',{{mods={},native_code=38,action=mode=='foreign_none' and 'none' or 'send_text',binding_id='independent__j'}}),true)
    end
    local committed,reason=f.owner.edit({{section='shortcuts.keyboard',key=slot,value='send_text',intent='keyboard_assignment'},{section='gestures.action_parameters',key='keyboard__'..slot..'__send_text',value='★'}})
    helpers.assert_eq(committed,false);helpers.assert_eq(reason,'collision')
    helpers.assert_eq(f.files.config,mode=='logical_chord' and source:gsub('foreign = 17','ctrl_g = "send_text", foreign = 17') or source)
    helpers.assert_eq(f.owner.pending(),false)
    if mode=='foreign_none' or mode=='foreign_action' then helpers.assert_eq(registrar.replace_physical_claims('independent-owner',{}),true)end
   end,mode=='logical_chord' and source:gsub('foreign = 17','ctrl_g = "send_text", foreign = 17') or source)
  end)
 end
 helpers.it('classifies native conflict-port throw without projecting its private detail',function()
  Fixture.run(function(f)
   local registrar=require('adapters.hotkey_registrar');local original=registrar.has_physical_conflict
   registrar.has_physical_conflict=function()error('private scalar path argv')end
   local committed,reason=f.owner.edit(rows)
   registrar.has_physical_conflict=original
   helpers.assert_eq(committed,false);helpers.assert_eq(reason,'unavailable');helpers.assert_eq(f.files.config,source)
  end,source)
 end)
 helpers.it('classifies actually unsupported native position without guessing from transformed logical input',function()
  Fixture.run(function(f)
   local claim={};helpers.assert_eq(f.keyboard.acquire_physical_publication(claim),true)
   local accepted,reason=f.keyboard.validate_physical_edits({{section='shortcuts.keyboard',key='physical_none_AudioVolumeUp',value='send_text'}},claim)
   helpers.assert_eq(accepted,false);helpers.assert_eq(reason,'unavailable');helpers.assert_eq(f.keyboard.release_physical_publication(claim),true)
   helpers.assert_eq(f.files.config,source)
  end,source)
 end)
 helpers.it('returns source_changed for foreign editor receipt with no native or source publication',function()
  Fixture.run(function(f)
   local before=f.controls.writes;local accepted,reason=f.owner.edit(rows,{})
   helpers.assert_eq(accepted,false);helpers.assert_eq(reason,'source_changed');helpers.assert_eq(f.controls.writes,before);helpers.assert_eq(f.files.config,source)
  end,source)
 end)
 helpers.it('success acknowledges no failure reason under the ordinary admission callback',function()
  Fixture.run(function(f)
   local accepted,reason=f.owner.edit(rows)
   helpers.assert_eq(accepted,true);helpers.assert_eq(reason,nil)
  end,source)
 end)
end)

helpers.describe('Mac physical reason transport under production Boolean admission contract',function()
 for _, mode in ipairs({'collision','private scalar path argv'})do
  helpers.it('retains only closed native reason through a Boolean-only admission: '..(mode=='collision' and 'known' or 'unknown'),function()
   local Scoped=require('ui.menu.scoped_preferences')
   local baseline={status='ok',content='controlled original source'}
   local owner=Scoped.new({scope='shortcuts',path='controlled',state={},files={},paused=function()return false end,
    admission=function(_,callback)return callback()==true end,backup_path=function()return 'protected' end,
    capture_preferences=function()return{}end,
    preferences={source_snapshot=function()return baseline end,replace_source=function()return true end},
    checkpoint={capture=function()return{}end,replace=function()return true,{}end,restore=function()return true end},
    runtime={capture=function()return{}end,apply=function()return true end,restore=function()return true end},
    edit_fence={acquire=function()return true end,release=function()return true end,validate=function()return false,mode end},
    transaction_factory=function(config)
     return{pending=function()return false end,apply_updates=function(_,updates)
      config.capture(baseline,'controlled candidate',updates)
      return config.apply({},updates),'private transaction detail discarded by Boolean admission'
     end}
    end})
   local accepted,reason=owner.edit(rows)
   helpers.assert_eq(accepted,false);helpers.assert_eq(reason,mode=='collision' and 'collision' or 'save_failed')
  end)
 end
end)
