local root=assert(os.getenv('ERGOPTI_AUDIT_SOURCE_ROOT'))
local b=root..'/static/ergopti_plus/'
package.path=b..'linux/?.lua;'..b..'linux/?/init.lua;'..b..'_shared/lua/?.lua;'..b..'_shared/lua/?/init.lua;'..package.path
local h=require('tests.helpers')
require(assert(arg[1]))
local r=h.get_results()
print('AUDIT_TEST_RESULT',r.passed,r.failed)
assert(r.failed==0)
