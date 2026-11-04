local os_name=assert(arg[1]);local name=assert(arg[2]);local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..os_name..'/?.lua;'..root..os_name..'/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
if os_name=='macos' then _G.hs=require('tests.stubs.hs') end
local h=require('tests.helpers')
require(name)
local r=h.get_results()
assert(r.passed>0,'no cases executed')
print('TOTAL '..r.passed..' passed, '..r.failed..' failed')
os.exit(r.failed==0 and 0 or 1)
