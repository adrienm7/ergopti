--- tests/unit/modules/hotstrings/test_bulk_scope.lua

--- ==============================================================================
--- MODULE: Hotstring Category Selection Parity (Linux)
--- DESCRIPTION:
--- Replays the shared selection corpus through the policy the canonical
--- choice owner uses before publishing any category or section changes.
--- ==============================================================================

local helpers = require("tests.helpers")
local planner = helpers.load_module("hotstrings.bulk_scope")
local Paths = helpers.load_module("infra.paths")
local Json = require("json")
local path = Paths.shared("tests/corpus/hotstrings/bulk_scope_vectors.json")
local file = assert(io.open(path, "r"))
local content = assert(file:read("*a"))
assert(file:close())
local corpus = assert(Json.decode(content))

require("test.hotstring_bulk_scope_contract").run(helpers, planner, corpus)

local admission_file = assert(io.open(path:gsub("bulk_scope_vectors.json$", "personal_scope_admission.json"), "r"))
local admission_content = assert(admission_file:read("*a"))
assert(admission_file:close())
require("test.personal_scope_contract").run(helpers, require("hotstrings.personal_scope"), assert(Json.decode(admission_content)))
