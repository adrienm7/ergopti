--- tests/unit/modules/llm/test_warmup_parked_during_pause.lua

--- ==============================================================================
--- MODULE: Regression — no backend may warm up during a pause
---         (warmup-parked-during-pause)
--- DESCRIPTION:
--- « pause = tout éteint » leaked on the LLM warmup path, twice.
---
--- ROOT CAUSE ENCODED:
---   1. pause_all() stopped the MLX warmup but never Ollama's, even though
---      api_ollama.stop_warmup already existed — it had been added for the
---      DISABLE path and never wired to the pause one. An in-flight warmup POST
---      kept its callbacks live across the pause and could flip readiness or
---      fire the user-facing "server ready" notification mid-pause.
---   2. A warmup the USER starts — switching profile or model from the menu
---      while paused — funnels through warmup_model, which had no pause guard.
---      api_mlx's _warmup_stopped flag only short-circuits its self-rescheduling
---      RETRY chain, so a freshly dispatched warmup sailed straight past it, and
---      Ollama has no such flag at all by design.
---
--- WHY IT WAS SILENT: a warmup produces no visible output unless it succeeds,
--- and then it announces itself — "serveur prêt" arriving while the user
--- believes everything is off is the first sign anything ran.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ Pause stops BOTH backends' warmups ==================
-- ================================================================
-- ================================================================

local SCRIPT_CONTROL_FIXTURE_MODULES = {
	"modules.shortcuts.script_control",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.keycodes",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"adapters.key_state",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"modules.llm.api_mlx",
	"modules.llm.warmup_controller",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"modules.keylogger",
}

local function exercise_committed_backend_pause()
	return helpers.with_fresh_modules(SCRIPT_CONTROL_FIXTURE_MODULES, function()
		local calls = {}
		local function count(name)
			return function()
				calls[name] = (calls[name] or 0) + 1
				return true
			end
		end
		local function backend_pause_calls()
			return (calls.mlx_pause or 0) + (calls.mlx_stop_fallback or 0)
				+ (calls.ollama_pause or 0) + (calls.ollama_stop_fallback or 0)
		end

		local idle_callback = nil
		local admission_fence = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.keycodes"] = {
			F13_KARABINER_RETURN = 106,
			F14_KARABINER_BACKSPACE = 107,
			F15_KARABINER_ESCAPE = 108,
			BACKSPACE = 51,
			RETURN = 36,
			ESCAPE = 53,
		}
		package.loaded["adapters.event_provenance"] = {}
		package.loaded["adapters.key_state"] = {
			is_right_altgr_held = function() return false end,
			describe_held_modifiers = function() return "(none)" end,
		}
		package.loaded["adapters.synthetic_input"] = {
			when_idle = function(callback)
				idle_callback = callback
				return true
			end,
			acquire_admission_fence = function()
				if admission_fence ~= nil then return nil end
				admission_fence = { active = true }
				return admission_fence
			end,
			release_admission_fence = function(token)
				if token ~= admission_fence or token.active ~= true then return false end
				token.active = false
				admission_fence = nil
				return true
			end,
			admission_open = function() return admission_fence == nil end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			every = function() return { timer = nil }, true end,
			cancel = function() return true end,
		}
		package.loaded["modules.gestures.engine"] = {}
		package.loaded["modules.gestures.actions"] = {
			get_label = function(name) return name end,
			execute_single = function() return true end,
			SG_NAMES = { "none", "script_pause_toggle" },
			AX_NAMES = {},
		}
		package.loaded["modules.llm.api_mlx"] = {
			pause_warmup = count("mlx_pause"),
			stop_warmup = count("mlx_stop_fallback"),
			resume_warmup = count("mlx_resume"),
		}
		package.loaded["modules.llm.api_ollama"] = {
			pause_warmup = count("ollama_pause"),
			stop_warmup = count("ollama_stop_fallback"),
			resume_warmup = count("ollama_resume"),
		}
		package.loaded["modules.llm.warmup_controller"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.api_remote"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["ui.wpm.wpm_menubar"] = {
			is_running = function() return false end,
			stop = function() return true end,
			resume_after_pause = function() return true end,
		}
		package.loaded["ui.wpm.wpm_widget"] = {
			is_running = function() return false end,
			stop = function() return true end,
			resume_after_pause = function() return true end,
		}
		package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
		package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
		package.loaded["modules.keylogger"] = { resync_context = function() return true end }

		local ScriptControl = helpers.load_with_stubs("modules.shortcuts.script_control")
		local pause_accepted = ScriptControl.pause_all()
		local calls_before_drain = backend_pause_calls()
		local pending_before_drain = ScriptControl.is_pause_transition_pending()
		local paused_before_drain = ScriptControl.is_paused()
		if idle_callback then idle_callback() end
		local paused_after_drain = ScriptControl.is_paused()
		local resume_accepted = ScriptControl.resume_all()
		local paused_after_resume = ScriptControl.is_paused()
		local fence_released = admission_fence == nil
		ScriptControl.stop()

		return {
			calls = calls,
			pause_accepted = pause_accepted,
			calls_before_drain = calls_before_drain,
			pending_before_drain = pending_before_drain,
			paused_before_drain = paused_before_drain,
			paused_after_drain = paused_after_drain,
			resume_accepted = resume_accepted,
			paused_after_resume = paused_after_resume,
			fence_released = fence_released,
		}
	end)
