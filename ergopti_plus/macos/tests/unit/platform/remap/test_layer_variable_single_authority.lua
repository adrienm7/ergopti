--- tests/unit/platform/remap/test_layer_variable_single_authority.lua

--- ==============================================================================
--- MODULE: Regression - One Karabiner Navigation-Layer Authority
--- DESCRIPTION:
--- Guards the production action registry and gesture bridge against restoring
--- asynchronous mirror variables that no Karabiner manipulator reads.
---
--- ROOT CAUSE ENCODED HERE:
--- 1. `layer_active` is the only layer state consumed by generated manipulators.
--- 2. Hold, release, explicit ON, and explicit OFF each write that authority once.
--- 3. The unread `layer_toggle` and `layer_hold` names remain absent from every
---    production Lua producer and from the canonical action catalogue.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAYER_VARIABLE = "layer_active"
local LAYER_ON       = 1
local LAYER_OFF      = 0





-- ====================================
-- ====================================
-- ======= 1/ Source Inspection =======
-- ====================================
-- ====================================

--- Reads one repository file without transforming its UTF-8 contents.
--- @param path string Absolute file path.
--- @return string body Complete file contents.
local function read_file(path)
	local handle = assert(io.open(path, "rb"))
	local body = handle:read("*a")
	handle:close()
	return body
end

--- Asserts one action phase writes only `layer_active` with the expected value.
--- @param action table Decoded actions.json row.
--- @param field string Event-list field to inspect.
--- @param expected number Expected layer_active value.
local function assert_single_layer_write(action, field, expected)
	local events = action[field]
	helpers.assert_eq(#events, 1,
		action.id .. "." .. field .. " must have exactly one layer-state writer")
	helpers.assert_eq(events[1].set_variable.name, LAYER_VARIABLE)
	helpers.assert_eq(events[1].set_variable.value, expected)
end





-- =====================================
-- =====================================
-- ======= 2/ Authority Contract =======
-- =====================================
-- =====================================

helpers.describe("karabiner layer state: one authority", function()
	helpers.it("layer hold on and off variants produce only layer_active", function()
		local driver_root = helpers.driver_root()
		local lua_source = helpers.read_driver_source()
		helpers.assert_not_nil(lua_source,
			"the production Lua tree must be readable before an absence assertion can pass")
		local catalogue_source = read_file(driver_root .. "platform/remap/data/actions.json")
		local producers = lua_source .. "\n" .. catalogue_source
		helpers.assert_true(not producers:find("layer_toggle", 1, true),
			"the unread layer_toggle mirror must not return to either producer")
		helpers.assert_true(not producers:find("layer_hold", 1, true),
			"the unread layer_hold mirror must not return to either producer")

		local actions = assert(_G.hs.json.decode(catalogue_source))
		local by_id = {}
		for _, action in ipairs(actions) do by_id[action.id] = action end
		assert_single_layer_write(by_id.layer, "karabiner_to", LAYER_ON)
		assert_single_layer_write(by_id.layer, "karabiner_to_after_key_up", LAYER_OFF)
		assert_single_layer_write(by_id.layer_on, "karabiner_to", LAYER_ON)
		assert_single_layer_write(by_id.layer_off, "karabiner_to", LAYER_OFF)
	end)
end)
