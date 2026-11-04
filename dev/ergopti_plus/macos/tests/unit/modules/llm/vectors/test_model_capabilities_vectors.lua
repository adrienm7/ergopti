--- tests/unit/modules/llm/vectors/test_model_capabilities_vectors.lua

--- ==============================================================================
--- MODULE: Model Capabilities Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/model_capabilities_vectors.json through the
--- shared module (_shared/lua/llm/model_capabilities.lua) and the thinking-off
--- resolver, which macOS and Linux use and the AutoHotkey port replays too:
--- recorded OpenRouter, Anthropic and Gemini listings, the controls they say
--- a model lacks, the request bodies that follow, and the listing cache.
---
--- ROOT CAUSE ENCODED:
--- A control a model does not take went out anyway and came back as an HTTP
--- 400, then a retry: the listing that says so was never read.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local ThinkingOff = require("llm.thinking_off")
local Caps = require("llm.model_capabilities")

--- @param path string Absolute JSON path (helpers.shared).
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

--- Compares two decoded JSON values structurally.
--- @return boolean equal, string|nil where
local function deep_equal(a, b, where)
	where = where or "$"
	if type(a) ~= type(b) then return false, where .. ": " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then return a == b, a == b and nil or (where .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
	for k, v in pairs(a) do
		local ok, why = deep_equal(v, b[k], where .. "." .. tostring(k))
		if not ok then return false, why end
	end
	for k in pairs(b) do
		if a[k] == nil then return false, where .. "." .. tostring(k) .. " is missing" end
	end
	return true
end

--- Counts a table's keys.
--- @param t table
--- @return integer
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("model_capabilities replays the shared corpus (thinking-off-capabilities)", function()
	local corpus = read_json(helpers.shared("tests/corpus/llm/model_capabilities_vectors.json"))
	local providers = read_json(helpers.shared("modules/llm/api_providers.json")).providers
	local raw_families = read_json(helpers.shared("modules/llm/thinking_off.json"))
	local families = assert(ThinkingOff.parse_families(raw_families))

	--- The records of one recorded listing answer.
	local function records(listing)
		return assert(Caps.parse(listing, corpus.answers[listing]))
	end

	helpers.it("the shipped configuration names a listing for each recorded answer", function()
		for provider, listing in pairs(families.capability.providers) do
			helpers.assert_true(corpus.answers[listing] ~= nil, provider .. " has a recorded " .. listing .. " answer")
		end
		helpers.assert_eq(families.capability.ttl_sec, raw_families.capability_listing.ttl_hours * 3600, "ttl in seconds")
	end)

	for _, v in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. v.id .. "'", function()
			local parsed, reason = Caps.parse(v.listing, corpus.answers[v.answer])
			helpers.assert_eq(reason, v.reason, v.id .. ": reason")
			if v.models then helpers.assert_eq(count(parsed), v.models, v.id .. ": models kept") end
		end)
	end

	for _, v in ipairs(corpus.lacks_vectors) do
		helpers.it("lacks vector " .. v.listing .. " " .. v.model .. " " .. v.kind, function()
			local record = Caps.record(records(v.listing), v.model)
			helpers.assert_eq(Caps.lacks(record, v.kind, v.level, v.fields), v.lacks, v.model .. " " .. v.kind)
		end)
	end

	for _, v in ipairs(corpus.resolve_vectors) do
		helpers.it("resolve vector '" .. v.id .. "'", function()
			local listing = families.capability.providers[v.provider]
			local record = Caps.record(records(listing), v.model)
			local dialect = assert(ThinkingOff.parse_dialect(providers[v.provider].thinking_dialect))
			local _, kind = ThinkingOff.apply(families, dialect, v.model, v.body, nil, function(k, level, template)
				return Caps.lacks(record, k, level, template)
			end)
			helpers.assert_eq(kind, v.kind, v.id .. ": kind")
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.cache_vectors) do
		helpers.it("cache vector '" .. v.id .. "'", function()
			local cache, ttl = {}, families.capability.ttl_sec
			for index, step in ipairs(v.steps) do
				local where = v.id .. " step " .. index
				if step.op == "needs" then
					helpers.assert_eq(Caps.needs_fetch(cache, "p", step.now, ttl), step.expect, where)
				elseif step.op == "begin" then
					Caps.begin(cache, "p")
				elseif step.op == "finish" then
					Caps.finish(cache, "p", step.listing and records(step.listing) or nil, step.now)
				else
					helpers.assert_eq(count(Caps.records(cache, "p") or {}), step.models, where)
				end
			end
		end)
	end

	helpers.it("a listing keeps at most MAX_MODELS models", function()
		local data = {}
		for i = 1, Caps.MAX_MODELS + 5 do data[i] = { id = "m" .. i, supported_parameters = {} } end
		helpers.assert_eq(count(Caps.parse("openrouter", { data = data })), Caps.MAX_MODELS, "bounded")
	end)
end)
