--- tests/unit/modules/hotstrings/test_extension_geometry_routing.lua

--- ==============================================================================
--- MODULE: Layout Extension Geometry Routing (Linux)
--- DESCRIPTION:
--- A layout extension may carry the rules of a bundled category that only make
--- sense on its geometry and bind them to that category. These tests pin the
--- Linux loader's side of the contract: a whole-category binding replaces the
--- bundled file, a section binding supplies only its sections while the bundled
--- file keeps the others and the metadata, the rules keep the category and its
--- common priority tier, and two owners of one source are refused.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Writes a temporary TOML file and returns its path.
--- @param text string Contents.
--- @return string path
local function temp_toml(text)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
	return path
end

--- An extension record as the shared scanner returns it.
--- @param id string Extension id.
--- @param bound table Array of { stem, path, binding }.
--- @return table
local function extension(id, bound)
	return { id = id, name = id, toml_files = {}, bound_files = bound }
end

local SECTION_BINDING = {
	category = "magickey", feature_section = "hotstrings.magic_key",
	sections = { "repeat_corrections" }, source = "common",
}

helpers.describe("extension geometry: routing bound files into bundled categories", function()

	helpers.it("(layout-extension-binding) replaces a whole category and splits a section-bound one", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local found = {
			extension("ergopti", {
				{ stem = "magicrepeat", path = "/ext/ergopti/hotstrings/magicrepeat.toml", binding = SECTION_BINDING },
				{ stem = "rolls", path = "/ext/ergopti/hotstrings/rolls.toml", binding = {
					category = "rolls", feature_section = "hotstrings.rolls", source = "common",
				} },
			}),
		}
		local routed = Config.route_bound_sources({
			"/bundled/magickey.toml",
			"/bundled/rolls.toml",
			{ path = "/bundled/french/magickey.toml", category = "french_magickey" },
		}, found)
		helpers.assert_eq(routed, {
			{ path = "/bundled/magickey.toml", category = "magickey", skip_sections = { "repeat_corrections" } },
			{ path = "/ext/ergopti/hotstrings/rolls.toml", category = "rolls",
				extension = { id = "ergopti", name = "ergopti" } },
			{ path = "/bundled/french/magickey.toml", category = "french_magickey" },
			{ path = "/ext/ergopti/hotstrings/magicrepeat.toml", category = "magickey",
				only_sections = { "repeat_corrections" }, extension = { id = "ergopti", name = "ergopti" } },
		})
	end)

	helpers.it("(layout-extension-binding) keeps a whole binding whose category is not bundled", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local routed = Config.route_bound_sources({ "/bundled/magickey.toml" }, {
			extension("ergopti", { { stem = "sfbs", path = "/ext/sfbs.toml", binding = {
				category = "sfbsreduction", feature_section = "hotstrings.sfbs_reduction", source = "common",
			} } }),
		})
		helpers.assert_eq(routed, { "/bundled/magickey.toml", { path = "/ext/sfbs.toml", category = "sfbsreduction",
			extension = { id = "ergopti", name = "ergopti" } } })
	end)

	helpers.it("(layout-extension-binding) leaves a catalogue without bindings untouched", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local paths = { "/bundled/magickey.toml", { path = "/b/x.toml", category = "ext:demo:x" } }
		helpers.assert_eq(Config.route_bound_sources(paths, { extension("demo", {}) }), paths)
	end)

	helpers.it("(layout-extension-binding) refuses two owners of one bundled section", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local ok, failure = pcall(Config.route_bound_sources, { "/bundled/magickey.toml" }, {
			extension("first", { { stem = "a", path = "/first/a.toml", binding = SECTION_BINDING } }),
			extension("second", { { stem = "b", path = "/second/b.toml", binding = SECTION_BINDING } }),
		})
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(failure):find("magickey.repeat_corrections", 1, true) ~= nil, tostring(failure))
	end)

	helpers.it("(layout-extension-binding) loads bound sections under the bundled category and tier", function()
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local bundled = temp_toml('[_meta]\nsections_order = ["repeat_corrections", "symbols"]\n'
			.. 'description = { en = "Magic key" }\n'
			.. '[[repeat_corrections]]\n"bundledrule" = { output = "OLD" }\n'
			.. '[[symbols]]\n"symbolrule" = { output = "SYM" }\n')
		local geometry = temp_toml('[_meta]\ndescription = { en = "Geometry" }\n'
			.. '[[repeat_corrections]]\n"geometryrule" = { output = "NEW" }\n'
			.. '[[other]]\n"strayrule" = { output = "NO" }\n')
		local pack = temp_toml('[_meta]\ndescription = { en = "Pack" }\n'
			.. '[[phrases]]\n"packrule" = { output = "PACK" }\n')
		local ok, catalogue = pcall(Loader.load_catalogue, {
			{ path = bundled, category = "magickey", skip_sections = { "repeat_corrections" } },
			{ path = geometry, category = "magickey", only_sections = { "repeat_corrections" } },
			{ path = pack, category = "ext:demo:phrases", extension = "demo" },
		})
		os.remove(bundled)
		os.remove(geometry)
		os.remove(pack)
		helpers.assert_true(ok, tostring(catalogue))
		local by_trigger = {}
		for _, mapping in ipairs(catalogue.mappings) do by_trigger[mapping.trigger] = mapping end
		helpers.assert_nil(by_trigger.bundledrule, "the bundled copy of a bound section must not load")
		helpers.assert_nil(by_trigger.strayrule, "a bound file supplies only the sections it binds")
		helpers.assert_eq(by_trigger.symbolrule.replacement, "SYM", "unbound sections keep their bundled source")
		helpers.assert_eq(by_trigger.geometryrule.group, "magickey", "the rules keep their historical category")
		helpers.assert_eq(by_trigger.geometryrule.section, "repeat_corrections")
		helpers.assert_eq(by_trigger.geometryrule.priority, 10, "and the common source tier")
		helpers.assert_eq(by_trigger.packrule.priority, 30,
			"an ordinary extension pack keeps the package tier the Windows engine gives it")
		local category = catalogue.categories.magickey
		helpers.assert_eq(category.sections_order, { "repeat_corrections", "symbols" })
		helpers.assert_eq(category.sections.repeat_corrections.count, 1)
		helpers.assert_eq(category.description, { en = "Magic key" }, "the metadata stays with the bundled file")
		helpers.assert_eq(category.count, 2)
	end)
end)
