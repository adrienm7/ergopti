--- tests/unit/metrics/engine/synthetic/test_trigger_roi.lua

--- The portable trigger metrics corpus runs under the macOS Lua ABI.
local helpers = require("tests.helpers")
local corpus = assert(loadfile(helpers.shared("tests/corpus/keystats/trigger_roi.lua")))()
corpus(helpers)
