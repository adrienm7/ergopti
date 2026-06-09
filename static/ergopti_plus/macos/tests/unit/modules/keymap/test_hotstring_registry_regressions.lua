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




--- ==============================================================================
--- Regression: ",d -> ds" shifted-comma case variants must anchor on nbsp/nnbsp.
---
--- On the Ergopti Shift layer the comma key emits nnbsp/nbsp + ";" and the period
--- key emits nnbsp/nbsp + ":". So the "uppercase" comma in a case-insensitive
--- hotstring is the nbsp-prefixed punctuation, NEVER a plain ASCII space. This
--- mirrors the AHK _BuildUppercasedSymbols fix: the shifted-comma variants must be
--- generated with an nbsp/nnbsp prefix so that
---   - "nnbsp + : + D" expands to "DS" (uppercase) and "nnbsp + ; + d" to "Ds"
---     (titlecase), exactly the casing the user expects from caps-comma + d;
---   - a bare "<space>:D" (the ":D" emoji typed after a normal word) NEVER matches
---     the comma hotstring and stays literal.
--- ==============================================================================

helpers.describe("Registry -- shifted-comma case variants (':D' emoji safety)", function()
	package.loaded["lib.logger"] = nil
	local _ = helpers.load_with_stubs("lib.logger")
	local State = helpers.load_with_stubs("modules.keymap.state")

	--- Reloads the registry so its module-level _state resets, inits a fresh
	--- shared state, and registers the production ",d -> ds" SFB-reduction entry.
	--- @return table state The shared state populated with the comma mappings.
	local function registry_with_comma_ds()
		package.loaded["modules.keymap.registry"] = nil
		package.loaded["modules.keymap.terminators"] = nil
		local R = require("modules.keymap.registry")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { sfbsreduction = 0.3 })
		R.init(state)
		-- Same flags as static/ergopti_plus/shared/hotstrings/sfbsreduction.toml:
		-- auto_expand=true (star), is_word=false (in-word), is_case_sensitive=false.
		R.add(",d", "ds", { auto_expand = true, is_word = false, is_case_sensitive = false })
		return state
	end

	--- Returns the replacement registered for the exact trigger string, or nil.
	--- @param state table The shared registry state.
	--- @param trigger string The trigger byte string to look up.
	--- @return string|nil
	local function repl_for(state, trigger)
		for _, m in ipairs(state.mappings) do
			if m.trigger == trigger then return m.repl end
		end
		return nil
	end

	local NNBSP = "\226\128\175"  -- U+202F
	local NBSP  = "\194\160"      -- U+00A0

	helpers.it("nnbsp + punctuation + uppercase d expands to DS", function()
		local state = registry_with_comma_ds()
		helpers.assert_eq(repl_for(state, NNBSP .. ":D"), "DS", "nnbsp + : + D -> DS")
		helpers.assert_eq(repl_for(state, NNBSP .. ";D"), "DS", "nnbsp + ; + D -> DS")
		helpers.assert_eq(repl_for(state, NBSP  .. ":D"), "DS", "nbsp + : + D -> DS")
		helpers.assert_eq(repl_for(state, NBSP  .. ";D"), "DS", "nbsp + ; + D -> DS")
	end)

	helpers.it("nnbsp + punctuation + lowercase d expands to titlecase Ds", function()
		local state = registry_with_comma_ds()
		helpers.assert_eq(repl_for(state, NNBSP .. ":d"), "Ds", "nnbsp + : + d -> Ds")
		helpers.assert_eq(repl_for(state, NNBSP .. ";d"), "Ds", "nnbsp + ; + d -> Ds")
		helpers.assert_eq(repl_for(state, NBSP  .. ":d"), "Ds", "nbsp + : + d -> Ds")
		helpers.assert_eq(repl_for(state, NBSP  .. ";d"), "Ds", "nbsp + ; + d -> Ds")
	end)

	helpers.it("plain-space + punctuation is NEVER registered (':D' emoji preserved)", function()
		local state = registry_with_comma_ds()
		-- A regular ASCII space before the colon/semicolon is the ":D" emoji typed
		-- after a normal word — it must match nothing, so the emoji stays literal.
		helpers.assert_nil(repl_for(state, " :D"), "<space> + : + D must not be a trigger")
		helpers.assert_nil(repl_for(state, " :d"), "<space> + : + d must not be a trigger")
		helpers.assert_nil(repl_for(state, " ;D"), "<space> + ; + D must not be a trigger")
		helpers.assert_nil(repl_for(state, " ;d"), "<space> + ; + d must not be a trigger")
	end)
end)
