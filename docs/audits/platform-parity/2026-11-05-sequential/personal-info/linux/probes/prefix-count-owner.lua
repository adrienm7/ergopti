local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local basedir='/workspace/scratch/parity-sequential-2026-11-05/personal-info/linux/probes/'
local P=require('infra.hotstring_preferences');assert(P._set_file_for_test(basedir..'count-preferences.toml'))
local D=require('modules.dynamic_hotstrings.manager')
for _,family in ipairs(D.RULE_FAMILIES) do if family.id then assert(P.set('hotstrings.dynamic.'..family.id..'.enabled',family.section=='ssnprefixes' or family.section=='ibanprefixes')) end end
assert(P.set('hotstrings.dynamic.enabled',true))
local path=basedir..'count-info.toml';local f=assert(io.open(path,'wb'));assert(f:write('[info]\nsocial_security_number="11223344556677"\niban="XX00112233445566778899"\n[letters]\n'));assert(f:close())
assert(D.init({personal_info_path=path,trigger_char='★'}))
local built=D.prefix_mappings();assert(#built==2 and D.active_count()==4)
print('ACTUAL_MANAGER enabled_ssn_iban_only=true prefix_mappings='..#built..' active_count='..D.active_count())
for _,m in ipairs(built) do assert(m.is_private==true) end
print('PASS actual dynamic manager; no output; shared-owned count finding')
