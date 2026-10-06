--- tests/unit/modules/hotstrings/test_common_autocorrection_reference.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Historical Reference (Linux)
--- DESCRIPTION:
--- Pins the actual shipped-file reader and catalogue loader to the independent
--- pre-split reference, including registration order and collision priority.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")
local Reader = require("toml_codec.reader")
local Codec = require("toml_codec.codec")

--- Reads one required source or independent reference file.
--- @param path string
--- @return string
local function read_file(path)
	local handle = assert(io.open(path, "r"))
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("common autocorrection historical reference", function()
	helpers.it("(common-autocorrection-reference) preserves the complete source and all 140 historical reader entries", function()
		local expected = Json.decode(read_file(Paths.shared("tests/corpus/hotstrings/common_autocorrection_entries.json")))
		helpers.assert_eq(#expected.entries, 140)
		helpers.assert_eq(expected.source, "common")
		helpers.assert_eq(expected.source_priority, 10)
		helpers.assert_eq(expected.legacy_section, "caps")
		local path = Paths.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml")
		helpers.assert_eq(Codec.decode(read_file(path))._meta, expected.meta)
		local parsed, committed = Reader.parse(path)
		helpers.assert_true(committed)
		helpers.assert_eq(parsed.sections_order, { "caps" })
		helpers.assert_eq(#parsed.sections.caps.entries, 140)
		local sections = 0
		for _ in pairs(parsed.sections) do sections = sections + 1 end
		helpers.assert_eq(sections, 1, "the editorial catalogue does not change runtime selection")
		for index, row in ipairs(expected.entries) do
			helpers.assert_eq(row.ordinal, index)
			helpers.assert_eq(row.section, "caps")
			local actual = parsed.sections.caps.entries[index]
			for _, field in ipairs({ "trigger", "output", "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(actual[field], row[field], row.trigger .. "/" .. field)
			end
			helpers.assert_nil(actual.priority)
			helpers.assert_true(actual.is_case_sensitive_strict ~= true)
		end
	end)

	helpers.it("(common-autocorrection-reference) loads every mapping exactly once with its historical flags, order and common tier", function()
		local expected = Json.decode(read_file(Paths.shared("tests/corpus/hotstrings/common_autocorrection_entries.json")))
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local catalogue = Loader.load_catalogue({ Paths.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml") })
		helpers.assert_true(catalogue.committed)
		helpers.assert_eq(catalogue.errors, 0)
		helpers.assert_eq(#catalogue.mappings, 140)
		local category = catalogue.categories.autocorrection
		helpers.assert_true(category ~= nil)
		helpers.assert_eq(category.sections_order, expected.meta.sections_order)
		helpers.assert_eq(category.count, 140)
		helpers.assert_eq(category.sections.caps.count, 140)
		helpers.assert_eq(category.description, expected.meta.description)
		helpers.assert_eq(category.delay, expected.meta.delay)
		helpers.assert_eq(category.color, expected.meta.color)
		helpers.assert_eq(category.show_tooltip, expected.meta.show_tooltip)
		for index, row in ipairs(expected.entries) do
			local actual = catalogue.mappings[index]
			helpers.assert_eq(row.ordinal, index)
			helpers.assert_eq(actual.group, expected.category)
			helpers.assert_eq(actual.section, row.section)
			helpers.assert_eq(actual.trigger, row.trigger)
			helpers.assert_eq(actual.replacement, row.output)
			helpers.assert_eq(actual.priority, expected.source_priority)
			for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(actual[flag], row[flag], row.trigger .. "/" .. flag)
			end
			helpers.assert_eq(actual.is_case_sensitive_strict, false)
			helpers.assert_eq(actual.is_private, false)
		end
	end)
end)

--- Rebind the real migration to the writer owned by this native refusal fixture.
--- Earlier modules can replace the writer cache independently of a warm migration.
--- @param writer table Exact writer whose publication method this fixture injects.
--- @return table Fresh native configuration owner.
local function load_config_with_migration_writer(writer)
	helpers.load_module_with_dependency("hotstrings.common_autocorrection_migration",
		"toml_codec.writer", writer)
	return helpers.load_module("modules.hotstrings.hotstrings_config")
end

helpers.describe("common autocorrection failed override admission", function()
	for _, selection in ipairs({
		{ group = true, family = "names", refused = true },
		{ group = false, family = "names", refused = false },
		{ group = true, family = false, refused = false },
		{ group = true, family = "abbreviations", refused = true },
		{ group = true, family = "technical_terms", refused = true },
		{ group = true, family = "names", refused = true, warm_writer = true },
	}) do
		helpers.it("(common-autocorrection-split) applies admission only to a requested common family: "
			.. tostring(selection.group) .. "/" .. tostring(selection.family)
			.. (selection.warm_writer and "/warm-writer" or ""), function()
			local Writer = require("toml_codec.writer")
			local publish, stale_publications = Writer.publish_if_unchanged, 0
			if selection.warm_writer then
				local stale_writer = setmetatable({ publish_if_unchanged = function(...)
					stale_publications = stale_publications + 1
					return publish(...)
				end }, { __index = Writer })
				helpers.load_module_with_dependency("hotstrings.common_autocorrection_migration",
					"toml_codec.writer", stale_writer)
			end
			local Config = load_config_with_migration_writer(Writer)
			local engine = require("modules.hotstrings.engine").new()
			engine:load_mappings({ { trigger = "foreign", replacement = "Preserved foreign", auto_expand = true } })
			local publication_count, published = 0, {}
			local load = engine.load_mappings
			engine.load_mappings = function(self, mappings)
				publication_count = publication_count + 1; published = mappings; return load(self, mappings)
			end
			local source = '[hotstrings.groups]\nautocorrection = ' .. tostring(selection.group)
				.. '\nmagickey = true\n[hotstrings.modules.autocorrection]\n'
			for _, family in ipairs({ "names", "abbreviations", "technical_terms" }) do
				source = source .. family .. " = " .. tostring(selection.family == family) .. "\n"
			end
			source = source .. '[hotstrings.modules.magickey]\ntext_expansion_symbols = true\n'
			local path = os.tmpname(); os.remove(path)
			local directory = path .. "-overrides"
			assert(require("adapters.shell_runner").run("mkdir -p " .. require("adapters.shell_runner").quote(directory)))
			local override_path = directory .. "/hotstrings_overrides.toml"
			local original = '[autocorrection.caps]\ndelay = 0.3\n# retain every legacy byte\n'
			local handle = assert(io.open(override_path, "wb")); assert(handle:write(original)); assert(handle:close())
			Config._set_override_config_dir_for_test(directory)
			local ok, detail = pcall(function()
				Writer.publish_if_unchanged = function() return false, "independent migration refusal" end
				require("tests.support.hotstring_choices").with_file(Config, source, function(config_path)
					helpers.assert_true(Config.init(engine, directory .. "/missing-packs"))
					local _, accepted, reason = Config.load_all()
					if selection.refused then
						helpers.assert_eq(accepted, false)
						helpers.assert_eq(reason, "common-autocorrection-overrides-unadmitted")
						helpers.assert_eq(publication_count, 0, "the existing whole runtime image remains untouched")
						engine:reset(); local match
						for char in ("foreign"):gmatch(".") do match = engine:on_char(char) end
						helpers.assert_eq(match.replacement, "Preserved foreign")
					else
						helpers.assert_eq(accepted, true, "other categories keep their independent native owner")
						helpers.assert_eq(publication_count, 1)
						helpers.assert_true(#published > 0)
						for _, mapping in ipairs(published) do helpers.assert_true(mapping.group ~= "autocorrection") end
					end
					helpers.assert_eq(require("tests.support.hotstring_choices").read(config_path), source,
						"admission refusal never changes desired activation choices")
				end)
				handle = assert(io.open(override_path, "rb")); local bytes = handle:read("*a"); assert(handle:close())
				helpers.assert_eq(bytes, original)
				helpers.assert_eq(stale_publications, 0, "a warm foreign writer never owns this refusal fixture")
			end)
			Writer.publish_if_unchanged = publish; Config._set_override_config_dir_for_test(nil)
			os.remove(override_path); require("lfs").rmdir(directory)
			if not ok then error(detail) end
		end)
	end
end)

require("test.common_autocorrection_split_contract").register(helpers, Paths.shared)

helpers.describe("common autocorrection shipped split engine", function()
	for _, selected in ipairs({ "all", "names", "abbreviations", "technical_terms" }) do
		helpers.it("(common-autocorrection-split) publishes and executes the real " .. selected .. " selection", function()
			local reference, assignment = require("test.common_autocorrection_split_contract").reference(Paths.shared)
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("modules.hotstrings.engine").new()
			local published = {}
			local load = engine.load_mappings
			engine.load_mappings = function(self, mappings) published = mappings; return load(self, mappings) end
			local source = '[hotstrings.groups]\nautocorrection = true\n[hotstrings.modules.autocorrection]\n'
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				source = source .. section .. " = " .. tostring(selected == "all" or section == selected) .. "\n"
			end
			local scratch = os.tmpname(); os.remove(scratch)
			Config._set_override_config_dir_for_test(scratch)
			local ok, detail = pcall(function()
				require("tests.support.hotstring_choices").with_file(Config, source, function()
					helpers.assert_true(Config.init(engine, scratch .. "/packs"))
					Config.load_all()
					local owned = {}
					for _, mapping in ipairs(published) do
						if mapping.group == "autocorrection" then owned[#owned + 1] = mapping end
					end
					helpers.assert_eq(#owned, ({ all = 140, names = 34, abbreviations = 95, technical_terms = 11 })[selected])
					local index = 0
					for _, row in ipairs(reference.entries) do
						if selected == "all" or assignment[row.trigger] == selected then
							index = index + 1
							local actual = owned[index]
							helpers.assert_eq(actual.trigger, row.trigger)
							helpers.assert_eq(actual.replacement, row.output)
							helpers.assert_eq(actual.section, assignment[row.trigger])
							helpers.assert_eq(actual.priority, reference.source_priority)
							for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
								helpers.assert_eq(actual[flag], row[flag])
							end
						end
					end
					for _, case in ipairs({
						{ section = "names", trigger = "chatgpt", output = "ChatGPT" },
						{ section = "abbreviations", trigger = "api", output = "API" },
						{ section = "technical_terms", trigger = "adaboost", output = "AdaBoost" },
					}) do
						engine:reset()
						local typed_at_ms = 0
						for char in case.trigger:gmatch(".") do
							typed_at_ms = typed_at_ms + 20
							engine:on_char(char, { typed_at_ms = typed_at_ms })
						end
						local result = engine:on_char(" ", { is_terminator = true, typed_at_ms = typed_at_ms + 20 })
						if selected == "all" or selected == case.section then
							helpers.assert_true(result ~= nil, "enabled selection must expand " .. case.trigger)
							helpers.assert_eq(result.replacement, case.output)
						else
							helpers.assert_nil(result, "another selection cannot expand " .. case.trigger)
						end
					end
					for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
						if Config.is_section_checked("autocorrection", section) then
							helpers.assert_true(Config.toggle_section("autocorrection", section))
						end
					end
					for _, mapping in ipairs(published) do
						helpers.assert_true(mapping.group ~= "autocorrection", "live disable retires every owned mapping")
					end
				end)
			end)
			Config._set_override_config_dir_for_test(nil)
			if not ok then error(detail) end
		end)
	end
end)

helpers.describe("common autocorrection migrated runtime policies", function()
	helpers.it("(common-autocorrection-split) native fan-out and live edits keep each section's own delay and priority", function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local engine = require("modules.hotstrings.engine").new()
		local published = {}
		local load = engine.load_mappings
		engine.load_mappings = function(self, mappings) published = mappings; return load(self, mappings) end
		local directory = os.tmpname(); os.remove(directory)
		assert(require("adapters.shell_runner").run("mkdir -p " .. require("adapters.shell_runner").quote(directory)))
		local path = directory .. "/hotstrings_overrides.toml"
		local input = read_file(Paths.shared("tests/corpus/common_autocorrection_migration/input.toml"))
		local expected = read_file(Paths.shared("tests/corpus/common_autocorrection_migration/expected.toml"))
		local handle = assert(io.open(path, "wb")); assert(handle:write(input)); assert(handle:close())
		Config._set_override_config_dir_for_test(directory)
		local choices = '[hotstrings.groups]\nautocorrection = true\n[hotstrings.modules.autocorrection]\n'
			.. 'names = true\nabbreviations = true\ntechnical_terms = true\n'
		local ok, detail = pcall(function()
			require("tests.support.hotstring_choices").with_file(Config, choices, function()
				helpers.assert_true(Config.init(engine, directory .. "/missing-packs"))
				local _, accepted = Config.load_all(); helpers.assert_eq(accepted, true)
				helpers.assert_eq(read_file(path), expected, "actual conditional native initialization owns the full independent image")
				local count = 0
				for _, mapping in ipairs(published) do
					if mapping.group == "autocorrection" then count = count + 1; helpers.assert_eq(mapping.priority, 23) end
				end
				helpers.assert_eq(count, 140)
				for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
					helpers.assert_eq(Config.resolve("autocorrection", section).delay, section == "names" and 0.2 or 0.875)
				end
				for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
					helpers.assert_true(Config.set_override("autocorrection", section, "delay", 0.6))
					helpers.assert_true(Config.set_override("autocorrection", section, "priority", 37))
					helpers.assert_eq(Config.resolve("autocorrection", section).delay, 0.6)
					for _, mapping in ipairs(published) do
						if mapping.group == "autocorrection" and mapping.section == section then
							helpers.assert_eq(mapping.priority, 37, "live section policy reaches its actual mapping owner")
						end
					end
					helpers.assert_true(Config.set_override("autocorrection", section, "delay", section == "names" and 0.2 or 0.875))
					helpers.assert_true(Config.set_override("autocorrection", section, "priority", 23))
					for _, other in ipairs({ "names", "abbreviations", "technical_terms" }) do
						helpers.assert_eq(Config.resolve("autocorrection", other).delay, other == "names" and 0.2 or 0.875)
						helpers.assert_eq(Config.resolve("autocorrection", other).priority, 23)
					end
				end
			end)
		end)
		Config._set_override_config_dir_for_test(nil); os.remove(path); require("lfs").rmdir(directory)
		if not ok then error(detail) end
	end)
end)

helpers.describe("common autocorrection classified cold startup", function()
	helpers.it("(common-autocorrection-split) publishes unrelated real startup rules while common admission remains unavailable", function()
		local Writer = require("toml_codec.writer")
		local Config = load_config_with_migration_writer(Writer)
		local engine = require("modules.hotstrings.engine").new()
		local source = '[hotstrings.groups]\nautocorrection = true\nmagickey = true\n'
			.. '[hotstrings.modules.autocorrection]\nnames = true\nabbreviations = false\ntechnical_terms = false\n'
			.. '[hotstrings.modules.magickey]\ntext_expansion_symbols = true\n'
		local scratch = os.tmpname(); os.remove(scratch)
		local directory = scratch .. "-cold-overrides"
		local Shell = require("adapters.shell_runner")
		assert(Shell.run("mkdir -p " .. Shell.quote(directory)))
		local path = directory .. "/hotstrings_overrides.toml"
		local original = '[autocorrection.caps]\ndelay = 0.3\n# retain the failed source exactly\n'
		local handle = assert(io.open(path, "wb")); assert(handle:write(original)); assert(handle:close())
		Config._set_override_config_dir_for_test(directory)
		local Loader = require("modules.hotstrings.loader")
		local publish, load_catalogue = Writer.publish_if_unchanged, Loader.load_catalogue
		local publications = 0
		local load_mappings = engine.load_mappings
		engine.load_mappings = function(self, mappings)
			publications = publications + 1
			return load_mappings(self, mappings)
		end
		local function expand(text)
			engine:reset(); local match, at = nil, 0
			for _, codepoint in utf8.codes(text) do
				at = at + 20
				local char = utf8.char(codepoint)
				match = engine:on_char(char, { typed_at_ms = at, is_terminator = char == " " })
			end
			return match
		end
		local ok, detail = pcall(function()
			Writer.publish_if_unchanged = function() return false, "independent cold migration refusal" end
			Loader.load_catalogue = function(paths, ...)
				for _, candidate in ipairs(paths) do
					local candidate_path = type(candidate) == "table" and candidate.path or candidate
					local category = type(candidate) == "table" and candidate.category or nil
					category = category or candidate_path:match("([^/\\]+)%.toml$")
					helpers.assert_true(category ~= "autocorrection", "the unadmitted common source never reaches native parsing")
				end
				return load_catalogue(paths, ...)
			end
			require("tests.support.hotstring_choices").with_file(Config, source, function(config_path)
				helpers.assert_true(Config.init(engine, directory .. "/missing-packs"))
				local count, accepted, reason, receipt = Config.load_all(nil, true)
				helpers.assert_eq(accepted, true); helpers.assert_nil(reason)
				helpers.assert_true(count > 0)
				helpers.assert_eq(receipt, { committed = true, complete = false, unavailable = { "autocorrection" } })
				helpers.assert_eq(publications, 1)
				helpers.assert_nil(Config.get_categories().autocorrection, "a refused source is never advertised as a loaded category")
				helpers.assert_eq(expand("(1)★").replacement, "➀", "the actual unrelated Unicode trigger still expands")
				helpers.assert_nil(expand("chatgpt "), "unavailable common rules cannot execute")
				local previous_categories = Config.get_categories()
				local _, live_accepted, live_reason = Config.load_all()
				helpers.assert_eq(live_accepted, false)
				helpers.assert_eq(live_reason, "common-autocorrection-overrides-unadmitted")
				helpers.assert_eq(publications, 1, "default/live refusal precedes every engine mutation")
				helpers.assert_true(Config.get_categories() == previous_categories)
				helpers.assert_eq(expand("(1)★").replacement, "➀", "live refusal retains the full existing image")
				helpers.assert_eq(read_file(path), original)
				helpers.assert_eq(require("tests.support.hotstring_choices").read(config_path), source,
					"cold refusal preserves persisted desired family choices")
				Writer.publish_if_unchanged = publish; Loader.load_catalogue = load_catalogue
				helpers.assert_true(Config.init(engine, directory .. "/missing-packs"))
				local _, complete_accepted, _, complete = Config.load_all(nil, true)
				helpers.assert_eq(complete_accepted, true)
				helpers.assert_eq(complete, { committed = true, complete = true, unavailable = {} })
				helpers.assert_eq(publications, 2)
				helpers.assert_eq(expand("chatgpt ").replacement, "ChatGPT", "acknowledged migration admits the actual common engine")
			end)
		end)
		Writer.publish_if_unchanged = publish; Loader.load_catalogue = load_catalogue
		Config._set_override_config_dir_for_test(nil)
		os.remove(path); require("lfs").rmdir(directory)
		if not ok then error(detail) end
	end)

	helpers.it("(common-autocorrection-split) the sole Linux startup consumes partial admission receipts", function()
		local source = read_file(helpers.driver_root() .. "/ergopti_hotstrings.lua"):gsub("%-%-[^\n]*", "")
		local cold = assert(source:find("hotstrings_config.load_all(nil, true)", 1, true))
		local committed = assert(source:find("if committed ~= true then", cold, true))
		local partial = assert(source:find('elseif type(receipt) ~= "table" or receipt.complete ~= true then', committed, true))
		local warning = assert(source:find("Common autocorrection is unavailable; %d unrelated hotstring mapping(s) loaded.", partial, true))
		local success = assert(source:find("%d hotstring mapping(s) loaded (%d parse error(s)).", warning, true))
		helpers.assert_true(cold < committed and committed < partial and partial < warning and warning < success)
		local _, callers = source:gsub("hotstrings_config%.load_all%(nil, true%)", "")
		helpers.assert_eq(callers, 1, "the cold mode belongs only to the actual startup initializer")
	end)
end)
