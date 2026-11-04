local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
local h=require('tests.helpers')
require('tests.support.secret_service_fake').isolate()
for i=1,#arg do local ok,err=pcall(require,arg[i]);if not ok then print('MODULE ERROR '..arg[i]..': '..tostring(err));os.exit(2)end end
local r=h.get_results();print('TOTAL '..r.passed..' passed '..r.failed..' failed');os.exit(r.failed==0 and 0 or 1)
