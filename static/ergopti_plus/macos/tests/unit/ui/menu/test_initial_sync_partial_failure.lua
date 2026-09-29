--- tests/unit/ui/menu/test_initial_sync_partial_failure.lua

--- ==============================================================================
--- MODULE: Initial Preference Sync Partial-Failure Isolation Regression
--- DESCRIPTION:
--- Boots the real ui.menu.start, MenuState and preference transaction over a
--- valid config.toml whose features are ON. One refused runtime owner used to
--- restore every pre-load default (Gestures, Metrics and AI OFF) and seed the
--- save transaction from them, so the next unrelated toggle rewrote config.toml
--- with those defaults. Each case refuses exactly one owner and checks that only
--- its feature is demoted, in memory only, and that config.toml keeps the saved
--- values.
--- ==============================================================================

local helpers = require("tests.helpers")
local boot = require("tests.support.menu_boot_fixture").boot





-- ================================================
-- ================================================
-- ======= 1/ Per-feature Refusal Isolation =======
-- ================================================
-- ================================================

helpers.describe("initial sync isolates one refused owner (R5)", function()
	helpers.it("keeps every saved feature when the editor shortcut cannot bind", function()
		local fixture = boot({ editor_bind = false })
		helpers.assert_not_nil(fixture.menu,
			"one refused hotkey must not abort the whole menubar")
		helpers.assert_eq(fixture.state.gestures, true, "Gestures must keep its saved ON")
		helpers.assert_eq(fixture.state.keylogger_enabled, true, "Metrics must keep its saved ON")
		helpers.assert_eq(fixture.state.llm_enabled, true, "AI must keep its saved ON")
		helpers.assert_true(fixture.has_error("hotstring_editor.set_shortcut"),
			"the refused owner must be named by an ERROR")

		helpers.assert_eq(fixture.save_prefs(), true)
		local written = fixture.saves[#fixture.saves]
		helpers.assert_eq(written.gestures, true)
		helpers.assert_eq(written.keylogger_enabled, true)
		helpers.assert_eq(written.llm_enabled, true)
		helpers.assert_eq(written.custom_editor_shortcut, { mods = { "ctrl" }, key = "k" },
			"the next save must not replace the saved chord with a default")
	end)

	helpers.it("demotes only Gestures in memory and never saves before seeding", function()
		local fixture = boot({ gestures_enable = false })
		helpers.assert_not_nil(fixture.menu)
		helpers.assert_eq(fixture.state.gestures, false,
			"the refused feature must show its real runtime posture")
		helpers.assert_eq(fixture.state.keylogger_enabled, true)
		helpers.assert_eq(fixture.state.llm_enabled, true)
		helpers.assert_eq(fixture.state.shortcuts, true)
		helpers.assert_eq(fixture.boot_saves, 0, "boot must not write config.toml")
		helpers.assert_true(not fixture.has_error("used before its boot snapshot was seeded"),
			"the gesture rollback must not call save_prefs before the transaction is seeded")
		helpers.assert_true(fixture.has_error("gestures"),
			"the demoted feature must be named by an ERROR")

		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true,
			"an unrelated save must keep the saved Gestures ON")
		helpers.assert_eq(fixture.state.gestures, false,
			"the save must not publish the saved value into the live state")
	end)

	helpers.it("lets a later user change of the demoted feature reach config.toml", function()
		local fixture = boot({ gestures_enable = false })
		fixture.state.gestures = true
		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true)
		fixture.state.gestures = false
		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, false,
			"once the user changed it, the saved value no longer overrides the state")
	end)

	helpers.it("keeps the saved value when the change that ended a demotion fails to save", function()
		local fixture = boot({ gestures_enable = false })
		fixture.state.gestures = true
		fixture.refuse_next_save()
		helpers.assert_eq(fixture.save_prefs(), false, "the refused write must not commit")
		helpers.assert_eq(fixture.state.gestures, false,
			"the refused save must roll the change back to the demoted posture")
		helpers.assert_eq(#fixture.saves, 0)

		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true,
			"a change that never reached config.toml must not end the demotion")
	end)

	helpers.it("keeps the saved value when a rollback cannot restore its runtime", function()
		local fixture = boot({})
		helpers.assert_eq(fixture.state.gestures, true)
		-- The user's OFF reaches the runtime, then config.toml cannot be written and
		-- the rollback's ON is refused: the runtime stays OFF, the file holds ON.
		fixture.runtime.gestures = false
		fixture.state.gestures = false
		fixture.runtime.refuse_enable = true
		fixture.refuse_next_save()
		helpers.assert_eq(fixture.save_prefs(), false)
		helpers.assert_eq(fixture.state.gestures, false,
			"the refused rollback must show the real runtime posture")

		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true,
			"a runtime refusal during the rollback must not rewrite config.toml")
	end)

	helpers.it("retired bulk switches cannot replace consent or the saved demoted value", function()
		local fixture = boot({ gestures_enable = false })
		local actions = fixture.global_actions()
		helpers.assert_nil(actions.disable_all, "the retired OFF operation must not be published")
		helpers.assert_nil(actions.enable_all, "the retired ON operation must not enable consent features")
		helpers.assert_eq(type(actions.reset_defaults), "function", "the remaining reset must stay reachable")
		helpers.assert_eq(fixture.save_prefs(), true)
		local written = fixture.saves[#fixture.saves]
		helpers.assert_true(written ~= nil, "the unrelated save must commit")
		helpers.assert_eq(written.gestures, true,
			"building the remaining global actions must retain the desired value")
	end)

	helpers.it("preserves the saved gesture value when a refused reset is reversed", function()
		local fixture = boot({ gestures_enable = false })
		-- Runtime sync writes first; refuse the reset owner's explicit setter.
		fixture.refuse_gesture_assignment_after(2)
		helpers.assert_eq(fixture.global_actions().factory_reset(), false,
			"a refused candidate assignment must fail the reset")
		helpers.assert_eq(fixture.gesture_assignment_refusals, 1, "the candidate must reach the injected refusal")
		helpers.assert_eq(fixture.gesture_assignment_calls, 3, "the refused candidate must be followed by its inverse")
		helpers.assert_eq(#fixture.saves, 0, "reset compensation must leave the saved file intact")
		helpers.assert_eq(fixture.state.gestures, false, "the live state keeps the real posture")

		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true,
			"the reversed action must leave the demotion active for later saves")
	end)

	helpers.it("preserves the saved metrics value when a refused reset is reversed", function()
		local fixture = boot({ keylogger_start = false })
		fixture.flush_deferred()
		helpers.assert_eq(fixture.state.keylogger_enabled, false)
		-- The following third call must be the reset owner's inverse.
		fixture.refuse_gesture_assignment_after(2)
		helpers.assert_eq(fixture.global_actions().factory_reset(), false,
			"a refused candidate assignment must fail the reset")
		helpers.assert_eq(fixture.gesture_assignment_refusals, 1, "the candidate must reach the injected refusal")
		helpers.assert_eq(fixture.gesture_assignment_calls, 3, "the refused candidate must be followed by its inverse")
		helpers.assert_eq(#fixture.saves, 0, "reset compensation must not write the demoted state")
		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].keylogger_enabled, true,
			"the inverse must keep the saved Metrics ON, not write the demoted posture")
	end)

	helpers.it("keeps Metrics ON in config.toml when the deferred keylogger start is refused", function()
		local fixture = boot({ keylogger_start = false })
		fixture.flush_deferred()
		helpers.assert_eq(fixture.state.keylogger_enabled, false,
			"the refused engine must not stay checked")
		helpers.assert_eq(#fixture.saves, 0,
			"a runtime refusal must not rewrite config.toml")
		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].keylogger_enabled, true,
			"the next save must keep the saved Metrics ON")
	end)
end)

return true
