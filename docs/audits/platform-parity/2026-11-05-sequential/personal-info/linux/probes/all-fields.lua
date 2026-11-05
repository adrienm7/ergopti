local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local base='/workspace/scratch/parity-sequential-2026-11-05/personal-info/linux/probes/'
local P=require('infra.hotstring_preferences');assert(P._set_file_for_test(base..'all-preferences.toml'))
local D=require('modules.dynamic_hotstrings.manager')
for _,family in ipairs(D.RULE_FAMILIES) do if family.id then assert(P.set('hotstrings.dynamic.'..family.id..'.enabled',true)) end end
assert(P.set('hotstrings.dynamic.enabled',true))
local keys={'bic','city','country','credit_card','date_of_birth','email_address','first_name','iban','last_name','phone_number','phone_number_clean','postal_code','social_security_number','street_address','work_email_address'}
local secret={bic=true,credit_card=true,iban=true,social_security_number=true}
local aliases,values={},{}
local path=base..'all-info.toml';local f=assert(io.open(path,'wb'));f:write('[info]\n')
for i,key in ipairs(keys) do values[key]='VALUE_'..string.format('%02d',i)..'_abcdefghijkl';f:write(key..'="'..values[key]..'"\n') end
f:write('[letters]\n');for i,key in ipairs(keys) do aliases[key]=string.char(96+i);f:write(aliases[key]..'="'..key..'"\n') end;f:close()
assert(D.init({personal_info_path=path,trigger_char='★'}))
local F=require('infra.personal_info_fields');local calls={}
package.loaded['modules.hotstrings.injector']={inject=function(backspaces,text,private,terminator,owner)
 assert(private==true and owner.current());calls[#calls+1]={backspaces=backspaces,text=text};return {ok=true,cleanup_ok=true}
end}
for _,key in ipairs(keys) do
 local value=values[key];assert(D.resolve_combo_values(aliases[key])[1]==value)
 assert(F.is_masked(key)==(secret[key]==true))
 local shown=F.for_preview(value,key);assert(secret[key] and shown~=value or not secret[key] and shown==value)
 assert(not F.for_log(value):find('VALUE',1,true))
 local ok,event=D.on_trigger('@'..aliases[key]..'★','★',true,{current=function() return true end,cached=function() return true end})
 assert(ok and event.is_private and event.replacement==value and calls[#calls].text==value)
 print('FIELD '..key..' alias='..aliases[key]..' masked='..tostring(secret[key]==true)..' insertion_full=true private=true')
end
assert(F.is_masked('custom_unknown_field'))
local payload=require('ui.personal_info_editor.bridge')._build_initial_payload({dyn_hotstrings=D,i18n={get=function(k) return k end}})
assert(#payload.fields==15)
for _,field in ipairs(payload.fields) do assert(field.value==values[field.key]);assert(field.hint=='(@'..aliases[field.key]..'★)') end
print('PASS all15 policy fields/custom aliases, full private insertion seam, full-value editor payload; no native input/display')
