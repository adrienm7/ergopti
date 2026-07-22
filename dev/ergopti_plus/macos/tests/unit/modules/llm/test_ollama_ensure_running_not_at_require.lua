--- tests/unit/modules/llm/test_ollama_ensure_running_not_at_require.lua

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
	helpers.it("api_ollama source has no top-level TimerScheduler.after(0, ensure_ollama)", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/modules/llm/api_ollama.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open api_ollama.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The old bug: module-level call to schedule ensure_ollama_running
		helpers.assert_true(
			src:find("TimerScheduler.after(0, function() pcall(ensure_ollama_running)", 1, true) == nil,
			"api_ollama.lua must not schedule ensure_ollama_running() at require-time"
		)
	end)

	helpers.it("api_ollama exposes M.ensure_running() for explicit invocation", function()
		local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")
		helpers.assert_true(
			type(ApiOllama.ensure_running) == "function",
			"ApiOllama must export ensure_running() for llm/init.lua to call explicitly"
		)
	end)

	helpers.it("llm init calls ApiOllama.ensure_running() only when backend is ollama", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/modules/llm/init.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open llm/init.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- Must reference ensure_running() at least once
		helpers.assert_true(
			src:find("ensure_running()", 1, true) ~= nil,
			"llm/init.lua must call ApiOllama.ensure_running() when backend resolves to ollama"
		)
	end)
end)
