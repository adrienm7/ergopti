--- tests/unit/modules/keystats/lifecycle/test_pause_forgets_mouse_seed.lua

--- ==============================================================================
--- MODULE: A Pause Forgets The Mouse Distance Seed (macOS)
--- DESCRIPTION:
--- A paused script polls no sensor, but the maintenance tick kept the last
--- pointer position, so the first poll after the resume credited the straight
--- line the pointer travelled during the pause (paused-records-no-keys). The
--- Metrics menu's own pause already forgot it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("(paused-records-no-keys) keystats watchers across a pause", function()
	helpers.it("(paused-records-no-keys) the first poll after a resume is a fresh seed", function()
		package.loaded["modules.keystats.watchers"] = nil
		local watchers = helpers.load_with_stubs("modules.keystats.watchers")
		local position = { x = 0, y = 0 }
		hs.mouse = hs.mouse or {}
		local previous_position = hs.mouse.absolutePosition
		hs.mouse.absolutePosition = function() return { x = position.x, y = position.y } end
		local state = { last_mouse_pos = nil, mouse_distance_px = 0, collection_suspended = false }
		local paused = false
		local ok, err = pcall(function()
			helpers.assert_true(watchers.init(state, function() return paused end))
			watchers.perform_maintenance()
			position = { x = 30, y = 40 }
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 50, "an active poll counts the travel")
			paused = true
			watchers.perform_maintenance()
			position = { x = 330, y = 440 }
			watchers.perform_maintenance()
			paused = false
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 50, "the travel of the pause is never credited")
			position = { x = 336, y = 448 }
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 60, "the resume counts again from a fresh seed")
		end)
		hs.mouse.absolutePosition = previous_position
		package.loaded["modules.keystats.watchers"] = nil
		if not ok then error(err, 0) end
	end)
end)
