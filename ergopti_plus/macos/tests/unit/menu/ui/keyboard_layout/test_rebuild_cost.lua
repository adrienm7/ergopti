--- tests/unit/menu/ui/keyboard_layout/test_rebuild_cost.lua

--- ==============================================================================
--- MODULE: Regression — the keyboard-layout row repeats no unchanged work
--- DESCRIPTION:
--- The keyboard-layout row was the slowest of every menu rebuild on the field
--- Mac (141.5 ms of 322 ms, 2026-10-31): each rebuild decoded the registry
--- settings JSON twice (picker and number-row availability), and the magic-key
--- rows looked each candidate's owner up by walking every candidate. Identical
--- settings bytes now decode once, and one owner table serves every row.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Keyboard layout row rebuild cost", function()
	helpers.it("(menu-rebuild-2026-10-31) decodes unchanged registry settings once", function()
		helpers.with_fresh_modules({ "modules.keymap.layout_registry" }, function()
			local Json = require("core.text.engine.json")
			local Registry = require("modules.keymap.layout_registry")
			local original, decodes = Json.decode, 0
			Json.decode = function(...)
				decodes = decodes + 1
				return original(...)
			end
			local ok, first, second = pcall(function() return Registry.settings(), Registry.settings() end)
			Json.decode = original
			assert(ok, first)
			helpers.assert_true(type(first) == "table" and type(second) == "table", "the settings must resolve")
			helpers.assert_eq(first.index_file, second.index_file)
			-- Two shared files, each decoded once whatever the number of calls.
			helpers.assert_eq(decodes, 2)
		end)
	end)
end)
