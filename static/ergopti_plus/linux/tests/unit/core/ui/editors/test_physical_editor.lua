--- tests/unit/core/ui/editors/test_physical_editor.lua

--- Exercises the shared editor with independent native publication ports.
local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local file = assert(io.open(helpers.driver_root() .. "/../_shared/layouts/data/keycodes/physical_keys.json", "rb"))
local registry = Json.decode(file:read("*a"))
file:close()
require("tests.lua.layouts.physical_editor_contract")(helpers, require("shortcuts.engine.physical_editor"),
	require("shortcuts.engine.physical_editor_window"), require("shortcuts.engine.physical_slots").new(registry))
