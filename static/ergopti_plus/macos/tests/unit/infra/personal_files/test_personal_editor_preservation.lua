--- macos/tests/unit/infra/personal_files/test_personal_editor_preservation.lua

--- ==============================================================================
--- MODULE: Personal Editor Preservation Parity
--- DESCRIPTION:
--- Replays the independent whole-model editor corpus through the macOS Lua runtime.
--- ==============================================================================

local helpers = require("tests.helpers")
local file = assert(io.open(helpers.shared("tests/corpus/hotstrings/personal_editor_preservation.json"), "r"))
local text = assert(file:read("*a")); assert(file:close())
require("test.personal_editor_preservation_contract").run(helpers, assert(require("adapters.json_codec").decode(text)))

local metadata_file = assert(io.open(helpers.shared("tests/corpus/hotstrings/personal_metadata_types.json"), "r"))
local metadata_text = assert(metadata_file:read("*a")); assert(metadata_file:close())
require("test.personal_metadata_type_contract").run(helpers, assert(require("adapters.json_codec").decode(metadata_text)))
