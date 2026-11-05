-- Execute one already-registered module in an otherwise fresh Lua process.
local root = assert(arg[1])
local driver = root .. "/static/ergopti_plus/linux"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("test.runner_home").isolate()
require("compat.utf8").install()
require("tests.support.secret_service_fake").isolate()
require("tests.support.menu_part_reload").install()
local helpers = require("tests.helpers")
local module = assert(arg[2])
assert(module:match("^tests%."))
assert(require(module))
local results = helpers.get_results()
assert(results.passed + results.failed > 0, "a zero-case module is not evidence")
print("AUDIT_RESULTS=" .. assert(require("json").encode(results)))
if results.failed > 0 then os.exit(1) end
