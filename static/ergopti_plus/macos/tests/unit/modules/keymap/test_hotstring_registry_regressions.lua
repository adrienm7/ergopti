--- static/ergopti_plus/macos/tests/unit/modules/keymap/test_hotstring_registry_regressions.lua
---
--- DESCRIPTION:
--- Regression tests for registry counting and loading bugs fixed during the session.

local helpers = require("tests.helpers")

local REGISTRY_OWNERSHIP = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
}

local PRIORITY_OWNERSHIP = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"infra.toml.reader",
	"modules.hotstrings.hotstrings_config",
}

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
			SECTION_DELAYS = {},
			recompute_word_timeout = function() end,
			seq_counter = 0,
			magic_key = "★"
		}
		
		-- Mock lib.toml_reader parse to return our data table directly
		local old_toml_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function(path) return data, true end
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
		
		package.loaded["infra.toml.reader"] = old_toml_reader
	end)
end)

helpers.describe("Registry — TOML read commitment", function()
	helpers.it("registers nothing when the reader returns a table without exact commitment", function()
		for key in pairs(package.loaded) do
			if type(key) == "string" and key:match("^modules%.keymap%.registry") then
				package.loaded[key] = nil
			end
		end
		local old_toml_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function()
				return {
					sections_order = { "ghost" },
					sections = { ghost = { trigger = "must-not-register" } },
				}
			end,
		}

		local Registry = require("modules.keymap.registry")
		local state = {
			groups = { existing = { enabled = true } },
			mappings = {}, mappings_lookup = {}, mappings_by_tail_char = {},
			mappings_by_star_tail_char = {}, seq_counter = 0, magic_key = "★",
		}
		Registry.init(state)
		local loaded = Registry.load_toml("unreadable", "/controlled/unreadable.toml")

		package.loaded["infra.toml.reader"] = old_toml_reader
		helpers.assert_eq(loaded, false, "nil commitment must be a terminal load failure")
		helpers.assert_eq(#state.mappings, 0, "the unreadable group must register no mappings")
		helpers.assert_true(state.groups.existing ~= nil, "the previous registry must survive intact")
		helpers.assert_nil(state.groups.unreadable, "an unreadable group must not be published")
	end)
end)

helpers.describe("Registry — same-group re-registration metadata", function()
	helpers.it("the last section refreshes every mutable field of a duplicate trigger", function()
		helpers.with_fresh_modules(PRIORITY_OWNERSHIP, function()
			local data = {
				sections_order = { "first", "second" },
				sections = {
					first = {
						duplicate = {
							output = "FIRST",
							is_case_sensitive = true,
							final_result = false,
							priority = 11,
						},
					},
					second = {
						duplicate = {
							output = "SECOND",
							is_case_sensitive = true,
							is_case_sensitive_strict = true,
							final_result = true,
							priority = 77,
						},
					},
				},
				meta = { sections = {} },
			}
			package.loaded["infra.toml.reader"] = { parse = function() return data, true end }
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_user_override = function() return nil end,
			}
			local Registry = require("modules.keymap.registry")
			local state = {
				groups = {
					rolls = {
						enabled = true,
						sections = {
							first = { enabled = true },
							second = { enabled = true },
						},
					},
				},
				mappings = {}, mappings_lookup = {}, mappings_by_tail_char = {},
				mappings_by_star_tail_char = {}, seq_counter = 0, magic_key = "★",
				SECTION_DELAYS = {}, recompute_word_timeout = function() end,
			}
			helpers.assert_eq(Registry.init(state), true)
			helpers.assert_eq(Registry.load_toml("rolls", "duplicate.toml"), true)

			local duplicates = {}
			for _, mapping in ipairs(state.mappings) do
				if mapping.trigger == "duplicate" then duplicates[#duplicates + 1] = mapping end
			end
			helpers.assert_eq(#duplicates, 1,
				"same-group duplicates must update one identity rather than accumulate")
			local surviving = duplicates[1]
			helpers.assert_eq(surviving.repl, "SECOND")
			helpers.assert_eq(surviving.section, "second")
			helpers.assert_eq(surviving.priority, 77)
			helpers.assert_eq(surviving.final_result, true)
			helpers.assert_eq(surviving.match_mode, "exact")
			helpers.assert_nil(surviving.trigger_folded,
				"switching from folded to exact matching must clear stale folded metadata")
		end)
	end)
end)




