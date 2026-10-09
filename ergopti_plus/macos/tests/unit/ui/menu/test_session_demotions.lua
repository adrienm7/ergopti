--- tests/unit/ui/menu/test_session_demotions.lua

--- ==============================================================================
--- MODULE: Session Feature Demotions Contract
--- DESCRIPTION:
--- A feature whose runtime refused its saved value shows the real posture in
--- memory while every save keeps the value config.toml holds. The demotion ends
--- when a save commits the user's change of that value, and a global action
--- detaches every demotion for its own explicit save, re-adopting them when
--- that action is reversed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh registry module with a silent logger.
--- @return table SessionDemotions
local function load_subject()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.menu.session_demotions"] = nil
	return require("ui.menu.session_demotions")
end





-- ==========================================
-- ==========================================
-- ======= 1/ Saved Values Stay Saved =======
-- ==========================================
-- ==========================================

helpers.describe("session demotions keep config.toml values", function()
	helpers.it("preserves independent child values without aliasing their runtime snapshot", function()
		local registry = load_subject().new()
		registry.record({ feature = "shortcuts", key = "shortcut_keys", subkey = "first",
			persisted = false, demoted = true })
		registry.record({ feature = "shortcuts", key = "shortcut_keys", subkey = "second",
			persisted = true, demoted = false })
		local live = { shortcut_keys = { first = true, second = false, other = true } }
		local view = registry.persisted_view(live)
		helpers.assert_eq(view.shortcut_keys, { first = false, second = true, other = true })
		helpers.assert_eq(live.shortcut_keys, { first = true, second = false, other = true })
		local released = registry.release_all()
		helpers.assert_true(rawequal(registry.persisted_view(live), live))
		registry.readopt(released)
		helpers.assert_eq(#registry.list(), 2)
		live.shortcut_keys.first = false
		registry.settle(live)
		helpers.assert_eq(#registry.list(), 1)
		helpers.assert_eq(registry.list()[1].subkey, "second")
		helpers.assert_eq(registry.persisted_view(live).shortcut_keys.second, true)
	end)

	helpers.it("serialises the saved value while the state holds the demoted one", function()
		local registry = load_subject().new()
		local state = { gestures = false, shortcuts = true }
		registry.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })

		local view = registry.persisted_view(state)
		helpers.assert_eq(view.gestures, true, "the save must keep the saved Gestures ON")
		helpers.assert_eq(view.shortcuts, true, "every other key must be the live value")
		helpers.assert_eq(state.gestures, false, "the live state must keep the real posture")
		helpers.assert_true(not rawequal(view, state), "the override must never mutate the state")
	end)

	helpers.it("hands back the live state itself when no demotion applies", function()
		local registry = load_subject().new()
		local state = { gestures = true }
		helpers.assert_true(rawequal(registry.persisted_view(state), state))
	end)

	helpers.it("ends a demotion once a save commits the user's change of that value", function()
		local registry = load_subject().new()
		local state = { gestures = false }
		registry.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })
		state.gestures = true
		helpers.assert_eq(registry.persisted_view(state).gestures, true)
		helpers.assert_eq(#registry.list(), 1,
			"building the view must not end the demotion before the save commits")
		registry.settle(state)
		helpers.assert_eq(#registry.list(), 0, "the committed change ends the demotion")
		state.gestures = false
		helpers.assert_eq(registry.persisted_view(state).gestures, false,
			"a later explicit OFF must reach config.toml")
	end)

	helpers.it("keeps a demotion whose key still holds its demoted posture at commit", function()
		local registry = load_subject().new()
		local state = { gestures = false, shortcuts = true }
		registry.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })
		registry.settle(state)
		helpers.assert_eq(#registry.list(), 1, "an unrelated committed save must not end it")
		helpers.assert_eq(registry.persisted_view(state).gestures, true)
		helpers.assert_true(not pcall(registry.settle, nil))
	end)

	helpers.it("keeps the first saved value when the same key is demoted again", function()
		local registry = load_subject().new()
		registry.record({ feature = "metrics", key = "keylogger_enabled", persisted = true, demoted = false })
		registry.record({ feature = "metrics", key = "keylogger_enabled", persisted = false, demoted = false })
		helpers.assert_eq(registry.persisted_view({ keylogger_enabled = false }).keylogger_enabled, true)

		registry.record({ feature = "hotstrings", key = "keymap", persisted = false, demoted = true })
		registry.record({ feature = "hotstrings", key = "keymap", persisted = true, demoted = true })
		helpers.assert_eq(registry.persisted_view({ keymap = true }).keymap, false,
			"a saved false must survive a second demotion of the same key")
	end)

	helpers.it("compares table values structurally", function()
		local registry = load_subject().new()
		registry.record({
			feature = "hotstring_editor", key = "custom_editor_shortcut",
			persisted = { mods = { "ctrl" }, key = "k" }, demoted = false,
		})
		local view = registry.persisted_view({ custom_editor_shortcut = false })
		helpers.assert_eq(view.custom_editor_shortcut, { mods = { "ctrl" }, key = "k" })
	end)

	helpers.it("rejects a record without a feature or a state key", function()
		local registry = load_subject().new()
		helpers.assert_true(not pcall(registry.record, { feature = "gestures" }))
		helpers.assert_true(not pcall(registry.record, { key = "gestures" }))
		helpers.assert_eq(#registry.list(), 0)
	end)
end)





-- ================================================
-- ================================================
-- ======= 2/ Global Actions Supersede Them =======
-- ================================================
-- ================================================

helpers.describe("session demotions and global actions", function()
	helpers.it("detaches every demotion for an explicit save and restores them on failure", function()
		local registry = load_subject().new()
		registry.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })

		local released = registry.release_all()
		helpers.assert_eq(registry.persisted_view({ gestures = false }).gestures, false,
			"Disable All must write its explicit OFF")
		helpers.assert_eq(registry.readopt(released), true)
		helpers.assert_eq(registry.persisted_view({ gestures = false }).gestures, true,
			"a reversed global save must not lose the saved value")
		helpers.assert_eq(registry.readopt(released), true, "a retried inverse may readopt again")
		helpers.assert_eq(#registry.list(), 1)
		helpers.assert_true(not pcall(registry.readopt, nil))
	end)
end)

return true
