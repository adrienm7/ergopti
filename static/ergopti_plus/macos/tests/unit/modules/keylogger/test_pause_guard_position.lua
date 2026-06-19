--- tests/unit/modules/keylogger/test_pause_guard_position.lua

--- ==============================================================================
--- MODULE: Regression — keylogger pause guard precedes all event branches (C1)
--- DESCRIPTION:
--- Prior audit C1: handle_key's is_paused() guard sat AFTER the mouse / keyUp /
--- flagsChanged branches, so while paused the keylogger still logged clicks, key
--- releases, and modifier press/hold — violating « pause = tout éteint ». The fix
--- hoisted the guard to the top of handle_key (right after the is_enabled check),
--- but the existing test only checks the string `is_paused` appears in the file,
--- NOT that the guard's POSITION precedes the branches — so a refactor moving it
--- back down would stay green. This test pins the ORDER (the C1 root cause).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: pause guard precedes the mouse/keyUp/flagsChanged branches (C1)", function()
	helpers.it("the is_paused() guard appears before the event-type branches in handle_key", function()
		local path = helpers.driver_root() .. "modules/keylogger/init.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open keylogger/init.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()

		local hk = src:find("local function handle_key", 1, true)
		helpers.assert_true(hk ~= nil, "handle_key must be locatable")

		-- First is_paused() AFTER handle_key starts = the pause guard.
		local guard = src:find("is_paused()", hk, true)
		local mouse = src:find("leftMouseDown", hk, true)
		local flags = src:find("flagsChanged", hk, true)

		helpers.assert_true(guard ~= nil, "handle_key must contain an is_paused() guard")
		helpers.assert_true(mouse ~= nil and flags ~= nil, "handle_key must branch on mouse + flagsChanged events")
		helpers.assert_true(guard < mouse, "the pause guard must precede the mouse branch (else clicks log while paused)")
		helpers.assert_true(guard < flags, "the pause guard must precede the flagsChanged branch (else modifiers log while paused)")
	end)
end)
