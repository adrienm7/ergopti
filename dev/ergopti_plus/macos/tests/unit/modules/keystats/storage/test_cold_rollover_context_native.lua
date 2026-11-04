--- tests/unit/modules/keystats/storage/test_cold_rollover_context_native.lua

--- ==============================================================================
--- MODULE: Native Cold Cache Rollover Context Integration
--- DESCRIPTION:
--- Compare public healthy rollover with real SQLite cache loss using identical
--- owned canonical files, real persistence modules and actual waited children.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote

helpers.describe("native cold cache rollover context", function()
	helpers.it("keeps the healthy context after actual cache loss (cold-rollover-context)", function()
		local executable = os.getenv("LUA") or arg[-1]
		assert(type(executable) == "string" and executable ~= "", "actual suite Lua executable required")
		local driver = helpers.driver_root()
		local command = "python3 -B " .. quote(driver .. "tests/support/keystats/cold_rollover_context_campaign.py")
			.. " " .. quote(driver .. "../../..") .. " " .. quote(executable) .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = assert(pipe:read("*a"))
		local ok, kind, status = pipe:close()
		helpers.assert_eq(ok, true, output)
		helpers.assert_eq(kind, "exit", output)
		helpers.assert_eq(status, 0, output)
		helpers.assert_eq(output, "PASS: healthy and cold rollover preserve the same fresh context\n")
	end)
end)
