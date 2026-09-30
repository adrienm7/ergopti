--- tests/unit/modules/keylogger/test_hs274_duplicate_count.lua

--- ==============================================================================
--- MODULE: HS-274 — a remapped tap and its physical key
--- DESCRIPTION:
--- Ported from docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua,
--- driving the real keylogger keyDown and flagsChanged branches and the real
--- aggregator instead of a stubbed classifier.
---
--- ROOT CAUSE ENCODED:
--- Two independent writers credit a managed tap-hold. The Karabiner
--- shell_command ledger credits the physical key (karabiner_press), and the
--- Quartz event tap credits the remapped output it observes (meta.kc). The
--- historical guard `kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or
--- keycode` always evaluated to keycode, because `true and nil` is nil and
--- `nil or keycode` is keycode, so every remapped tap is credited twice. With the
--- shipped defaults, one CapsLock tap (tap = Return) credits CapsLock AND Return.
---
--- These legacy cases pin today's behaviour, double count included: fixing it
--- by suppressing the output keycode would lose real presses (see
--- test_hs274_physical_collision.lua). Only exclusive producer ownership can
--- remove it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Accounting = require("tests.support.hs274_accounting_fixture")

-- macOS virtual keycodes of the shipped CapsLock tap (tap = Return).
local KEYCODE_CAPS_LOCK = 57
local KEYCODE_RETURN = 36
-- The left Command modifier, a flagsChanged key.
local KEYCODE_LEFT_COMMAND = 55

--- Returns the meta.kc of the only recorded typing event.
--- @param scenario table HS-274 accounting scenario.
--- @return number|nil kc
local function only_typing_kc(scenario)
	local events = scenario.typing_events()
	helpers.assert_eq(#events, 1, "the key must produce exactly one typing event")
	return events[1][3].kc
end





-- =================================
-- =================================
-- ======= 1/ Legacy Sources =======
-- =================================
-- =================================

helpers.describe("HS-274 duplicate count — legacy sources", function()
	helpers.it("credits a managed tap as its physical key and as its output (documented double count)", function()
		Accounting.run(function(scenario)
			-- Even when the classifier claims Return as a managed output, the
			-- legacy writer keeps crediting it: suppression is not the fix.
			scenario.kc_bridge.is_ke_managed_output_kc = function() return true end
			scenario.ledger_press(KEYCODE_CAPS_LOCK)
			scenario.key_down(KEYCODE_RETURN, "\r")
			helpers.assert_eq(only_typing_kc(scenario), KEYCODE_RETURN)
			helpers.assert_eq(scenario.counts(), { [KEYCODE_CAPS_LOCK] = 1, [KEYCODE_RETURN] = 1 },
				"one physical CapsLock tap is credited twice while the legacy sources own accounting")
		end)
	end)

	helpers.it("credits an ordinary key exactly once", function()
		Accounting.run(function(scenario)
			scenario.key_down(0, "a")
			helpers.assert_eq(only_typing_kc(scenario), 0)
			helpers.assert_eq(scenario.counts(), { [0] = 1 })
		end)
	end)

	helpers.it("records modifier presses and holds from flagsChanged", function()
		Accounting.run(function(scenario)
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, { cmd = true })
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, {})
			helpers.assert_eq(#scenario.system_events, 2)
			helpers.assert_eq(scenario.system_events[1].action, "modifier_press")
			helpers.assert_eq(scenario.system_events[1].keycode, KEYCODE_LEFT_COMMAND)
			helpers.assert_eq(scenario.system_events[2].action, "modifier_hold")
			helpers.assert_eq(scenario.system_events[2].keycode, KEYCODE_LEFT_COMMAND)
		end)
	end)
end)
