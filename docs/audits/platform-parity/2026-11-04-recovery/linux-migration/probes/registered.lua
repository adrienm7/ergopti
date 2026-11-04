local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
if not utf8 then require('compat.utf8').install() end
local helpers=require('tests.helpers')
require('tests.unit.infra.config.test_legacy_folder_migration')
local result=helpers.get_results()
print('REGISTERED_MIGRATION_RESULT',result.passed,result.failed)
assert(result.failed==0)
