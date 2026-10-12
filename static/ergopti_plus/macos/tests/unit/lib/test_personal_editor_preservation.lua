--- macos/tests/unit/lib/test_personal_editor_preservation.lua

--- ==============================================================================
--- MODULE: Personal Editor Preservation Parity
--- DESCRIPTION:
--- Replays the independent whole-model editor corpus through the macOS Lua runtime.
--- ==============================================================================

local helpers = require("tests.helpers")
local file = assert(io.open(helpers.shared("tests/corpus/hotstrings/personal_editor_preservation.json"), "r"))
local text = assert(file:read("*a")); assert(file:close())
require("test.personal_editor_preservation_contract").run(helpers, assert(require("adapters.json_codec").decode(text)))
