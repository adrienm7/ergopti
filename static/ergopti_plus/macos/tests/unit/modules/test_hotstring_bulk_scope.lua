--- tests/unit/modules/test_hotstring_bulk_scope.lua

--- ==============================================================================
--- MODULE: Hotstring Category Selection Parity (macOS)
--- DESCRIPTION:
--- Replays the shared selection corpus through the policy this driver's
--- registry uses for its explicit category enable/disable commands.
--- ==============================================================================

local helpers = require("tests.helpers")
local planner = helpers.load_with_stubs("hotstrings.bulk_scope")
local Json = require("adapters.json_codec")
local path = helpers.shared("tests/corpus/hotstrings/bulk_scope_vectors.json")
local file = assert(io.open(path, "r"))
local content = assert(file:read("*a"))
assert(file:close())
local corpus = assert(Json.decode(content))

require("test.hotstring_bulk_scope_contract").run(helpers, planner, corpus)
