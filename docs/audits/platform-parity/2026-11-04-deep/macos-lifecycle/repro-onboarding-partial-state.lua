local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local with_finish=require('tests.support.onboarding_finish_fixture').with_finish
for _,mode in ipairs({'true','false','throw','newer-schema'})do
 local directory='/old-config'
 local path_writes={}
 with_finish({answers={locale='de',config_dir='/new-config',operations={{path='gestures.enabled',value=false}}},write=mode,read=mode=='newer-schema' and function()return '[_meta]\nschema_version = 999\n', 'ok'end or nil,
  menu_paths={persist_config_dir_for_wizard=function(value) directory=value;path_writes[#path_writes+1]=value;return true end,
    get=function()return directory..'/config.toml'end}},function(state)
  print(string.format('write=%s current_dir=%s path_writes=%d locale_persists=%d config_writes=%d error_alerts=%d reloads=%d',
   mode,directory,#path_writes,state.locale_persists,#state.writes,#state.alerts,state.deferred))
  assert(directory=='/new-config' and #path_writes==1)
  if mode~='true'then assert(#state.alerts==1 and state.deferred==0 and state.notifications==0)end
 end)
end
