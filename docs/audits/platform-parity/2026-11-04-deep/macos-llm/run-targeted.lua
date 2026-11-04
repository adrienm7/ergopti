local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local helpers = require('tests.helpers')
_G.hs = require('tests.stubs.hs')
for _, path in ipairs(arg) do
  dofile(root..'macos/'..path)
end
local results = helpers.get_results()
print(string.format('AUDIT TARGETED TOTAL: %d passed, %d failed', results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
