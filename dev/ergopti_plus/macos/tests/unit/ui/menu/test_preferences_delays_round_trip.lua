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

local CATEGORY = "rolls"
local DELAY    = 0.75




-- ==================================================================
-- ==================================================================
-- ======= 1/ save -> load -> merge keeps the delay =================
-- ==================================================================
-- ==================================================================

helpers.describe("preferences: a per-category expansion delay round-trips through disk", function()

	helpers.it("survives save, load and merge", function()
		package.loaded["ui.menu.preferences"] = nil
		local Prefs = helpers.load_with_stubs("ui.menu.preferences")

		local path = os.tmpname()
		local state = { delays = { [CATEGORY] = DELAY } }

		local ok_save = pcall(Prefs.save, path, state, {}, {})
		helpers.assert_true(ok_save, "save must not throw on a minimal state")

		local saved = select(2, pcall(Prefs.load, path))
		helpers.assert_type(saved, "table", "load must return the parsed preferences table")

		local restored = { delays = {} }
		pcall(Prefs.merge_saved_data, restored, saved)
		os.remove(path)

		helpers.assert_eq(restored.delays[CATEGORY], DELAY,
			"a per-category expansion delay must survive the trip through disk; a key that is "
			.. "written and read but not mapped is dropped by save with no diagnostic, and the "
			.. "next reload silently restores the previous value")
	end)

	helpers.it("does not invent a delay that was never set", function()
		package.loaded["ui.menu.preferences"] = nil
		local Prefs = helpers.load_with_stubs("ui.menu.preferences")

		local path = os.tmpname()
		pcall(Prefs.save, path, { delays = {} }, {}, {})
		local saved = select(2, pcall(Prefs.load, path))
		local restored = { delays = {} }
		pcall(Prefs.merge_saved_data, restored, saved)
		os.remove(path)

		helpers.assert_nil(restored.delays[CATEGORY],
			"without this case the assertion above would pass against a merge that fabricates "
			.. "every category with a default")
	end)

end)
