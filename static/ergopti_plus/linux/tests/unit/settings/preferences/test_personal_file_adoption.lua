--- tests/unit/settings/preferences/test_personal_file_adoption.lua

--- ==============================================================================
--- MODULE: Additional Personal File Adoption Parity
--- DESCRIPTION:
--- Replays the independent shared identity/default policy on this native driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local path = helpers.load_module("core.fs.engine.paths").shared("tests/corpus/hotstrings/personal_file_adoption.json")
local Json = require("core.text.engine.json")
local file = assert(io.open(path, "r"))
local content = assert(file:read("*a"))
assert(file:close())
require("tests.lua.hotstrings.personal_file_adoption_contract").run(helpers, assert(Json.decode(content)))
