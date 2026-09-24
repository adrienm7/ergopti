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

	helpers.it("lets Disable All write its explicit OFF over a demoted feature", function()
		local fixture = boot({ gestures_enable = false })
		helpers.assert_eq(fixture.global_actions().disable_all(), true)
		local written = fixture.saves[#fixture.saves]
		helpers.assert_true(written ~= nil, "Disable All must save")
		helpers.assert_eq(written.gestures, false,
			"a global action sets every feature explicitly, so no demotion may override it")
	end)

	helpers.it("restores the saved value when a refused Disable All save is reversed", function()
		local fixture = boot({ gestures_enable = false })
		fixture.refuse_next_save()
		helpers.assert_eq(fixture.global_actions().disable_all(), false,
			"a refused candidate save must fail Disable All")
		helpers.assert_eq(#fixture.saves, 1, "the inverse must republish the pre-action preferences")
		helpers.assert_eq(fixture.saves[1].gestures, true,
			"the inverse must keep the saved Gestures ON, not write the demoted posture")
		helpers.assert_eq(fixture.state.gestures, false, "the live state keeps the real posture")

		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(fixture.saves[#fixture.saves].gestures, true,
			"the reversed action must leave the demotion active for later saves")
	end)

	helpers.it("restores the saved value when a refused Enable All save is reversed", function()
		local fixture = boot({ keylogger_start = false })
		fixture.flush_deferred()
		helpers.assert_eq(fixture.state.keylogger_enabled, false)
		fixture.refuse_next_save()
		helpers.assert_eq(fixture.global_actions().enable_all(), false,
			"a refused candidate save must fail Enable All")
		helpers.assert_eq(#fixture.saves, 1, "the inverse must republish the pre-action preferences")
		helpers.assert_eq(fixture.saves[1].keylogger_enabled, true,
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
