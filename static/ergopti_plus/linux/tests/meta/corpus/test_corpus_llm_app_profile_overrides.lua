--- tests/meta/corpus/test_corpus_llm_app_profile_overrides.lua

--- ==============================================================================
--- MODULE: Per-Application Profile Overrides Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/app_profile_overrides_vectors.json through
--- the shared llm.app_profile_overrides module the Linux prediction engine uses
--- to choose a profile for the focused application. The macOS suite replays the
--- same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local path = helpers.driver_root() .. "/../_shared/tests/corpus/llm/app_profile_overrides_vectors.json"
local handle = assert(io.open(path, "rb"), "cannot open " .. path)
local corpus = Json.decode_lossless(handle:read("*a"))
handle:close()

--- A decoded JSON value that is absent or null.
local function absent(value)
	return value == nil or Json.is_null(value)
end

--- The same entries in two maps.
local function same_map(actual, expected)
	for key, value in pairs(expected) do
		helpers.assert_eq(actual[key], value, "entry " .. key)
	end
	for key in pairs(actual) do
		helpers.assert_true(expected[key] ~= nil, "unexpected entry " .. tostring(key))
	end
end

helpers.describe("per-application profile overrides corpus: the shared rule on Linux", function()
	local Overrides = require("llm.app_profile_overrides")

	helpers.it("app-override corpus is readable", function()
		helpers.assert_true(type(corpus) == "table" and #corpus.normalize > 0 and #corpus.resolve > 0
			and #corpus.decode > 0 and #corpus.encode > 0, "every section must hold vectors")
	end)

	for index, case in ipairs(corpus.normalize) do
		helpers.it("app-override normalize " .. index, function()
			local actual = Overrides.normalize_app(case.input)
			if absent(case.expected) then helpers.assert_nil(actual) else helpers.assert_eq(actual, case.expected) end
		end)
	end

	for _, case in ipairs(corpus.resolve) do
		helpers.it("app-override resolve " .. case.id, function()
			local app = (not absent(case.app)) and case.app or nil
			helpers.assert_eq(Overrides.resolve(case.overrides, app, case.default), case.expected)
		end)
	end

	for _, case in ipairs(corpus.decode) do
		helpers.it("app-override decode " .. case.id, function()
			local overrides, reason = Overrides.decode(case.payload)
			if case.refused then
				helpers.assert_nil(overrides)
				helpers.assert_true(type(reason) == "string" and reason:find(case.refused, 1, true) ~= nil,
					"refusal must say '" .. case.refused .. "', said: " .. tostring(reason))
			else
				helpers.assert_true(overrides ~= nil, "must be read: " .. tostring(reason))
				same_map(overrides, case.expected)
			end
		end)
	end

	for _, case in ipairs(corpus.encode) do
		helpers.it("app-override encode " .. case.id, function()
			local payload, reason = Overrides.encode(case.overrides)
			helpers.assert_eq(payload, case.expected, tostring(reason))
			if payload ~= "" then same_map(Overrides.decode(payload), case.overrides) end
		end)
	end

	helpers.it("app-override edits return copies and refuse unusable input", function()
		local base = { slack = "formal" }
		local added = Overrides.with(base, "Code.exe", "basic")
		helpers.assert_eq(added.code, "basic")
		helpers.assert_nil(base.code, "the map in force is untouched")
		local removed = Overrides.without(added, "CODE")
		helpers.assert_nil(removed.code)
		helpers.assert_eq(added.code, "basic")
		local refused, reason = Overrides.with(base, "", "basic")
		helpers.assert_nil(refused)
		helpers.assert_true(type(reason) == "string")
		helpers.assert_nil((Overrides.with(base, "code", "")))
	end)
end)
