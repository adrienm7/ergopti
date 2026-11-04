local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
helpers.warm_timings()
for _, name in ipairs(arg) do
 print('MODULE '..name)
 local ok,err=pcall(require,name)
 if not ok then error(err) end
end
local results=helpers.get_results()
print('RESULT '..results.passed..' passed '..results.failed..' failed')
assert(results.failed==0)
