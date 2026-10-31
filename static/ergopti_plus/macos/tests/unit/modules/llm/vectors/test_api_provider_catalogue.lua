--- tests/unit/modules/llm/vectors/test_api_provider_catalogue.lua

--- ==============================================================================
--- MODULE: API Provider Catalogue Coverage (macOS)
--- DESCRIPTION:
--- Checks every concrete provider of _shared/modules/llm/api_providers.json
--- against the shared corpora: an https base_url, a default model, a thinking
--- dialect its wire format can carry, a thinking-off vector for its default
--- model (thinking_off_vectors.json) and a listing recorded from the provider
--- (api_model_listing_vectors.json ids, replayed by the three drivers) or the
--- reason none was recorded. The Linux suite runs the same checks.
---
--- ROOT CAUSE ENCODED:
--- A provider could join the catalogue with an address, a default model and
--- a dialect that nothing checked: its default model's reasoning and its
--- model listing were only seen working on a user's machine.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local ThinkingOff = require("llm.thinking_off")
local UrlTemplate = require("llm.api_url_template")
local TokenExchange = require("llm.api_token_exchange")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end




-- ============================================
-- ======= 1/ Catalogue coverage ==============
-- ============================================

--- The shipped thinking dialect kinds an OpenAI-format body can carry: Vertex
--- AI takes the Gemini levels (minimal, low) as reasoning_effort.
local OPENAI_KINDS = { toggle = true, effort = true, gemini_level = true }
-- The wire formats whose providers chat and list their models.
local CHAT_FORMATS = { openai = true, anthropic = true, gemini = true }

--- Whether a list of strings holds a value.
local function holds(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

helpers.describe("api_providers.json: every concrete provider is usable and covered", function()
	local catalogue = read_json("modules/llm/api_providers.json")
	local thinking = read_json("tests/corpus/llm/thinking_off_vectors.json")
	local listing = read_json("tests/corpus/llm/api_model_listing_vectors.json")
	local unlisted = listing.unlisted_providers or {}

	--- The listing vectors recorded from one provider.
	local function fixtures(id)
		local found = {}
		for _, vector in ipairs(listing.ids) do
			if vector.provider == id then found[#found + 1] = vector end
		end
		return found
	end

	helpers.it("provider_order names every provider once, and every label differs", function()
		local seen, labels = {}, {}
		for _, id in ipairs(catalogue.provider_order) do
			helpers.assert_nil(seen[id], "listed twice: " .. id)
			seen[id] = true
			local desc = catalogue.providers[id]
			helpers.assert_true(type(desc) == "table", "unknown provider " .. id)
			helpers.assert_true(type(desc.label) == "string" and desc.label ~= "", id .. ": a label")
			helpers.assert_nil(labels[desc.label], id .. ": label shared with " .. tostring(labels[desc.label]))
			labels[desc.label] = id
		end
		for id in pairs(catalogue.providers) do helpers.assert_true(seen[id], id .. " is not in provider_order") end
	end)

	for _, id in ipairs(catalogue.provider_order) do
		local desc = catalogue.providers[id]
		if CHAT_FORMATS[desc.format] and id ~= "openai_compat" then
			-- A per-account address is a template the add-entry form fills; its model is the user's
			local fields, malformed = UrlTemplate.fields(desc.base_url)
			local per_account = #fields > 0
			helpers.it(id .. ": an https base_url, a default model and a dialect its format carries", function()
				helpers.assert_true(desc.base_url:match("^https://[^%s]*[^/%s]$") ~= nil,
					id .. ": https, no trailing slash: " .. desc.base_url)
				helpers.assert_nil(malformed, id .. ": template")
				if per_account then
					helpers.assert_eq(desc.default_model, "", id .. ": the model of a per-account provider is the user's")
				else
					helpers.assert_true(type(desc.default_model) == "string" and desc.default_model ~= "", id .. ": default model")
				end
				local _, auth_problem = TokenExchange.parse(desc.auth)
				helpers.assert_nil(auth_problem, id .. ": auth block")
				local dialect, problem = ThinkingOff.parse_dialect(desc.thinking_dialect)
				helpers.assert_true(dialect ~= nil, id .. ": " .. tostring(problem))
				if desc.format == "openai" then
					for kind in pairs(dialect) do
						helpers.assert_true(OPENAI_KINDS[kind], id .. ": an OpenAI body cannot carry " .. kind)
					end
				end
			end)

			helpers.it(id .. ": its default model, or any model of a per-account provider, has a thinking-off vector", function()
				local found = false
				for _, vector in ipairs(thinking.resolve_vectors) do
					if vector.provider == id and (per_account or vector.model == desc.default_model) then found = true end
				end
				helpers.assert_true(found, id .. ": no resolve vector for " .. desc.default_model)
			end)

			helpers.it(id .. ": a recorded listing holding its default model, or the reason it has none", function()
				local recorded = fixtures(id)
				local reason = unlisted[id]
				if #recorded == 0 then
					helpers.assert_true(type(reason) == "string" and reason ~= "", id .. ": no listing fixture and no reason")
					return
				end
				helpers.assert_nil(reason, id .. ": a listing fixture and an unlisted reason")
				for _, vector in ipairs(recorded) do
					helpers.assert_eq(vector.format, desc.format, vector.name .. ": format")
					helpers.assert_true(type(vector.source) == "string" and vector.source ~= "", vector.name .. ": source")
					helpers.assert_true(per_account or holds(vector.expect, desc.default_model),
						vector.name .. ": lists " .. desc.default_model)
				end
			end)
		end
	end

	helpers.it("every fixture and every unlisted reason names a shipped provider", function()
		for _, vector in ipairs(listing.ids) do
			if vector.provider ~= nil then
				helpers.assert_true(catalogue.providers[vector.provider] ~= nil, vector.name .. ": unknown provider")
			end
		end
		for id in pairs(unlisted) do
			if id:sub(1, 1) ~= "_" then helpers.assert_true(catalogue.providers[id] ~= nil, "unlisted: unknown " .. id) end
		end
	end)
end)
