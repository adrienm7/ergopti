-- Run one registered module independently; fixture ports do not certify native receiving.
local repository=assert(arg[1],"repository root required")
local driver=repository.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local helpers=require("tests.helpers")
helpers.warm_timings()
require(assert(arg[2],"test module required"))
local results=helpers.get_results()
assert(results.passed>0,"zero executed cases")
print("AUDIT_RESULT",results.passed,results.failed)
assert(results.failed==0,"registered test failures")
