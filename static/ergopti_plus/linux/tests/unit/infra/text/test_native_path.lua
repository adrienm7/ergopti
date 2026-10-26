--- tests/unit/infra/text/test_native_path.lua

--- Replays the shared native path contract on the Linux suite.
require("test.native_path_contract").register(require("tests.helpers"))

require("test.module_source_identity_contract").register(require("tests.helpers"))

local helpers = require("tests.helpers")
helpers.describe("native constructor source", function()
	helpers.it("source-identity-native: actual constructor accepts literal POSIX component bytes", function()
		local quote = require("text_utils").shell_quote
		local root = helpers.driver_root()
		local executable = assert(require("luv").exepath())
		-- A normal runner need not export TMPDIR; retain the actual ABI/provider
		-- while proving native temporary-root resolution in that environment.
		local result = os.execute("env -u TMPDIR " .. quote(executable) .. " " .. quote(root .. "/tests/hardware/run_source_identity_native.lua") .. " " .. quote(root))
		helpers.assert_true(result == true or result == 0, "actual source constructor and native pathname assertions must complete")
	end)
end)
