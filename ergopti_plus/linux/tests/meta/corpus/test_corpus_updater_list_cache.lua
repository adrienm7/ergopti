--- tests/meta/corpus/test_corpus_updater_list_cache.lua

--- ==============================================================================
--- MODULE: Updater List Copy Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/updater/list_cache_vectors.json through the
--- shared updater.list_cache module that manager.lua uses to decide whether a
--- release-list copy read back from Storage may be sent as a conditional
--- request again. The macOS suite replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local corpus_path = helpers.driver_root() .. "/../_shared/tests/corpus/updater/list_cache_vectors.json"

local handle = assert(io.open(corpus_path, "r"), "cannot open corpus at " .. corpus_path)
local corpus = require("json").decode(handle:read("*a"))
handle:close()

local function load_module()
	package.loaded["updater.list_cache"] = nil
	return require("updater.list_cache")
end

helpers.describe("updater list copy corpus: the shared validation on Linux", function()
	helpers.it("corpus is readable and has cases", function()
		helpers.assert_true(type(corpus) == "table" and type(corpus.cases) == "table" and #corpus.cases > 0,
			"the corpus must hold cases")
		helpers.assert_eq(corpus.max_body_bytes, load_module().MAX_BODY_BYTES,
			"the corpus and the module agree on the bound")
	end)

	for _, case in ipairs(corpus.cases) do
		helpers.it("vector " .. case.id, function()
			local stored = case.stored
			if type(stored) == "table" and stored.body_repeat then
				stored.body = stored.body_repeat.prefix .. string.rep(stored.body_repeat.unit, stored.body_repeat.count)
				stored.body_repeat = nil
			end
			local copy, reason = load_module().validate(stored, case.expected_url)
			if case.valid then
				helpers.assert_true(copy ~= nil, "must be admitted: " .. tostring(reason))
				helpers.assert_eq(copy.url, stored.url)
				helpers.assert_eq(copy.etag, stored.etag)
				helpers.assert_eq(copy.body, stored.body)
			else
				helpers.assert_nil(copy)
				helpers.assert_true(type(reason) == "string" and reason:find(case.reason_contains, 1, true) ~= nil,
					"refusal must say '" .. case.reason_contains .. "', said: " .. tostring(reason))
			end
		end)
	end
end)
