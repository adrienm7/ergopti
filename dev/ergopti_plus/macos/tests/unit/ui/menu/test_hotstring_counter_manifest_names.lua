--- tests/unit/ui/menu/test_hotstring_counter_manifest_names.lua

--- ==============================================================================
--- MODULE: Extension Manifest Metadata Regression Tests
--- DESCRIPTION:
--- Compares real preview and shared discovery metadata, including failed parses
--- that must remain retryable without publishing a successful count cache.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")
local Extensions = require("hotstrings.extensions")

local function scan(content)
	return Extensions.scan({ "/extensions" }, {
		list_dirs = function() return { "/extensions/demo" } end,
		list_files = function() return { "/extensions/demo/hotstrings/demo.toml" } end,
		read_file = function() return content end,
	})
end

helpers.describe("extension manifest metadata parity", function()
	helpers.it("(manifest-input) distinguishes absent metadata from a refused read result", function()
		helpers.assert_nil(Extensions.parse_name(nil))
		local ok, failure = pcall(scan, false)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(failure):find("Invalid extension manifest input", 1, true) ~= nil)
	end)
	for index, case in ipairs({
		{ '[extension]\nname = "Demo"', "Demo" },
		{ '[extension]\n\tname  =  "Indented" # comment', "Indented" },
		{ '# name = "Decoy"\n[extension]\nname = "Real"', "Real" },
		{ 'name = "Decoy"\n[extension]\nname = "Real"', "Real" },
		{ '[other]\nname = "Decoy"\n[extension]\nname = "Real"', "Real" },
		{ '[extension]\nname = "Quoted\\\"Name"', 'Quoted"Name' },
		{ '[extension]\nname = "Path\\\\Name"', 'Path\\Name' },
		{ '[extension]\nname = "\\u00C9xtension"', 'Éxtension' },
		{ "[extension]\nname = 'Literal name'", "Literal name" },
		{ '[extension]\nid = "demo"', "demo" },
	}) do
		helpers.it("(manifest-name-parity) preserves canonical name " .. index, function()
			with_counter(function(counter, state, context)
				state.target, state.manifest_content = "manifest", case[1]
				local discovered = scan(case[1])
				helpers.assert_eq(discovered[1].name, case[2])
				local counts = counter.count_all(context, {})
				helpers.assert_eq(counts.ext_details[1].name, case[2])
				helpers.assert_eq(counts.ext, 1)
				helpers.assert_eq(counter.count_all(context, {}).ext_details[1].name, case[2])
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
			end)
		end)
	end

	for index, content in ipairs({
		'[extension]\nname = "PRIVATE_DETAIL\\q"',
		'[extension]\nname = "PRIVATE_DETAIL',
		'[extension]\nname = "A"\nname = "B"',
		'[extension]\nname = true',
		'extension = false',
		'[[extension]]\nname = "Present"',
		'[extension]\nname = "Demo"\ndescription = 42',
		'[extension]\nname = "Demo"\ndescription = { en = 42 }',
	}) do
		helpers.it("(manifest-parse-retry) refuses invalid metadata and retries " .. index, function()
			with_counter(function(counter, state, context)
				state.target, state.manifest_content = "manifest", content
				local ok, failure = pcall(scan, content)
				helpers.assert_eq(ok, false)
				helpers.assert_true(not tostring(failure):find("PRIVATE_DETAIL", 1, true))
				for _ = 1, 2 do
					ok, failure = pcall(counter.count_all, context, {})
					helpers.assert_eq(ok, false)
					helpers.assert_true(not tostring(failure):find("PRIVATE_DETAIL", 1, true))
				end
				helpers.assert_eq(state.opens, 2)
				helpers.assert_eq(state.closes, 2)
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_true(not table.concat(state.errors):find("PRIVATE_DETAIL", 1, true))
				state.manifest_content = '[extension]\nname = "Repaired"'
				helpers.assert_eq(counter.count_all(context, {}).ext_details[1].name, "Repaired")
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 3)
				helpers.assert_eq(state.closes, 3)
			end)
		end)
	end

	helpers.it("(manifest-descriptions) preserves escaped localized values and section ownership", function()
		local content = '# description = { en = "Decoy" }\n[extension]\n'
			.. 'name = "Demo"\ndescription = { en = "A\\\"B", fr = "\\u00C9", "fr-CA" = "Locale" }'
		local expected = { en = 'A"B', fr = "É", ["fr-CA"] = "Locale" }
		helpers.assert_eq(Extensions.parse_descriptions(content), expected)
		helpers.assert_eq(scan(content)[1].descriptions, expected)
	end)
end)
