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
		helpers.assert_eq(#ergopti.bound_files, 6)
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
		helpers.assert_nil(without.categories.french_distancesreduction,
			"the suffixes have no source when the Ergopti extension is absent")
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


helpers.describe("Ergopti suffix and native-feature relocation", function()
	helpers.it("(ergopti-suffixes-ext) loads all historical suffixes and the metadata-only replacement from the shipped binding", function()
		local expected = {
	{ "à'", "ance" }, { "àa", "aire" }, { "àc", "ction" }, { "àd", "would" },
	{ "àê", "able" }, { "àf", "iste" }, { "àg", "ought" }, { "àh", "ight" },
	{ "ài", "ying" }, { "àk", "ique" }, { "àl", "elle" }, { "àm", "isme" },
	{ "àn", "ation" }, { "àp", "ence" }, { "àq", "ique" }, { "àr", "erre" },
	{ "às", "ement" }, { "àt", "ettre" }, { "àv", "ment" }, { "àx", "ieux" },
	{ "àz", "ez-vous" }, { "à’", "ance" }, { "càd", "could" }, { "shàd", "should" },
		}
		local catalogue, discovered = load(true)
		local category = catalogue.categories.french_distancesreduction
		helpers.assert_true(category ~= nil)
		helpers.assert_eq(category.extension, { id = "ergopti", name = "Ergopti+" })
		helpers.assert_true(category.path:find("/ergopti/hotstrings/suffixes_a.toml", 1, true) ~= nil)
		helpers.assert_eq(category.count, 24)
		helpers.assert_eq(category.delay, 0.5)
		helpers.assert_eq(category.show_tooltip, false)
		helpers.assert_eq(category.sections_order, { "suffixes_a" })
		local actual = {}
		for _, row in ipairs(catalogue.mappings) do
			if row.group == "french_distancesreduction" then
				actual[#actual + 1] = { row.trigger, row.replacement }
				helpers.assert_eq(row.section, "suffixes_a")
				helpers.assert_eq(row.priority, 10)
				helpers.assert_eq(row.is_word, false)
				helpers.assert_eq(row.auto_expand, true)
				helpers.assert_eq(row.is_case_sensitive, false)
				helpers.assert_eq(row.final_result, false)
			end
		end
		helpers.assert_eq(actual, expected, "all independent historical rules retain source order")
		local replacement = catalogue.categories.magickey.sections.replace
		helpers.assert_true(replacement ~= nil, "the metadata-only native feature is admitted")
		helpers.assert_eq(replacement.count, 0)
		helpers.assert_eq(replacement.extension, { id = "ergopti", name = "Ergopti+" })
		local Reader = require("toml_codec.reader")
		local parsed, committed = Reader.parse(Extensions.bound_source(discovered, "magickey", "replace"))
		helpers.assert_true(committed)
		helpers.assert_eq(parsed.sections.replace.description.en, "Transform a key into the ★ key")
		helpers.assert_eq(catalogue.categories.magickey.sections_order[1], "replace")
		local french_source = Paths.shared("modules/hotstrings/french/autocorrection.toml")
		helpers.assert_true(exists(french_source), "the common French resolver still reaches its actual source")
		local french_directory = assert(french_source:match("^(.*)/[^/]+$"))
		helpers.assert_eq(exists(french_directory .. "/distancesreduction.toml"), false,
			"the retired common suffix source cannot provide a fallback")
		local shipped = require("modules.keymap.layout_registry").shipped_extension_root()
		helpers.assert_type(shipped, "table", "the actual native resolver supplies the shipped extension")
		local shipped_suffixes = shipped.pack .. "/hotstrings/suffixes_a.toml"
		helpers.assert_true(exists(shipped_suffixes), "the production extension resolver reaches the moved physical file")
		local resolved_suffixes, resolved_committed = Reader.parse(shipped_suffixes)
		helpers.assert_true(resolved_committed)
		helpers.assert_eq(#resolved_suffixes.sections.suffixes_a.entries, 24,
			"the physical resolver and bound catalogue consume the same complete suffix pack")
		local without = load(false)
		helpers.assert_nil(without.categories.french_distancesreduction)
		helpers.assert_nil(without.categories.magickey.sections.replace)
	end)
end)

helpers.describe("Single shipped source binding admission", function()
	for _, route in ipairs({ "absolute", "relative" }) do
		helpers.it("(ergopti-single-source) loads only the canonical category through its " .. route .. " route", function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local Loader = require("modules.hotstrings.loader")
			local canonical = Paths.shared("modules/hotstrings/magickey.toml")
			local selected = route == "absolute" and canonical or "../_shared/modules/hotstrings/magickey.toml"
			helpers.assert_true(Loader.same_file(selected, canonical), "the native filesystem proves the actual shipped route")
			local choices = os.tmpname()
			write(choices, '[hotstrings]\ngroups = { magickey = true }\n[hotstrings.modules.magickey]\nreplace = false\n')
			helpers.assert_true(Config._set_config_file_for_test(choices))
			local ok, err = pcall(function()
				helpers.assert_true(Config.init({ load_mappings = function() return true end }, selected))
				local _, committed = Config.load_all()
				helpers.assert_true(committed)
				local categories, count = Config.get_categories(), 0
				for name in pairs(categories) do
					count = count + 1
					helpers.assert_eq(name, "magickey", "single logical selection admits no foreign extension category")
				end
				helpers.assert_eq(count, 1)
				helpers.assert_eq(categories.magickey.sections.replace.count, 0)
				helpers.assert_eq(categories.magickey.sections.replace.extension.id, "ergopti")
				helpers.assert_eq(categories.magickey.sections.replace.description.en, "Transform a key into the ★ key")
				helpers.assert_eq(categories.magickey.sections.repeat_corrections.count, 14)
				helpers.assert_eq(Config.is_section_enabled("magickey", "replace"), false)
				helpers.assert_true(Config.set_all_sections("magickey", true))
				helpers.assert_eq(Config.is_section_enabled("magickey", "replace"), true,
					"the actual registered metadata-only native gate opens after exact selection ACK")
				helpers.assert_eq(#Config.personal_file_sources(), 0, "a shipped source grants no personal adoption authority")
			end)
			Config._set_config_file_for_test(nil)
			os.remove(choices); os.remove(choices .. ".tmp")
			if not ok then error(err, 0) end
		end)
	end
	helpers.it("(ergopti-single-source) leaves a physically distinct user copy exact even with identical shipped bytes", function()
		local dir = user_folder()
		local copy = dir .. "/magickey.toml"
		local Loader = require("modules.hotstrings.loader")
		local canonical = Paths.shared("modules/hotstrings/magickey.toml")
		write(copy, assert(Loader.read_file(canonical)))
		local choices = os.tmpname()
		write(choices, '[hotstrings]\ngroups = { magickey = true }\n')
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		helpers.assert_true(Config._set_config_file_for_test(choices))
		local ok, err = pcall(function()
			helpers.assert_eq(Loader.same_file(copy, canonical), false, "filenames and bytes cannot grant shipped identity")
			helpers.assert_true(Config.init({ load_mappings = function() return true end }, copy))
			local _, committed = Config.load_all(); helpers.assert_true(committed)
			local categories, count = Config.get_categories(), 0
			for name in pairs(categories) do count = count + 1; helpers.assert_eq(name, "magickey") end
			helpers.assert_eq(count, 1)
			helpers.assert_eq(categories.magickey.path, copy)
			helpers.assert_nil(categories.magickey.sections.replace, "an explicit custom fragment gains no undeclared native section")
			helpers.assert_nil(categories.magickey.sections.repeat_corrections, "foreign bound payloads cannot join an explicit custom file")
			helpers.assert_type(categories.magickey.sections.text_expansion_symbols, "table")
		end)
		Config._set_config_file_for_test(nil)
		os.remove(copy); os.remove(choices); os.remove(choices .. ".tmp"); os.remove(dir)
		if not ok then error(err, 0) end
	end)
	helpers.it("(ergopti-single-source) refuses unavailable, nonregular, placeholder and changing native identities", function()
		local Loader = require("modules.hotstrings.loader")
		local old_lfs, old_uv = package.loaded.lfs, package.loaded.luv
		local ok, err = pcall(function()
			package.loaded.lfs = {}; package.loaded.luv = {}
			helpers.assert_eq(Loader.same_file("one", "one"), false, "a matching path is not native identity evidence")
			for _, attrs in ipairs({ { mode = "directory", dev = 4, ino = 5 },
				{ mode = "file", dev = 0, ino = 0 }, { mode = "file", dev = 4 },
				{ mode = "file", dev = 4, ino = math.huge }, { mode = "file", dev = 4, ino = 1.5 },
				{ mode = "file", dev = "device", ino = "inode" } }) do
				package.loaded.lfs = { attributes = function() return attrs end }
				helpers.assert_eq(Loader.same_file("one", "two"), false)
			end
			local reads = 0
			package.loaded.lfs = { attributes = function()
				reads = reads + 1; return { mode = "file", dev = 4, ino = reads <= 2 and 5 or 6 }
			end }
			helpers.assert_eq(Loader.same_file("one", "two"), false, "a changed route loses native binding admission")
			package.loaded.lfs = {}
			package.loaded.luv = { fs_stat = function() return { type = "file", dev = 4, ino = 5 } end }
			helpers.assert_true(Loader.same_file("one", "two"), "the alternate native metadata backend follows the same strict policy")
		end)
		package.loaded.lfs, package.loaded.luv = old_lfs, old_uv
		if not ok then error(err, 0) end
	end)
end)

--- Reaches actual shipped resolution while refusing accidental runtime dependencies.
--- @param body function Test receiving the real registry and observed native reads.
local function with_offline_shipped_probe(body)
	local updater_name, registry_name = "modules.updater.manager", "modules.keymap.layout_registry"
	local previous_updater, previous_preload = package.loaded[updater_name], package.preload[updater_name]
	local previous_registry = package.loaded[registry_name]
	local Http, FileSystem = require("adapters.http_client"), require("adapters.file_system")
	local previous_get, previous_read = Http.get, FileSystem.read
	local observed = { updater = 0, network = 0, reads = {} }
	package.loaded[updater_name] = nil
	package.preload[updater_name] = function()
		observed.updater = observed.updater + 1
		error("the offline shipped source must not initialize the updater")
	end
	Http.get = function()
		observed.network = observed.network + 1
		error("the offline shipped source must not fetch network data")
	end
	FileSystem.read = function(path)
		observed.reads[#observed.reads + 1] = path
		if observed.refuse and path == Paths.shared(observed.refuse) then return nil end
		return previous_read(path)
	end
	local ok, err = pcall(function()
		local Registry = helpers.load_module(registry_name)
		body(Registry, observed)
	end)
	Http.get, FileSystem.read = previous_get, previous_read
	package.loaded[updater_name], package.preload[updater_name] = previous_updater, previous_preload
	package.loaded[registry_name] = previous_registry
	if not ok then error(err, 0) end
end

helpers.describe("Offline shipped hotstring binding root", function()
	helpers.it("(ergopti-offline-root) resolves the real shipped pack without updater, network or installed records", function()
		with_offline_shipped_probe(function(Registry, observed)
			local root = Registry.shipped_extension_root()
			helpers.assert_type(root, "table")
			helpers.assert_true(exists(root.pack .. "/manifest.toml"))
			helpers.assert_true(exists(root.pack .. "/hotstrings/magickeyreplace.toml"))
			helpers.assert_eq(observed.updater, 0); helpers.assert_eq(observed.network, 0)
			helpers.assert_eq(#observed.reads, 2, "offline resolution reads only its two actual defaults")
			helpers.assert_eq(observed.reads[1], Paths.shared("modules/layouts/defaults.json"))
			helpers.assert_eq(observed.reads[2], Paths.shared("modules/updater/defaults.json"))
		end)
	end)
	for _, source in ipairs({ "modules/layouts/defaults.json", "modules/updater/defaults.json" }) do
		helpers.it("(ergopti-offline-root) refuses unavailable " .. source .. " without guessing a shipped location", function()
			with_offline_shipped_probe(function(Registry, observed)
				observed.refuse = source
				local ok, err = pcall(Registry.shipped_extension_root)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find("is unreadable", 1, true) ~= nil)
				helpers.assert_eq(observed.updater, 0); helpers.assert_eq(observed.network, 0)
			end)
		end)
	end
end)
