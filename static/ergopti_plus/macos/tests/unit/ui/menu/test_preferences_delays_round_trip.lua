--- tests/unit/ui/menu/test_preferences_delays_round_trip.lua

--- ==============================================================================
--- MODULE: Regression — per-category expansion delays must survive a reload
--- DESCRIPTION:
--- The Hotstrings menu writes a per-category delay into state.delays, and
--- menu_state reads it back at boot. But `delays` appeared in neither KEY_MAP nor
--- NESTED_KEY_MAP, and those two tables are the entire translation layer between
--- the in-memory state and the file on disk. save() therefore dropped every delay
--- the user set, silently, and the next reload restored the previous value.
---
--- ROOT CAUSE ENCODED:
--- A key that exists on the writer side and the reader side but not in the map
--- between them. This drives the real save -> load -> merge round trip through a
--- temp file, so the guarantee is asserted rather than the shape of the table
--- that currently delivers it.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.preferences_roundtrip_fixture")

local CATEGORY = "rolls"
local DELAY    = 0.75

--- Requires a committed disk roundtrip before checking restored preferences.
--- @param state table Preferences to persist.
--- @param callback function Checks the restored state.
local function with_roundtrip(state, callback)
	return fixture.with_roundtrip(state, function(saved, preferences)
		local restored = { delays = {} }
		preferences.merge_saved_data(restored, saved)
		return callback(restored)
	end)
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ save -> load -> merge keeps the delay =================
-- ==================================================================
-- ==================================================================

helpers.describe("preferences: a per-category expansion delay round-trips through disk", function()

	helpers.it("survives save, load and merge", function()
		with_roundtrip({ delays = { [CATEGORY] = DELAY } }, function(restored)
			helpers.assert_eq(restored.delays[CATEGORY], DELAY,
				"a per-category expansion delay must survive the trip through disk; a key that is "
				.. "written and read but not mapped is dropped by save with no diagnostic, and the "
				.. "next reload silently restores the previous value")
		end)
	end)

	helpers.it("does not invent a delay that was never set", function()
		with_roundtrip({ delays = {} }, function(restored)
			helpers.assert_nil(restored.delays[CATEGORY],
				"without this case the assertion above would pass against a merge that fabricates "
				.. "every category with a default")
		end)
	end)

end)
