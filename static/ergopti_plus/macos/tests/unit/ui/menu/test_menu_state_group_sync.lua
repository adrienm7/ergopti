--- tests/unit/ui/menu/test_menu_state_group_sync.lua

--- ==============================================================================
--- MODULE: Menu State — Hotstring Group Sync (perf regression)
--- DESCRIPTION:
--- Locks down that MenuState.sync_state_to_modules applies ONLY the delta when
--- restoring saved hotstring-group state: an already-enabled group is left alone
--- (a single cheap enable_group no-op), never disabled-then-re-enabled.
---
--- ROOT CAUSE ENCODED: the boot state-restore used to run disable_group +
--- enable_group for EVERY enabled group. At startup all groups are already
--- enabled, so this purged and RE-PARSED each category TOML from disk and
--- re-sorted all ~5355 mappings ~16× for zero net change — the dominant ~2 s of
--- the "Menu + UI + script control start" boot phase. If a future edit
--- reintroduces the blind round-trip, the disable assertion below fails.
--- ==============================================================================

local helpers = require("tests.helpers")

local original_deferred_work = package.loaded["infra.deferred_work"]
local original_subject = package.loaded["ui.menu.menu_state"]
local DeferredWork = {
	after = function(_, callback)
		callback()
		return true
	end,
}
package.loaded["infra.deferred_work"] = DeferredWork
local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

--- True when `list` contains the string `needle`.
local function has(list, needle)
	for _, v in ipairs(list) do
		if v == needle then return true end
	end
	return false
end

