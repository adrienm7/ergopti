--- tests/unit/modules/shortcuts/apps/test_app_cloner_dock_lock.lua

--- ==============================================================================
--- MODULE: App Cloner Dock Writer Coordination
--- DESCRIPTION:
--- Execute the actual embedded writer with owned plist files and real kernel
--- locks. Controlled native boundaries never modify the host Dock.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote

helpers.describe("App Cloner Dock writer coordination", function()
	helpers.it("preserves concurrent clone entries with one held kernel lock", function()
		local driver = helpers.driver_root()
		local command = "python3 -B " .. quote(driver .. "tests/support/apps/dock_update_campaign.py")
			.. " " .. quote(driver .. "apps/App Cloner.app/Contents/Resources/clone_app.sh") .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = assert(pipe:read("*a"))
		local ok, kind, status = pipe:close()
		helpers.assert_eq(ok, true, output)
		helpers.assert_eq(kind, "exit", output)
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:find('"state": "PASS"', 1, true) ~= nil, output)
	end)
end)
