--- tests/meta/test_gestures_stop_force_cleanup.lua

--- ==============================================================================
--- MODULE: Gestures M.stop() force_cleanup Guard
--- DESCRIPTION:
--- Static source guard for the "gesture-stuck-click-on-stop" audit finding in
--- modules/gestures/init.lua.
---
--- ROOT CAUSE ENCODED:
--- When a gesture held a synthetic left- or right-click (via toggle_right_click
--- or a long-press action) and the user reloaded Hammerspoon or called M.stop(),
--- the OS remained stuck with that virtual button held down because M.stop()
--- never called Actions.force_cleanup(). The user was then unable to click
--- normally until a physical button press released the stuck state.
---
--- The fix adds a `pcall(Actions.force_cleanup)` at the top of M.stop(), before
--- CoreState.enabled is set to false, so any held synthetic clicks are released
--- while the module is still logically running.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function func_body(src, func_def)
	local idx = src:find(func_def, 1, true)
	if not idx then return "" end
	local rest = src:sub(idx)
	-- Find the first closing brace at column 0 (top-level end of function)
	local _, stop = rest:find("\nend\n")
	if stop then return rest:sub(1, stop) end
	return rest
end





-- ======================================================================
-- ======================================================================
-- ======= 1/ M.stop() calls Actions.force_cleanup (source guard) =======
-- ======================================================================
-- ======================================================================

helpers.describe("gestures/init.lua: M.stop() releases held clicks (gesture-stuck-click-on-stop)", function()

	helpers.it("M.stop() body contains a pcall(Actions.force_cleanup) call", function()
		local src  = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		local body = func_body(src, "function M.stop()")
		helpers.assert_true(body ~= "",
			"M.stop() must exist in modules/gestures/init.lua")
		helpers.assert_true(
			body:match("pcall%(Actions%.force_cleanup%)") ~= nil,
			"M.stop() must call pcall(Actions.force_cleanup) to release held clicks (gesture-stuck-click-on-stop)")
	end)

	helpers.it("force_cleanup call precedes CoreState.enabled = false", function()
		local src  = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		local body = func_body(src, "function M.stop()")
		local cleanup_pos = body:find("pcall%(Actions%.force_cleanup%)")
		local enabled_pos = body:find("CoreState%.enabled%s*=%s*false")
		helpers.assert_true(
			cleanup_pos ~= nil and enabled_pos ~= nil and cleanup_pos < enabled_pos,
			"force_cleanup must appear BEFORE CoreState.enabled = false in M.stop() so clicks are released while the module is still running (gesture-stuck-click-on-stop)")
	end)

end)
