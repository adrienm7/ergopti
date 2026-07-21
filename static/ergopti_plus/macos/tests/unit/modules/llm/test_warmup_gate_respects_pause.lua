--- tests/unit/modules/llm/test_warmup_gate_respects_pause.lua

--- ==============================================================================
--- MODULE: Regression — warmup must stop on BOTH backends and stay parked in pause
--- DESCRIPTION:
--- Two halves of the same invariant (« pause = tout éteint », and "AI off means no
--- POSTs"), each applied to one side only.
---
--- ROOT CAUSE 1 — only MLX's warmup was stopped.
--- set_llm_enabled(false) called api_mlx.stop_warmup() and returned. An Ollama
--- warmup POST triggers the actual model load and can stay in flight for tens of
--- seconds, so its response landed AFTER the gate closed, flipped _is_ready back
--- to true and fired the user-facing "server ready" notification while AI was
--- switched off. api_ollama had no invalidation entry point at all.
---
--- ROOT CAUSE 2 — re-enabling AI mid-pause revived the warmup loop.
--- set_llm_enabled(true) unconditionally cleared api_mlx's _warmup_stopped flag and
--- re-armed the controller. That flag is owned by script_control.pause_all(), and
--- resume_all() clears it and re-arms both drivers itself — so toggling AI on from
--- the menu during a pause restarted the 2 s POST loop and fired "server ready"
--- while the driver was suspended, which is precisely the violation the disable
--- side of this same function exists to prevent.
---
--- The tests drive the real set_llm_enabled with recording backend doubles, so they
--- observe the calls that actually reach the network layer.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ Backend And Pause Doubles =========
-- ==============================================
-- ==============================================

--- Loads the prediction engine with recording MLX/Ollama doubles and a
--- script_control double reporting `paused`.
--- @param paused boolean What script_control.is_paused() reports.
--- @return table engine, table calls
local function load_engine(paused)
	local calls = { mlx_stop = 0, ollama_stop = 0, mlx_resume = 0, scheduled = 0 }

	package.loaded["modules.llm.api_mlx"] = {
		stop_warmup   = function() calls.mlx_stop   = calls.mlx_stop   + 1 end,
		resume_warmup = function() calls.mlx_resume = calls.mlx_resume + 1 end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		stop_warmup = function() calls.ollama_stop = calls.ollama_stop + 1 end,
	}
	package.loaded["modules.llm.warmup_controller"] = {
		stop = function() end,
		schedule_warmup_with_retry = function() calls.scheduled = calls.scheduled + 1 end,
	}
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return paused end,
	}

	package.loaded["modules.llm.prediction_engine"] = nil
	return helpers.load_with_stubs("modules.llm.prediction_engine"), calls
end




-- ==============================================
-- ==============================================
-- ======= 2/ Both Backends, Both States ========
-- ==============================================
-- ==============================================

helpers.describe("disabling AI stops warmup on every backend", function()
	helpers.it("stops the Ollama warmup as well as the MLX one", function()
		local Engine, calls = load_engine(false)

		Engine.set_llm_enabled(false)

		helpers.assert_true(calls.mlx_stop >= 1, "the MLX warmup must still be stopped")
		helpers.assert_true(calls.ollama_stop >= 1,
			"the Ollama warmup must be stopped too — its POST triggers the model load and "
			.. "can stay in flight for tens of seconds, so the response lands after the gate "
			.. "closed and fires the 'server ready' notification while AI is off")
	end)
end)

helpers.describe("enabling AI does not revive warmup during a pause", function()
	helpers.it("parks the warmup when the script is paused", function()
		local Engine, calls = load_engine(true)

		Engine.set_llm_enabled(true)

		helpers.assert_eq(calls.mlx_resume, 0,
			"set_llm_enabled(true) must not clear _warmup_stopped mid-pause: that flag is "
			.. "owned by pause_all(), and resume_all() clears it and re-arms both drivers "
			.. "itself. Reviving it here restarts the 2s POST loop while suspended")
		helpers.assert_eq(calls.scheduled, 0,
			"nor may it re-arm the warmup controller while paused")
	end)

	helpers.it("still arms the warmup normally when NOT paused", function()
		-- The opposite failure: a guard that always parked would mean AI never warms
		-- up from the menu toggle at all.
		local Engine, calls = load_engine(false)

		Engine.set_llm_enabled(true)

		helpers.assert_true(calls.mlx_resume >= 1,
			"outside a pause, enabling AI must still clear the stop flag")
		helpers.assert_true(calls.scheduled >= 1,
			"outside a pause, enabling AI must still schedule the warmup")
	end)
end)
