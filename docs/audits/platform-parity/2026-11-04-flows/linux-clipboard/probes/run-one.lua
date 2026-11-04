local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
if not utf8 then require('compat.utf8').install() end
local helpers=require('tests.helpers')
if arg[2] then helpers.set_only_filter(arg[2]) end
require(arg[1])
local result=helpers.get_results()
print('AUDIT_RESULT',result.passed,result.failed)
assert(result.failed==0,'focused cases failed')
