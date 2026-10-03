--- tests/unit/meta/test_common_autocorrection_reference.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Historical Reference (macOS)
--- DESCRIPTION:
--- Pins the real TOML reader and registry to an independent pre-split corpus.
--- Classification is data only; every saved preference still names caps.
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
		local path = helpers.shared("modules/hotstrings/autocorrection.toml")
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
			helpers.assert_true(Registry.reload_toml("autocorrection", helpers.shared("modules/hotstrings/autocorrection.toml")))
			helpers.assert_eq(#state.mappings, baseline_count, "caps disables its canonical rules and native aliases only")
			for _, mapping in ipairs(state.mappings) do
				helpers.assert_true(mapping.group ~= expected.category, "the complete disabled section stays absent")
			end
			assert_foreign_preserved()
		end)
	end)
end)
