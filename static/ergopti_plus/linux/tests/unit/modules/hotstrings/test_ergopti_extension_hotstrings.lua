--- tests/unit/modules/hotstrings/test_ergopti_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Hotstrings (Linux)
--- DESCRIPTION:
--- SFB reduction, rolls and the magic key's repeat corrections moved from the
--- shared hotstrings folder into the Ergopti layout extension. These tests drive
--- the SHIPPED files through the real discovery, routing and loader: with the
--- Ergopti extension the driver ships, the three groups load under their
--- historical categories, sections and common tier, so every saved preference
--- still addresses them and the typed outputs are the ones the shared files
--- produced; without it, they are absent.
--- ==============================================================================

local helpers = require("tests.helpers")

local Paths      = require("infra.paths")
local Json       = require("json")
local Extension  = require("layouts.extension")
local Extensions = require("hotstrings.extensions")

--- The registry settings the drivers read, from the shared defaults.
--- @return table
local function registry_settings()
	local fh = assert(io.open(Paths.shared("modules/layouts/defaults.json"), "r"))
	local text = fh:read("*a")
	fh:close()
	return Json.decode(text).registry
end

--- Whether a file exists.
--- @param path string
--- @return boolean
local function exists(path)
	local fh = io.open(path, "r")
	if fh then fh:close() end
	return fh ~= nil
end

--- The shipped roots: bundled extensions, then the Ergopti extension when shipped.
--- @param with_ergopti boolean Whether the registry ships the Ergopti extension.
--- @return table
local function roots(with_ergopti)
	local out = { Paths.shared_root() .. "/../extensions" }
	if with_ergopti then
		local registry = Paths.shared_root() .. "/../../layouts/registry/"
		out[#out + 1] = Extension.shipped_root(registry, registry_settings(), exists)
	end
	return out
end

--- Discovers, routes and loads the shipped catalogue like load_all() does.
--- @param with_ergopti boolean
--- @return table catalogue
--- @return table found
local function load(with_ergopti)
	local Loader = helpers.load_module("modules.hotstrings.loader")
	local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
	local found = Extensions.scan(roots(with_ergopti), {
		list_dirs = Loader.list_subdirs, list_files = Loader.find_toml_files, read_file = Loader.read_file,
	})
	local paths = {}
	for _, path in ipairs(Loader.find_toml_files(Paths.shared("modules/hotstrings"))) do
		paths[#paths + 1] = path
	end
	local catalogue = Loader.load_catalogue(Config.route_bound_sources(paths, found))
	return catalogue, found
end

--- The mapping registered for a trigger in one category.
--- @param catalogue table
--- @param group string
--- @param trigger string
--- @return table|nil
local function mapping(catalogue, group, trigger)
	for _, m in ipairs(catalogue.mappings) do
		if m.group == group and m.trigger == trigger then return m end
	end
	return nil
end

helpers.describe("Ergopti extension hotstrings: shipped with the driver", function()
	helpers.it("(ergopti-hotstrings-ext) loads the three groups from the shipped Ergopti extension", function()
		local catalogue, found = load(true)
		local ergopti
		for _, pack in ipairs(found) do if pack.id == "ergopti" then ergopti = pack end end
		helpers.assert_true(ergopti ~= nil, "the shipped Ergopti extension is discovered")
		helpers.assert_eq(#ergopti.bound_files, 3)
		helpers.assert_eq(#ergopti.toml_files, 0, "none of its files becomes an ext: category")

		local sfbs, rolls = catalogue.categories.sfbsreduction, catalogue.categories.rolls
		helpers.assert_true(sfbs ~= nil and rolls ~= nil, "SFB reduction and rolls keep their category ids")
		helpers.assert_true(sfbs.path:find("layouts/registry/ergopti/hotstrings/sfbsreduction.toml", 1, true) ~= nil,
			sfbs.path)
		helpers.assert_eq(sfbs.extension, { id = "ergopti", name = "Ergopti" }, "the menu files it under Ergopti")
		helpers.assert_eq(rolls.extension, { id = "ergopti", name = "Ergopti" })
		helpers.assert_eq(sfbs.count, 34)
		helpers.assert_eq(rolls.count, 35)
		helpers.assert_eq(catalogue.categories.magickey.sections.repeat_corrections.count, 14,
			"the repeat corrections stay a section of the magic key category")
		helpers.assert_nil(catalogue.categories.magickey.extension, "the magic key category stays bundled")
		helpers.assert_eq(catalogue.categories.magickey.sections.repeat_corrections.extension,
			{ id = "ergopti", name = "Ergopti" }, "its bound section names the extension the menu lists it under")
		helpers.assert_nil(catalogue.categories.magickey.sections.text_expansion_symbols.extension)
	end)

	helpers.it("(ergopti-hotstrings-ext) replays one historical expansion per moved group", function()
		local catalogue = load(true)
		local cases = {
			{ group = "sfbsreduction", section = "comma", trigger = ",t", output = "pt", strict = false },
			{ group = "rolls", section = "hc", trigger = "hc", output = "wh", strict = false },
			{ group = "magickey", section = "repeat_corrections", trigger = "ccê", output = "ccu", strict = false },
		}
		for _, case in ipairs(cases) do
			local m = mapping(catalogue, case.group, case.trigger)
			helpers.assert_true(m ~= nil, case.group .. " has " .. case.trigger)
			helpers.assert_eq(m.replacement, case.output)
			helpers.assert_eq(m.section, case.section, "the preference key is the historical section")
			helpers.assert_eq(m.priority, 10, "and the common tier, as when the file was shared")
			helpers.assert_eq(m.auto_expand, true)
			helpers.assert_eq(m.is_word, false)
			helpers.assert_eq(m.is_case_sensitive_strict, case.strict)
		end
	end)

	helpers.it("(ergopti-hotstrings-ext) leaves the three groups out when Ergopti is not installed", function()
		local catalogue = load(false)
		helpers.assert_nil(catalogue.categories.sfbsreduction)
		helpers.assert_nil(catalogue.categories.rolls)
		helpers.assert_nil(catalogue.categories.magickey.sections.repeat_corrections)
		helpers.assert_true(catalogue.categories.magickey.count > 0, "the bundled magic key category still loads")
	end)
end)
