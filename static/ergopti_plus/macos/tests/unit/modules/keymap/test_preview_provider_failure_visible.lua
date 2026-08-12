--- tests/unit/modules/keymap/test_preview_provider_failure_visible.lua

--- ==============================================================================
--- MODULE: Preview Provider Failure Visibility Regression
--- DESCRIPTION:
--- Drives a throwing custom preview provider through the real bridge. Its
--- failure must be reported once outside the HID callback while the static
--- prospective resolver continues to paint the action it would execute.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Runs the provider-failure scenario with isolated process-global modules.
local function run_scenario()
	local dependency_names = {
		"adapters.synthetic_input",
		"adapters.timer_scheduler",
		"infra.logger",
		"infra.manifest_reader",
		"modules.hotstrings.hotstrings_config",
		"modules.keymap.expander",
		"modules.keymap.registry",
		"modules.keymap.registry_groups",
		"modules.keymap.registry_index",
		"modules.keymap.utils",
		"modules.keylogger",
		"modules.llm",
		"modules.llm.prediction_engine",
		"ui.tooltip",
		"modules.keymap.llm_bridge",
	}
	local previous = {}
	for _, name in ipairs(dependency_names) do previous[name] = package.loaded[name] end

	local scheduled = {}
	local effects = { errors = {}, provider_calls = 0, renders = 0, rows = nil }
	local action_epoch = {}
	local star_mapping = {
		group = "default",
		section = "star",
		has_magic = true,
		is_private = false,
		star_base = "abc",
	}
	local Logger = helpers.make_logger_stub()
	Logger.error = function(_log, format_string, ...)
		effects.errors[#effects.errors + 1] = string.format(format_string, ...)
	end

	package.loaded["adapters.synthetic_input"] = {
		current_action_epoch = function() return action_epoch end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, fn)
			local handle = { delay = delay, fn = fn }
			scheduled[#scheduled + 1] = handle
			return handle, true
		end,
	}
	package.loaded["infra.logger"] = Logger
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "★" end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["modules.keymap.expander"] = {
		resolve_magic_action = function()
			local star_action = {
				mapping = star_mapping,
				kind = "star",
				eff_plain = "STATIC",
				eff_repl = "STATIC",
				typed = "abc",
			}
			return { winner = star_action, candidates = { star_action } }
		end,
	}
	package.loaded["modules.keymap.utils"] = {
		tokens_from_repl = function(value) return value end,
		plain_text = function(value) return value end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
	}
	package.loaded["modules.llm.prediction_engine"] = {
		set_runtime_guard = function() end,
		init = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		tint = function() return {} end,
		show_stacked = function(rows)
			effects.renders = effects.renders + 1
			effects.rows = rows
			return true
		end,
	}

	local ok, err = xpcall(function()
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local state = {
			buffer = "abc",
			mappings = {},
			groups = {},
			magic_key = "★",
			no_rescan_until = 0,
			preview_providers = {
				function()
					effects.provider_calls = effects.provider_calls + 1
					error("simulated provider crash", 0)
				end,
			},
			is_repeat_feature_enabled = function() return false end,
		}
		Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })

		local delivered = 0
		--- Drains every callback appended to the deterministic scheduler queue.
		local function drain_scheduled()
			while delivered < #scheduled do
				delivered = delivered + 1
				scheduled[delivered].fn()
			end
		end

		Bridge.update_preview(state.buffer)
		helpers.assert_eq(#effects.errors, 0,
			"provider diagnostics must not perform file logging in the HID callback")
		drain_scheduled()
		helpers.assert_eq(effects.renders, 1,
			"the throwing provider must not suppress the static fallback")
		helpers.assert_eq(#(effects.rows or {}), 1)
		helpers.assert_eq(effects.rows[1].text, "STATIC")
		helpers.assert_eq(effects.rows[1].dimmed, false)
		helpers.assert_eq(#effects.errors, 1,
			"the first provider failure must become one deferred ERROR")
		helpers.assert_true(effects.errors[1]:find("Preview provider #1 raised", 1, true) ~= nil)
		helpers.assert_true(effects.errors[1]:find("simulated provider crash", 1, true) ~= nil)

		Bridge.update_preview(state.buffer)
		drain_scheduled()
		helpers.assert_eq(effects.provider_calls, 2,
			"the diagnostic latch must not quarantine a provider that can recover later")
		helpers.assert_eq(effects.renders, 2,
			"the fallback must remain available after repeated provider failures")
		helpers.assert_eq(#effects.errors, 1,
			"one broken provider must not flood the log on every keystroke")
	end, debug.traceback)

	for _, name in ipairs(dependency_names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("preview provider failure visibility", function()
	helpers.it("(preview-provider-error-once) logs off-HID and preserves static fallback", function()
		run_scenario()
	end)
end)

return true
