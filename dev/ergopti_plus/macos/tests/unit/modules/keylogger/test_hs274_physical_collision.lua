--- tests/unit/modules/keylogger/test_hs274_physical_collision.lua

--- ==============================================================================
--- MODULE: HS-274 — a managed output that is also a real key
--- DESCRIPTION:
--- Ported from docs/audits/hammerspoon/2026_09_08/proofs/physical-collision.lua,
--- driving the real keylogger keyDown branch, the real Karabiner bridge
--- classifier and the real aggregator.
---
--- ROOT CAUSE ENCODED:
--- A managed output keycode is not proof that a keyDown came from a remapped
--- key. With Escape's tap sent to Space, the bridge classifies 49 as a managed
--- output, yet the physical Space key (a none/none passthrough) produces the
--- very same Quartz keyDown and writes no ledger line. The rejected one-line fix
--- (docs/audits/hammerspoon/2026_09_08/proofs/rejected-keycode.patch) suppressed
--- every managed output keycode and silently lost that real Space; the shipped
--- defaults make Return and Backspace collide the same way. The physical Space
--- must keep exactly one credit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Accounting = require("tests.support.hs274_accounting_fixture")

-- macOS virtual keycodes of the Escape → Space fixture.
local KEYCODE_ESCAPE = 53
local KEYCODE_SPACE = 49

--- Loads the real Karabiner bridge classifier with Escape's tap sent to Space
--- and publishes it on the keylogger's bridge, exactly as a READY lease does.
--- @param scenario table HS-274 accounting scenario.
--- @return table bridge Real kc_bridge module.
local function claim_space_as_managed_output(scenario)
	package.loaded["modules.keylogger.kc_bridge"] = nil
	local real_bridge = require("modules.keylogger.kc_bridge")
	helpers.assert_true(real_bridge.refresh_managed_set({
		escape = { tap = "space", hold = "none" },
		spacebar = { tap = "none", hold = "none" },
	}, { { id = "space", karabiner_to = { { key_code = "spacebar" } } } }))
	helpers.assert_true(real_bridge.is_ke_managed_output_kc(KEYCODE_SPACE),
		"the fixture must reproduce the collision: Space is a managed output")
	scenario.kc_bridge.is_ke_managed_output_kc = real_bridge.is_ke_managed_output_kc
	return real_bridge
end





-- =================================
-- =================================
-- ======= 1/ Legacy Sources =======
-- =================================
-- =================================

helpers.describe("HS-274 physical collision — legacy sources", function()
	helpers.it("keeps the credit of a passthrough Space that a managed Escape tap also outputs", function()
		Accounting.run(function(scenario)
			claim_space_as_managed_output(scenario)
			scenario.key_down(KEYCODE_SPACE, " ")
			local events = scenario.typing_events()
			helpers.assert_eq(#events, 1)
			helpers.assert_eq(events[1][1], " ", "Space must still be recorded as logical text")
			helpers.assert_eq(scenario.counts(), { [KEYCODE_SPACE] = 1 },
				"global suppression of managed outputs loses the unjournaled physical Space")
		end)
	end)

	helpers.it("credits a remapped Escape twice and the passthrough Space once (documented double count)", function()
		Accounting.run(function(scenario)
			claim_space_as_managed_output(scenario)
			-- Only the remapped Escape writes a ledger line; its output Space is
			-- credited again by the event tap (the documented HS-274 double count).
			scenario.ledger_press(KEYCODE_ESCAPE)
			scenario.key_down(KEYCODE_SPACE, " ")
			scenario.key_down(KEYCODE_SPACE, " ")
			helpers.assert_eq(scenario.counts(), { [KEYCODE_ESCAPE] = 1, [KEYCODE_SPACE] = 2 })
		end)
	end)
end)





-- ===================================
-- ===================================
-- ======= 2/ Exclusive Stream =======
-- ===================================
-- ===================================

helpers.describe("HS-274 physical collision — admitted producer stream", function()
	helpers.it("credits the remapped Escape and the passthrough Space once each", function()
		Accounting.run(function(scenario)
			claim_space_as_managed_output(scenario)
			scenario.admit_stream()
			-- Escape pressed: the stream credits Escape, Karabiner outputs Space.
			scenario.stream_press(KEYCODE_ESCAPE)
			scenario.key_down(KEYCODE_SPACE, " ")
			-- Space pressed: the stream credits Space, which passes through.
			scenario.stream_press(KEYCODE_SPACE)
			scenario.key_down(KEYCODE_SPACE, " ")
			helpers.assert_eq(scenario.counts(), { [KEYCODE_ESCAPE] = 1, [KEYCODE_SPACE] = 1 })
			helpers.assert_eq(scenario.aggregate().agg_batch.chars_class[
				Accounting.DAY .. "\1" .. Accounting.APP].space, 2,
				"both logical Spaces must still be recorded as text")
		end)
	end)
end)
