--- tests/unit/ui/test_hotstring_editor_reload_group.lua

--- ==============================================================================
--- MODULE: Regression — the editor must reload into the group the boot loader used
--- DESCRIPTION:
--- lib/personal_hotstrings loads personal_hotstrings.toml at boot under one group
--- name; the editor reloaded the SAME file under a different one on save. The
--- registry's dedup key includes the owning group, so both copies survived, and
--- the sort comparator broke the tie on group_order — a monotonic first-load-wins
--- counter that the boot group always wins. run_trigger_checks returns on the
--- first bucket entry that fires, so a hotstring the user had just edited kept
--- expanding to its old text.
---
--- ROOT CAUSE ENCODED:
--- Not "the priorities were wrong" but "two groups held the same file". Raising
--- the editor group's priority would have fixed an EDITED hotstring and not a
--- DELETED one, because a deleted trigger leaves no competing row to outrank the
--- survivor. Two per-group lookups rode along on the same mistake: the expansion
--- delay and the user's priority override are both keyed by group name, so
--- neither applied to the second copy.
--- ==============================================================================

local helpers = require("tests.helpers")


--- A keymap stub exposing the constant the real module exports, plus recorders
--- for the three calls the save path makes.
--- @return table
local function make_keymap_stub()
	local rec = { calls = {} }
	rec.km = {
		PERSONAL_GROUP_NAME = "personal",
		disable_group  = function(g) rec.calls[#rec.calls + 1] = { "disable", g } end,
		enable_group   = function(g) rec.calls[#rec.calls + 1] = { "enable", g } end,
		load_toml      = function(g, p) rec.calls[#rec.calls + 1] = { "load", g, p } end,
		sort_mappings  = function() rec.calls[#rec.calls + 1] = { "sort" } end,
	}
	return rec
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ One group name, read from one place ===================
-- ==================================================================
-- ==================================================================

helpers.describe("hotstring editor: saves reload into the boot group, not a second one", function()

	helpers.it("reports the group name the keymap module owns", function()
		package.loaded["ui.hotstring_editor"] = nil
		local Editor = helpers.load_with_stubs("ui.hotstring_editor")
		local rec = make_keymap_stub()

		Editor.init("/tmp/does-not-matter.toml", rec.km, function() end, 50)

		helpers.assert_eq(Editor.get_reload_group_name(), "personal",
			"the editor must reload into the group the boot loader used; a second group name "
			.. "leaves both copies alive and the boot one wins every tie-break")
	end)

	helpers.it("takes that name from the keymap module rather than a private literal", function()
		package.loaded["ui.hotstring_editor"] = nil
		local Editor = helpers.load_with_stubs("ui.hotstring_editor")
		local rec = make_keymap_stub()
		-- A deliberately unusual name: a hardcoded literal would ignore it.
		rec.km.PERSONAL_GROUP_NAME = "personal_renamed"

		Editor.init("/tmp/does-not-matter.toml", rec.km, function() end, 50)

		helpers.assert_eq(Editor.get_reload_group_name(), "personal_renamed",
			"the name must come from the keymap module, so renaming the group in one place "
			.. "cannot leave the editor writing into the old one")
	end)

	helpers.it("the exported constant is the same one the real keymap module publishes", function()
		local keymap = require("modules.keymap")
		helpers.assert_eq(type(keymap.PERSONAL_GROUP_NAME), "string",
			"modules.keymap must publish the personal group name for the boot loader and the "
			.. "editor to share")
		helpers.assert_eq(keymap.PERSONAL_GROUP_NAME, "personal",
			"changing this value is a migration, not a rename: existing user config, per-group "
			.. "delays and priority overrides are all keyed by it")
	end)

end)
