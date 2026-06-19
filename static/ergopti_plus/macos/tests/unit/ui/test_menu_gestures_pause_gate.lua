--- tests/unit/ui/test_menu_gestures_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — gestures master toggle is pause-gated (F-MED-5)
--- DESCRIPTION:
--- The gesture engine's only fire gate is the shared CoreState.enabled flag, which
--- script_control.pause_all() drives via gestures.disable_all(). The menu's
--- gestures master toggle wrote that SAME flag with no pause guard, so two states
--- conflated:
---   (a) toggling gestures ON during pause set enabled=true → a swipe fired while
---       the script was paused (« pause = tout éteint » violated);
---   (b) toggling gestures OFF during pause desynced the _gestures_were_enabled
---       snapshot, so resume_all() re-enabled gestures against the user's intent.
---
--- Fix: pause-gate the master toggle (disabled + nil fn while paused), mirroring
--- the hotstrings master toggle, so pause owns the gesture state until resume
--- restores it. Pinned at source: the master toggle's fn must be gated on
--- `not paused` and the item carries `disabled = paused`.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_gestures: master toggle is pause-gated (F-MED-5)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/menu/menu_gestures.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open menu_gestures.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("gates the master-toggle fn on `not paused`", function()
		local src = read_src()
		local gate_pos = src:find("fn      = (not paused) and function()", 1, true)
		local body_pos = src:find("local new_state = not state.gestures", 1, true)
		helpers.assert_true(gate_pos ~= nil, "the gestures master toggle fn must be gated on `not paused`")
		helpers.assert_true(body_pos ~= nil, "the master-toggle body (state.gestures flip) must still exist")
		helpers.assert_true(gate_pos < body_pos, "the `not paused` gate must wrap the toggle body")
	end)

	helpers.it("marks the master toggle disabled while paused", function()
		local src = read_src()
		-- Pin the master toggle specifically (slot items also use disabled=paused).
		local master = src:match("local item = {.-local new_state = not state.gestures")
		helpers.assert_true(master ~= nil, "master toggle item block must be locatable")
		helpers.assert_true(master:find("disabled = paused or nil", 1, true) ~= nil,
			"the gestures master toggle must carry `disabled = paused or nil`")
	end)
end)
