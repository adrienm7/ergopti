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

return true
