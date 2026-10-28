--- tests/unit/modules/llm/features/test_engine_transcripts.lua

--- ==============================================================================
--- MODULE: Shared Engine Transcripts (macOS)
--- DESCRIPTION:
--- Runs the real macOS prediction engine on recording fakes of its timer, HTTP
--- and tooltip ports and compares the port calls with the shared corpus
--- request_plan_engine_transcripts.json, which the Linux engine replays too.
--- ==============================================================================

local helpers = require("tests.helpers")
local Transcript = require("test.llm_engine_transcript")
local World = require("tests.support.modules.llm.engine_transcript_world")

Transcript.run(helpers, helpers.shared("tests/corpus/llm/request_plan_engine_transcripts.json"), World.with_world)

local CONFIG = { debounce_ms = 400, count = 1, profile = "basic", watch_timers_ms = { 400 } }

helpers.describe("the engine checks its ports at init", function()
	helpers.it("refuses an incomplete scheduler or HTTP client, naming the missing method", function()
		World.with_world(CONFIG, function()
			for ports, expected in pairs({
				[{ TimerScheduler = { after = function() end } }] = "TimerScheduler lacks: cancel",
				[{ HttpClient = { post = function() end } }] = "HttpClient lacks: cancel",
			}) do
				package.loaded["modules.llm.prediction_engine"] = nil
				local fresh = require("modules.llm.prediction_engine")
				local ok, err = pcall(fresh.init, { buffer = "", mappings = {} }, ports)
				helpers.assert_eq(ok, false, "init must raise for " .. expected)
				helpers.assert_contains(tostring(err), expected)
			end
		end)
	end)
end)

return true
