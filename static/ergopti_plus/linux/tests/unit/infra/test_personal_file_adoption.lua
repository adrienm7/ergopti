--- tests/unit/infra/test_personal_file_adoption.lua

--- ==============================================================================
--- MODULE: Additional Personal File Adoption Parity
--- DESCRIPTION:
--- Replays the independent shared identity/default policy on this native driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local path = helpers.load_module("infra.paths").shared("tests/corpus/hotstrings/personal_file_adoption.json")
local Json = require("json")
local file = assert(io.open(path, "r"))
local content = assert(file:read("*a"))
assert(file:close())
require("test.personal_file_adoption_contract").run(helpers, assert(Json.decode(content)))
