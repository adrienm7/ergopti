local b='/workspace/ergopti/static/ergopti_plus/'
package.path=b..'linux/?.lua;'..b..'linux/?/init.lua;'..b..'_shared/lua/?.lua;'..b..'_shared/lua/?/init.lua;'..package.path
local h=require('tests.helpers')
require(arg[1])
local result=h.get_results()
print('AUDIT_TEST_RESULT',result.passed,result.failed)
assert(result.failed==0,'existing test cases failed')
