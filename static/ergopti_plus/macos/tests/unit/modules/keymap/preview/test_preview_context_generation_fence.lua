--- tests/unit/modules/keymap/preview/test_preview_context_generation_fence.lua

--- ==============================================================================
--- MODULE: Preview callbacks reject a stale AI context
--- DESCRIPTION:
--- Exercises build, render, and visible-row expiry callbacks after the AI
--- context changes while the bounded hotstring suffix remains identical.
--- ==============================================================================

local helpers = require("tests.helpers")

local FIRST_PREVIEW_TIME_SEC = 100
local EXPIRED_PREVIEW_TIME_SEC = 100.02
local LITERAL_LIFETIME_SEC = 0.01


--- Runs the scenario while restoring every process-global module mutation.
local function run_scenario(mode)
	local dependency_names = {
		"platform.input.synthetic_input",
		"core.events.timer_scheduler",
		"infra.manifest_reader",
		"modules.hotstrings.hotstrings_config",
		"modules.keymap.expander",
		"modules.keymap.utils",
		"modules.keystats",
		"modules.llm",
		"modules.llm.prediction_engine",
		"core.ui.ui.tooltip",
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

	package.loaded["platform.input.synthetic_input"] = {
		current_action_epoch = function() return action_epoch end,
	}
	package.loaded["core.events.timer_scheduler"] = {
		hotstring_time = function() return _G.hs.timer.secondsSinceEpoch() end,
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
	package.loaded["modules.keystats"] = {
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
	package.loaded["core.ui.ui.tooltip"] = {
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
			if mode == "build" and clock_reads > 1 then return EXPIRED_PREVIEW_TIME_SEC end
			if mode == "render" and clock_reads > 2 then return EXPIRED_PREVIEW_TIME_SEC end
			return FIRST_PREVIEW_TIME_SEC
		end
		local state = {
			buffer = string.rep("x", 500),
			llm_context_generation = 1,
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
		require("modules.keymap.llm_context").seed(state, state.buffer or "", "")
		Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
		Bridge.update_preview(state.buffer)

		local function deliver()
			local delivered = 0
			while delivered < #scheduled do
				delivered = delivered + 1
				scheduled[delivered].fn()
			end
		end
		if mode == "expire" then
			deliver()
			local row = assert(effects.rows and effects.rows[1], "expected a visible timed winner")
			local on_expire = assert(row.on_expire, "timed winner must have an expiry callback")
			local before = effects.resolver_calls
			state.llm_context_generation = state.llm_context_generation + 1
			on_expire()
			helpers.assert_eq(effects.resolver_calls, before, "stale expiry must not re-resolve the unchanged suffix")
		else
			local before = effects.resolver_calls
			state.llm_context_generation = state.llm_context_generation + 1
			deliver()
			helpers.assert_eq(effects.resolver_calls, before, "stale deferred callback must not re-resolve the unchanged suffix")
			helpers.assert_eq(effects.renders, 0, "stale deferred callback must not paint the prior context")
		end

	end, debug.traceback)

	for _, name in ipairs(dependency_names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("preview callbacks and AI context generation", function()
	for _, mode in ipairs({ "build", "render", "expire" }) do
		helpers.it("rejects stale " .. mode .. " callback with unchanged 500-character suffix", function()
			run_scenario(mode)
		end)
	end
end)

return true