end

helpers.describe("pause_all: every backend's warmup is parked", function()
	helpers.it("stops the Ollama warmup as well as the MLX one", function()
		local result = exercise_committed_backend_pause()
		helpers.assert_true(result.pause_accepted)
		helpers.assert_true(result.pending_before_drain)
		helpers.assert_eq(result.paused_before_drain, false)
		helpers.assert_eq(result.calls_before_drain, 0,
			"neither backend owner may run before the exact SyntheticInput drain")
		helpers.assert_true(result.paused_after_drain,
			"delivering the drain must commit PAUSED before the assertion is meaningful")
		helpers.assert_eq(result.calls.mlx_pause, 1,
			"the exact MLX warmup owner must be parked once")
		helpers.assert_eq(result.calls.ollama_pause, 1,
			"the exact Ollama warmup owner must be parked once")
		helpers.assert_eq(result.calls.mlx_stop_fallback, nil,
			"the MLX fallback must not run when pause_warmup is available")
		helpers.assert_eq(result.calls.ollama_stop_fallback, nil,
			"the Ollama fallback must not run when pause_warmup is available")
		helpers.assert_true(result.resume_accepted)
		helpers.assert_eq(result.paused_after_resume, false)
		helpers.assert_eq(result.calls.mlx_resume, 1)
		helpers.assert_eq(result.calls.ollama_resume, 1)
		helpers.assert_true(result.fence_released)
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ A user-initiated warmup is refused too ==============
-- ================================================================
-- ================================================================

--- Loads modules.llm with a controllable pause state and a recording backend, so
--- the test can observe whether a warmup actually reached the backend.
--- @param paused boolean
--- @param warmup_mode string|nil Optional false/nil/throw backend result.
--- @return table llm, table warmups
local function load_llm(paused, warmup_mode)
	local warmups = {}

	-- Installed BEFORE modules.llm loads: it captures its backend modules as
	-- upvalues at require time, so a stub installed afterwards is never seen.
	for _, name in ipairs({ "modules.llm.api_ollama", "modules.llm.api_mlx", "modules.llm.api_remote" }) do
		package.loaded[name] = setmetatable({
			warmup      = function(model, _profile)
				warmups[#warmups + 1] = tostring(model)
				if warmup_mode == "throw" then error("synthetic warmup throw") end
				if warmup_mode == "false" then return false end
				if warmup_mode == "nil" then return nil end
				return true
			end,
			stop_warmup = function() end,
			reset_ready = function() end,
		}, { __index = function() return function() end end })
	end

	local LLM = helpers.load_with_stubs("modules.llm")

	-- The pause owner is read through package.loaded, so installing a stand-in
	-- there is exactly how the production lookup sees it.
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return paused end,
	}

	return LLM, warmups
end

--- Clears the stubs so later test files see the real modules.
local function unload_stubs()
	for _, name in ipairs({
		"modules.llm.api_ollama", "modules.llm.api_mlx", "modules.llm.api_remote",
		"modules.shortcuts.script_control", "modules.llm",
	}) do
		package.loaded[name] = nil
	end
end

helpers.describe("warmup_model: refuses to dispatch while paused", function()
	helpers.it("does not reach the backend during a pause", function()
		local LLM, warmups = load_llm(true)
		helpers.assert_eq(type(LLM.warmup_model), "function", "warmup_model must exist")

		helpers.assert_eq(LLM.warmup_model("some-model", { id = "default" }), true)

		helpers.assert_eq(#warmups, 0,
			"no warmup may reach the backend while paused. Switching profile or model from the "
				.. "menu funnels through here, and neither backend flag catches it: api_mlx's "
				.. "_warmup_stopped only short-circuits its retry chain, and Ollama has no such "
				.. "flag by design")

		unload_stubs()
	end)

	helpers.it("still dispatches when not paused", function()
		local LLM, warmups = load_llm(false)

		helpers.assert_eq(LLM.warmup_model("some-model", { id = "default" }), true)

		helpers.assert_eq(#warmups, 1,
			"with the script running the warmup must go out — a guard that never opens is not a "
				.. "fix, it is the feature removed")
		helpers.assert_eq(warmups[1], "some-model", "and it must carry the requested model")

		unload_stubs()
	end)

	helpers.it("propagates every backend warmup acquisition refusal", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local LLM, warmups = load_llm(false, mode)
			helpers.assert_eq(LLM.warmup_model("some-model", { id = "default" }), false)
			helpers.assert_eq(#warmups, 1)
			unload_stubs()
		end
	end)
end)
