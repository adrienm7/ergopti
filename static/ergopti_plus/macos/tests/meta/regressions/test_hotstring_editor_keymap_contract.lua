--- tests/meta/regressions/test_hotstring_editor_keymap_contract.lua

--- ==============================================================================
--- MODULE: Regression — the hotstring editor calls only what keymap exports
--- DESCRIPTION:
--- The editor reloads the personal group through keymap.reload_toml, but the
--- keymap module never exported it: the call returned nil, so every save wrote
--- the file and then reported "saved but the live group reload rolled back"
--- (field log of 2026-10-30 11:37), leaving the edit inactive until a reload.
--- The editor tests stub a keymap that has the function, so only a check on
--- the real module's exports can fail for it (hotstring-editor-keymap-contract).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hotstring editor keymap contract (hotstring-editor-keymap-contract)", function()
	helpers.it("every keymap field the editor reads is exported by the keymap module", function()
		local editor = helpers.read_driver_source("Personal hotstrings were saved but the live group reload")
		local keymap = helpers.read_driver_source("local function preview_fenced_registry_mutation")
		helpers.assert_true(type(editor) == "string" and type(keymap) == "string", "both sources must be found")
		local seen = 0
		for name in editor:gmatch("_keymap%.([%a_][%w_]*)") do
			seen = seen + 1
			helpers.assert_true(keymap:find("\nM%." .. name .. "%s*=") ~= nil,
				"keymap must export " .. name .. " for the hotstring editor")
		end
		helpers.assert_true(seen >= 3, "the guard must see the editor's keymap calls")
	end)
end)
