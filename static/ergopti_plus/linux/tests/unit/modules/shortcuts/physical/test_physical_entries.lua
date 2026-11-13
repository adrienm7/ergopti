--- tests/unit/modules/shortcuts/physical/test_physical_entries.lua

--- Replays the independent user physical-entry contract through the Linux gate.
local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local PhysicalSlots = require("shortcuts.engine.physical_slots")

--- Reads checked-in independent vectors and canonical registry metadata.
--- @param relative string Path below the shared tree.
--- @return table decoded JSON data.
local function read_shared(relative)
	local path = helpers.driver_root() .. "/../_shared/" .. relative
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	return Json.decode(raw)
end

require("tests.lua.layouts.physical_entries_contract")(helpers, require("shortcuts.engine.physical_entries"),
	PhysicalSlots, read_shared("layouts/data/keycodes/physical_keys.json"))
