--- tests/unit/hotstrings/engine/expander/expansion/test_injection_plan.lua

--- ==============================================================================
--- MODULE: Shared Hotstring Injection Plan
--- DESCRIPTION:
--- Replays the shared injection-plan vectors against this driver.
--- ==============================================================================

local helpers = require("tests.helpers")

local file = assert(io.open(require("core.fs.engine.paths").shared("tests/corpus/hotstrings/injection_plan_vectors.json"), "rb"))
local corpus = assert(require("core.text.engine.json").decode_lossless(file:read("*a")))
file:close()
require("tests.lua.hotstrings.injection_plan_contract")(helpers, corpus, 18)
