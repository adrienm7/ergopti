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
	local paths, language_sources = {}, {}
	local root = Paths.shared("modules/hotstrings")
	local Languages = require("hotstrings.languages")
	for _, pack in ipairs(Config.language_packs()) do
		for _, stem in ipairs(pack.categories) do
			local path = root .. "/" .. pack.id .. "/" .. stem .. ".toml"
			language_sources[path] = { path = path, category = Languages.group_id(pack.id, stem) }
		end
	end
	for _, path in ipairs(Loader.find_toml_files(root)) do
		paths[#paths + 1] = language_sources[path] or path
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
		helpers.assert_eq(#ergopti.bound_files, 4)
		helpers.assert_eq(#ergopti.toml_files, 0, "none of its files becomes an ext: category")

		local sfbs, rolls = catalogue.categories.sfbsreduction, catalogue.categories.rolls
		helpers.assert_true(sfbs ~= nil and rolls ~= nil, "SFB reduction and rolls keep their category ids")
		helpers.assert_true(sfbs.path:find("layouts/registry/ergopti/hotstrings/sfbsreduction.toml", 1, true) ~= nil,
			sfbs.path)
		helpers.assert_eq(sfbs.extension, { id = "ergopti", name = "Ergopti+" }, "the menu files it under Ergopti+")
		helpers.assert_eq(rolls.extension, { id = "ergopti", name = "Ergopti+" })
		helpers.assert_eq(sfbs.count, 34)
		helpers.assert_eq(rolls.count, 35)
		helpers.assert_eq(catalogue.categories.magickey.sections.repeat_corrections.count, 14,
			"the repeat corrections stay a section of the magic key category")
		helpers.assert_nil(catalogue.categories.magickey.extension, "the magic key category stays bundled")
		helpers.assert_eq(catalogue.categories.magickey.sections.repeat_corrections.extension,
			{ id = "ergopti", name = "Ergopti+" }, "its bound section names the extension the menu lists it under")
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

--- The independent pre-move reference shared by all three native suites.
--- @return table
local function distance_reference()
	local text = assert(require("modules.hotstrings.loader").read_file(
		Paths.shared("tests/corpus/hotstrings/distance_reduction_entries.json")))
	return Json.decode(text)
end

helpers.describe("Ergopti extension distance reduction", function()
	helpers.it("(ergopti-distance-ext) loads all 101 reference rules under the historical category and common priority", function()
		local catalogue = load(true)
		local reference = distance_reference()
		helpers.assert_eq(#reference.entries, 101)
		local category = catalogue.categories.distancesreduction
		helpers.assert_true(category ~= nil)
		helpers.assert_eq(category.extension, { id = "ergopti", name = "Ergopti+" })
		helpers.assert_true(category.path:find("layouts/registry/ergopti/hotstrings/distancesreduction.toml", 1, true) ~= nil)
		helpers.assert_eq(category.count, #reference.entries)
		helpers.assert_eq(category.delay, reference.meta.delay)
		helpers.assert_eq(category.description, reference.meta.description)
		helpers.assert_eq(category.sections.comma_j.delay, reference.meta.section_delays.comma_j)
		local order = {}
		for _, section in ipairs(reference.meta.sections_order) do
			if section ~= "-" then order[#order + 1] = section end
		end
		helpers.assert_eq(category.sections_order, order)
		local total = 0
		for _, mapping in ipairs(catalogue.mappings) do
			if mapping.group == reference.category then total = total + 1 end
		end
		helpers.assert_eq(total, #reference.entries, "each rule is loaded once")
		for _, row in ipairs(reference.entries) do
			local m = mapping(catalogue, reference.category, row.trigger)
			helpers.assert_true(m ~= nil, row.section .. "/" .. row.trigger)
			helpers.assert_eq(m.section, row.section)
			helpers.assert_eq(m.replacement, row.output)
			helpers.assert_eq(m.priority, 10)
			for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(m[flag], row[flag], row.trigger .. "/" .. flag)
			end
		end
		helpers.assert_eq(exists(Paths.shared("modules/hotstrings") .. "/distancesreduction.toml"), false)
		local without = load(false)
		helpers.assert_nil(without.categories.distancesreduction)
		helpers.assert_eq(without.categories.french_distancesreduction.count, 24,
			"the separate French language category keeps every rule")
		for _, m in ipairs(without.mappings) do
			helpers.assert_true(m.group ~= reference.category, "no extension means no distance rules")
		end
	end)
end)

--- Creates an empty temporary folder standing for the user's hotstrings folder.
--- @return string
local function user_folder()
	local dir = os.tmpname()
	os.remove(dir)
	assert(os.execute("mkdir '" .. dir .. "'"))
	return dir
end

--- Writes one file.
--- @param path string
--- @param text string
local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A one-section pack with one entry, as a user writes an override.
--- @param section string
--- @param trigger string
--- @param output string
--- @return string
local function one_entry_pack(section, trigger, output)
	return "[_meta]\nsections_order = [\"" .. section .. "\"]\n\n[[" .. section .. "]]\n\"" .. trigger
		.. "\" = { output = \"" .. output .. "\", is_word = false, auto_expand = true,"
		.. " is_case_sensitive = false, final_result = false }\n"
end

--- Loads the catalogue the way the daemon does, with `dir` as the user's folder.
--- @param dir string
--- @return table categories
local function load_with_user_folder(dir)
	local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
	-- The engine accepts the catalogue: the owner publishes a catalogue only
	-- once its engine has, so a silent stub would leave every category out.
	Config.init({ load_mappings = function() return true end }, dir)
	Config.load_all()
	return Config.get_categories()
end

helpers.describe("Ergopti extension hotstrings: the user's own copies", function()
	helpers.it("(ergopti-distance-ext) keeps a user's distance reduction copy without appending shipped rules", function()
		local dir = user_folder()
		write(dir .. "/distancesreduction.toml", one_entry_pack("qu", "qa", "my distance"))
		local ok, categories = pcall(load_with_user_folder, dir)
		os.remove(dir .. "/distancesreduction.toml")
		os.remove(dir)
		helpers.assert_true(ok, tostring(categories))
		helpers.assert_eq(categories.distancesreduction.path, dir .. "/distancesreduction.toml")
		helpers.assert_eq(categories.distancesreduction.count, 1)
		helpers.assert_eq(categories.distancesreduction.extension, { id = "ergopti", name = "Ergopti+" })
	end)

	helpers.it("(ergopti-distance-ext) preserves canonical disabled group and section choices across reloads", function()
		local dir = user_folder()
		local config_path = dir .. "/config.toml"
		local original = '[hotstrings.groups]\ndistancesreduction = true\n'
			.. '[hotstrings.modules.distancesreduction]\nqu = true\ncomma_j = false\n'
		write(config_path, original)
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		Config._set_config_file_for_test(config_path)
		local observed = {}
		local ok, failure = pcall(function()
			local engine = { load_mappings = function(_, mappings) observed = mappings; return true end }
			helpers.assert_true(Config.init(engine, dir))
			for _ = 1, 2 do
				local _, committed = Config.load_all()
				helpers.assert_eq(committed, true)
				helpers.assert_eq(Config.is_group_enabled("distancesreduction"), true)
				helpers.assert_eq(Config.is_section_enabled("distancesreduction", "qu"), true)
				helpers.assert_eq(Config.is_section_enabled("distancesreduction", "comma_j"), false)
				local count = 0
				for _, m in ipairs(observed) do
					if m.group == "distancesreduction" then
						count = count + 1
						helpers.assert_eq(m.section, "qu", "only the historically enabled section runs")
					end
				end
				helpers.assert_eq(count, 10)
				helpers.assert_eq(require("modules.hotstrings.loader").read_file(config_path), original)
			end
			write(config_path, original:gsub("distancesreduction = true", "distancesreduction = false"))
			helpers.assert_true(Config.init(engine, dir))
			local _, committed = Config.load_all()
			helpers.assert_eq(committed, true)
			helpers.assert_eq(Config.is_group_enabled("distancesreduction"), false)
			helpers.assert_eq(Config.is_section_checked("distancesreduction", "qu"), true)
			for _, m in ipairs(observed) do helpers.assert_true(m.group ~= "distancesreduction") end
		end)
		Config._set_config_file_for_test(nil)
		os.remove(config_path)
		os.remove(dir)
		helpers.assert_true(ok, tostring(failure))
	end)
	helpers.it("(ergopti-hotstrings-ext) keeps a user's rolls.toml over the extension's file", function()
		local dir = user_folder()
		write(dir .. "/rolls.toml", one_entry_pack("mine", "zqx", "my roll"))
		local ok, categories = pcall(load_with_user_folder, dir)
		os.remove(dir .. "/rolls.toml")
		os.remove(dir)
		helpers.assert_true(ok, tostring(categories))
		helpers.assert_eq(categories.rolls.path, dir .. "/rolls.toml",
			"the user's copy of a category is an explicit override, extension or not")
		helpers.assert_eq(categories.rolls.count, 1, "and it is the only source of the category")
		helpers.assert_eq(categories.rolls.sections.mine.count, 1)
		helpers.assert_eq(categories.rolls.extension, { id = "ergopti", name = "Ergopti+" },
			"the category is still listed under the extension that binds it")
		helpers.assert_eq(categories.sfbsreduction.count, 34, "the other bound category still comes from the extension")
	end)

	helpers.it("(ergopti-hotstrings-ext) keeps the repeat corrections a user's magickey.toml declares", function()
		local dir = user_folder()
		write(dir .. "/magickey.toml", one_entry_pack("repeat_corrections", "zqê", "my fix"))
		local ok, categories = pcall(load_with_user_folder, dir)
		os.remove(dir .. "/magickey.toml")
		os.remove(dir)
		helpers.assert_true(ok, tostring(categories))
		local section = categories.magickey.sections.repeat_corrections
		helpers.assert_eq(categories.magickey.path, dir .. "/magickey.toml")
		helpers.assert_eq(section.count, 1, "the user's own section, not the extension's 14 on top of it")
		helpers.assert_nil(section.extension)
	end)

	helpers.it("(ergopti-hotstrings-ext) adds the extension's repeat corrections to a user's magickey.toml without them",
		function()
			local dir = user_folder()
			write(dir .. "/magickey.toml", one_entry_pack("replace", "zqk", "my key"))
			local ok, categories = pcall(load_with_user_folder, dir)
			os.remove(dir .. "/magickey.toml")
			os.remove(dir)
			helpers.assert_true(ok, tostring(categories))
			helpers.assert_eq(categories.magickey.sections.replace.count, 1)
			helpers.assert_eq(categories.magickey.sections.repeat_corrections.count, 14)
			helpers.assert_eq(categories.magickey.sections.repeat_corrections.extension,
				{ id = "ergopti", name = "Ergopti+" })
		end)
end)

helpers.describe("Ergopti extension hotstrings: the Hotstrings scope", function()
	-- The scope planner writes a manifest recommendation only for a bundled
	-- category. Listing the bundled folder alone left the moved categories out,
	-- so « restore recommended » skipped their sections' delays.
	helpers.it("(ergopti-hotstrings-ext) keeps the moved categories bundled for restore and clear", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local bundled = Config.bundled_categories()
		for _, id in ipairs({ "distancesreduction", "sfbsreduction", "rolls", "magickey" }) do
			helpers.assert_true(bundled[id] == true, id .. " is restored to its manifest recommendation")
		end
	end)
end)
