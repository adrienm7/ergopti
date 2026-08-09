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

helpers.describe("pause_all: every backend's warmup is parked", function()
	helpers.it("stops the Ollama warmup as well as the MLX one", function()
		local src = helpers.read_driver_source("local function pause_all")
		helpers.assert_true(src ~= nil and src ~= "", "script_control must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("local function pause_all", 1, true)
		helpers.assert_true(at ~= nil, "pause_all must exist")

		local resume_at = code:find("\nlocal function resume_all", at, true)
		helpers.assert_true(resume_at ~= nil,
			"pause_all must be bounded by the sibling resume_all declaration")
		local body = code:sub(at, resume_at and (resume_at - 1) or #code)

		helpers.assert_true(body:find("modules.llm.api_mlx", 1, true) ~= nil,
			"the MLX warmup must still be stopped")
		helpers.assert_true(body:find("modules.llm.api_ollama", 1, true) ~= nil,
			"Ollama's warmup must be stopped too. Its stop_warmup already existed — added for "
				.. "the disable path — and was simply never wired here, so an in-flight POST kept "
				.. "its callbacks live across the pause and could announce 'server ready' while "
				.. "the script was supposed to be entirely off")

		local stops = 0
		for _ in body:gmatch("stop_warmup") do stops = stops + 1 end
		helpers.assert_true(stops >= 2,
			"both backends must actually have stop_warmup called (found " .. stops
				.. " reference(s)) — requiring the module without calling it parks nothing")
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
--- @return table llm, table warmups
local function load_llm(paused)
	local warmups = {}

	-- Installed BEFORE modules.llm loads: it captures its backend modules as
	-- upvalues at require time, so a stub installed afterwards is never seen.
	for _, name in ipairs({ "modules.llm.api_ollama", "modules.llm.api_mlx", "modules.llm.api_remote" }) do
		package.loaded[name] = setmetatable({
			warmup      = function(model, _profile) warmups[#warmups + 1] = tostring(model) end,
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

		LLM.warmup_model("some-model", { id = "default" })

		helpers.assert_eq(#warmups, 0,
			"no warmup may reach the backend while paused. Switching profile or model from the "
				.. "menu funnels through here, and neither backend flag catches it: api_mlx's "
				.. "_warmup_stopped only short-circuits its retry chain, and Ollama has no such "
				.. "flag by design")

		unload_stubs()
	end)

	helpers.it("still dispatches when not paused", function()
		local LLM, warmups = load_llm(false)

		LLM.warmup_model("some-model", { id = "default" })

		helpers.assert_eq(#warmups, 1,
			"with the script running the warmup must go out — a guard that never opens is not a "
				.. "fix, it is the feature removed")
		helpers.assert_eq(warmups[1], "some-model", "and it must carry the requested model")

		unload_stubs()
	end)
end)
