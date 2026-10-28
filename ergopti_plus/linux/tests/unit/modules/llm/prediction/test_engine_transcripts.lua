--- tests/unit/modules/llm/prediction/test_engine_transcripts.lua

--- ==============================================================================
--- MODULE: Shared Engine Transcripts (Linux)
--- DESCRIPTION:
--- Runs the real Linux prediction engine on recording fakes of its timer, HTTP
--- and tooltip ports and compares the port calls with the shared corpus
--- request_plan_engine_transcripts.json, which the macOS engine replays too.
--- ==============================================================================

local helpers = require("tests.helpers")
local Transcript = require("test.llm_engine_transcript")
local World = require("tests.support.llm_engine_transcript_world")

Transcript.run(helpers,
	helpers.driver_root() .. "/../_shared/tests/corpus/llm/request_plan_engine_transcripts.json",
	World.with_world)

local CONFIG = { debounce_ms = 400, count = 1, profile = "basic", watch_timers_ms = { 400 } }

helpers.describe("the engine checks its three ports at init", function()
	helpers.it("refuses an incomplete scheduler, HTTP client or overlay, naming the missing method", function()
		World.with_world(CONFIG, function(world)
			for options, expected in pairs({
				[{ scheduler = { after = function() end } }] = "TimerScheduler lacks: cancel",
				[{ http_client = { post = function() end } }] = "HttpClient lacks: cancel",
				[{ overlay = { show = function() end } }] = "TooltipRenderer lacks: hide",
			}) do
				local ok, err = pcall(world.engine.init, options)
				helpers.assert_eq(ok, false, "init must raise for " .. expected)
				helpers.assert_contains(tostring(err), expected)
			end
		end)
	end)
end)

return true