--- ==============================================================================
--- Regression: ",d -> ds" shifted-comma case variants must anchor on nbsp/nnbsp.
---
--- On the Ergopti Shift layer the comma key emits NNBSP + ";" and the period key
--- emits NBSP + ":" (French typography pairs ";" with the narrow space and ":"
--- with the full one). The precise emission lives in the AHK layout only -- macOS
--- input goes through Karabiner -- so the "uppercase" comma in a case-insensitive
--- hotstring is a no-break-space-prefixed punctuation, NEVER a plain ASCII space.
--- Matching is deliberately LENIENT: "DS" must come out regardless of which
--- no-break space precedes the punctuation. This mirrors the AHK
--- _BuildUppercasedSymbols table -- the shifted-comma variants are generated with
--- an nbsp/nnbsp prefix so that
---   - any of "{nnbsp,nbsp} + {:,;} + D" expands to "DS" (uppercase) and the
---     lowercase-d forms to "Ds" (titlecase), exactly the casing the user expects
---     from caps-comma + d;
---   - a bare "<space>:D" (the ":D" emoji typed after a normal word) NEVER matches
---     the comma hotstring and stays literal.
--- ==============================================================================

helpers.describe("Registry -- shifted-comma case variants (':D' emoji safety)", function()
	package.loaded["infra.logger"] = nil
	local _ = helpers.load_with_stubs("infra.logger")
	local State = helpers.load_with_stubs("modules.keymap.state")

	--- Reloads the registry so its module-level _state resets, inits a fresh
	--- shared state, and registers the production ",d -> ds" SFB-reduction entry.
	--- @return table state The shared state populated with the comma mappings.
	local function registry_with_comma_ds()
		return helpers.with_fresh_modules(REGISTRY_OWNERSHIP, function()
			local R = require("modules.keymap.registry")
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { sfbsreduction = 0.3 })
			helpers.assert_eq(R.init(state), true)
			-- Same flags as static/ergopti_plus/_shared/modules/hotstrings/sfbsreduction.toml:
			-- auto_expand=true (star), is_word=false (in-word), is_case_sensitive=false.
			R.add(",d", "ds", { auto_expand = true, is_word = false, is_case_sensitive = false })
			return state
		end)
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




--- ==============================================================================
--- Section-priority cascade: load_toml must read the user's per-section priority
--- from the SHARED override file (modules.hotstrings_config), exactly like the AHK
--- engine reads HotstringsResolve. The order is user-section > user-file >
--- meta-section > meta-file > source default. Without this the macOS collision
--- sort never sees a priority set from the delays/colors window (the engine path
--- was dormant — the TOML reader populated no section_priorities and load_toml
--- never consulted the override file).
--- ==============================================================================

helpers.describe("Registry — section priority from the shared override file", function()
	package.loaded["infra.logger"] = nil
	local _ = helpers.load_with_stubs("infra.logger")

	--- Reload the registry fresh (resets module _state), mock the TOML reader and
	--- the hotstrings_config override layer, load one single-entry group, and return
	--- the resolved priority of that mapping.
	--- @param toml_data table The parsed-TOML table load_toml will receive.
	--- @param override_fn function get_user_override(name, section) -> table|nil.
	--- @return number|nil priority, table Registry The mapping priority and module.
	local function priority_after_load(toml_data, override_fn)
		return helpers.with_fresh_modules(PRIORITY_OWNERSHIP, function()
			package.loaded["infra.toml.reader"] = { parse = function() return toml_data, true end }
			package.loaded["modules.hotstrings.hotstrings_config"] = { get_user_override = override_fn }
			local Registry = require("modules.keymap.registry")

			local state = {
				groups = { rolls = { enabled = true, sections = { sec1 = { enabled = true } } } },
				mappings = {}, mappings_lookup = {}, mappings_by_tail_char = {},
				mappings_by_star_tail_char = {}, seq_counter = 0, magic_key = "★",
				SECTION_DELAYS = {}, recompute_word_timeout = function() end,
			}
			helpers.assert_eq(Registry.init(state), true)
			Registry.load_toml("rolls", "dummy.toml")

			local prio
			for _, m in ipairs(state.mappings) do
				if m.trigger == "trg" then prio = m.priority end
			end
			return prio, Registry
		end)
	end

	-- One enabled section with one entry that carries no per-entry priority.
	local function base_data()
		return {
			sections_order = { "sec1" },
			sections = { sec1 = { trg = "out" } },
			meta = { sections = {} },
		}
	end

	helpers.it("a user section-priority override from hotstrings_config reaches the mapping", function()
		local prio = priority_after_load(base_data(), function(name, section)
			if name == "rolls" and section == "sec1" then return { priority = 42 } end
			return nil
		end)
		helpers.assert_eq(prio, 42, "override-file section priority must win the cascade")
	end)

	helpers.it("falls back to the TOML [_meta] section priority when no user override", function()
		local data = base_data()
		data.meta.sections.sec1 = { priority = 33 }
		local prio = priority_after_load(data, function() return nil end)
		helpers.assert_eq(prio, 33, "TOML [_meta] section priority is the next layer below the override file")
	end)

	helpers.it("falls back to the source default when nothing sets a priority", function()
		local prio, Registry = priority_after_load(base_data(), function() return nil end)
		helpers.assert_eq(prio, Registry.PRIORITY_COMMON, "a common group with no priority lands at the source default (10)")
	end)
end)
