local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate();require('tests.support.secret_service_fake').isolate()
local h=require('tests.helpers')
local ok,err=xpcall(function()require(assert(arg[1]))end,debug.traceback)
if not ok then print('MODULE ERROR '..tostring(err));os.exit(2)end
local r=h.get_results();print('TOTAL '..r.passed..' passed '..r.failed..' failed');os.exit(r.failed==0 and 0 or 1)
