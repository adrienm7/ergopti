local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local H=require('tests.helpers');_G.hs=require('hs')
local uv=require('luv');local Codec=require('toml_codec')
for _,mode in ipairs({'timer_refused','settings_refused','persist_settings_refused','cancel_refused'})do
 local dir=assert(uv.fs_mkdtemp('/tmp/ergopti-audit-locale-XXXXXX'));local path=dir..'/config.toml'
 local f=assert(io.open(path,'wb'));assert(f:write('[script]\nlocale="fr"\n'));assert(f:close())
 for _,name in ipairs({'infra.i18n','infra.script_scope','adapters.storage','adapters.timer_scheduler','adapters.file_system'})do package.loaded[name]=nil end
 package.loaded['infra.config_paths']={get=function()return path end}
 local log=H.make_logger_stub();local errors={};log.error=function(_,format,...)errors[#errors+1]=string.format(format,...)end
 package.loaded['infra.logger']=log
 for key in pairs(hs.settings.__store)do hs.settings.__store[key]=nil end;local original_set=hs.settings.set
 if mode=='settings_refused' or mode=='persist_settings_refused' then hs.settings.set=function()return false end end
 local callbacks,reloads={},0;hs.reload=function()reloads=reloads+1;return true end
 package.loaded['adapters.timer_scheduler']={after=function(_,fn)callbacks[#callbacks+1]=fn;return {timer=mode=='timer_refused' and nil or {}},mode~='timer_refused' end,cancel=function()return mode~='cancel_refused' end}
 local i18n=require('infra.i18n');assert(i18n.get_locale()=='fr')
 local accepted
 if mode=='cancel_refused' then assert(i18n.set_locale('de')==true);accepted=i18n.set_locale('en')
 elseif mode=='persist_settings_refused' then accepted=i18n.persist_locale('de') else accepted=i18n.set_locale('de') end
 assert(accepted==false)
 local current=assert(io.open(path,'rb'));local bytes=current:read('*a');current:close()
 local expected=mode=='cancel_refused' and 'en' or 'de'
 assert(Codec.decode(bytes).script.locale==expected)
 assert(i18n.get_locale()==(mode=='cancel_refused' and 'de' or 'fr'))
 if mode=='cancel_refused' then assert(hs.settings.get('ergopti.i18n_locale')=='de');callbacks[1]();assert(reloads==1)else assert(hs.settings.get('ergopti.i18n_locale')==nil)end
 hs.settings.set=original_set
 local adopted=assert(require('infra.script_scope').adopt_configured());assert(adopted['script.locale']==expected)
 assert(require('adapters.storage').get('i18n_locale')==expected)
 print(mode..': public=false; current RAM='..i18n.get_locale()..'; canonical disk='..expected..'; next-start adoption='..expected..'; earlier accepted reloads='..reloads..'; errors='..#errors)
 -- Writer locks are process-owned scratch state. Remove only this probe directory.
 for name in uv.fs_scandir_next,assert(uv.fs_scandir(dir))do assert(uv.fs_unlink(dir..'/'..name))end
 assert(uv.fs_rmdir(dir))
end
print('Real locale+script authority+native file writer+boot adoption; timer/settings refusals recorded; no user preference state touched.')
