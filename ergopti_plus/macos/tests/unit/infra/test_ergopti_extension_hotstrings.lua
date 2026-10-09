--- tests/unit/infra/test_ergopti_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Hotstrings (macOS)
--- DESCRIPTION:
--- SFB reduction, rolls and the magic key's repeat corrections moved from the
--- shared hotstrings folder into the Ergopti layout extension. These tests read
--- the SHIPPED files: with the Ergopti extension the app ships, discovery routes
--- the three groups to its files under their historical categories and
--- sections, so every saved preference still addresses them and the typed
--- outputs are the shared ones; without it, nothing supplies them.
--- ==============================================================================

local helpers = require("tests.helpers")

local Packs     = require("infra.extension_packs")
local TomlCodec = require("toml_codec.codec")
local Json = require("json")

--- The repository's static folder, from this driver's shared tree.
--- @return string
local function static_dir()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local macos = source:match("^(.*)/tests/unit/infra/[^/]+$")
	if macos == nil or macos == "" then macos = "." end
	return macos .. "/../.."
end

--- Real-filesystem scanner collaborators: sorted children of one kind.
--- @return table io_fns
local function real_io()
	local function list(path, flag)
		local out = {}
		local handle = io.popen('find "' .. path .. '" -mindepth 1 -maxdepth 1 -type ' .. flag .. ' 2>/dev/null')
		for line in handle:lines() do out[#out + 1] = line end
		handle:close()
		table.sort(out)
		return out
	end
	return {
		list_dirs  = function(path) return list(path, "d") end,
		list_files = function(path) return list(path, "f") end,
		read_file  = function(path)
			local fh = io.open(path, "r")
			if not fh then return nil end
			local text = fh:read("*a")
			fh:close()
			return text
		end,
	}
end

--- The shipped roots: bundled extensions, then the Ergopti extension when shipped.
--- @param with_ergopti boolean
--- @return table
local function roots(with_ergopti)
	local static = static_dir()
	local out = { static .. "/ergopti_plus/extensions" }
	if with_ergopti then
		local LayoutRegistry = require("modules.keymap.layout_registry")
		out[#out + 1] = LayoutRegistry.shipped_extension_root({
			settings = { ergopti_family = "ergopti" },
			bundled_dir = static .. "/layouts/registry/",
			exists = function(path)
				local fh = io.open(path, "r")
				if fh then fh:close() end
				return fh ~= nil
			end,
		})
	end
	return out
end

--- The first entry of a trigger in one section of a bound file.
--- @param path string
--- @param section string
--- @param trigger string
--- @return table|nil
local function entry(path, section, trigger)
	local fh = assert(io.open(path, "r"))
	local document = TomlCodec.decode(fh:read("*a"))
	fh:close()
	for _, block in ipairs(document[section] or {}) do
		if block[trigger] then return block[trigger] end
	end
	return nil
end

