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
		local control = { refuse_write = false }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path)
				if disk[path] == nil then return nil, "absent" end
				return disk[path], "ok"
			end,
			write_if_unchanged = function(path, content)
				if control.refuse_write then return false end
				disk[path] = content
				return true
			end,
		}
		local preferences = helpers.load_with_stubs("infra.preferences")
		return callback(preferences, disk, control)
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

-- Owners derived from other files (tap-key assignments, the layer's wheel in
-- layers.toml): no [shortcuts.keys] preference is ever written for them.
local DERIVED_IDS = { tap_keys = true, layer_wheel = true }

--- Asserts declared preferences survive and the derived dispatchers stay absent.
--- @param bindings table Real Bindings module.
--- @param keys table Decoded [shortcuts.keys].
--- @param context string Diagnostic context.
local function assert_keys(bindings, keys, context)
	for id in pairs(Fixture.index(bindings)) do
		helpers.assert_eq(keys[id], id ~= DISABLED_ID and not DERIVED_IDS[id] and true or nil,
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
				Fixture.with_recommended_bindings(function(bindings, ctx)
					helpers.assert_eq(bindings.start(), true, table.concat(ctx.errors, "\n"))
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
			Fixture.with_recommended_bindings(function(bindings, ctx)
				helpers.assert_eq(bindings.start(), true, table.concat(ctx.errors, "\n"))
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

helpers.describe("preferences: refused shortcut replay (shortcut-replay-refusal)", function()
	helpers.it("keeps the saved leaf across other changes and failed publication", function()
		helpers.with_fresh_modules({
			"ui.menu.menu_state", "ui.menu.keymap_lifecycle", "adapters.storage",
			"infra.deferred_work", "modules.keylogger.text_cipher",
			"ui.menu.session_demotions", "ui.menu.preferences_transaction",
		}, function()
			with_preferences(function(preferences, disk, control)
				disk[CONFIG_PATH] = "[shortcuts]\nenabled = true\n[shortcuts.keys]\nctrl_d = false\n"
				local saved = preferences.load(CONFIG_PATH)
				Fixture.with_recommended_bindings(function(bindings, ctx)
					helpers.assert_eq(bindings.start(), true, table.concat(ctx.errors, "\n"))
					local denied_handle
					for handle in pairs(ctx.live) do
						if handle.id == "ctrl+d" then denied_handle = handle end
					end
					helpers.assert_type(denied_handle, "table", "the refusal must target a live shortcut")
					local real_delete = denied_handle.delete
					denied_handle.delete = function() return false end
					package.loaded["infra.deferred_work"] = { after = function() return true end }
					local subject = helpers.load_with_stubs("ui.menu.menu_state")
					local facade = {
						pause_bindings = bindings.pause, resume_bindings = bindings.resume_after_pause,
						enable = bindings.enable, disable = bindings.disable,
						list_shortcuts = bindings.list_shortcuts, is_enabled = bindings.is_enabled,
					}
					local state = { shortcuts = true, hotstrings = {} }
					local core = { shortcuts_mod = facade }
					local committed, report = subject.sync_state_to_modules(state, saved, false,
						{ core_mods = core, hotstring_editor = {} })
					helpers.assert_eq(committed, false, "a refused replay is not successful synchronization")
					helpers.assert_eq(#report.demotions, 1)
					helpers.assert_eq(#report.unsettled, 0, "the actual preference is observable")
					local registry = require("ui.menu.session_demotions").new()
					registry.record(report.demotions[1])
					local save = require("ui.menu.preferences_transaction").bind(preferences, {
						path = CONFIG_PATH, state = state, hotfiles = {}, core_modules = core,
						initial_state = state,
						initial_preferences = preferences.snapshot(state, {}, core),
						snapshot_view = registry.persisted_view,
						on_commit = function(_, runtime_snapshot) registry.settle(runtime_snapshot) end,
						restore_runtime = function(snapshot)
							for id, wanted in pairs(snapshot.shortcut_keys) do
								local apply = wanted and bindings.enable or bindings.disable
								if apply(id) ~= true then return false end
							end
							return true
						end,
					})
					helpers.assert_eq(save(), true)
					helpers.assert_eq(preferences.load(CONFIG_PATH).shortcut_keys.ctrl_d, nil)
					helpers.assert_eq(bindings.is_enabled(DISABLED_ID), true,
						"the saved view must not pretend native teardown succeeded")
					local other
					for id in pairs(Fixture.index(bindings)) do
						if id ~= DISABLED_ID then other = id; break end
					end
					helpers.assert_type(other, "string")
					helpers.assert_eq(bindings.disable(other), true)
					helpers.assert_eq(save(), true)
					local reloaded = preferences.load(CONFIG_PATH)
					helpers.assert_eq(reloaded.shortcut_keys[other], nil)
					helpers.assert_eq(reloaded.shortcut_keys.ctrl_d, nil,
						"editing a sibling must not end the refused leaf's preservation")
					helpers.assert_eq(#registry.list(), 1)
					denied_handle.delete = real_delete
					helpers.assert_eq(bindings.disable(DISABLED_ID), true)
					control.refuse_write = true
					local before = disk[CONFIG_PATH]
					helpers.assert_eq(save(), false)
					helpers.assert_eq(disk[CONFIG_PATH], before)
					helpers.assert_eq(#registry.list(), 1, "failed writes cannot settle a demotion")
					helpers.assert_eq(bindings.is_enabled(DISABLED_ID), true,
						"rollback must restore the actual committed runtime snapshot")
					control.refuse_write = false
					helpers.assert_eq(bindings.disable(DISABLED_ID), true)
					helpers.assert_eq(save(), true)
					helpers.assert_eq(#registry.list(), 0, "an explicit committed change ends preservation")
					helpers.assert_eq(bindings.enable(DISABLED_ID), true)
					helpers.assert_eq(save(), true)
					helpers.assert_eq(preferences.load(CONFIG_PATH).shortcut_keys.ctrl_d, true)
				end)
			end)
		end)
	end)
end)

return true
