--- tests/unit/modules/test_gesture_dispatch.lua

--- ==============================================================================
--- MODULE: A Decoded Gesture Reaches Its Action
--- DESCRIPTION:
--- The join between the multitouch decoder and the action registry: a completed
--- gesture becomes a slot name, and the slot's bound action runs.
---
--- WHY THIS IS ITS OWN SEAM:
--- `process_frame` classifies from a list of touch POINTS, deriving the finger
--- count from how many it was given. libinput describes devices that can count
--- more fingers than they can locate as "the vast majority of touchpads", so on
--- most hardware that count is wrong — a five-finger swipe arrives as two.
---
--- `dispatch_gesture` takes the finished answer instead, because the decoder
--- reads the count the KERNEL reports through BTN_TOOL_*. Everything below is
--- about the naming and the lookup, which is the part that can silently bind a
--- gesture to the wrong action.
---
--- WHAT IS NOT TESTED HERE: whether the action does anything. That is the emit
--- path, which is still xdotool and therefore silent under Wayland — recorded in
--- todo_linux.md §12.5 rather than asserted as working.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The manager, with a recording action executor and known bindings.
--- @param bindings table slot -> action name
--- @return table manager, table fired
local function manager_with(bindings)
	local M = helpers.load_module("modules.gestures.manager")
	M.init({ enabled = true, persist = false })

	local fired = {}
	-- Recorded at the registry level rather than by stubbing the shell: what is
	-- under test is which SLOT resolves, and running xdotool from a test would
	-- prove nothing and touch the developer's session.
	for slot, action in pairs(bindings) do M.set_action(slot, action) end
	M._test_execute = function(action, _next, slot)
		fired[#fired + 1] = { slot = slot, action = action }
	end
	return M, fired
end




-- =================================================================
-- =================================================================
-- ======= 1/ The slot a gesture belongs to ========================
-- =================================================================
-- =================================================================

helpers.describe("gesture dispatch: naming the slot", function()

	helpers.it("names a swipe by finger count and direction", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		M.set_action("swipe_5_up", "mission_control")

		helpers.assert_true(M.dispatch_gesture({ fingers = 5, direction = "up", tap = false }),
			"a five-finger swipe up must reach swipe_5_up — the slot no libinput-based "
				.. "route can serve at all")
	end)

	helpers.it("names a tap by finger count", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		M.set_action("tap_4", "app_window_previous")

		helpers.assert_true(M.dispatch_gesture({ fingers = 4, direction = nil, tap = true }),
			"libinput implements tapping for one, two and three fingers only, and "
				.. "delivers them as pointer buttons rather than gestures — four is ours")
	end)

	helpers.it("names every diagonal the way the slot space spells it", function()
		-- Taken from the DECLARED slots rather than typed here: the whole failure
		-- this guards against is a name that looks reasonable and matches nothing.
		-- It caught exactly that — the decoder said "up_right" while every declared
		-- slot is spelled horizontal-first — so the check reads the real list.
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })

		local declared = {}
		for _, slot in ipairs(M.SINGLE_SLOTS or {}) do declared[slot] = true end
		helpers.assert_true(next(declared) ~= nil, "the slot space must load at all")

		for _, direction in ipairs({ "left_up", "right_up", "left_down", "right_down" }) do
			local slot = "swipe_3_" .. direction
			helpers.assert_true(declared[slot], slot .. " must be a declared slot")
			M.set_action(slot, "tab_next")
			helpers.assert_true(M.dispatch_gesture({ fingers = 3, direction = direction, tap = false }),
				"the decoder's name for a diagonal has to reach " .. slot)
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ When nothing should happen ===========================
-- =================================================================
-- =================================================================

helpers.describe("gesture dispatch: when it must not fire", function()

	helpers.it("does nothing for an unbound slot", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		-- Linux ships NO default bindings, so this is the ordinary state of most
		-- slots until the user chooses. It must be quiet, not an error.
		helpers.assert_true(not M.dispatch_gesture({ fingers = 3, direction = "left", tap = false }),
			"an unbound slot is the normal state on this driver, not a fault")
	end)

	helpers.it("does nothing while gestures are disabled", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		M.set_action("swipe_5_up", "mission_control")
		M.disable()
		helpers.assert_true(not M.dispatch_gesture({ fingers = 5, direction = "up", tap = false }),
			"the master toggle has to gate the new path as well as the old one")
	end)

	helpers.it("refuses a gesture with neither direction nor tap", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		helpers.assert_true(not M.dispatch_gesture({ fingers = 3, direction = nil, tap = false }),
			"a swipe with no direction is not a slot; firing something would be "
				.. "worse than firing nothing")
		helpers.assert_true(not M.dispatch_gesture({}), "and an empty table is not a gesture")
		helpers.assert_true(not M.dispatch_gesture(nil), "nor is nil")
	end)

	helpers.it("does not invent a sixth finger", function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = true, persist = false })
		M.set_action("tap_5", "show_desktop")
		-- Six or more fingers clears every BTN_TOOL_* bit, so a decoder that got
		-- confused could report a large count. It must land on the top slot the
		-- catalogue has rather than name one that does not exist.
		helpers.assert_true(M.dispatch_gesture({ fingers = 7, direction = nil, tap = true }),
			"a count above five clamps to the highest declared slot")
	end)

end)
