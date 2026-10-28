--- tests/unit/modules/llm/vectors/test_api_model_listing_vectors.lua

--- ==============================================================================
--- MODULE: API Model Listing Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/api_model_listing_vectors.json through the
--- shared listing plan (_shared/lua/llm/api_model_listing.lua) the model
--- selector page draws its API rows with; Linux and the AutoHotkey port replay
--- it too.
---
--- ROOT CAUSE ENCODED:
--- Windows and Linux listed only the configured model of an API entry while
--- macOS listed the provider's models: a refused or unreachable listing left
--- one row and no reason, and the three drivers had no rule in common.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Listing = require("llm.api_model_listing")

local CORPUS = helpers.shared("tests/corpus/llm/api_model_listing_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the listing corpus is not valid JSON")
end

--- Whether a decoded JSON value is null: the decoder reads null as an empty
--- table, and no expectation of the corpus is an empty list or object.
local function is_null(value) return value == nil or (type(value) == "table" and next(value) == nil) end

--- Compares a plan with the corpus expectation.
local function assert_plan(plan, expect, name)
	helpers.assert_eq(#plan.models, #expect.models, name .. ": row count")
	for index, row in ipairs(expect.models) do
		helpers.assert_eq(plan.models[index].model, row.model, name .. ": row " .. index)
		helpers.assert_eq(plan.models[index].listed, row.listed, name .. ": listed " .. index)
	end
	if is_null(expect.typed) then
		helpers.assert_nil(plan.typed, name .. ": no typed row")
	else
		helpers.assert_eq(plan.typed and plan.typed.hint_key, expect.typed.hint_key, name .. ": typed hint")
	end
end

helpers.describe("api model listing replays the shared corpus", function()
	local corpus = read_corpus()

	helpers.it("the corpus pins the bounds and holds both families", function()
		helpers.assert_eq(Listing.MAX_MODELS, corpus.max_models)
		helpers.assert_eq(Listing.MAX_ID_LENGTH, corpus.max_id_length)
		helpers.assert_eq(Listing.MAX_ENTRIES, corpus.max_entries)
		helpers.assert_true(#corpus.ids >= 6, "id vectors")
		helpers.assert_true(#corpus.plans >= 8, "plan vectors")
		helpers.assert_true(#corpus.names >= 5, "name vectors")
	end)

	for _, vector in ipairs(corpus.ids) do
		helpers.it("ids: " .. vector.name, function()
			local ids, reason = Listing.model_ids(vector.format, vector.body)
			if is_null(vector.expect) then
				helpers.assert_nil(ids, vector.name)
				helpers.assert_eq(reason, vector.reason, vector.name)
				return
			end
			helpers.assert_eq(table.concat(ids, ","), table.concat(vector.expect, ","), vector.name)
		end)
	end

	for _, vector in ipairs(corpus.names) do
		helpers.it("names: " .. vector.name, function()
			local base, suffix = Listing.name_parts(vector.name, vector.model)
			helpers.assert_eq(base, vector.base, vector.name)
			helpers.assert_eq(suffix, vector.suffix, vector.name)
		end)
	end

	for _, vector in ipairs(corpus.plans) do
		helpers.it("plan: " .. vector.name, function()
			local listing = not is_null(vector.listing) and vector.listing or nil
			assert_plan(Listing.plan(vector.view, listing), vector.expect, vector.name)
		end)
	end

	helpers.it("a listing keeps at most MAX_MODELS ids and refuses an overlong one", function()
		local data = { { id = string.rep("x", Listing.MAX_ID_LENGTH + 1) } }
		for index = 1, Listing.MAX_MODELS + 5 do data[#data + 1] = { id = string.format("m%03d", index) } end
		local ids = Listing.model_ids("openai", { data = data })
		helpers.assert_eq(#ids, Listing.MAX_MODELS)
		helpers.assert_eq(ids[1], "m001")
	end)
end)
