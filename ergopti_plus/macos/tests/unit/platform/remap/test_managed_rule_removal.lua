--- tests/unit/platform/remap/test_managed_rule_removal.lua

--- ==============================================================================
--- MODULE: Managed-Rule Removal Tests
--- DESCRIPTION:
--- « Ergopti uses Karabiner » off must leave no ErgoptiPlus rule in
--- karabiner.json while every personal rule stays byte-identical: the removal
--- cuts exact spans instead of re-encoding the user's file, and refuses any
--- document it cannot prove.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"adapters.file_system",
	"adapters.json_codec",
	"platform.remap.lease_contract",
	"platform.remap.managed_rule_removal",
}

local TOKEN = "0123456789abcdef0123456789abcdef"
local MANAGED_A = '{"description": "[ErgoptiPlus managed:' .. TOKEN .. ':normal] Caps Lock",'
	.. ' "manipulators": [{"type": "basic", "from": {"key_code": "caps_lock"}}]}'
local MANAGED_B = '{"description":"[ErgoptiPlus managed:' .. TOKEN .. ':pause] Paused control",'
	.. '"manipulators":[]}'
-- Personal rules spelled in ways a decode/re-encode round trip would change:
-- key order, number spelling, escapes, compact and indented layouts
local PERSONAL_1 = '{ "manipulators":[ {"type":"basic","from":{"key_code":"a"},'
	.. '"parameters":{"basic.to_if_alone_timeout_milliseconds":1.0e2}} ],\n'
	.. '        "description" : "Mine \\u00e9 \\/ 1.50" }'
local PERSONAL_2 = '{\n\t"description": "[ErgoptiPlus managed:not-a-token:normal] lookalike",\n'
	.. '\t"manipulators": []\n}'
local PERSONAL_3 = '{"description":"Inactive profile personal","manipulators":[]}'

--- Builds a karabiner.json whose selected profile interleaves managed and
--- personal rules and whose inactive profile holds a stale managed rule.
--- @return string document
local function sample_document()
	return '{\n'
		.. '  "global" : { "show_in_menu_bar": false },\n'
		.. '  "profiles": [\n'
		.. '    {\n'
		.. '      "name": "Default", "selected": true,\n'
		.. '      "complex_modifications": {\n'
		.. '        "parameters": { "basic.simultaneous_threshold_milliseconds": 50 },\n'
		.. '        "rules": [\n'
		.. '          ' .. MANAGED_A .. ',\n'
		.. '          ' .. PERSONAL_1 .. ',\n'
		.. '          ' .. MANAGED_B .. ' ,\n'
		.. '          ' .. PERSONAL_2 .. '\n'
		.. '        ]\n'
		.. '      }\n'
		.. '    },\n'
		.. '    {"name":"Other","complex_modifications":{"rules":[' .. MANAGED_B .. ','
		.. PERSONAL_3 .. ']}}\n'
		.. '  ]\n'
		.. '}\n'
end

--- Counts plain occurrences of a needle.
--- @param haystack string Text.
--- @param needle string Exact substring.
--- @return integer count
local function count_plain(haystack, needle)
	local count, cursor = 0, 1
	while true do
		local at = haystack:find(needle, cursor, true)
		if not at then return count end
		count = count + 1
		cursor = at + #needle
	end
end

