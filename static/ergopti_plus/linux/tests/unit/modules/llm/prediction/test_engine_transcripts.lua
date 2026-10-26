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

return true
