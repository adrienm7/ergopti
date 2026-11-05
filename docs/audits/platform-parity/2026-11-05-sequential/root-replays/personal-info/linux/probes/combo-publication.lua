local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
require('adapters.storage');require('toml_codec.writer');require('config_file_inverse')
local basedir='/workspace/scratch/parity-sequential-2026-11-05/root-replays/personal-info/linux/probes/'
local P=require('infra.hotstring_preferences');assert(P._set_file_for_test(basedir..'private-preferences.toml'))
local Manager=require('modules.dynamic_hotstrings.manager')
for _,family in ipairs(Manager.RULE_FAMILIES) do if family.id then assert(P.set('hotstrings.dynamic.'..family.id..'.enabled',true)) end end
assert(P.set('hotstrings.dynamic.enabled',true))
local path=basedir..'private-info.toml';local f=assert(io.open(path,'wb'));f:write('[info]\nfirst_name="e"\nlast_name="s"\n[letters]\np="first_name"\nn="last_name"\n');f:close()
assert(Manager.init({personal_info_path=path,trigger_char='★'}))
local layout=require('adapters.keyboard_layout');layout._set_table_for_test({s={keycode=31,mods={}},e={keycode=18,mods={}}})
local original_plan=layout.plan
local transition
layout.plan=function(...) if transition then transition() end;return original_plan(...) end
local Injector=require('modules.hotstrings.injector');Injector._set_nanosleep_for_test(function() end)
local Fixture=require('tests.support.text_owner_fixture')
local function scenario(tag, change)
 Fixture.with(function(guard,focus)
  local wire,targets={},{}
  Injector._set_uinput({is_open=function() return true end,emit=function(code,value)
   wire[#wire+1]=code..':'..value;targets[focus.path]=true;return true
  end})
  local publication=assert(guard.capture_text_owner())
  local once=false
  transition=function() if not once and change then once=true;focus.path='/field/successor' end end
  local fired,event=Manager.on_trigger('@'..tag..'★','★',true,publication)
  local stale=not publication.current()
  print('tag='..tag..' changed='..tostring(change)..' publication_stale='..tostring(stale)..' fired='..tostring(fired)..' emits='..#wire..' successor='..tostring(targets['/field/successor']==true))
  if change and tag=='p' then assert(stale and not fired and #wire==0) end
  if change and tag=='np' then assert(stale and fired and #wire>0 and targets['/field/successor']) end
  if not change then assert(fired and #wire>0 and not targets['/field/successor']) end
  if fired then assert(event.is_private==true);assert(event.replacement==(tag=='np' and 'se' or 'e')) end
  if tag=='np' and fired then local tabs=0;for _,write in ipairs(wire) do if write=='15:1' then tabs=tabs+1 end end;assert(tabs==1) end
  transition=nil;Injector._set_uinput(nil)
 end)
end
scenario('p',false);scenario('np',false);scenario('p',true);scenario('np',true)
layout.plan=original_plan;Injector._set_nanosleep_for_test(nil)
print('PASS production manager+injector+focus guard; controlled native focus/uinput ports; no native desktop receiving')