--- Loads the remover over an in-memory karabiner.json.
--- @param content string|nil Current file bytes; nil means absent.
--- @param write_result boolean|nil Result of the conditional writer.
--- @return table remover
--- @return table calls
local function load_remover(content, write_result)
	local calls = { writes = {}, reads = 0 }
	package.loaded["adapters.file_system"] = {
		read_with_status = function()
			calls.reads = calls.reads + 1
			if content == nil then return nil, "absent" end
			return content, "ok"
		end,
		write_if_unchanged = function(path, bytes, expected_source)
			calls.writes[#calls.writes + 1] = { path = path, bytes = bytes, expected = expected_source }
			if write_result == false then return false, "source changed" end
			return true
		end,
	}
	package.loaded["adapters.json_codec"] = nil
	package.loaded["platform.remap.lease_contract"] = nil
	local remover = helpers.load_with_stubs("platform.remap.managed_rule_removal")
	return remover, calls
end

helpers.describe("Managed-rule removal keeps personal rules byte-identical", function()
	helpers.it("cuts every marked rule in every profile and nothing else", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover = load_remover(nil)
			local original = sample_document()
			local stripped, removed = remover.strip_managed_rules(original)
			helpers.assert_true(type(stripped) == "string", "the sample must be accepted: " .. tostring(removed))
			helpers.assert_eq(removed, 3, "two selected-profile rules and one inactive-profile rule")
			helpers.assert_eq(count_plain(stripped, "[ErgoptiPlus managed:" .. TOKEN), 0,
				"no exactly marked rule may survive")
			for _, personal in ipairs({ PERSONAL_1, PERSONAL_2, PERSONAL_3 }) do
				helpers.assert_eq(count_plain(stripped, personal), 1,
					"a personal rule must survive byte for byte: " .. personal)
			end
			helpers.assert_eq(count_plain(stripped, '"global" : { "show_in_menu_bar": false }'), 1,
				"bytes outside the rule arrays are untouched")
			helpers.assert_eq(count_plain(stripped,
				'"parameters": { "basic.simultaneous_threshold_milliseconds": 50 }'), 1)
			local decoded = hs.json.decode(stripped)
			helpers.assert_true(type(decoded) == "table", "the result must stay valid JSON")
			helpers.assert_eq(#decoded.profiles[1].complex_modifications.rules, 2)
			helpers.assert_eq(#decoded.profiles[2].complex_modifications.rules, 1)
		end)
	end)

	helpers.it("returns the exact input when no rule is marked", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover = load_remover(nil)
			local personal_only = '{"profiles":[{"selected":true,"complex_modifications":{"rules":['
				.. PERSONAL_1 .. ',' .. PERSONAL_2 .. ']}}]}'
			local stripped, removed = remover.strip_managed_rules(personal_only)
			helpers.assert_eq(removed, 0)
			helpers.assert_true(rawequal(stripped, personal_only) or stripped == personal_only)
		end)
	end)

	helpers.it("leaves a valid empty array when every rule was Ergopti's", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover = load_remover(nil)
			local stripped, removed = remover.strip_managed_rules(
				'{"profiles":[{"complex_modifications":{"rules":[ ' .. MANAGED_A .. ' , ' .. MANAGED_B .. ' ]}}]}')
			helpers.assert_eq(removed, 2)
			helpers.assert_eq(stripped, '{"profiles":[{"complex_modifications":{"rules":[ ]}}]}')
		end)
	end)

	helpers.it("refuses documents it cannot prove instead of guessing", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover = load_remover(nil)
			local refused = {
				'{"profiles":[{"complex_modifications":{"rules":[' .. MANAGED_A .. ',]}}]}',
				'{"profiles":[{"complex_modifications":{"rules":[],"rules":[' .. MANAGED_A .. ']}}]}',
				'{"profiles":[{"complex_modifications":{"rules":[' .. MANAGED_A .. ',"text"]}}]}',
				'{"profiles":[{"complex_modifications":{"rules":[' .. MANAGED_A .. ']}}]} trailing',
				'{"profiles":{"complex_modifications":{"rules":[' .. MANAGED_A .. ']}}}',
				'[' .. MANAGED_A .. ']',
			}
			for _, document in ipairs(refused) do
				local stripped, reason = remover.strip_managed_rules(document)
				helpers.assert_nil(stripped, "must refuse: " .. document)
				helpers.assert_type(reason, "string")
			end
		end)
	end)
end)

helpers.describe("Managed-rule removal publishes only a proven change", function()
	helpers.it("writes the stripped bytes against the exact scanned source", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local original = sample_document()
			local remover, calls = load_remover(original)
			local ok, detail, removed = remover.remove_managed_rules("/Users/me/.config/karabiner/karabiner.json")
			helpers.assert_eq(ok, true)
			helpers.assert_eq(detail, "removed")
			helpers.assert_eq(removed, 3)
			helpers.assert_eq(#calls.writes, 1)
			helpers.assert_eq(calls.writes[1].expected.status, "ok")
			helpers.assert_eq(calls.writes[1].expected.content, original,
				"publication must be conditional on the exact bytes that were scanned")
			helpers.assert_eq(count_plain(calls.writes[1].bytes, PERSONAL_1), 1)
		end)
	end)

	helpers.it("never writes when the file is absent, clean or unprovable", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover, calls = load_remover(nil)
			local ok, detail = remover.remove_managed_rules("/k.json")
			helpers.assert_eq(ok, true)
			helpers.assert_eq(detail, "absent")
			helpers.assert_eq(#calls.writes, 0)

			remover, calls = load_remover('{"profiles":[{"complex_modifications":{"rules":[' .. PERSONAL_3 .. ']}}]}')
			ok, detail = remover.remove_managed_rules("/k.json")
			helpers.assert_eq(ok, true)
			helpers.assert_eq(detail, "unchanged")
			helpers.assert_eq(#calls.writes, 0)

			remover, calls = load_remover('{"profiles": [ {')
			ok = remover.remove_managed_rules("/k.json")
			helpers.assert_eq(ok, false, "malformed JSON must be refused")
			helpers.assert_eq(#calls.writes, 0)
		end)
	end)

	helpers.it("reports a refused conditional write as a failure", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local remover, calls = load_remover(sample_document(), false)
			local ok, detail, removed = remover.remove_managed_rules("/k.json")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("source changed", 1, true) ~= nil)
			helpers.assert_eq(removed, 0)
			helpers.assert_eq(#calls.writes, 1)
		end)
	end)
end)
