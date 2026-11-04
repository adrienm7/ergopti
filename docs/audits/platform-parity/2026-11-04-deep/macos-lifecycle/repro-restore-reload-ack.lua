local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local with_changelog=require('tests.support.changelog_fixture').with_changelog
for _,mode in ipairs({'true','false','throw'})do
 with_changelog(function(changelog,state,post)
  local restores,reloads=0,0
  changelog._deps={updater={is_local_source=function()return false end,current_version=function()return '0.0.0-dev.140'end},
   backup={owner=function()return {latest=function()return nil end,restore=function()restores=restores+1;return true,nil,{path='/pre-restore'}end}end},
   installer={},coordinator={request_reload=function()reloads=reloads+1;if mode=='throw'then error('reload refused')end;return mode=='true'end}}
  assert(changelog.open({channel='dev'}));post('ready');post({action='restore_backup',id='pre-install-x'})
  local phases={}
  for _,code in ipairs(state.evaluations)do if code:find('setRestoreProgress(',1,true)then phases[#phases+1]=code:match('"phase":"([%a_]+)"')end end
  print('reload='..mode..' restores='..restores..' reload_calls='..reloads..' page_phases='..table.concat(phases,','))
  assert(restores==1 and reloads==1 and phases[#phases]=='restored')
 end)
end
