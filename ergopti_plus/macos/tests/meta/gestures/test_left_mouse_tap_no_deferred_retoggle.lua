--- tests/meta/gestures/test_left_mouse_tap_no_deferred_retoggle.lua

--- ==============================================================================
--- MODULE: LeftMouseTap leaves no deferred re-toggle (meta)
--- DESCRIPTION:
--- gestures/actions.lua leftMouseTap must not defer a re-toggle after mouseUp.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("leftMouseTap leaves no deferred re-toggle", function()

	-- ========================================================
	-- ===== 5) actions.lua: leftMouseTap deferred race removed
	-- ========================================================

	helpers.it("actions.lua leftMouseTap must not defer a re-toggle after mouseUp", function()
		-- The synthetic click-hold subsystem was extracted into actions_click.lua;
		-- read both so the guard assertion survives that move (move-resilient).
		local src = (read_src("local function switch_to_least_recent_application") or "") ..
			"\n" .. (read_src("local function start_click_key_watcher") or "")
		assert(src ~= "", "gestures actions/actions_click source must be readable")
		-- The original fix guarded the deferred toggle. Removing that deferral is
		-- stronger: the callback now fences state and passes physical mouseUp on.
		assert(
			not src:find("doAfter%(0, M%.toggle_left_click%)", 1, false),
			"actions.lua: bare doAfter(0, M.toggle_left_click) must never return"
		)
		assert(
			not src:find("if leftClickHeld then M%.toggle_left_click", 1, false),
			"actions.lua: leftMouseUp must not depend on an in-process deferred re-toggle"
		)
	end)

end)
