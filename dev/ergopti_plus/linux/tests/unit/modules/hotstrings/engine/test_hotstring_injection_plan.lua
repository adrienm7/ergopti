--- tests/unit/modules/hotstrings/engine/test_hotstring_injection_plan.lua

--- ==============================================================================
--- MODULE: Shared Hotstring Injection Plan
--- DESCRIPTION:
--- Replays the shared injection-plan vectors against this driver.
--- ==============================================================================

local helpers = require("tests.helpers")

local file = assert(io.open(require("infra.paths").shared("tests/corpus/hotstrings/injection_plan_vectors.json"), "rb"))
local corpus = assert(require("json").decode_lossless(file:read("*a")))
file:close()
require("test.hotstring_injection_plan_contract")(helpers, corpus, 18)
