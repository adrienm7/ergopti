--- tests/unit/ai/engine/ollama/test_api_ollama_budget.lua

--- ==============================================================================
--- MODULE: Ollama Request Budget (Linux)
--- DESCRIPTION:
--- Windows judges a local request against [budgets] llm_local_request_ms
--- (ai/engine/prediction/request_latency.ahk) and macOS its Ollama answer
--- (ai/engine/api/ollama.lua); the Linux Ollama chat timed nothing, so a slow
--- local model never reached the log or tools/dev/field-log-analyse.py
--- (linux-llm-local-budget, timing parity campaign TIM-03). The transport and
--- the clock are controlled; the lines are the delivered log lines.
--- ==============================================================================

local helpers = require("tests.support.logger_fixture").helpers({
	"ai.engine.api.api_ollama", "core.network.adapters.http_client", "ai.engine.prediction.engine",
	"core.logger.engine.monotonic", "core.logger.engine.perf_budget",
})

--- Runs body(api, transport, clock, lines) with the real backend and logger.
--- @param budget_ms number The llm_local_request_ms the judge reads.
--- @param body function
local function isolated(budget_ms, body)
	package.loaded["core.logger.engine"] = nil
	package.loaded["core.logger.engine.shim"] = nil
	local logger = require("core.logger.engine")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(10)
	for _, name in ipairs({ "ai.engine.api.api_ollama", "ai.engine.prediction.engine",
		"core.logger.engine.perf_budget" }) do package.loaded[name] = nil end
	local transport, clock = {}, { now = 1000 }
	package.loaded["core.network.adapters.http_client"] = {
		postStream = function(_, _, _, _, chunk, done)
			transport.chunk, transport.done = chunk, done
			return true
		end,
		cancel = function() return true end,
	}
	package.loaded["core.logger.engine.monotonic"] = { now_ms = function() return clock.now end }
	local Timings = require("core.timing.engine.timings")
	local held_ms = Timings.ms
	Timings.ms = function(section, key)
		if section == "budgets" and key == "llm_local_request_ms" then return budget_ms end
		return held_ms(section, key)
	end
	local api = require("ai.engine.api.api_ollama")
	local ok, err = pcall(body, api, transport, clock, lines)
	api.cancel()
	Timings.ms = held_ms
	if not ok then error(err, 0) end
end

--- The delivered lines that contain a text.
local function matching(lines, text)
	local found = {}
	for _, line in ipairs(lines) do if line:find(text, 1, true) then found[#found + 1] = line end end
	return found
end

--- Starts one chat and returns its terminal records.
local function begin(api)
	local terminals = {}
	helpers.assert_true(api.chat("http://127.0.0.1:11434", "fixture-model", {}, { stream = true },
		function() end, function(text, err) terminals[#terminals + 1] = { text = text, error = err } end))
	return terminals
end

helpers.describe("Ollama request budget (linux-llm-local-budget)", function()
	helpers.it("(linux-llm-local-budget) a completed chat over its budget writes the shared overrun line", function()
		isolated(2000, function(api, transport, clock, lines)
			local terminals = begin(api)
			clock.now = 1000 + 2500
			transport.chunk('{"message":{"content":"done"},"done":true}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#terminals, 1)
			helpers.assert_eq(terminals[1].text, "done")
			helpers.assert_eq(#matching(lines, "Over budget: llm.local took 2500 ms (budget 2000 ms)."), 1)
		end)
	end)

	helpers.it("(linux-llm-local-budget) a chat within its budget or a refused one writes no overrun", function()
		isolated(2000, function(api, transport, clock, lines)
			begin(api)
			clock.now = 1000 + 1500
			transport.chunk('{"message":{"content":"done"},"done":true}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#matching(lines, "Ollama completion received (4 chars in 1500 ms)."), 1)
			helpers.assert_eq(#matching(lines, "Over budget"), 0)
		end)
		isolated(2000, function(api, transport, clock, lines)
			local terminals = begin(api)
			clock.now = 1000 + 9000
			transport.chunk('{"message":{"content":"partial"},"done":false}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_true(type(terminals[1].error) == "string")
			helpers.assert_eq(#matching(lines, "Over budget"), 0)
		end)
	end)
end)