helpers.describe("Ergopti extension hotstrings: shipped with the app", function()
	helpers.it("(ergopti-hotstrings-ext) routes the three groups to the shipped Ergopti extension", function()
		Packs._reset()
		local found = Packs.discover(roots(true), real_io())
		local ergopti
		for _, pack in ipairs(found) do if pack.id == "ergopti" then ergopti = pack end end
		helpers.assert_true(ergopti ~= nil, "the Ergopti extension the app ships is installed")
		helpers.assert_eq(#ergopti.bound_files, 6)
		helpers.assert_eq(#ergopti.toml_files, 0, "none of its files becomes an ext: category")
		local sfbs = Packs.route("sfbsreduction", nil)
		local rolls = Packs.route("rolls", nil)
		helpers.assert_true(sfbs:find("/layouts/registry/ergopti/hotstrings/sfbsreduction.toml", 1, true) ~= nil, sfbs)
		helpers.assert_true(rolls:find("/layouts/registry/ergopti/hotstrings/rolls.toml", 1, true) ~= nil, rolls)
		local magickey, sources = Packs.route("magickey", "/bundled/magickey.toml")
		helpers.assert_eq(magickey, "/bundled/magickey.toml", "the magic key keeps its bundled file")
		helpers.assert_eq(#sources, 2)
		helpers.assert_eq(sources[1].sections, { "replace" })
		helpers.assert_eq(sources[2].sections, { "repeat_corrections" })
		local unbundled = Packs.unbundled_routes({ magickey = true })
		helpers.assert_eq(#unbundled, 4, "every whole category loads without a bundled copy")

		-- One historical expansion per moved group, with the flags it always had.
		for _, case in ipairs({
			{ path = sfbs, section = "comma", trigger = ",t", output = "pt" },
			{ path = rolls, section = "hc", trigger = "hc", output = "wh" },
			{ path = sources[2].path, section = "repeat_corrections", trigger = "ccê", output = "ccu" },
		}) do
			local found_entry = entry(case.path, case.section, case.trigger)
			helpers.assert_true(found_entry ~= nil, case.trigger)
			helpers.assert_eq(found_entry.output, case.output)
			helpers.assert_eq(found_entry.is_word, false)
			helpers.assert_eq(found_entry.auto_expand, true)
		end
		Packs._reset()
	end)

	helpers.it("(ergopti-hotstrings-ext) keeps the user's own copies over the extension's files", function()
		Packs._reset()
		Packs.discover(roots(true), real_io())
		local function pack(section)
			local path = os.tmpname()
			local fh = assert(io.open(path, "w"))
			fh:write("[_meta]\nsections_order = [\"" .. section .. "\"]\n\n[[" .. section .. "]]\n"
				.. "\"zqx\" = { output = \"mine\", is_word = false, auto_expand = true,"
				.. " is_case_sensitive = false, final_result = false }\n")
			fh:close()
			return path
		end
		local rolls, fixes, others = pack("mine"), pack("repeat_corrections"), pack("replace")

		local routed = table.pack(Packs.route("rolls", rolls, true))
		local with_fixes = table.pack(Packs.route("magickey", fixes, true))
		local without_fixes, sources = Packs.route("magickey", others, true)
		local shipped = Packs.route("rolls", rolls, false)
		for _, path in ipairs({ rolls, fixes, others }) do os.remove(path) end
		Packs._reset()

		helpers.assert_eq(routed, { rolls, n = 2 },
			"the user's copy of a category an extension binds whole is an explicit override")
		helpers.assert_eq(with_fixes[1], fixes, "a user's magickey.toml keeps the repeat corrections it declares itself")
		helpers.assert_eq(with_fixes.n, 2)
		helpers.assert_eq(#with_fixes[2], 1)
		helpers.assert_eq(with_fixes[2][1].sections, { "replace" }, "the extension supplies only the missing native feature")
		helpers.assert_eq(without_fixes, others)
		helpers.assert_eq(#sources, 1, "the extension supplies the repeat corrections a user's copy lacks")
		helpers.assert_eq(sources[1].sections, { "repeat_corrections" })
		helpers.assert_true(shipped:find("/layouts/registry/ergopti/hotstrings/rolls.toml", 1, true) ~= nil,
			"the driver's own file still yields to the extension")

		-- The boot hands every file of the configured folder over as the user's copy.
		local boot = helpers.read_driver_source("local function is_user_hotstrings_copy(path)")
		helpers.assert_true(boot ~= nil, "the boot's user-copy predicate must be locatable")
		local _, routes = boot:gsub("ExtensionPacks%.route%(name, own, is_user_hotstrings_copy%(own%)%)", "")
		helpers.assert_eq(routes, 2, "the common and the language files are routed with their origin")
		helpers.assert_true(boot:find("if is_user_hotstrings_copy(own) and ok_attr", 1, true) ~= nil,
			"the metadata resolver reads the user's copy of a bound category, which is what loads")
	end)

	helpers.it("(ergopti-hotstrings-ext) keeps the repeat corrections row in the settings window", function()
		Packs._reset()
		Packs.discover(roots(true), real_io())
		local magickey = static_dir() .. "/ergopti_plus/_shared/modules/hotstrings/magickey.toml"
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		local function sections_of(with_resolver)
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local Config = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
			local override = helpers.temp_dir() .. "/hcfg_ergopti_" .. tostring(with_resolver) .. ".toml"
			os.remove(override)
			Config.init({
				override_path = override,
				toml_resolver = function() return magickey end,
				section_sources_resolver = with_resolver and function(category, path)
					local _, sources = Packs.route(category, path, false)
					return sources
				end or nil,
			})
			local names, descriptions = {}, {}
			for _, section in ipairs(Config.get_sections("magickey")) do
				names[#names + 1] = section.name
				descriptions[section.name] = section.description
			end
			os.remove(override)
			return names, descriptions
		end
		local names, descriptions = sections_of(true)
		local without = sections_of(false)
		Packs._reset()

		helpers.assert_eq(names, { "replace", "repeat_corrections", "text_expansion_symbols", "text_expansion_symbols_typst" },
			"the section the extension binds keeps the place the magic key's order gives it")
		helpers.assert_eq(type(descriptions.repeat_corrections), "table",
			"with the localized description of the extension's file, not its raw id")
		helpers.assert_true(tostring(descriptions.repeat_corrections.en):find("(ê→u)", 1, true) ~= nil)
		helpers.assert_eq(without, { "text_expansion_symbols", "text_expansion_symbols_typst" },
			"the magic key's own file no longer carries it")

		local boot = helpers.read_driver_source("local function is_user_hotstrings_copy(path)")
		helpers.assert_true(boot ~= nil and boot:find(
			"local _, sources = ExtensionPacks.route(category, path, is_user_hotstrings_copy(path))", 1, true) ~= nil,
			"the boot hands the settings window the sections the keymap loads from the extension")
	end)

	helpers.it("(ergopti-hotstrings-ext) routes nothing when Ergopti is not installed", function()
		Packs._reset()
		Packs.discover(roots(false), real_io())
		helpers.assert_eq(table.pack(Packs.route("rolls", nil)), { n = 2 })
		helpers.assert_eq(table.pack(Packs.route("magickey", "/bundled/magickey.toml")),
			{ "/bundled/magickey.toml", n = 2 })
		helpers.assert_eq(Packs.unbundled_routes({}), {})
		Packs._reset()
	end)
end)

--- The independent pre-move reference shared by all three native suites.
--- @return table
local function distance_reference()
	local path = static_dir() .. "/ergopti_plus/_shared/tests/corpus/hotstrings/distance_reduction_entries.json"
	local fh = assert(io.open(path, "r"))
	local reference = Json.decode(fh:read("*a"))
	fh:close()
	return reference
end

helpers.describe("Ergopti extension distance reduction", function()
	helpers.it("(ergopti-distance-ext) owns all 101 historical rules and their metadata without a common duplicate", function()
		Packs._reset()
		Packs.discover(roots(true), real_io())
		local path = Packs.route("distancesreduction", nil)
		helpers.assert_true(type(path) == "string", "Ergopti owns the historical category")
		helpers.assert_true(path:find("/layouts/registry/ergopti/hotstrings/distancesreduction.toml", 1, true) ~= nil)
		local reference = distance_reference()
		helpers.assert_eq(#reference.entries, 101)
		local document = TomlCodec.decode(assert(real_io().read_file(path)))
		helpers.assert_eq(document._meta, reference.meta, "all localized descriptions, delays and section ordering survive")
		local count = 0
		for name, blocks in pairs(document) do
			if name ~= "_meta" then
				for _, block in ipairs(blocks) do for _ in pairs(block) do count = count + 1 end end
			end
		end
		helpers.assert_eq(count, #reference.entries, "no rule is added or lost")
		for _, row in ipairs(reference.entries) do
			local found = entry(path, row.section, row.trigger)
			helpers.assert_true(found ~= nil, row.section .. "/" .. row.trigger)
			for _, flag in ipairs({ "output", "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(found[flag], row[flag], row.trigger .. "/" .. flag)
			end
		end
		helpers.assert_nil(real_io().read_file(static_dir() .. "/ergopti_plus/_shared/modules/hotstrings/distancesreduction.toml"))
		local user = os.tmpname()
		local fh = assert(io.open(user, "w"))
		fh:write('[[mine]]\n"qa" = { output = "user" }\n')
		fh:close()
		local routed = Packs.route("distancesreduction", user, true)
		os.remove(user)
		helpers.assert_eq(routed, user, "a user copy retains precedence")
		Packs._reset()
		Packs.discover(roots(false), real_io())
		helpers.assert_nil(Packs.route("distancesreduction", nil), "without Ergopti no source supplies these rules")
		Packs._reset()
	end)

	helpers.it("(ergopti-distance-ext) loads the reference through the registry and preserves disabled sections on reload", function()
		helpers.with_stub_scope({
			"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
			"modules.keymap.state", "modules.keymap.terminators", "adapters.storage",
			"modules.hotstrings.hotstrings_config", "infra.toml.reader",
		}, function()
			local State = helpers.load_with_stubs("modules.keymap.state")
			local Registry = helpers.load_with_stubs("modules.keymap.registry")
			local Storage = require("adapters.storage")
			local reference = distance_reference()
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			Registry.init(state)
			Packs._reset()
			Packs.discover(roots(true), real_io())
			local path = Packs.route("distancesreduction", nil)
			for section in pairs(reference.section_counts) do
				helpers.assert_true(Storage.set("hotstrings_section_distancesreduction_" .. section, true))
			end
			helpers.assert_true(Registry.load_toml("distancesreduction", path))
			for _, row in ipairs(reference.entries) do
				local found
				for _, mapping in ipairs(state.mappings) do
					if mapping.group == "distancesreduction" and mapping.section == row.section
						and mapping.trigger == row.trigger then found = mapping; break end
				end
				helpers.assert_true(found ~= nil, row.section .. "/" .. row.trigger)
				helpers.assert_eq(found.repl, row.output)
				helpers.assert_eq(found.is_word, row.is_word)
				helpers.assert_eq(found.auto, row.auto_expand)
				-- Comma rules keep explicit shifted-symbol variants; ordinary
				-- case-insensitive rules use the conforming registry entry.
				local mode = row.is_case_sensitive and "fold"
					or (row.trigger:find("[,'.]") and "exact" or "conform")
				helpers.assert_eq(found.match_mode, mode, row.trigger .. " matching mode")
				helpers.assert_eq(found.final_result, row.final_result)
				helpers.assert_eq(found.priority, Registry.PRIORITY_COMMON)
			end
			local metadata = state.groups.distancesreduction.delay_metadata
			for _, key in ipairs({ "delay", "section_delays", "show_tooltip", "description", "sections_order" }) do
				helpers.assert_eq(metadata[key], reference.meta[key], "native metadata: " .. key)
			end
			for section, description in pairs(reference.meta.sections) do
				helpers.assert_eq(metadata.sections[section].description, description, section .. " native description")
			end
			helpers.assert_true(Storage.set("hotstrings_section_distancesreduction_comma_j", false))
			helpers.assert_true(Registry.reload_toml("distancesreduction", path))
			helpers.assert_eq(Registry.is_section_enabled("distancesreduction", "comma_j"), false)
			for _, mapping in ipairs(state.mappings) do
				helpers.assert_true(mapping.section ~= "comma_j", "disabled rules stay absent after reload")
			end
			helpers.assert_true(Registry.disable_group("distancesreduction"))
			helpers.assert_true(Registry.reload_toml("distancesreduction", path))
			helpers.assert_eq(Registry.is_group_enabled("distancesreduction"), false)
			helpers.assert_eq(#state.mappings, 0)
			Packs._reset()
		end)
	end)
end)


helpers.describe("Ergopti suffix and native-feature relocation", function()
	helpers.it("(ergopti-suffixes-ext) registers every suffix through the actual bound-source registry and supports live withdrawal", function()
		helpers.with_stub_scope({
			"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
			"modules.keymap.state", "modules.keymap.terminators", "adapters.storage",
			"modules.hotstrings.hotstrings_config", "infra.toml.reader",
		}, function()
			package.loaded["modules.hotstrings.hotstrings_config"] = { get_user_override = function() return nil end }
			local State = helpers.load_with_stubs("modules.keymap.state")
			local Registry = helpers.load_with_stubs("modules.keymap.registry")
			local Storage = require("adapters.storage")
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			helpers.assert_true(Registry.init(state))
			Packs._reset()
			Packs.discover(roots(true), real_io())
			local path = Packs.route("french_distancesreduction", nil)
			helpers.assert_true(type(path) == "string")
			helpers.assert_true(path:find("/ergopti/hotstrings/suffixes_a.toml", 1, true) ~= nil)
			helpers.assert_true(Storage.set("hotstrings_section_french_distancesreduction_suffixes_a", true))
			helpers.assert_true(Registry.load_toml("french_distancesreduction", path))
			local expected = {
	{ "à'", "ance" }, { "àa", "aire" }, { "àc", "ction" }, { "àd", "would" },
	{ "àê", "able" }, { "àf", "iste" }, { "àg", "ought" }, { "àh", "ight" },
	{ "ài", "ying" }, { "àk", "ique" }, { "àl", "elle" }, { "àm", "isme" },
	{ "àn", "ation" }, { "àp", "ence" }, { "àq", "ique" }, { "àr", "erre" },
	{ "às", "ement" }, { "àt", "ettre" }, { "àv", "ment" }, { "àx", "ieux" },
	{ "àz", "ez-vous" }, { "à’", "ance" }, { "càd", "could" }, { "shàd", "should" },
			}
			local previous = 0
			for _, row in ipairs(expected) do
				local found
				for _, mapping in ipairs(state.mappings) do
					if mapping.group == "french_distancesreduction" and mapping.trigger == row[1] then found = mapping; break end
				end
				helpers.assert_true(found ~= nil, row[1])
				helpers.assert_eq(found.repl, row[2])
				helpers.assert_eq(found.section, "suffixes_a")
				helpers.assert_eq(found.priority, Registry.PRIORITY_COMMON)
				helpers.assert_eq(found.is_word, false)
				helpers.assert_eq(found.auto, true)
				helpers.assert_eq(found.final_result, false)
				helpers.assert_true(found.seq > previous, "canonical suffix registration preserves historical source order")
				previous = found.seq
			end
			helpers.assert_eq(state.groups.french_distancesreduction.delay_metadata.delay, 0.5)
			helpers.assert_eq(state.groups.french_distancesreduction.delay_metadata.show_tooltip, false)
			helpers.assert_true(Storage.set("hotstrings_section_french_distancesreduction_suffixes_a", false))
			helpers.assert_true(Registry.reload_toml("french_distancesreduction", path))
			for _, mapping in ipairs(state.mappings) do helpers.assert_true(mapping.group ~= "french_distancesreduction") end
			local common = static_dir() .. "/ergopti_plus/_shared/modules/hotstrings/magickey.toml"
			local _, sources = Packs.route("magickey", common)
			helpers.assert_eq(#sources, 2)
			helpers.assert_eq(sources[1].sections, { "replace" })
			local replacement = TomlCodec.decode(assert(real_io().read_file(sources[1].path)))
			helpers.assert_eq(replacement._meta.sections.replace.en, "Transform a key into the ★ key")
			helpers.assert_nil(replacement.replace, "native replacement owns no fabricated mapping")
			Packs._reset()
			Packs.discover(roots(false), real_io())
			helpers.assert_nil(Packs.route("french_distancesreduction", nil))
			Packs._reset()
		end)
	end)
end)
