--- tests/unit/ui/menu/test_menu_state_replays_shortcut_keys_behind_fence.lua

--- ==============================================================================
--- MODULE: Boot Replay Of [shortcuts.keys] Behind The Fence
--- DESCRIPTION:
--- menu_state.sync_state_to_modules pauses the Shortcuts layer when the master
--- switch is off, then replays every saved [shortcuts.keys] entry through
--- enable/disable. Bindings refused every enable behind that fence with an
--- ERROR, and listed the released binding as the preference, so a boot with
--- Shortcuts OFF logged one ERROR per key and the next save wrote every key
--- false. The real menu_state drives the real Bindings registry here, so a
--- reordered replay or a Bindings contract change fails this file.
---
--- FEATURES & RATIONALE:
--- 1. Real Consumer: the replay loop under test is menu_state's own, not a copy.
--- 2. Aggregate Edges: pause_bindings/resume_bindings map onto the Bindings
---    edges the modules.shortcuts aggregate reaches (pause, resume_after_pause).
--- 3. Both Axes: every listed shortcut is checked for preference and binding.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

local DISABLED_ID = "ctrl_d"

-- menu_state requires these transitively; require() publishes them directly to
-- the cache, so they are owned here to keep the suite order-independent.
local MENU_STATE_MODULES = {
	"ui.menu.menu_state",
	"ui.menu.keymap_lifecycle",
	"adapters.storage",
	"infra.deferred_work",
	"modules.keylogger.text_cipher",
}

--- Runs the real sync_state_to_modules against the real Bindings registry.
--- @param bindings table Real Bindings module.
--- @param shortcuts_on boolean Shortcuts master switch.
--- @param keys table Saved [shortcuts.keys].
--- @return boolean committed Exact sync result.
local function sync(bindings, shortcuts_on, keys)
	return helpers.with_fresh_modules(MENU_STATE_MODULES, function()
		-- Deferred warm-up work is irrelevant to the replay and must not outlive
		-- the fixture that owns the Bindings registry.
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		local menu_state = helpers.load_with_stubs("ui.menu.menu_state")
		local facade = {
			pause_bindings = bindings.pause,
			resume_bindings = bindings.resume_after_pause,
			enable = bindings.enable,
			disable = bindings.disable,
			list_shortcuts = bindings.list_shortcuts,
			is_enabled = bindings.is_enabled,
		}
		return menu_state.sync_state_to_modules(
			{ shortcuts = shortcuts_on, hotstrings = {} },
			{ shortcut_keys = keys },
			false,
			{ core_mods = { shortcuts_mod = facade }, hotstring_editor = {} }
		)
	end)
end

--- Builds saved keys with every listed shortcut on except DISABLED_ID.
--- @param bindings table Real Bindings module.
--- @return table keys Saved [shortcuts.keys].
local function saved_keys(bindings)
	local keys = {}
	for id in pairs(Fixture.index(bindings)) do keys[id] = id ~= DISABLED_ID end
	helpers.assert_eq(keys[DISABLED_ID], false,
		"the disabled shortcut must be registered, or the replay is one-sided")
	return keys
end





-- ========================================================
-- ========================================================
-- ======= 1/ Shortcuts OFF At Boot Keeps Every Key =======
-- ========================================================
-- ========================================================

helpers.describe("menu_state: [shortcuts.keys] replay behind the fence (shortcut-preference-vs-binding)", function()
	helpers.it("reports a refused enable without replacing its saved preference (shortcut-replay-refusal)", function()
		Fixture.with_bindings(function(bindings, ctx)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.disable("at_hash"), true)
			ctx.refuse.at_hash = true
			local committed, report = sync(bindings, true, { at_hash = true })
			helpers.assert_eq(committed, false)
			helpers.assert_eq(#report.failures, 1)
			helpers.assert_eq(report.demotions, {
				{ feature = "shortcuts", key = "shortcut_keys", subkey = "at_hash",
					persisted = true, demoted = false },
			})
			helpers.assert_eq(#report.unsettled, 0)
			helpers.assert_eq(bindings.is_enabled("at_hash"), false)
		end)
	end)

	helpers.it("records every saved key while Shortcuts is OFF and binds them when it turns ON", function()
		Fixture.with_bindings(function(bindings, ctx)
			-- init.lua starts the bindings before the menu applies config.toml.
			helpers.assert_eq(bindings.start(), true)
			local keys = saved_keys(bindings)

			helpers.assert_eq(sync(bindings, false, keys), true,
				"the Shortcuts OFF boot sync must commit")
			helpers.assert_eq(#ctx.errors, 0,
				"replaying saved keys behind the fence is not an error: "
					.. table.concat(ctx.errors, " | "))
			helpers.assert_eq(Fixture.live_count(ctx), 0,
				"Shortcuts OFF must leave no native hotkey")
			for id, entry in pairs(Fixture.index(bindings)) do
				helpers.assert_eq(entry.enabled, keys[id],
					"Shortcuts OFF: preference of " .. id)
				helpers.assert_eq(entry.bound, false, "Shortcuts OFF: binding of " .. id)
			end

			helpers.assert_eq(sync(bindings, true, keys), true,
				"the Shortcuts ON sync must commit")
			helpers.assert_eq(#ctx.errors, 0, table.concat(ctx.errors, " | "))
			for id, entry in pairs(Fixture.index(bindings)) do
				helpers.assert_eq(entry.enabled, keys[id], "Shortcuts ON: preference of " .. id)
				helpers.assert_eq(entry.bound, keys[id], "Shortcuts ON: binding of " .. id)
			end
		end)
	end)
end)

return true
