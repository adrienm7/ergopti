--- tests/unit/modules/keystats/storage/test_historical_rollover_context_native.lua

--- ==============================================================================
--- MODULE: Historical Rollover Native Regression
--- DESCRIPTION:
--- Preserve independent typing generations across actual cache loss and a warm
--- revision rebuild whose committed raw rows are still owned by the SQL outbox.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote

local function campaign(mode)
	local executable = os.getenv("LUA") or arg[-1]
	assert(type(executable) == "string" and executable ~= "", "actual suite Lua executable required")
	local driver = helpers.driver_root()
	local command = "python3 -B " .. quote(driver .. "tests/support/keystats/historical_rollover_context_campaign.py")
		.. " " .. quote(driver .. "../../..") .. " " .. quote(executable) .. " " .. quote(mode) .. " 2>&1"
	local pipe = assert(io.popen(command, "r"))
	local output = assert(pipe:read("*a"))
	local ok, kind, status = pipe:close()
	helpers.assert_eq(ok, true, output)
	helpers.assert_eq(kind, "exit", output)
	helpers.assert_eq(status, 0, output)
	helpers.assert_eq(output, "PASS: completed rollovers preserve independent historical typing\n")
end

helpers.describe("historical rollover native context", function()
	helpers.it("keeps committed generations separate after actual cache loss (historical-rollover-context)", function()
		campaign("cold")
	end)

	helpers.it("retains current outbox typing during a warm revision rebuild (historical-rollover-context)", function()
		campaign("outbox")
	end)
end)
