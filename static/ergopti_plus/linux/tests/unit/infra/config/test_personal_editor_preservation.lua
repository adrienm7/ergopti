--- linux/tests/unit/infra/config/test_personal_editor_preservation.lua

--- ==============================================================================
--- MODULE: Personal Editor Preservation Parity
--- DESCRIPTION:
--- Replays the independent whole-model editor corpus through the Linux Lua runtime.
--- ==============================================================================

local helpers = require("tests.helpers")
local path = helpers.load_module("infra.paths").shared("tests/corpus/hotstrings/personal_editor_preservation.json")
local file = assert(io.open(path, "r")); local text = assert(file:read("*a")); assert(file:close())
require("test.personal_editor_preservation_contract").run(helpers, assert(require("json").decode(text)))

local metadata_path = helpers.load_module("infra.paths").shared("tests/corpus/hotstrings/personal_metadata_types.json")
local metadata_file = assert(io.open(metadata_path, "r")); local metadata_text = assert(metadata_file:read("*a")); assert(metadata_file:close())
require("test.personal_metadata_type_contract").run(helpers, assert(require("json").decode(metadata_text)))
