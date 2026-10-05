--- tests/unit/meta/test_common_autocorrection_reference.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Historical Reference (macOS)
--- DESCRIPTION:
--- Pins the real TOML reader and registry to an independent pre-split corpus.
--- Keeps the frozen legacy reader and independently reviewed current families.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Reader = require("toml_codec.reader")
local Codec = require("toml_codec.codec")

--- Reads an independent, checked-in reference through the shared JSON codec.
--- @return table
local function reference()
	local handle = assert(io.open(helpers.shared("tests/corpus/hotstrings/common_autocorrection_entries.json"), "r"))
	local text = handle:read("*a")
	handle:close()
	return Json.decode(text)
end

helpers.describe("common autocorrection historical reference", function()
	helpers.it("(common-autocorrection-reference) preserves all 140 entries, flags, metadata and source order in the real reader", function()
		local expected = reference()
		helpers.assert_eq(#expected.entries, 140)
		helpers.assert_eq(expected.source, "common")
		helpers.assert_eq(expected.source_priority, 10)
		helpers.assert_eq(expected.legacy_section, "caps")
		local path = helpers.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml")
		local handle = assert(io.open(path, "r"))
		local text = handle:read("*a")
		handle:close()
		helpers.assert_eq(Codec.decode(text)._meta, expected.meta, "every metadata field remains historical")
		local parsed, committed = Reader.parse(path)
		helpers.assert_true(committed)
		helpers.assert_eq(parsed.sections_order, { "caps" })
		helpers.assert_eq(#parsed.sections.caps.entries, 140)
		local sections = 0
		for _ in pairs(parsed.sections) do sections = sections + 1 end
		helpers.assert_eq(sections, 1, "classification must not split the live section")
		for index, row in ipairs(expected.entries) do
			helpers.assert_eq(row.ordinal, index)
			helpers.assert_eq(row.section, "caps")
			local actual = parsed.sections.caps.entries[index]
			for _, field in ipairs({ "trigger", "output", "is_word", "auto_expand", "is_case_sensitive", "final_result" }) do
				helpers.assert_eq(actual[field], row[field], row.trigger .. "/" .. field)
			end
			helpers.assert_nil(actual.priority, "no individual override changes the common tier")
			helpers.assert_true(actual.is_case_sensitive_strict ~= true, "literal registration still folds matching case")
		end
	end)

	helpers.it("(common-autocorrection-reference) registers every historical mapping once with its native priority and insertion order", function()
		helpers.with_stub_scope({
			"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
			"modules.keymap.state", "modules.keymap.terminators", "adapters.storage",
			"modules.hotstrings.hotstrings_config", "infra.toml.reader",
		}, function()
			-- The registry is real; the override port represents an empty user file.
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_user_override = function() return nil end,
			}
			local State = helpers.load_with_stubs("modules.keymap.state")
			local Registry = helpers.load_with_stubs("modules.keymap.registry")
			local Storage = require("adapters.storage")
			local expected = reference()
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			helpers.assert_true(Registry.init(state))
			Registry.set_group_context("personal_reference")
			Registry.add("personal-reference", "Existing personal replacement", {
				is_word = true, is_case_sensitive = true, priority = 50, section = "personal",
			})
			Registry.set_group_context(nil)
			Registry.sort_mappings()
			local baseline = {}
			for _, mapping in ipairs(state.mappings) do
				local snapshot = {}
				for field, value in pairs(mapping) do
					helpers.assert_true(type(value) ~= "table", "the foreign fixture snapshot owns every scalar field")
					snapshot[field] = value
				end
				baseline[mapping.seq] = snapshot
			end
			local baseline_count, baseline_seq = #state.mappings, state.seq_counter
			helpers.assert_eq(baseline_count, 1, "the fixture includes an unrelated live mapping")
			local function assert_foreign_preserved()
				local observed = {}
				for _, mapping in ipairs(state.mappings) do
					if mapping.group ~= expected.category then observed[mapping.seq] = mapping end
				end
				helpers.assert_eq(observed, baseline, "loading or disabling caps preserves every foreign mapping field")
			end
			helpers.assert_true(Storage.set("hotstrings_section_autocorrection_caps", true))
			helpers.assert_true(Registry.load_toml("autocorrection", helpers.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml")))
			-- Native registration adds NBSP/NNBSP aliases to these three spaced
			-- triggers. Name the six expectations explicitly, independently of
			-- the production variant builder or the captured source reader.
			local aliases = {
				["azure devops"] = { "azure" .. utf8.char(0xA0) .. "devops", "azure" .. utf8.char(0x202F) .. "devops" },
				["data science"] = { "data" .. utf8.char(0xA0) .. "science", "data" .. utf8.char(0x202F) .. "science" },
				["data scientist"] = { "data" .. utf8.char(0xA0) .. "scientist", "data" .. utf8.char(0x202F) .. "scientist" },
			}
			local mappings, owned_count = {}, 0
			for _, mapping in ipairs(state.mappings) do
				if mapping.group == expected.category then
					helpers.assert_eq(mapping.section, expected.legacy_section)
					helpers.assert_nil(mappings[mapping.trigger], "duplicate owned native registration")
					mappings[mapping.trigger] = mapping
					owned_count = owned_count + 1
				end
			end
			helpers.assert_eq(owned_count, 140 + 6, "140 canonical rules plus precisely six native space aliases")
			helpers.assert_eq(#state.mappings, baseline_count + owned_count)
			assert_foreign_preserved()
			local function assert_mapping(actual, row, trigger, sequence)
				helpers.assert_true(actual ~= nil, "the native registry keeps " .. trigger)
				helpers.assert_eq(actual.trigger, trigger)
				helpers.assert_eq(actual.group, expected.category)
				helpers.assert_eq(actual.section, row.section)
				helpers.assert_eq(actual.repl, row.output)
				helpers.assert_eq(actual.is_word, row.is_word)
				helpers.assert_eq(actual.auto, row.auto_expand)
				helpers.assert_eq(actual.final_result, row.final_result)
				helpers.assert_eq(actual.is_private, false)
				helpers.assert_eq(actual.match_mode, "fold")
				helpers.assert_eq(actual.priority, expected.source_priority)
				helpers.assert_eq(actual.seq, sequence, "registration order is part of collision precedence")
			end
			local alias_count, canonical_count = 0, 0
			for _, row in ipairs(expected.entries) do
				local sequence = baseline_seq + row.ordinal + alias_count
				assert_mapping(mappings[row.trigger], row, row.trigger, sequence)
				canonical_count = canonical_count + 1
				for index, trigger in ipairs(aliases[row.trigger] or {}) do
					assert_mapping(mappings[trigger], row, trigger, sequence + index)
					alias_count = alias_count + 1
				end
			end
			helpers.assert_eq(canonical_count, 140)
			helpers.assert_eq(alias_count, 6)
			helpers.assert_eq(state.groups.autocorrection.delay_metadata.delay, expected.meta.delay)
			helpers.assert_true(Storage.set("hotstrings_section_autocorrection_caps", false))
			helpers.assert_true(Registry.reload_toml("autocorrection", helpers.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml")))
			helpers.assert_eq(#state.mappings, baseline_count, "caps disables its canonical rules and native aliases only")
			for _, mapping in ipairs(state.mappings) do
				helpers.assert_true(mapping.group ~= expected.category, "the complete disabled section stays absent")
			end
			assert_foreign_preserved()
		end)
	end)
end)


helpers.describe("common autocorrection interleaved source order", function()
	local function interleaved()
		local handle = assert(io.open(helpers.shared("tests/corpus/hotstrings/source_order_entries.json"), "r"))
		local text = handle:read("*a"); assert(handle:close())
		return Json.decode(text)
	end

	local function actual_registry(category, caps_only, bound_mode)
		local expected = interleaved()
		local path = os.tmpname()
		local handle = assert(io.open(path, "w")); assert(handle:write(expected.source)); assert(handle:close())
		local bound_path = path .. ".bound"
		if bound_mode then
			handle = assert(io.open(bound_path, "w")); assert(handle:write(expected.bound_source)); assert(handle:close())
		end
		local ok, failure = pcall(function()
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
				for _, section in ipairs(expected.sections) do
					helpers.assert_true(Storage.set("hotstrings_section_" .. category .. "_" .. section,
						section ~= "unknown" and (not caps_only or section == "caps")))
				end
				local sources = bound_mode and { { path = bound_path, sections = { "caps" } } } or nil
				if bound_mode == "missing" then
					assert(os.remove(bound_path))
					helpers.assert_eq(Registry.load_toml(category, path, sources), false)
					helpers.assert_eq(#state.mappings, 0, "an unavailable bound owner cannot fall through to bundled caps")
					return
				end
				helpers.assert_true(Registry.load_toml(category, path, sources))
				local ordered = {}
				for _, mapping in ipairs(state.mappings) do ordered[mapping.seq] = mapping.trigger end
				local wanted = bound_mode and (caps_only and expected.bound_caps_order or expected.bound_declared_order)
					or caps_only and expected.caps_order
					or (category == "autocorrection" and expected.admitted_source_order or expected.declared_order)
				helpers.assert_eq(ordered, wanted, "native Seq must follow the category's actual order policy")
				local counts = {}
				for _, section in ipairs(state.groups[category].sections) do counts[section.name] = section.count end
				local wanted_counts = {}
				for key, value in pairs(expected.counts) do wanted_counts[key] = value end
				if bound_mode then wanted_counts.caps = 4 end
				helpers.assert_eq(counts, wanted_counts, "disabled sections keep their menu metadata")
				for _, mapping in ipairs(state.mappings) do
					helpers.assert_true(mapping.trigger ~= "unknownx", "an unknown disabled section cannot become admitted")
					if mapping.trigger == "secondx" then
						helpers.assert_eq(mapping.match_mode, "exact"); helpers.assert_eq(mapping.priority, 44)
					elseif mapping.trigger == "firstx" then
						helpers.assert_eq(mapping.priority, 10); helpers.assert_eq(mapping.final_result, true)
					end
				end
			end)
		end)
		assert(os.remove(path))
		if bound_mode and bound_mode ~= "missing" then assert(os.remove(bound_path)) end
		if not ok then error(failure, 0) end
	end

	helpers.it("(source-ordered-autocorrection) registers the actual common registry across interleaved sections", function()
		actual_registry("autocorrection", false)
	end)
	helpers.it("(source-ordered-autocorrection) preserves French declared order and the existing caps-only admission", function()
		actual_registry("french_autocorrection", false)
		actual_registry("autocorrection", true)
	end)
	helpers.it("(source-ordered-autocorrection) preserves actual bound section order and refuses missing bound sources", function()
		actual_registry("autocorrection", false, "bound")
		actual_registry("autocorrection", true, "bound")
		actual_registry("autocorrection", true, "missing")
	end)
	helpers.it("(source-ordered-autocorrection) reparses old grouped cache documents before claiming source order", function()
		local path = helpers.shared("tests/corpus/hotstrings/common_autocorrection_legacy/autocorrection.toml")
		local reader = helpers.load_with_stubs("toml_codec.reader")
		local old, accepted = reader.parse(path)
		helpers.assert_true(accepted); old.source_entries = nil
		local stored, observed_count = 0, nil
		reader.set_cache_provider({
			load = function() return old end, capture_source = function() return "owned" end,
			store = function(_, parsed) stored = stored + 1; observed_count = #parsed.source_entries end,
		})
		local parsed, committed = reader.parse(path)
		reader.set_cache_provider(nil)
		helpers.assert_true(committed)
		helpers.assert_eq(#parsed.source_entries, 140, "old section-grouped cache cannot manufacture physical order")
		helpers.assert_eq(stored, 1)
		helpers.assert_eq(observed_count, 140, "cache observations are asserted outside the protected callback")
	end)
end)

require("test.common_autocorrection_split_contract").register(helpers, helpers.shared)

--- Qualifies each selectable family and their original composed registration order.
local function shipped_split_registry(only)
		helpers.with_stub_scope({
			"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
			"modules.keymap.state", "modules.keymap.terminators", "adapters.storage",
			"modules.keymap.expander", "modules.keymap.terminator_replay",
			"modules.hotstrings.hotstrings_config", "infra.toml.reader",
		}, function()
			-- The registry is real; the override port represents an empty user file.
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_user_override = function() return nil end,
			}
			local State = helpers.load_with_stubs("modules.keymap.state")
			local Registry = helpers.load_with_stubs("modules.keymap.registry")
			local Storage = require("adapters.storage")
			local expected, assignment = require("test.common_autocorrection_split_contract").reference(helpers.shared)
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
			helpers.assert_true(Registry.init(state))
			Registry.set_group_context("personal_reference")
			Registry.add("personal-reference", "Existing personal replacement", {
				is_word = true, is_case_sensitive = true, priority = 50, section = "personal",
			})
			Registry.set_group_context(nil)
			Registry.sort_mappings()
			local baseline = {}
			for _, mapping in ipairs(state.mappings) do
				local snapshot = {}
				for field, value in pairs(mapping) do
					helpers.assert_true(type(value) ~= "table", "the foreign fixture snapshot owns every scalar field")
					snapshot[field] = value
				end
				baseline[mapping.seq] = snapshot
			end
			local baseline_count, baseline_seq = #state.mappings, state.seq_counter
			helpers.assert_eq(baseline_count, 1, "the fixture includes an unrelated live mapping")
			local function assert_foreign_preserved()
				local observed = {}
				for _, mapping in ipairs(state.mappings) do
					if mapping.group ~= expected.category then observed[mapping.seq] = mapping end
				end
				helpers.assert_eq(observed, baseline, "loading or disabling current families preserves every foreign mapping field")
			end
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_true(Storage.set("hotstrings_section_autocorrection_" .. section, only == nil or section == only))
			end
			helpers.assert_true(Registry.load_toml("autocorrection", helpers.shared("modules/hotstrings/autocorrection.toml")))
			-- Native registration adds NBSP/NNBSP aliases to these three spaced
			-- triggers. Name the six expectations explicitly, independently of
			-- the production variant builder or the captured source reader.
			local aliases = {
				["azure devops"] = { "azure" .. utf8.char(0xA0) .. "devops", "azure" .. utf8.char(0x202F) .. "devops" },
				["data science"] = { "data" .. utf8.char(0xA0) .. "science", "data" .. utf8.char(0x202F) .. "science" },
				["data scientist"] = { "data" .. utf8.char(0xA0) .. "scientist", "data" .. utf8.char(0x202F) .. "scientist" },
			}
			local mappings, owned_count = {}, 0
			for _, mapping in ipairs(state.mappings) do
				if mapping.group == expected.category then
					helpers.assert_eq(mapping.section, assignment[mapping.trigger:gsub(utf8.char(0xA0), " "):gsub(utf8.char(0x202F), " ")])
					helpers.assert_nil(mappings[mapping.trigger], "duplicate owned native registration")
					mappings[mapping.trigger] = mapping
					owned_count = owned_count + 1
				end
			end
			helpers.assert_eq(owned_count, ({ names = 36, abbreviations = 95, technical_terms = 15 })[only] or 146, "independent section counts include exactly the owned aliases")
			helpers.assert_eq(#state.mappings, baseline_count + owned_count)
			assert_foreign_preserved()
			local function assert_mapping(actual, row, trigger, sequence)
				helpers.assert_true(actual ~= nil, "the native registry keeps " .. trigger)
				helpers.assert_eq(actual.trigger, trigger)
				helpers.assert_eq(actual.group, expected.category)
				helpers.assert_eq(actual.section, assignment[row.trigger])
				helpers.assert_eq(actual.repl, row.output)
				helpers.assert_eq(actual.is_word, row.is_word)
				helpers.assert_eq(actual.auto, row.auto_expand)
				helpers.assert_eq(actual.final_result, row.final_result)
				helpers.assert_eq(actual.is_private, false)
				helpers.assert_eq(actual.match_mode, "fold")
				helpers.assert_eq(actual.priority, expected.source_priority)
				helpers.assert_eq(actual.seq, sequence, "registration order is part of collision precedence")
			end
			local alias_count, canonical_count = 0, 0
			for _, row in ipairs(expected.entries) do
				if only == nil or assignment[row.trigger] == only then
				local sequence = baseline_seq + canonical_count + 1 + alias_count
				assert_mapping(mappings[row.trigger], row, row.trigger, sequence)
				canonical_count = canonical_count + 1
				for index, trigger in ipairs(aliases[row.trigger] or {}) do
					assert_mapping(mappings[trigger], row, trigger, sequence + index)
					alias_count = alias_count + 1
				end
				end
			end
			helpers.assert_eq(canonical_count, ({ names = 34, abbreviations = 95, technical_terms = 11 })[only] or 140)
			helpers.assert_eq(alias_count, ({ names = 2, abbreviations = 0, technical_terms = 4 })[only] or 6)
			helpers.assert_eq(state.groups.autocorrection.delay_metadata.delay, expected.meta.delay)
			local Expander = helpers.load_with_stubs("modules.keymap.expander")
			helpers.assert_true(Expander.init(state, Registry, {}))
			for _, case in ipairs({
				{ section = "names", trigger = "chatgpt", output = "ChatGPT" },
				{ section = "abbreviations", trigger = "api", output = "API" },
				{ section = "technical_terms", trigger = "adaboost", output = "AdaBoost" },
			}) do
				local mapping = mappings[case.trigger]
				if only == nil or only == case.section then
					helpers.assert_true(mapping ~= nil)
					helpers.assert_eq(Expander.would_fire(mapping, case.trigger), case.output,
						"the actual native expander keeps each independently expected result")
				else
					helpers.assert_nil(mapping, "unselected families expose no candidate to the native expander")
				end
			end
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_true(Storage.set("hotstrings_section_autocorrection_" .. section, false))
			end
			helpers.assert_true(Registry.reload_toml("autocorrection", helpers.shared("modules/hotstrings/autocorrection.toml")))
			helpers.assert_eq(#state.mappings, baseline_count, "disabled current families remove their canonical rules and native aliases only")
			for _, mapping in ipairs(state.mappings) do
				helpers.assert_true(mapping.group ~= expected.category, "the complete disabled section stays absent")
			end
			assert_foreign_preserved()
		end)
end

helpers.describe("common autocorrection shipped split registry", function()
	helpers.it("(common-autocorrection-split) registers all three families in independent historical order", function() shipped_split_registry(nil) end)
	for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
		helpers.it("(common-autocorrection-split) registers and disables only " .. section, function() shipped_split_registry(section) end)
	end
end)

helpers.describe("common autocorrection cold boot receipts", function()
	helpers.it("(common-autocorrection-split) rejects false, nil and raising native cold loaders without advertising their sources", function()
		local Boot = require("infra.common_hotstrings_boot")
		for _, load in ipairs({ function() return false end, function() return nil end,
			function() error("private source bytes must never escape the receipt") end }) do
			local files, paths = { "previous" }, { previous = "proven" }
			local receipt = Boot.load({ load_toml = load }, "autocorrection", "private-path", nil, files, paths)
			helpers.assert_eq(receipt, { committed = false, complete = false, unavailable = { "autocorrection" } })
			helpers.assert_eq(files, { "previous" })
			helpers.assert_eq(paths, { previous = "proven" })
		end
	end)

	helpers.it("(common-autocorrection-split) routes every actual root cold TOML loop through admitted boot receipts", function()
		local code = assert(helpers.read_driver_unit('local common_file_count = 0')):gsub("%-%-[^\n]*", "")
		local start = assert(code:find('local CommonHotstringsBoot = require("infra.common_hotstrings_boot")', 1, true))
		local finish = assert(code:find('Logger.info(LOG, string.format("Loaded %d TOML hotstring file(s)', start, true))
		local loops = code:sub(start, finish - 1)
		local function consumes_receipts(source)
			local _, calls = source:gsub("CommonHotstringsBoot%.load%(", "")
			return calls == 3 and not source:find("keymap.load_toml", 1, true)
				and not source:find("table.insert(hotfiles", 1, true)
				and not source:find("hotfile_paths[name] =", 1, true)
				and not source:find("hotfile_paths[route.category] =", 1, true)
		end
		helpers.assert_true(consumes_receipts(loops), "common, language and unbundled routes consume the native result")
		helpers.assert_eq(consumes_receipts(loops:gsub("CommonHotstringsBoot%.load", "keymap.load_toml", 1)), false)
		helpers.assert_eq(consumes_receipts(loops .. "\ntable.insert(hotfiles, name)"), false)
		helpers.assert_true(code:find("common_file_count, language_file_count", finish, true) ~= nil,
			"the successful-source count excludes refused cold registrations")
	end)
end)
