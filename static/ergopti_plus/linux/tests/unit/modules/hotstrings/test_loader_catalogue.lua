--- tests/unit/modules/hotstrings/test_loader_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Loader — categories and their metadata
--- DESCRIPTION:
--- What a category IS, and what the menu is told about it, from real TOML files.
---
--- ROOT CAUSE ENCODED:
--- The loader derived a mapping's category from its PARENT DIRECTORY. The five
--- shared packs live flat beside each other in _shared/modules/hotstrings/, and
--- install.sh copies them flat into ~/.config/ergopti/hotstrings/ — so every
--- entry in magickey.toml, autocorrection.toml, rolls.toml, sfbsreduction.toml
--- and distancesreduction.toml reported the same group, literally named after
--- the folder. Nothing could match the manifest's category ids, so the menu
--- rendered "no group loaded" stubs and the one real group fell into the
--- personal bucket by exclusion. The category menu the user saw was wrong, not
--- merely unlocalised, and no test exercised it against the real layout.
---
--- The second half is what was thrown away. [_meta] carries a description in 21
--- locales, the section order, the delay and the tooltip colour; the loader
--- dropped all of it, so a menu could only ever show a raw file stem.
---
--- Driven against the SHIPPED files rather than fixtures. A fixture proves the
--- parser reads a shape somebody invented; these five files are the shape that
--- actually ships, and the defect was precisely that nothing read them the way
--- they are laid out on disk.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The packs the Ergopti layout extension carries since they moved out of the
-- shared folder (static/layouts/registry/ergopti/manifest.toml).
local ERGOPTI_PACKS = { ["rolls.toml"] = true, ["sfbsreduction.toml"] = true }

--- The absolute path of a shipped hotstring pack.
--- @param name string File name.
--- @return string
local function pack(name)
	local Paths = require("infra.paths")
	if ERGOPTI_PACKS[name] then
		return Paths.shared_root() .. "/../../layouts/registry/ergopti/hotstrings/" .. name
	end
	return Paths.shared("modules/hotstrings/" .. name)
end

