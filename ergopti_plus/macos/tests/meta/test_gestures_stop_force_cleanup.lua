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
--- M.stop() now delegates to the shared exact teardown transaction.  That
--- transaction must call Actions.force_cleanup through xpcall before it lowers
--- CoreState.enabled, so held synthetic clicks are released while the module is
--- still logically running without duplicating the teardown sequence.
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

local function segment_between(src, start_marker, end_marker)
	local start_idx = src:find(start_marker, 1, true)
	if not start_idx then return "" end
	local end_idx = src:find(end_marker, start_idx + #start_marker, true)
	if not end_idx then return "" end
	return src:sub(start_idx, end_idx - 1)
end





-- ======================================================================
-- ======================================================================
-- ======= 1/ M.stop() calls Actions.force_cleanup (source guard) =======
-- ======================================================================
-- ======================================================================

helpers.describe("gestures/init.lua: M.stop() releases held clicks (gesture-stuck-click-on-stop)", function()

	helpers.it("M.stop() delegates to the exact runtime teardown", function()
		local src  = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		local body = func_body(src, "function M.stop()")
		helpers.assert_true(body ~= "",
			"M.stop() must exist in modules/gestures/init.lua")
		helpers.assert_true(
			body:find("teardown_gesture_runtime(false)", 1, true) ~= nil,
			"M.stop() must route through the shared exact teardown transaction")
	end)

	helpers.it("shared teardown releases held clicks before disabling gestures", function()
		local src  = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		local body = segment_between(src,
			"teardown_gesture_runtime = function",
			"local function reject_gesture_start")
		helpers.assert_true(body ~= "",
			"the shared gesture teardown transaction must remain discoverable")
		local cleanup_pos = body:find(
			"Actions%.force_cleanup,%s*debug%.traceback,%s*GESTURE_ACTION_PARENT")
		local enabled_pos = body:find("CoreState%.enabled%s*=%s*false")
		helpers.assert_true(
			cleanup_pos ~= nil and enabled_pos ~= nil and cleanup_pos < enabled_pos,
			"the exact teardown must release held clicks before lowering CoreState.enabled")
	end)

end)
