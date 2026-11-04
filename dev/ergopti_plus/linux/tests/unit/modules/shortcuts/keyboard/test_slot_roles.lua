--- tests/unit/modules/shortcuts/keyboard/test_slot_roles.lua

--- Replays the neutral keyboard-slot contract through the linux gate.
local helpers = require("tests.helpers")
local Json = require("json")
local SlotRoles = require("shortcuts.slot_roles")

--- Reads the checked-in independent vectors.
--- @param relative string Path below the shared tree.
--- @return table decoded JSON data.
local function read_shared(relative)
	local path = helpers.driver_root() .. "/../_shared/" .. relative
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	return Json.decode(raw)
end

require("test.slot_roles_contract")(helpers, SlotRoles, {
	driver = "linux",
	corpus = read_shared("tests/corpus/shortcuts/neutral_slots.json"),
})
