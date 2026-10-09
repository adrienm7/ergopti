--- tests/unit/ui/test_physical_editor.lua

--- Exercises the shared editor with independent native publication ports.
local helpers = require("tests.helpers")
local Json = require("json")
local file = assert(io.open(helpers.shared("data/keycodes/physical_keys.json"), "rb"))
local registry = Json.decode(file:read("*a"))
file:close()
require("test.physical_editor_contract")(helpers, require("shortcuts.physical_editor"),
	require("shortcuts.physical_editor_window"), require("shortcuts.physical_slots").new(registry))