--- Loads the catalogue for a set of shared packs.
--- @param names table File names.
--- @return table catalogue
local function catalogue_of(names)
	local loader = helpers.load_module("modules.hotstrings.loader")
	local paths = {}
	for _, name in ipairs(names) do paths[#paths + 1] = pack(name) end
	return loader.load_catalogue(paths)
end





-- =================================================================
-- =================================================================
-- ======= 1/ A category is a file, not a folder ===================
-- =================================================================
-- =================================================================

helpers.describe("loader: the category is the file stem", function()

	helpers.it("keeps the shared packs apart", function()
		local cat = catalogue_of({ "rolls.toml", "sfbsreduction.toml" })
		helpers.assert_true(cat.categories.rolls ~= nil,
			"rolls.toml is the category 'rolls'")
		helpers.assert_true(cat.categories.sfbsreduction ~= nil,
			"and sfbsreduction.toml is its own category")
		helpers.assert_true(cat.categories.hotstrings == nil,
			"the folder they share must not become a category — that collapse is what "
				.. "made every pack report the same group")
	end)

	helpers.it("stamps the category onto every mapping", function()
		local cat = catalogue_of({ "rolls.toml" })
		helpers.assert_true(#cat.mappings > 0, "the pack has entries")
		for _, m in ipairs(cat.mappings) do
			helpers.assert_eq(m.group, "rolls",
				"a mapping's group is the pack it came from; the menu gates entries by it")
		end
	end)

	helpers.it("records which section an entry came from", function()
		local cat = catalogue_of({ "rolls.toml" })
		local with_section = 0
		for _, m in ipairs(cat.mappings) do
			if type(m.section) == "string" and m.section ~= "" then
				with_section = with_section + 1
			end
		end
		helpers.assert_eq(with_section, #cat.mappings,
			"per-section toggles and per-section counts both need it, and it was not "
				.. "on the mapping at all")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ The metadata the menu renders ========================
-- =================================================================
-- =================================================================

helpers.describe("loader: category metadata", function()

	helpers.it("carries the localised description, not just the stem", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_eq(rolls.description.fr, "Roulements",
			"the French name is in the TOML and was being discarded")
		helpers.assert_eq(rolls.description.en, "Rolls", "and the English one")
		local locales = 0
		for _ in pairs(rolls.description) do locales = locales + 1 end
		helpers.assert_true(locales >= 20,
			"the packs are translated into every locale this project ships; got " .. locales)
	end)

	helpers.it("carries the section order the file declares", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_true(#rolls.sections_order >= 5,
			"the order is data: it groups related rolls together, and sorting the "
				.. "sections alphabetically instead would scatter them")
		helpers.assert_eq(rolls.sections_order[1], "hc", "and it starts where the file says")
		for _, name in ipairs(rolls.sections_order) do
			helpers.assert_true(name ~= "-",
				"the separators the menu draws itself must not arrive as section names")
		end
	end)

	helpers.it("carries the delay and the tooltip setting", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_eq(rolls.delay, 0.5,
			"rolls fire fast on purpose; the resolver's category rung reads this")
		helpers.assert_eq(rolls.show_tooltip, false,
			"and they deliberately show no preview — a value of nil would read as "
				.. "'not configured' and turn the preview back on")
	end)

	helpers.it("counts the entries, per section and in total", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_true(rolls.count > 0, "the category total the menu shows")
		local summed = 0
		for _, section in pairs(rolls.sections) do summed = summed + section.count end
		helpers.assert_eq(summed, rolls.count,
			"the per-section counts must add up to the total, or one of the two is "
				.. "counting something the other is not")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ What is not a category ===============================
-- =================================================================
-- =================================================================

helpers.describe("loader: the scan skips what is not a pack", function()

	helpers.it("rejects the files in that directory that are not categories", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		-- Asserted on the predicate rather than on the scan around it. The scan
		-- shells out to POSIX `find`, which does not exist on the interpreter this
		-- repo is developed on, so a case driving it would only ever run in CI —
		-- and this rule is exactly the kind quietly dropped in a rewrite.
		helpers.assert_eq(loader.is_pack_file("/x/_index.toml"), false,
			"_index.toml is the menu index for the directory; loading it as a "
				.. "category produced a group called '_index' with no entries")
		helpers.assert_eq(loader.is_pack_file("/x/defaults.toml"), false,
			"defaults.toml holds the resolver's fallback delays and colours, not hotstrings")
	end)

	helpers.it("accepts every pack the index declares", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		for _, name in ipairs({
			"distancesreduction", "sfbsreduction", "rolls", "autocorrection", "magickey",
		}) do
			helpers.assert_eq(loader.is_pack_file("/x/" .. name .. ".toml"), true,
				"_index.toml lists '" .. name .. "' in categories_order, so a filter "
					.. "that excluded it would leave a menu entry with nothing behind it")
		end
	end)

	helpers.it("rejects anything that is not a TOML file at all", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		helpers.assert_eq(loader.is_pack_file("/x/README.md"), false, "not a pack")
		helpers.assert_eq(loader.is_pack_file(""), false, "nor is an empty path")
		helpers.assert_eq(loader.is_pack_file(nil), false, "nor a missing one")
	end)

end)


helpers.describe("personal-file descriptors: independent cross-driver corpus", function()
	helpers.it("preserves exact relative components without borrowing mutable arrays", function()
		local PersonalFiles = require("hotstrings.personal_files")
		local handle = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/personal_file_descriptors.json", "r"))
		local content = assert(handle:read("*a")); assert(handle:close())
		local corpus = assert(require("json").decode(content))
		helpers.assert_eq(#corpus.vectors, 13, "the independent corpus must not become vacuous")
		local identities = {}
		for _, vector in ipairs(corpus.vectors) do
			local descriptor = PersonalFiles.describe(vector.components)
			helpers.assert_eq(descriptor.id, vector.id, vector.name)
			helpers.assert_eq(descriptor.label, vector.label, vector.name)
			helpers.assert_eq(PersonalFiles.components(vector.id), vector.components, vector.name)
			helpers.assert_nil(identities[descriptor.id], "each admitted filename has a distinct identity")
			identities[descriptor.id] = true
			helpers.assert_true(not descriptor.id:find(".", 1, true), "the id remains one TOML path segment")
			local copied = PersonalFiles.copy(descriptor)
			descriptor.components[1] = "mutated.toml"
			helpers.assert_eq(copied.components, vector.components, "each consumer owns its components")
			helpers.assert_true(PersonalFiles.is_descriptor(copied))
			helpers.assert_eq(PersonalFiles.is_descriptor(descriptor), false, "forged components refuse")
			copied.label = "forged"
			helpers.assert_eq(PersonalFiles.is_descriptor(copied), false, "forged display labels refuse")
		end
		for _, components in ipairs(corpus.invalid_components) do
			local accepted = pcall(PersonalFiles.describe, components)
			helpers.assert_eq(accepted, false, "malformed relative components refuse")
		end
		for _, identity in ipairs(corpus.invalid_ids) do
			helpers.assert_nil(PersonalFiles.components(identity), "noncanonical identities refuse: " .. identity)
		end
		for _, components in ipairs({ { "a.toml", extra = true }, { [1] = "a", [3] = "b.toml" },
			{ string.char(0xED, 0xA0, 0x80) .. ".toml" } }) do
			local admitted, refusal = pcall(PersonalFiles.describe, components)
			helpers.assert_eq(admitted, false, "shape and Unicode refuse")
			helpers.assert_true(type(refusal) == "string" and refusal:find("invalid personal-file", 1, true) ~= nil)
		end
		local extra = PersonalFiles.describe({ "a.toml" }); extra.future = true
		helpers.assert_eq(PersonalFiles.is_descriptor(extra), false, "unknown descriptor fields refuse")
	end)
end)


helpers.describe("personal-file transport through the real loader and compiled engine", function()
	helpers.it("keeps independent source metadata, preview identity and old collision/output order", function()
		local path = os.tmpname()
		local handle = assert(io.open(path, "w"))
		assert(handle:write('[_meta]\ndelay = 1.25\n[probe]\n"pqx" = { output = "Owned", auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true, priority = 73 }\n'))
		assert(handle:close())
		local ok, err = pcall(function()
			local PersonalFiles = require("hotstrings.personal_files")
			local source = PersonalFiles.describe({ "Équipe", "mémoire.toml" })
			local Loader = helpers.load_module("modules.hotstrings.loader")
			local catalogue = Loader.load_catalogue({ { path = path, category = "legacy", personal_source = source } })
			helpers.assert_eq(catalogue.committed, true); helpers.assert_eq(#catalogue.mappings, 1)
			local mapping = catalogue.mappings[1]
			helpers.assert_eq({ mapping.trigger, mapping.replacement, mapping.group, mapping.section, mapping.priority },
				{ "pqx", "Owned", "legacy", "probe", 73 })
			helpers.assert_eq(catalogue.categories.legacy.delay, 1.25)
			helpers.assert_eq(mapping.personal_source.id, "personal-file:c3897175697065:6dc3a96d6f6972652e746f6d6c")
			source.components[1] = "mutated"
			helpers.assert_eq(mapping.personal_source.components[1], "Équipe")
			helpers.assert_true(mapping.personal_source ~= catalogue.categories.legacy.personal_source)
			local engine = require("hotstring_engine").new()
			helpers.assert_true(engine:load_mappings(catalogue.mappings))
			mapping.personal_source.components[1] = "borrowed"
			engine:on_char("p"); engine:on_char("q"); local result = engine:on_char("x")
			helpers.assert_eq(result.replacement, "Owned"); helpers.assert_eq(result.group, "legacy")
			helpers.assert_eq(result.personal_source_id, "personal-file:c3897175697065:6dc3a96d6f6972652e746f6d6c")
			local rows = engine:candidates()
			helpers.assert_eq(#rows, 1); helpers.assert_eq(rows[1].personal_source_id, result.personal_source_id)
			helpers.assert_eq(rows[1].replacement, "Owned"); helpers.assert_eq(rows[1].fires, true)
			local before = engine:mapping_state()
			helpers.assert_eq(engine:load_mappings(catalogue.mappings), false, "borrowed invalid metadata refuses atomically")
			helpers.assert_eq(engine:mapping_state(), before)
			engine:reset(); engine:on_char("p"); engine:on_char("q")
			helpers.assert_eq(engine:on_char("x").personal_source_id, result.personal_source_id)
			local forged = PersonalFiles.describe({ "a.toml" }); forged.label = "forged"
			local admitted, refusal = pcall(Loader.load_catalogue, { { path = path, personal_source = forged } })
			helpers.assert_eq(admitted, false)
			helpers.assert_true(type(refusal) == "string" and refusal:find("invalid personal source descriptor", 1, true) ~= nil)
		end)
		os.remove(path)
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("personal-file discovery: exact owners preserve source and choice intent", function()
	helpers.it("retains recursive provenance, refuses ambiguous legacy choices and publishes independent exact owners", function()
		local root = os.tmpname(); os.remove(root)
		local Shell = require("adapters.shell_runner")
		assert(Shell.run("mkdir -p " .. Shell.quote(root .. "/a") .. " " .. Shell.quote(root .. "/work")
			.. " " .. Shell.quote(root .. "/home") .. " " .. Shell.quote(root .. "/Équipe")))
		local files = { ["a__b.toml"] = "flatx", ["a/b.toml"] = "nestedx", ["words.old.toml"] = "dottedx",
			["work/team.toml"] = "workx", ["home/team.toml"] = "homex", ["Équipe/mémoire.toml"] = "memoryx",
			["rolls.toml"] = "userrollx" }
		local source_bytes = {}
		local ok, err = pcall(function()
			for relative, trigger in pairs(files) do
				local content = '[probe]\n"' .. trigger .. '" = { output = "' .. trigger
					.. '-result", auto_expand = true, is_case_sensitive_strict = true }\n'
				local handle = assert(io.open(root .. "/" .. relative, "w"))
				assert(handle:write(content)); assert(handle:close())
				source_bytes[relative] = content
			end
			local discovered = require("modules.hotstrings.loader").find_toml_files(root)
			local team_discovered = 0
			for _, path in ipairs(discovered) do
				if path:match("/team%.toml$") then team_discovered = team_discovered + 1 end
			end
			helpers.assert_eq(team_discovered, 2, "actual discovery must retain both same-stem physical files")
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstring_engine").new()
			Config._set_override_config_dir_for_test(root)
			local Choices = require("tests.support.hotstring_choices")
			Choices.with_file(Config,
				'[hotstrings]\ngroups = { a__b = true, b = true, "words.old" = true, team = true, "mémoire" = true, rolls = true }\n'
				.. '[hotstrings.modules]\na__b = { probe = true }\nb = { probe = true }\n"words.old" = { probe = true }\n'
				.. 'team = { probe = true }\n"mémoire" = { probe = true }\nrolls = { probe = true }\n', function(choice_path)
				local before = Choices.read(choice_path)
				helpers.assert_true(Config.init(engine, root, nil))
				local count, published = Config.load_all()
				helpers.assert_eq(published, true)
				helpers.assert_eq(count, 5, "two ambiguous legacy sources stay closed; the exact dotted owner is addressable")
				local discovery = Config.personal_file_sources()
				helpers.assert_eq(#discovery, 7, "discovery preserves provenance independently of activation")
				local sources, descriptors, records = {}, {}, {}
				for _, item in ipairs(discovery) do
					local relative = item.path:sub(#root + 2)
					sources[relative], descriptors[relative] = item.descriptor.id, require("hotstrings.personal_files").copy(item.descriptor)
					records[#records + 1] = { source = require("hotstrings.personal_files").copy(item.descriptor), path = item.path,
						legacy_name = relative:match("([^/]+)%.toml$") }
				end
				helpers.assert_eq(sources, {
					["a__b.toml"] = "personal-file:615f5f622e746f6d6c", ["a/b.toml"] = "personal-file:61:622e746f6d6c",
					["words.old.toml"] = "personal-file:776f7264732e6f6c642e746f6d6c",
					["work/team.toml"] = "personal-file:776f726b:7465616d2e746f6d6c", ["home/team.toml"] = "personal-file:686f6d65:7465616d2e746f6d6c",
					["Équipe/mémoire.toml"] = "personal-file:c3897175697065:6dc3a96d6f6972652e746f6d6c", ["rolls.toml"] = "personal-file:726f6c6c732e746f6d6c",
				})
				discovery[1].descriptor.components[1] = "borrowed"
				helpers.assert_true(require("hotstrings.personal_files").is_descriptor(Config.personal_file_sources()[1].descriptor))
				local function match(text)
					engine:reset(); local result
					for char in text:gmatch(".") do result = engine:on_char(char) end
					return result
				end
				local function proves_live(relative, group)
					local result = match(files[relative])
					helpers.assert_not_nil(result)
					helpers.assert_eq(result.replacement, files[relative] .. "-result")
					helpers.assert_eq(result.group, group or sources[relative])
					helpers.assert_eq(result.personal_source_id, sources[relative], "real compiled matches retain source identity")
					local preview
					for _, row in ipairs(engine:candidates()) do
						if row.trigger == files[relative] then preview = row end
					end
					helpers.assert_not_nil(preview)
					helpers.assert_eq(preview.personal_source_id, sources[relative], "the actual preview agrees")
					helpers.assert_eq(preview.fires, true)
				end
				local Codec = require("toml_codec")
				local inventory = assert(require("infra.personal_file_adoption").stage(records,
					Codec.decode(before).hotstrings, root .. "/personal_hotstrings.toml"))
				local evidence = {}
				for _, item in ipairs(inventory) do evidence[item.source.id] = item end
				local Policy = require("hotstrings.personal_scope")
				for _, relative in ipairs({ "home/team.toml", "work/team.toml" }) do
					local id, record = sources[relative], evidence[sources[relative]]
					helpers.assert_eq(record.owner, id)
					helpers.assert_eq(record.reason, "ambiguous-legacy-owner")
					helpers.assert_eq(record.admitted, false); helpers.assert_eq(record.exclusive, false)
					helpers.assert_type(record.physical, "string", "the refusal is semantic, not missing native identity")
					local accepted, refusal = Policy.admit(inventory, { source = descriptors[relative], owner = id, path = root .. "/" .. relative })
					helpers.assert_nil(accepted); helpers.assert_eq(refusal, "unadmitted-source")
					helpers.assert_nil(Config.personal_file_scope_binding(id))
					helpers.assert_eq(Config.enable_group(id), false, "an ambiguous historical choice cannot grant either native owner")
					helpers.assert_nil(match(files[relative]))
				end
				helpers.assert_true(evidence[sources["home/team.toml"]].physical ~= evidence[sources["work/team.toml"]].physical)
				for _, relative in ipairs({ "a__b.toml", "a/b.toml", "words.old.toml", "Équipe/mémoire.toml" }) do proves_live(relative) end
				proves_live("rolls.toml", "rolls")
				helpers.assert_nil(Config.personal_file_scope_binding(sources["rolls.toml"]), "a bound historical category carries provenance without a second descriptor capability")
				helpers.assert_eq(Choices.read(choice_path), before, "discovery and refused adoption never rewrite historical choices")

				-- Deliberately retire only the ambiguous historical team leaves. Exact
				-- native owners begin closed, so no old true choice transfers to either.
				local home, work = sources["home/team.toml"], sources["work/team.toml"]
				local operations = {
					{ path = { "hotstrings", "groups", "team" }, delete = true },
					{ path = { "hotstrings", "modules", "team" }, delete = true },
					{ path = { "hotstrings", "groups", home }, value = false },
					{ path = { "hotstrings", "groups", work }, value = false },
				}
				local rows = require("toml_codec.leaf_rows").prepare(before, operations)
				helpers.assert_eq(require("toml_codec.writer").batch_write(choice_path, rows, nil,
					{ status = "ok", content = before .. "\n# stale source receipt\n" }), false, "stale publication cannot retire another owner's legacy choices")
				helpers.assert_eq(Choices.read(choice_path), before)
				helpers.assert_eq(engine:mapping_state().mappings, 5)
				helpers.assert_eq(require("toml_codec.writer").batch_write(choice_path, rows, nil,
					{ status = "ok", content = before }), true, "explicit repair needs actual conditional publication")
				local repaired = Choices.read(choice_path)
				local choices = Codec.decode(repaired).hotstrings
				helpers.assert_nil(choices.groups.team); helpers.assert_nil(choices.modules.team)
				helpers.assert_eq(choices.groups[home], false); helpers.assert_eq(choices.groups[work], false)
				local original = Codec.decode(before).hotstrings
				for key, value in pairs(original.groups) do if key ~= "team" then helpers.assert_eq(choices.groups[key], value) end end
				for key, value in pairs(original.modules) do if key ~= "team" then helpers.assert_eq(choices.modules[key], value) end end
				helpers.assert_eq(Config.refresh_choices(), true)
				helpers.assert_eq(engine:mapping_state().mappings, 5)
				local home_binding, work_binding = Config.personal_file_scope_binding(home), Config.personal_file_scope_binding(work)
				helpers.assert_not_nil(home_binding); helpers.assert_not_nil(work_binding)
				helpers.assert_eq(home_binding.current(), true); helpers.assert_eq(work_binding.current(), true)
				helpers.assert_eq(home_binding.source.id, home); helpers.assert_eq(work_binding.source.id, work)
				helpers.assert_eq(home_binding.path, root .. "/home/team.toml")
				helpers.assert_eq(work_binding.path, root .. "/work/team.toml")
				helpers.assert_nil(match("homex")); helpers.assert_nil(match("workx"))
				helpers.assert_eq(Choices.read(choice_path), repaired, "native adoption itself stays read-only")
				helpers.assert_eq(Config.enable_group(home), true)
				helpers.assert_eq(Config.refresh_choices(), true, "the acknowledged home choice survives a disk reload")
				helpers.assert_eq(engine:mapping_state().mappings, 6)
				proves_live("home/team.toml"); helpers.assert_nil(match("workx"))
				helpers.assert_eq(Codec.decode(Choices.read(choice_path)).hotstrings.groups[work], false)
				helpers.assert_eq(home_binding.current(), false, "a captured binding cannot follow a later catalogue generation")
				local lease = {}
				helpers.assert_eq(Config.acquire(lease), true)
				local held = Choices.read(choice_path)
				local generation = engine:mapping_state()
				helpers.assert_eq(Config.enable_group(work), false, "another native scope cannot publish into the held owner")
				helpers.assert_eq(Config.release({}), false, "a foreign receipt cannot release the original native owner")
				helpers.assert_eq(Choices.read(choice_path), held); helpers.assert_eq(engine:mapping_state(), generation)
				helpers.assert_eq(Config.release(lease), true)
				helpers.assert_eq(Config.enable_group(work), true)
				helpers.assert_eq(Config.refresh_choices(), true)
				helpers.assert_eq(engine:mapping_state().mappings, 7)
				proves_live("home/team.toml"); proves_live("work/team.toml")
				helpers.assert_eq(Config.disable_group(home), true)
				helpers.assert_eq(Config.refresh_choices(), true)
				helpers.assert_eq(engine:mapping_state().mappings, 6)
				helpers.assert_nil(match("homex")); proves_live("work/team.toml")
				helpers.assert_eq(Codec.decode(Choices.read(choice_path)).hotstrings.groups[home], false)
				helpers.assert_eq(Config.enable_group(home), true)
				helpers.assert_eq(Config.refresh_choices(), true)
				helpers.assert_eq(engine:mapping_state().mappings, 7)
				for relative in pairs(files) do proves_live(relative, relative == "rolls.toml" and "rolls" or nil) end
				for relative, content in pairs(source_bytes) do
					helpers.assert_eq(Choices.read(root .. "/" .. relative), content, "choice publication never mutates source bytes")
				end
				local final = Codec.decode(Choices.read(choice_path)).hotstrings
				helpers.assert_nil(final.groups.team); helpers.assert_nil(final.modules.team)
				for key, value in pairs(original.groups) do if key ~= "team" then helpers.assert_eq(final.groups[key], value) end end
				for key, value in pairs(original.modules) do if key ~= "team" then helpers.assert_eq(final.modules[key], value) end end
			end)
		end)
		for relative in pairs(files) do os.remove(root .. "/" .. relative) end
		for _, directory in ipairs({ "a", "work", "home", "Équipe", "" }) do os.remove(root .. "/" .. directory) end
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("common autocorrection interleaved source order", function()
	local function actual_catalogue(category, selected)
		local Paths = require("infra.paths")
		local handle = assert(io.open(Paths.shared("tests/corpus/hotstrings/source_order_entries.json"), "r"))
		local expected = require("json").decode(handle:read("*a")); assert(handle:close())
		local path = os.tmpname()
		handle = assert(io.open(path, "w")); assert(handle:write(expected.source)); assert(handle:close())
		local ok, failure = pcall(function()
			local Loader = helpers.load_module("modules.hotstrings.loader")
			local result = Loader.load_catalogue({ { path = path, category = category,
				only_sections = selected, skip_sections = { "unknown" } } })
			helpers.assert_eq(result.committed, true); helpers.assert_eq(result.errors, 0)
			local order = {}
			for _, mapping in ipairs(result.mappings) do
				order[#order + 1] = mapping.trigger
				helpers.assert_eq(mapping.group, category)
				helpers.assert_true(mapping.trigger ~= "unknownx")
				if mapping.trigger == "secondx" then
					helpers.assert_eq(mapping.is_case_sensitive_strict, true); helpers.assert_eq(mapping.priority, 44)
				elseif mapping.trigger == "firstx" then
					helpers.assert_eq(mapping.final_result, true); helpers.assert_eq(mapping.priority, 10)
				end
			end
			local wanted = selected and expected.caps_order
				or (category == "autocorrection" and expected.admitted_source_order or expected.declared_order)
			helpers.assert_eq(order, wanted, "the real catalogue stream supplies native insertion precedence")
			local category_info = result.categories[category]
			helpers.assert_eq(category_info.count, #wanted)
			if not selected then
				helpers.assert_eq(category_info.sections.caps.count, 3)
				helpers.assert_eq(category_info.sections.terms.count, 1)
				helpers.assert_eq(category_info.sections.caps.delay, 0.2)
				helpers.assert_eq(category_info.sections.terms.delay, 0.3)
			end
		end)
		assert(os.remove(path))
		if not ok then error(failure, 0) end
	end
	helpers.it("(source-ordered-autocorrection) publishes interleaved common entries through the actual loader", function()
		actual_catalogue("autocorrection")
	end)
	helpers.it("(source-ordered-autocorrection) retains French declared order and caps-only filtering", function()
		actual_catalogue("french_autocorrection")
		actual_catalogue("autocorrection", { "caps" })
	end)
end)
