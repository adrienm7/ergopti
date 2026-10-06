--- tests/unit/modules/shortcuts/test_physical_entries.lua

--- Replays the independent user physical-entry contract through the macOS gate.
local helpers = require("tests.helpers")
local Json = require("json")
local PhysicalSlots = require("shortcuts.physical_slots")

--- Reads checked-in independent vectors and canonical registry metadata.
--- @param relative string Path below the shared tree.
--- @return table decoded JSON data.
local function read_shared(relative)
	local file = assert(io.open(helpers.shared(relative), "rb"))
	local raw = file:read("*a")
	file:close()
	return Json.decode(raw)
end

require("test.physical_entries_contract")(helpers, require("shortcuts.physical_entries"),
	PhysicalSlots, read_shared("data/keycodes/physical_keys.json"))
