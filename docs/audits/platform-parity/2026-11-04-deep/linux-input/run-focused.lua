local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
local helpers=require('tests.helpers')
for i=1,#arg do
 local ok,err=pcall(require,arg[i]); if not ok then print('MODULE ERROR '..arg[i]..': '..tostring(err)); os.exit(2) end
end
local result=helpers.get_results()
print('TOTAL '..result.passed..' passed '..result.failed..' failed')
os.exit(result.failed==0 and 0 or 1)
