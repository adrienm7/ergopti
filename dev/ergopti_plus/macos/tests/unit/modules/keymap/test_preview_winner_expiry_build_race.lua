--- tests/unit/modules/keymap/test_preview_winner_expiry_build_race.lua

--- ==============================================================================
--- MODULE: Preview Winner Expiry During Row Construction Regression
--- DESCRIPTION:
--- Reproduces a timed literal winner expiring after prospective resolution but
--- before tooltip rows are built. The bridge must re-resolve off the HID path
--- and paint the newly live fallback as the sole active promise.
--- ==============================================================================

local helpers = require("tests.helpers")

local FIRST_PREVIEW_TIME_SEC = 100
local EXPIRED_PREVIEW_TIME_SEC = 100.02
local LITERAL_LIFETIME_SEC = 0.01


--- Runs the scenario while restoring every process-global module mutation.
local function run_scenario()
	local dependency_names = {
		"adapters.synthetic_input",
		"adapters.timer_scheduler",
		"infra.manifest_reader",
		"modules.hotstrings.hotstrings_config",
		"modules.keymap.expander",
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
	local effects = { resolver_calls = 0, renders = 0, rows = nil }
	local action_epoch = {}
	local literal_mapping = {
		group = "default",
		section = "literal",
		has_magic = false,
		is_private = false,
	}
	local star_mapping = {
		group = "default",
		section = "star",
		has_magic = true,
		is_private = false,
		star_base = "old",
	}

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
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "a" end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["modules.keymap.expander"] = {
		resolve_magic_action = function(_buffer, literal_allowed)
			effects.resolver_calls = effects.resolver_calls + 1
			local literal_live, remaining = literal_allowed(literal_mapping)
			local star_action = {
				mapping = star_mapping,
				kind = "star",
				eff_plain = "STAR",
				eff_repl = "STAR",
				typed = "old",
			}
			if not literal_live then
				return { winner = star_action, candidates = { star_action } }
			end
			local literal_action = {
				mapping = literal_mapping,
				kind = "literal_auto",
				eff_plain = "LITERAL",
				eff_repl = "LITERAL",
				typed = "olda",
				remaining_delay = remaining,
			}
			return {
				winner = literal_action,
				candidates = { literal_action, star_action },
			}
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
		init = function() return true end,
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
		local hs_stub = _G.hs
		local clock_reads = 0
		hs_stub.timer.secondsSinceEpoch = function()
			clock_reads = clock_reads + 1
			if clock_reads == 1 then return FIRST_PREVIEW_TIME_SEC end
			return EXPIRED_PREVIEW_TIME_SEC
		end
		local state = {
			buffer = "old",
			mappings = {},
			groups = {},
			magic_key = "a",
			no_rescan_until = 0,
			last_key_time = FIRST_PREVIEW_TIME_SEC,
			COMPLEX_DELAY_MULT = 1,
			preview_providers = {},
			is_repeat_feature_enabled = function() return false end,
			mapping_delay_remaining = function(_mapping, elapsed)
				local remaining = LITERAL_LIFETIME_SEC - elapsed
				return remaining > 0, math.max(0, remaining)
			end,
		}
		Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
		Bridge.update_preview(state.buffer)

		local delivered = 0
		while delivered < #scheduled do
			delivered = delivered + 1
			scheduled[delivered].fn()
		end

		helpers.assert_true(effects.resolver_calls >= 2,
			"expiry before paint must trigger a fresh prospective resolution")
		helpers.assert_eq(effects.renders, 1,
			"only the post-expiry arbitration may reach the canvas")
		helpers.assert_eq(#(effects.rows or {}), 1,
			"the expired literal must not survive beside the live fallback")
		helpers.assert_eq(effects.rows[1].text, "STAR")
		helpers.assert_eq(effects.rows[1].dimmed, false,
			"the engine's newly live fallback must be the active visible promise")
	end, debug.traceback)

	for _, name in ipairs(dependency_names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("preview winner expiry during row construction", function()
	helpers.it("(preview-winner-expiry-build-race) re-resolves before painting a fallback", function()
		run_scenario()
	end)
end)

return true
