--- tests/unit/modules/keymap/test_registry_bound_sections.lua

--- ==============================================================================
--- MODULE: Registry Bound Sections Tests
--- DESCRIPTION:
--- A layout extension may bind sections of a bundled category to its own file.
--- The registry then loads those sections from the extension file and every
--- other section, with the category's metadata, from the bundled one, under the
--- bundled category, and keeps doing so through every disable, enable and
--- reload of the group.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.state",
	"modules.keymap.utils",
	"infra.toml.reader",
	"infra.timings",
	"modules.hotstrings.hotstrings_config",
}

local BUNDLED = "/bundled/group_a.toml"
local GEOMETRY = "/ext/ergopti/hotstrings/magicrepeat.toml"
local SOURCES = { { path = GEOMETRY, sections = { "repeat_corrections" } } }

--- Parses a fixture file set keyed by path.
--- @return table
local function fixture_files()
	return {
		[BUNDLED] = {
			sections_order = { "repeat_corrections", "-", "symbols" },
			sections = {
				repeat_corrections = { bundledrule = { output = "OLD" } },
				symbols = { symbolrule = { output = "SYM" } },
			},
			meta = { description = "Magic key", section_delays = { repeat_corrections = 1.5 } },
		},
		[GEOMETRY] = {
			sections_order = { "repeat_corrections", "other" },
			sections = {
				repeat_corrections = { geometryrule = { output = "NEW" } },
				other = { strayrule = { output = "NO" } },
			},
			meta = { description = "Geometry", section_delays = { repeat_corrections = 0.25 } },
		},
	}
end

local function with_registry(data_by_path, callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["infra.toml.reader"] = {
			parse = function(path)
				local data = data_by_path[path]
				return data, data ~= nil
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			get_user_override = function() return nil end,
		}
		local State = helpers.load_with_stubs("modules.keymap.state")
		package.loaded["infra.timings"] = { sec = function() return 0.01 end }
		local Registry = require("modules.keymap.registry")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { group_a = 0.4 })
		helpers.assert_eq(Registry.init(state), true)
		return callback(state, Registry)
	end)
end

local function triggers(state)
	local out = {}
	for _, mapping in ipairs(state.mappings) do out[mapping.trigger] = mapping end
	return out
end

helpers.describe("Registry: sections a layout extension binds", function()
	helpers.it("(layout-extension-binding) loads bound sections from the extension file under the bundled group", function()
		local files = fixture_files()
		with_registry(files, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_a", BUNDLED, SOURCES), true)
			local live = triggers(state)
			helpers.assert_nil(live.bundledrule, "the bundled copy of a bound section must not load")
			helpers.assert_nil(live.strayrule, "a bound file supplies only the sections it binds")
			helpers.assert_eq(live.symbolrule.repl, "SYM", "unbound sections keep their bundled source")
			helpers.assert_eq(live.geometryrule.repl, "NEW")
			helpers.assert_eq(live.geometryrule.group, "group_a", "the rules keep their historical category")
			helpers.assert_eq(live.geometryrule.section, "repeat_corrections")
			local names = {}
			for _, section in ipairs(Registry.get_sections("group_a")) do names[#names + 1] = section.name end
			helpers.assert_eq(names, { "repeat_corrections", "-", "symbols" }, "the bundled order is kept")
			helpers.assert_eq(Registry.get_meta_description("group_a"), "Magic key",
				"the category's metadata stays with the bundled file")
			helpers.assert_eq(state.SECTION_DELAYS.group_a.repeat_corrections, 0.25,
				"a bound section brings its own section metadata")
			helpers.assert_eq(files[BUNDLED].sections.repeat_corrections.bundledrule.output, "OLD",
				"the reader's snapshot is copied, never edited")
		end)
	end)

	helpers.it("(layout-extension-binding) keeps the bound sections through disable, enable and reload", function()
		with_registry(fixture_files(), function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_a", BUNDLED, SOURCES), true)
			helpers.assert_eq(Registry.disable_group("group_a"), true)
			helpers.assert_eq(Registry.enable_group("group_a"), true)
			helpers.assert_eq(triggers(state).geometryrule.repl, "NEW", "enabling reads the bound file again")
			helpers.assert_nil(triggers(state).bundledrule)
			helpers.assert_eq(Registry.reload_toml("group_a", BUNDLED), true)
			helpers.assert_eq(triggers(state).geometryrule.repl, "NEW", "a reload keeps the group's sources")
			helpers.assert_nil(triggers(state).bundledrule)
		end)
	end)

	helpers.it("(layout-extension-binding) refuses a bound file without its section and malformed sources", function()
		local files = fixture_files()
		files[GEOMETRY].sections.repeat_corrections = nil
		with_registry(files, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_a", BUNDLED, SOURCES), false,
				"a bound section the file does not carry would silently drop the rules")
			helpers.assert_eq(#state.mappings, 0)
			helpers.assert_eq(Registry.load_toml("group_a", BUNDLED, { { path = GEOMETRY } }), false)
			helpers.assert_eq(Registry.load_toml("group_a", BUNDLED, "not sources"), false)
		end)
	end)
end)
