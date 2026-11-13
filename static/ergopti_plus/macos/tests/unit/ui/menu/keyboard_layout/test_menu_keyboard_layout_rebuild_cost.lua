--- tests/unit/ui/menu/keyboard_layout/test_menu_keyboard_layout_rebuild_cost.lua

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

	helpers.it("(menu-rebuild-2026-10-31) labels the magic-key candidates from one owner table", function()
		helpers.with_fresh_modules({ "ui.menu.magic_key_source_menu", "modules.keymap.magic_key_source" }, function()
			local Geometry = require("adapters.keyboard_geometry")
			local Source = require("modules.keymap.magic_key_source")
			local Menu = require("ui.menu.magic_key_source_menu")
			local candidates = #Source.resolver().candidates()
			helpers.assert_true(candidates > 1, "the manifest must declare several candidates")
			local original, projections = Geometry.physical_code, 0
			Geometry.physical_code = function(...)
				projections = projections + 1
				return original(...)
			end
			local ok, rows = pcall(Menu.rows, {
				state = {}, save_prefs = function() return true end,
				keymap = { set_magic_key_source = function() end }, paused = false,
			})
			Geometry.physical_code = original
			assert(ok, rows)
			helpers.assert_true(type(rows) == "table" and #rows > 0, "the magic-key rows must render")
			-- One projection per candidate: a lookup per row made it quadratic.
			helpers.assert_eq(projections, candidates)
		end)
	end)

	helpers.it("(menu-rebuild-2026-10-31) keeps the candidate owner code_for answers", function()
		helpers.with_fresh_modules({ "modules.keymap.magic_key_source" }, function()
			local Source = require("modules.keymap.magic_key_source")
			local resolver = Source.resolver()
			local owners, owned = Source.candidates_by_code(nil), 0
			for _, candidate in ipairs(resolver.candidates()) do
				local native = resolver.native(candidate)
				if native ~= nil and owners[native] ~= nil then
					owned = owned + 1
					helpers.assert_eq(Source.code_for(native, nil), owners[native])
				end
			end
			helpers.assert_true(owned > 0, "the ANSI candidates must own their codes")
			helpers.assert_nil(Source.code_for("not a code", nil))
		end)
	end)
end)
