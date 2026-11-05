local root=assert(arg[1]);local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs');local helpers=require('tests.helpers');package.loaded['infra.logger']=helpers.make_logger_stub()
local Text=helpers.load_with_stubs('modules.shortcuts.actions.text')
package.loaded['infra.deferred_work']={after=function()return true end}
package.loaded['infra.fs_dir']={entries=function()return{}end}
package.loaded['infra.dialog_util']={}
package.loaded['modules.shortcuts']={DEFAULT_STATE={chatgpt_url='https://example.test',shortcuts=true}}
package.loaded['infra.i18n']={get=function(k)return k end,section=function(k)return k end,decorate_section=function(k)return k end}
package.loaded['ui.menu.menu_utils']={}
local Native=require('infra.manifest_menu')
package.loaded['infra.manifest_menu']={group_receiver=Native.group_receiver,template_rows=Native.template_rows,build=function(_,_,_,_,_,providers)return providers.wrap_symbols_menu()end}
package.loaded['ui.menu.shortcut_utils']={};package.loaded['ui.menu.menu_keyboard_slots']={provide_rows=function()return{}end};package.loaded['infra.manifest_reader']={default_for=function()return 'star'end}
local state={shortcuts=true,chatgpt_url='https://example.test',wrap_symbol_states={},custom_wrap_symbols={}}
local getter;local saves=0;local ack=true
local shortcuts={list_shortcuts=function()return{}end,resume_bindings=function()return true end,pause_bindings=function()return true end,set_wrap_pairs_getter=function(g)getter=g;return true end}
local Menu=require('ui.menu.menu_shortcuts')
local function build()
 return assert(Menu.build({base_dir='/fixture/driver/',shortcuts=shortcuts,state=state,paused=false,applyTriggerChar=function(v)return v end,save_prefs=function()saves=saves+1;assert(getter()['“']~=nil,'input must hold previous view while saving');return ack end,notify_feature=function()end,updateMenu=function()end,commands={},state_getters={}})).submenu[1].items
end
local function row(items,label)
 for _,v in ipairs(items)do if v.label==label then return v end end
 error('missing actual menu row: '..label)
end
local items=build();local quotes=row(items,'menu.shortcuts.wrap_group_quotes').items
assert(row(quotes,'“ … ”').checked and row(quotes,'„ … “').checked)
ack=false;assert(row(quotes,'„ … “').action()==false);assert(state.wrap_symbol_states['„']==nil and getter()['“']);print('refused preference ACK control: prior “ native lookup remains and state unchanged')
ack=true;assert(row(quotes,'„ … “').action()==true);assert(state.wrap_symbol_states['„']==false and getter()['“']==nil)
local refreshed=row(build(),'menu.shortcuts.wrap_group_quotes').items
assert(row(refreshed,'“ … ”').checked==true and not row(refreshed,'„ … “').checked)
print('WSM-003 actual menu: disabled „ … “; refreshed “ … ” stays checked; live input getter[“]=nil; saves='..saves)
local guillemets=row(refreshed,'«  …  »');assert(guillemets.checked==true);assert(getter()['«']==nil and getter()['«\u{00A0}']==nil and getter()['« ']);print('WSM-001 actual menu: spaced « … » stays checked; bare and shipped NBSP guillemet triggers absent; ASCII-space key present')
