--- static/ergopti_plus/macos/tests/unit/modules/keymap/test_hotstring_registry_regressions.lua
---
--- DESCRIPTION:
--- Regression tests for registry counting and loading bugs fixed during the session.

local helpers = require("tests.helpers")

helpers.describe("Registry — hotstring counting regressions", function()
	local Registry = helpers.load_with_stubs("modules.keymap.registry")
	
	helpers.it("correctly counts and loads hotstrings from standard TOML table sections", function()
		-- Mock data with mixed formats: one array-of-tables (legacy) and one direct-table (modern)
		local data = {
			sections_order = {"legacy", "modern"},
			sections = {
				legacy = {
					description = "Legacy Array Format",
					entries = {
						{ trigger = "tr1", output = "out1" },
						{ trigger = "tr2", output = "out2" }
					}
				},
				modern = {
					description = "Modern Table Format",
					tr3 = "out3",
					tr4 = { output = "out4", is_word = true }
				}
			}
		}
		
		-- Use a dummy state
		local state = {
			groups = {
				test_group = {
					enabled = true,
					sections = {
						legacy = { enabled = true },
						modern = { enabled = true }
					}
				}
			},
			mappings = {},
			mappings_lookup = {},
			mappings_by_tail_char = {},
			mappings_by_star_tail_char = {},
			seq_counter = 0,
			magic_key = "★"
		}
		
		-- Mock lib.toml_reader parse to return our data table directly
		local old_toml_reader = package.loaded["lib.toml_reader"]
		package.loaded["lib.toml_reader"] = {
			parse = function(path) return data end
		}

		Registry.init(state)
		-- Call the real load_toml function which will use our mocked toml_reader
		Registry.load_toml("test_group", "dummy_path.toml")
		local info = state.groups["test_group"]
		
		-- Verify counts
		helpers.assert_eq(info.sections[1].count, 2, "legacy section should have 2 entries")
		helpers.assert_eq(info.sections[2].count, 2, "modern section should have 2 entries")
		
		-- Verify total mappings loaded
		local count = 0
		for _ in pairs(state.mappings) do count = count + 1 end
		helpers.assert_eq(count, 12, "total mappings should be 12")
		
		package.loaded["lib.toml_reader"] = old_toml_reader
	end)
end)
