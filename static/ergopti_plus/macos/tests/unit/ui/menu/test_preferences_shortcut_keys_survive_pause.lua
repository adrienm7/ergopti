--- tests/unit/ui/menu/test_preferences_shortcut_keys_survive_pause.lua

--- ==============================================================================
--- MODULE: [shortcuts.keys] Survive Pause Regression
--- DESCRIPTION:
--- Preferences.save filled [shortcuts.keys] from Bindings.list_shortcuts, whose
--- `enabled` was the live native binding. Every save made while the Shortcuts
--- layer was paused, off, stopped or rebinding (Disable All publishes exactly
--- then) therefore wrote every named shortcut as false, and the next boot
--- disabled each of them individually even with [shortcuts] enabled = true.
---
--- FEATURES & RATIONALE:
--- 1. Real Pair: the real Bindings registry feeds the real Preferences encoder,
---    and the keys are read back through the real TOML decoder.
--- 2. Every Release Edge: pause, stop and the layout-rebind fence all release
---    native hotkeys, so each one is a separate publication window.
--- 3. Re-application: applying the saved keys behind the fence, as the boot and
---    Disable All synchronization do, must reproduce them without an ERROR.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

local CONFIG_PATH = "/virtual/config.toml"
local DISABLED_ID = "ctrl_d"

--- Runs a scenario against real Preferences over an in-memory config file.
--- @param callback function Receives (preferences, disk).
--- @return ... Callback results.
local function with_preferences(callback)
	return helpers.with_stub_scope({
		"infra.preferences", "adapters.file_system", "infra.logger",
	}, function()
		local disk = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path)
				if disk[path] == nil then return nil, "absent" end
				return disk[path], "ok"
			end,
			write_if_unchanged = function(path, content)
				disk[path] = content
				return true
			end,
		}
		local preferences = helpers.load_with_stubs("infra.preferences")
		return callback(preferences, disk)
	end)
end

--- Saves through the real encoder and reads [shortcuts.keys] back from disk.
--- @param preferences table Real Preferences module.
--- @param bindings table Real Bindings module.
--- @return table keys Decoded [shortcuts.keys].
local function save_and_read_keys(preferences, bindings)
	helpers.assert_eq(preferences.save(CONFIG_PATH, { shortcuts = false }, {},
		{ shortcuts_mod = bindings }), true, "the preference save must commit")
	local saved, status = preferences.load(CONFIG_PATH)
	helpers.assert_eq(status, "ok")
	helpers.assert_type(saved.shortcut_keys, "table",
		"[shortcuts.keys] must be written")
	return saved.shortcut_keys
end

--- Asserts every listed shortcut was persisted with its preference.
--- @param bindings table Real Bindings module.
--- @param keys table Decoded [shortcuts.keys].
--- @param context string Diagnostic context.
local function assert_keys(bindings, keys, context)
	for id in pairs(Fixture.index(bindings)) do
		helpers.assert_eq(keys[id], id ~= DISABLED_ID,
			context .. ": [shortcuts.keys] " .. id)
	end
end





-- ============================================================
-- ============================================================
-- ======= 1/ A Save Behind The Fence Keeps Preferences =======
-- ============================================================
-- ============================================================

helpers.describe("preferences: [shortcuts.keys] survive a paused save (shortcut-preference-vs-binding)", function()
	for _, edge in ipairs({ "pause", "stop", "pause_hotkeys_only" }) do
		helpers.it("persists the preference, not the binding, after " .. edge, function()
			with_preferences(function(preferences)
				Fixture.with_bindings(function(bindings, ctx)
					helpers.assert_eq(bindings.start(), true)
					helpers.assert_eq(bindings.disable(DISABLED_ID), true)
					helpers.assert_eq(bindings[edge](), true)
					helpers.assert_eq(Fixture.live_count(ctx), 0,
						"the save must happen while no hotkey is bound")
					assert_keys(bindings, save_and_read_keys(preferences, bindings),
						"after " .. edge)
				end)
			end)
		end)
	end
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Re-Applying Saved Keys Behind The Fence =======
-- ==========================================================
-- ==========================================================

helpers.describe("preferences: saved keys re-apply while paused (shortcut-preference-vs-binding)", function()
	helpers.it("reproduces the same keys without an ERROR and binds them on resume", function()
		with_preferences(function(preferences)
			Fixture.with_bindings(function(bindings, ctx)
				helpers.assert_eq(bindings.start(), true)
				helpers.assert_eq(bindings.disable(DISABLED_ID), true)
				-- Saved while the layer runs, so this set is right even before the
				-- fix; only the replay behind the fence below is under test.
				local keys = save_and_read_keys(preferences, bindings)
				assert_keys(bindings, keys, "saved while running")
				helpers.assert_eq(bindings.pause(), true)

				-- The boot and Disable All synchronizations pause the layer first,
				-- then replay every saved key through enable/disable.
				for id, wanted in pairs(keys) do
					local method = wanted and bindings.enable or bindings.disable
					helpers.assert_eq(method(id), true,
						"re-applying '" .. id .. "' behind the fence must commit")
				end
				helpers.assert_eq(#ctx.errors, 0,
					"replaying saved preferences is not an error: " .. table.concat(ctx.errors, " | "))
				assert_keys(bindings, save_and_read_keys(preferences, bindings), "replayed")

				helpers.assert_eq(bindings.resume_after_pause(), true)
				for id, entry in pairs(Fixture.index(bindings)) do
					helpers.assert_eq(entry.bound, id ~= DISABLED_ID,
						"resume must bind exactly the preferred shortcuts: " .. id)
				end
			end)
		end)
	end)
end)

return true