--- Runs sync_state_to_modules with a spy keymap and returns the ordered list of
--- enable_group / disable_group calls it made.
--- @param hotstrings table Map of group name → desired enabled boolean.
--- @return table Array of "enable:<name>" / "disable:<name>" strings.
local function capture_group_calls(hotstrings)
	local calls = {}
	local fake_keymap = {
		enable_group     = function(n) calls[#calls + 1] = "enable:"  .. n end,
		disable_group    = function(n) calls[#calls + 1] = "disable:" .. n end,
		is_group_enabled = function() return true end,
	}
	local state = { hotstrings = hotstrings }
	MenuState.sync_state_to_modules(state, {}, false, {
		keymap           = fake_keymap,
		hotstring_editor = {},  -- empty: every type(...) guard skips it
		core_mods        = {},
		save_prefs       = function() end,
	})
	return calls
end

helpers.describe("menu_state: hotstring group sync applies only the delta", function()
	helpers.it("enables a wanted group WITHOUT disabling it first (no costly reload round-trip)", function()
		local calls = capture_group_calls({ magickey = true })
		helpers.assert_true(has(calls, "enable:magickey"),
			"an enabled group must be passed to enable_group")
		helpers.assert_true(not has(calls, "disable:magickey"),
			"an enabled group must NOT be disabled first — that forced a full TOML reload + re-sort")
	end)

	helpers.it("disables ONLY the groups the user turned off", function()
		local calls = capture_group_calls({ rolls = false })
		helpers.assert_true(has(calls, "disable:rolls"),
			"a disabled group must be passed to disable_group")
		helpers.assert_true(not has(calls, "enable:rolls"),
			"a disabled group must NOT be re-enabled")
	end)
end)

helpers.describe("menu_state: custom terminator restore quarantines rejected rows", function()
	for _, wanted in ipairs({ false, true }) do
		helpers.it("restores the saved " .. tostring(wanted)
			.. " after registration (custom-terminator-restore-state)", function()
			local runtime_enabled
			local restored = 0
			local state = {
				hotstrings = {},
				custom_terminators = {
					{ key = "custom_ok", char = "@", label = "valid", consume = false },
				},
				terminator_states = { custom_ok = wanted },
			}
			local committed = MenuState.sync_state_to_modules(state,
				{ terminator_states = { custom_ok = wanted } }, false, {
					keymap = {
						set_llm_model = function() return true end,
						get_terminator_defs = function() return {} end,
						remove_custom_terminator = function() return true end,
						validate_custom_terminator = function() return true end,
						add_custom_terminator = function()
							runtime_enabled = true
							return true
						end,
						set_terminator_enabled = function(_, enabled)
							-- Before registration the real registry cannot find this key.
							if runtime_enabled == nil then return false end
							runtime_enabled = enabled
							restored = restored + 1
							return true
						end,
					},
					core_mods = {}, hotstring_editor = {},
				})
			helpers.assert_eq(committed, true)
			helpers.assert_eq(runtime_enabled, wanted,
				"registration must not replace the saved OFF with its default ON")
			helpers.assert_eq(restored, 1,
				"the preference must reach the registered key exactly once")
		end)
	end

	helpers.it("retains only exact committed custom definitions and reports the repair", function()
		local add_calls = {}
		local save_calls = 0
		local state = {
			hotstrings = {},
			custom_terminators = {
				{ key = "custom_ok", char = "@", label = "valid", consume = false },
				{ key = "custom_bad", char = ",", label = "collision", consume = true },
			},
			terminator_states = { custom_ok = false, custom_bad = true },
		}
		local saved = {
			terminator_states = { custom_ok = false, custom_bad = true },
		}
		local committed, report = MenuState.sync_state_to_modules(state, saved, false, {
			keymap = {
				set_llm_model = function() return true end,
				get_terminator_defs = function() return {} end,
				remove_custom_terminator = function() return true end,
				validate_custom_terminator = function(key)
					return key == "custom_ok"
				end,
				add_custom_terminator = function(key)
					add_calls[#add_calls + 1] = key
					return true
				end,
				set_terminator_enabled = function() return true end,
			},
			hotstring_editor = {},
			core_mods = {},
			save_prefs = function()
				save_calls = save_calls + 1
				return true
			end,
		})

		helpers.assert_eq(committed, true,
			"successful quarantine persistence must leave startup usable")
		helpers.assert_eq(add_calls, { "custom_ok" },
			"invalid persisted rows must be rejected before runtime mutation")
		helpers.assert_eq(#state.custom_terminators, 1)
		helpers.assert_eq(state.custom_terminators[1].key, "custom_ok")
		helpers.assert_nil(state.terminator_states.custom_bad)
		helpers.assert_eq(save_calls, 0,
			"the sync never persists: at boot it runs before the save transaction exists")
		helpers.assert_eq(report.repairs, { "custom_terminators" },
			"the caller must learn that the repaired rows still have to be saved")
	end)

	for _, outcome in ipairs({ "false", "nil", "throw" }) do
		helpers.it("does not quarantine a valid row after a runtime " .. outcome, function()
			local save_calls = 0
			local state = {
				hotstrings = {},
				custom_terminators = {
					{ key = "custom_runtime", char = "@", label = "valid", consume = false },
				},
				terminator_states = { custom_runtime = true },
			}
			local committed = MenuState.sync_state_to_modules(state,
				{ terminator_states = { custom_runtime = true } }, false, {
					keymap = {
						set_llm_model = function() return true end,
						get_terminator_defs = function() return {} end,
						remove_custom_terminator = function() return true end,
						validate_custom_terminator = function() return true end,
						add_custom_terminator = function()
							if outcome == "throw" then error("injected restore refusal", 0) end
							if outcome == "false" then return false end
							return nil
						end,
						set_terminator_enabled = function() return true end,
					},
					hotstring_editor = {},
					core_mods = {},
					save_prefs = function() save_calls = save_calls + 1; return true end,
				})

			helpers.assert_eq(committed, false)
			helpers.assert_eq(#state.custom_terminators, 1,
				"a runtime refusal is not evidence that persisted data is invalid")
			helpers.assert_eq(state.custom_terminators[1].key, "custom_runtime")
			helpers.assert_eq(state.terminator_states.custom_runtime, true)
			helpers.assert_eq(save_calls, 0,
				"runtime refusal must not rewrite valid preferences")
		end)
	end
end)

helpers.describe("menu_state: gesture boot restore requires an exact lifecycle commit", function()
	for _, desired in ipairs({ false, true }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("restores runtime state after "
				.. (desired and "enable " or "disable ") .. mode, function()
				local runtime_enabled = not desired
				local lifecycle_calls = 0
				local save_calls = 0
				local function lifecycle()
					lifecycle_calls = lifecycle_calls + 1
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					error("synthetic gesture boot refusal")
				end
				local state = { gestures = desired, hotstrings = {} }
				local committed, report = MenuState.sync_state_to_modules(state, {}, false, {
					keymap = {}, hotstring_editor = {}, core_mods = {},
					gestures = {
						enable_all = desired and lifecycle or function() return true end,
						disable_all = desired and function() return true end or lifecycle,
						is_enabled = function() return runtime_enabled end,
					},
					save_prefs = function()
						save_calls = save_calls + 1
						return true
					end,
				})
				helpers.assert_eq(committed, false)
				helpers.assert_eq(lifecycle_calls, 1)
				helpers.assert_eq(state.gestures, runtime_enabled,
					"the restored state must describe the exact surviving runtime")
				helpers.assert_eq(save_calls, 0,
					"a runtime refusal must not rewrite config.toml, nor save before seeding")
				helpers.assert_eq(#report.demotions, 1)
				helpers.assert_eq(report.demotions[1].key, "gestures")
				helpers.assert_eq(report.demotions[1].persisted, desired,
					"the demotion must carry the saved value for the caller to keep on disk")
				helpers.assert_eq(report.demotions[1].demoted, runtime_enabled)
				helpers.assert_eq(#report.unsettled, 0)
			end)
		end
	end
end)

helpers.describe("menu_state: keylogger start is deferred off the boot path", function()
	helpers.it("does NOT start the keylogger synchronously during sync", function()
		-- ROOT CAUSE ENCODED: keylogger.start (~1.3 s of SQLite + rotation work) ran
		-- inline during sync_state_to_modules and dominated boot. It must be deferred
		-- through retained deferred work; a synchronous regression fails the count below.
		local started = { count = 0 }
		local fake_kl = {
			set_options       = function() end,
			set_disabled_apps = function() end,
			start             = function() started.count = started.count + 1; return true end,
			stop              = function() return true end,
		}

		local deferred = {}
		DeferredWork.after = function(_delay, callback)
			deferred[#deferred + 1] = callback
			return true
		end

		MenuState.sync_state_to_modules(
			{ hotstrings = {}, keylogger_enabled = true },
			{}, false,
			{ keymap = {}, hotstring_editor = {}, core_mods = { keylogger = fake_kl }, save_prefs = function() return true end }
		)

		helpers.assert_eq(started.count, 0)        -- not started inline
		helpers.assert_true(#deferred >= 1,
			"keylogger start must be scheduled through the retained owner")

		-- Firing the deferred callbacks must then actually start it.
		for _, fn in ipairs(deferred) do pcall(fn) end
		helpers.assert_eq(started.count, 1)        -- started exactly once, later
	end)

	helpers.it("discards an enabled timer superseded by rollback to disabled", function()
		local started = 0
		local deferred = {}
		DeferredWork.after = function(_delay, callback)
			deferred[#deferred + 1] = callback
			return true
		end
		local deps = {
			keymap = {}, hotstring_editor = {}, save_prefs = function() return true end,
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			core_mods = { keylogger = {
				set_options = function() end,
				set_disabled_apps = function() end,
				start = function() started = started + 1; return true end,
				stop = function() return true end,
			} },
		}
		MenuState.sync_state_to_modules({ hotstrings = {}, keylogger_enabled = true }, {}, false, deps)
		MenuState.sync_state_to_modules({ hotstrings = {}, keylogger_enabled = false }, {}, false, deps)
		deferred[1]()
		helpers.assert_eq(started, 0,
			"a failed enable rolled back to disabled must fence its deferred keylogger start")
	end)

	helpers.it("demotes Metrics in memory only when deferred start is rejected", function()
		local deferred = {}
		local save_calls = 0
		local demotions = {}
		DeferredWork.after = function(_delay, callback)
			deferred[#deferred + 1] = callback
			return true
		end
		local state = { hotstrings = {}, keylogger_enabled = true }
		MenuState.sync_state_to_modules(state, {}, false, {
			keymap = {}, hotstring_editor = {},
			save_prefs = function() save_calls = save_calls + 1; return true end,
			on_runtime_demotion = function(record) demotions[#demotions + 1] = record end,
			core_mods = { keylogger = {
				set_options = function() end,
				set_disabled_apps = function() end,
				start = function() return false end,
			} },
		})

		for _, fn in ipairs(deferred) do fn() end
		helpers.assert_eq(false, state.keylogger_enabled,
			"a rejected deferred start must not leave the restored checkmark enabled")
		helpers.assert_eq(0, save_calls,
			"a missing permission must not rewrite the saved Metrics ON")
		helpers.assert_eq(#demotions, 1, "the late demotion must reach its session owner")
		helpers.assert_eq(demotions[1].key, "keylogger_enabled")
		helpers.assert_eq(demotions[1].persisted, true)
		helpers.assert_eq(demotions[1].demoted, false)
	end)

	helpers.it("contains a raising demotion owner inside the guarded timer callback", function()
		for _, outcome in ipairs({ "start_false", "start_throw" }) do
			local deferred = {}
			local save_calls = 0
			local recorder_calls = 0
			DeferredWork.after = function(_delay, callback)
				deferred[#deferred + 1] = callback
				return true
			end
			local state = { hotstrings = {}, keylogger_enabled = true }
			MenuState.sync_state_to_modules(state, {}, false, {
				keymap = {}, hotstring_editor = {},
				save_prefs = function() save_calls = save_calls + 1; return true end,
				on_runtime_demotion = function()
					recorder_calls = recorder_calls + 1
					error("injected demotion owner failure")
				end,
				core_mods = { keylogger = {
					set_options = function() end,
					set_disabled_apps = function() end,
					start = function()
						if outcome == "start_throw" then error("injected start refusal") end
						return false
					end,
				} },
			})

			local callback_ok, callback_err = true, nil
			for _, callback in ipairs(deferred) do
				local fired, fire_err = pcall(callback)
				if not fired then callback_ok, callback_err = false, fire_err end
			end
			helpers.assert_eq(true, callback_ok,
				"a " .. outcome .. " demotion must remain inside the guarded timer callback: "
					.. tostring(callback_err))
			helpers.assert_eq(false, state.keylogger_enabled)
			helpers.assert_eq(1, recorder_calls)
			helpers.assert_eq(0, save_calls)
		end
	end)
end)

-- A config.toml holding a built-in delimiter state, a custom delimiter and its
-- state, and the state of a delimiter no build defines any more.
local DELIMITER_CONFIG = table.concat({
	"[hotstrings]",
	"terminators = [ { key = \"custom_at\", char = \"@\", label = \"at\", consume = false } ]",
	"",
	"[hotstrings.terminator_states]",
	"comma = false",
	"custom_at = false",
	"retired_pipe = true",
	"",
}, "\n")

helpers.describe("menu_state: saved delimiter states replay without ERROR (config-outdated-terminators)", function()
	helpers.it("applies built-in and custom states and only warns about a retired key", function()
		helpers.with_fresh_modules({ "logger.shim", "keymap.terminators", "config_outdated", "infra.preferences" },
			function()
				local errors, warnings = {}, {}
				local shim = helpers.make_logger_stub()
				shim.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
				shim.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
				package.loaded["logger.shim"] = shim
				local Terminators = require("keymap.terminators")
				local Preferences = helpers.load_with_stubs("infra.preferences")
				local saved = Preferences.flatten_document(require("toml_codec").decode(DELIMITER_CONFIG))
				helpers.assert_eq(saved.terminator_states, { comma = false, custom_at = false })

				local state = {
					hotstrings = {},
					custom_terminators = saved.custom_terminators,
					terminator_states = saved.terminator_states,
				}
				local committed = MenuState.sync_state_to_modules(state, saved, false, {
					keymap = {
						set_llm_model = function() return true end,
						get_terminator_defs = Terminators.get_terminator_defs,
						set_terminator_enabled = Terminators.set_terminator_enabled,
						validate_custom_terminator = Terminators.validate_custom_terminator,
						add_custom_terminator = Terminators.add_custom_terminator,
						remove_custom_terminator = Terminators.remove_custom_terminator,
					},
					core_mods = {}, hotstring_editor = {},
				})
				helpers.assert_eq(committed, true)
				helpers.assert_eq(errors, {}, "a saved delimiter state is never an ERROR")
				helpers.assert_eq(Terminators.is_terminator_enabled("comma"), false)
				helpers.assert_eq(Terminators.is_terminator_enabled("custom_at"), false)
				helpers.assert_eq(#warnings, 1, table.concat(warnings, " | "))
				helpers.assert_true(warnings[1]:find("'hotstrings.terminator_states.retired_pipe'", 1, true) ~= nil,
					warnings[1])
				local scan = require("config_unused_keys").find_in_source(DELIMITER_CONFIG,
					Preferences.mark_config_reads)
				helpers.assert_eq(#scan.keys, 1)
				helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key },
					{ "hotstrings.terminator_states", "retired_pipe" })
			end)
	end)
end)

package.loaded["infra.deferred_work"] = original_deferred_work
package.loaded["ui.menu.menu_state"] = original_subject
