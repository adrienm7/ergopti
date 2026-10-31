--- tests/unit/modules/llm/ollama/test_ollama_ensure_running_not_at_require.lua

--- ==============================================================================
--- MODULE: Regression — Ollama ensure_running not triggered at require-time
--- DESCRIPTION:
--- Guards against the bug where api_ollama.lua scheduled ensure_ollama_running()
--- via TimerScheduler.after(0, ...) at module require-time. This pkill'd and
--- relaunched Ollama on every boot/reload regardless of the active backend —
--- MLX and API users had Ollama killed and relaunched on every HS reload.
---
--- Fix (2026-06-19): removed the require-time scheduler. Exposed M.ensure_running()
--- which is called by llm/init.lua only when the effective backend is "ollama".
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ No require-time Ollama launch ================================
-- =========================================================================
-- =========================================================================

helpers.describe("api_ollama: no require-time Ollama start", function()
	helpers.it("requiring api_ollama schedules no timer, so it cannot start Ollama at boot", function()
		-- The old bug ran TimerScheduler.after(0, ensure_ollama_running) at
		-- module level. Every scheduling call api_ollama's own code makes while
		-- the module loads is recorded; dependencies it requires (the keystats
		-- watchers) keep the real adapter, and so does reading the clock.
		local Real = require("adapters.timer_scheduler")
		local scheduled = {}
		-- The file the loader itself resolves for the module, never a typed path.
		local own_source = "@" .. assert(package.searchpath("modules.llm.api_ollama", package.path))
		local function own_call() return debug.getinfo(3, "S").source == own_source end
		local recorder = setmetatable({
			after = function(delay, ...)
				if not own_call() then return Real.after(delay, ...) end
				scheduled[#scheduled + 1] = "after(" .. tostring(delay) .. ")"
			end,
			every = function(interval, ...)
				if not own_call() then return Real.every(interval, ...) end
				scheduled[#scheduled + 1] = "every(" .. tostring(interval) .. ")"
			end,
		}, { __index = Real })
		local saved = package.loaded["adapters.timer_scheduler"]
		package.loaded["adapters.timer_scheduler"] = recorder
		local ok, loaded = pcall(helpers.load_with_stubs, "modules.llm.api_ollama")
		package.loaded["adapters.timer_scheduler"] = saved
		helpers.assert_true(ok, tostring(loaded))
		helpers.assert_eq(0, #scheduled,
			"api_ollama must not schedule anything at require-time: " .. table.concat(scheduled, ", "))
	end)

	helpers.it("api_ollama exposes M.ensure_running() for explicit invocation", function()
		local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")
		helpers.assert_true(
			type(ApiOllama.ensure_running) == "function",
			"ApiOllama must export ensure_running() for llm/init.lua to call explicitly"
		)
	end)

	-- Who calls ensure_running() is behaviour-tested where it is decided: the
	-- backend start gate tests (test_backend_ollama_start_gate) drive llm/init's
	-- set_backend and auto-detection and prove an MLX or API identity never
	-- starts Ollama while an admitted Ollama one starts it once.
end)
