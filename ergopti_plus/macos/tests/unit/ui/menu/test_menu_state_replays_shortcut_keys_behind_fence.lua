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
-- A registered binding with a raw factory the fixture can make refuse.
local REFUSED_ID = "cmd_star"
-- Owners derived from other files (tap-key assignments, the layer's wheel in
-- layers.toml) rather than from a saved key.
local DERIVED_IDS = { tap_keys = true, layer_wheel = true }

-- A config.toml written by an older build: at_hash was removed from the
-- binding registry and the manifest, and retired_off never existed.
local OUTDATED_KEYS = table.concat({
	"[shortcuts.keys]",
	"at_hash = true",
	DISABLED_ID .. " = false",
	"retired_off = false",
	"",
}, "\n")

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

--- Builds saved preferences, excluding the dispatcher derived from assignments.
--- @param bindings table Real Bindings module.
--- @return table keys Saved [shortcuts.keys].
local function saved_keys(bindings)
	local keys = {}
	for id in pairs(Fixture.index(bindings)) do
		if id ~= "tap_keys" then keys[id] = id ~= DISABLED_ID end
	end
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
			-- A REGISTERED binding whose native factory refuses: the fail-closed
			-- contract of a real refusal. at_hash used to stand here, but it is no
			-- longer registered, so the case pinned an unknown id instead.
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.disable(REFUSED_ID), true)
			ctx.refuse[REFUSED_ID] = true
			local committed, report = sync(bindings, true, { [REFUSED_ID] = true })
			helpers.assert_eq(committed, false)
			helpers.assert_eq(#report.failures, 1)
			helpers.assert_eq(report.demotions, {
				{ feature = "shortcuts", key = "shortcut_keys", subkey = REFUSED_ID,
					persisted = true, demoted = false },
			})
			helpers.assert_eq(#report.unsettled, 0)
			helpers.assert_eq(bindings.is_enabled(REFUSED_ID), false)
			helpers.assert_true(#ctx.errors > 0, "a real native refusal stays an ERROR")
		end)
	end)

	helpers.it("warns once about a removed saved key and never refuses the boot (config-outdated-at-hash)", function()
		helpers.with_fresh_modules({ "logger.shim", "config_outdated", "infra.preferences" }, function()
		Fixture.with_bindings(function(bindings, ctx)
			local warnings = {}
			local shim = helpers.make_logger_stub()
			shim.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			shim.error = function(_, message, ...) ctx.errors[#ctx.errors + 1] = string.format(message, ...) end
			package.loaded["logger.shim"] = shim
			helpers.load_with_stubs("config_outdated")
			local Preferences = helpers.load_with_stubs("infra.preferences")
			local decoded = require("toml_codec").decode(OUTDATED_KEYS)

			-- The loader is the gate: the removed id never reaches the replay.
			local saved = Preferences.flatten_document(decoded)
			helpers.assert_eq(saved.shortcut_keys, { [DISABLED_ID] = false })
			helpers.assert_eq(bindings.start(), true)
			local committed, report = sync(bindings, true, saved.shortcut_keys)
			helpers.assert_eq(committed, true, "an outdated key must not fail the boot sync")
			helpers.assert_eq(#report.failures, 0)
			helpers.assert_eq(report.demotions, {})
			helpers.assert_eq(#ctx.errors, 0, table.concat(ctx.errors, " | "))
			helpers.assert_eq(bindings.is_enabled(DISABLED_ID), false)

			-- One WARNING per outdated entry, however often the file is read.
			Preferences.flatten_document(require("toml_codec").decode(OUTDATED_KEYS))
			table.sort(warnings)
			helpers.assert_eq(#warnings, 2, table.concat(warnings, " | "))
			helpers.assert_true(warnings[1]:find("'shortcuts.keys.at_hash'", 1, true) ~= nil, warnings[1])
			helpers.assert_true(warnings[1]:find("offered for cleanup", 1, true) ~= nil, warnings[1])
			helpers.assert_true(warnings[2]:find("'shortcuts.keys.retired_off'", 1, true) ~= nil, warnings[2])

			-- Warned is offered: the cleanup lists exactly the outdated entries.
			local scan = require("config_unused_keys").find_in_source(OUTDATED_KEYS, Preferences.mark_config_reads)
			local offered = {}
			for _, key in ipairs(scan.keys) do offered[#offered + 1] = key.section .. "." .. key.key end
			table.sort(offered)
			helpers.assert_eq(offered, { "shortcuts.keys.at_hash", "shortcuts.keys.retired_off" })
		end)
		end)
	end)

	helpers.it("records every saved key while Shortcuts is OFF and binds them when it turns ON", function()
		Fixture.with_bindings(function(bindings, ctx)
			local tap_keys = require("modules.shortcuts.tap_keys")
			helpers.assert_eq(tap_keys.set_action("number_row_left", "screen_capture"), true)
			-- A layers.toml that binds the wheel: the other owner derived from a file.
			ctx.wheel.vertical[1] = { code = "WheelUp", strokes = { { system = "SOUND_UP" } } }
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
				local expected = DERIVED_IDS[id] or keys[id]
				helpers.assert_eq(entry.enabled, expected,
					"Shortcuts OFF: preference of " .. id)
				helpers.assert_eq(entry.bound, false, "Shortcuts OFF: binding of " .. id)
			end

			helpers.assert_eq(sync(bindings, true, keys), true,
				"the Shortcuts ON sync must commit")
			helpers.assert_eq(#ctx.errors, 0, table.concat(ctx.errors, " | "))
			for id, entry in pairs(Fixture.index(bindings)) do
				local expected = DERIVED_IDS[id] or keys[id]
				helpers.assert_eq(entry.enabled, expected, "Shortcuts ON: preference of " .. id)
				helpers.assert_eq(entry.bound, expected, "Shortcuts ON: binding of " .. id)
			end
		end)
	end)
end)

return true
