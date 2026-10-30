--- tests/unit/modules/llm/vectors/test_thinking_off_vectors.lua

--- ==============================================================================
--- MODULE: Thinking-Off Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/thinking_off_vectors.json through the
--- shared resolver (_shared/lua/llm/thinking_off.lua) under the Linux runtime
--- (LuaJIT in CI), as the macOS suite and the AutoHotkey port do: glob matching, the deep merge, the
--- shipped rules of every provider and the refusal of a malformed list.
---
--- ROOT CAUSE ENCODED:
--- Only Cerebras' default model had its reasoning turned off: every other
--- model a user picked (gpt-5.x, the o-series, Claude 5, Gemini 2.5 and 3,
--- Grok, Qwen3 on any provider...) spent the small prediction budget thinking
--- and answered late or not at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"

local ThinkingOff = require("llm.thinking_off")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(SHARED .. path, "r"), "cannot open " .. path)
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




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

--- Sorted dotted form of added paths, for an order-free comparison.
--- @param added table Array of paths.
--- @return string
local function paths(added)
	local out = {}
	for _, path in ipairs(added) do out[#out + 1] = table.concat(path, ".") end
	table.sort(out)
	return table.concat(out, ",")
end

--- Decoded array of strings as a set.
local function set(list)
	local out = {}
	for _, name in ipairs(list or {}) do out[name] = true end
	return out
end

helpers.describe("thinking_off replays the shared corpus (thinking-off-everywhere)", function()
	local corpus = read_json("tests/corpus/llm/thinking_off_vectors.json")
	local providers = read_json("modules/llm/api_providers.json").providers
	local families = assert(ThinkingOff.parse_families(read_json("modules/llm/thinking_off.json")))

	--- The shipped dialect of a provider.
	local function dialect(provider)
		return assert(ThinkingOff.parse_dialect(providers[provider].thinking_dialect))
	end

	helpers.it("the corpus covers the families on every provider", function()
		helpers.assert_true(#corpus.resolve_vectors >= 40, "the corpus must hold its resolve vectors")
	end)

	for _, v in ipairs(corpus.normalize_vectors) do
		helpers.it("normalize '" .. v.model .. "'", function()
			helpers.assert_eq(ThinkingOff.normalize(v.model), v.normalized, v.model)
		end)
	end

	for _, v in ipairs(corpus.glob_vectors) do
		helpers.it("glob '" .. v.glob .. "' against '" .. v.model .. "'", function()
			helpers.assert_eq(ThinkingOff.matches(v.glob, v.model), v.match, v.glob .. " / " .. v.model)
		end)
	end

	for _, v in ipairs(corpus.merge_vectors) do
		helpers.it("merge vector '" .. v.id .. "'", function()
			local added = ThinkingOff.merge(v.body, v.fields)
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
			helpers.assert_eq(paths(added), paths(v.added), v.id .. ": added paths")
		end)
	end

	for _, v in ipairs(corpus.resolve_vectors) do
		helpers.it("resolve vector '" .. v.id .. "'", function()
			local family, kind, added = ThinkingOff.apply(families, dialect(v.provider), v.model, v.body)
			helpers.assert_eq(family, v.family, v.id .. ": family")
			helpers.assert_eq(kind, v.kind, v.id .. ": kind")
			helpers.assert_eq(paths(added), paths(v.added), v.id .. ": added paths")
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.refusal_vectors) do
		helpers.it("refusal vector '" .. v.id .. "'", function()
			local _, _, added = ThinkingOff.apply(families, dialect(v.provider), v.model, v.body)
			local field = ThinkingOff.refused_field(v.status, v.message, added)
			helpers.assert_eq(field, v.field, v.id .. ": refused field")
			if field then ThinkingOff.strip(v.body, added, field) end
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.refused_vectors) do
		helpers.it("refused vector '" .. v.id .. "'", function()
			local family, kind = ThinkingOff.apply(families, dialect(v.provider), v.model, v.body, set(v.refused))
			helpers.assert_eq(family, v.family, v.id .. ": family")
			helpers.assert_eq(kind, v.kind, v.id .. ": kind")
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.family_parse_vectors) do
		helpers.it("family parse vector '" .. v.id .. "'", function()
			helpers.assert_eq(ThinkingOff.parse_families(v.table) ~= nil, v.valid, v.id)
		end)
	end

	for _, v in ipairs(corpus.dialect_parse_vectors) do
		helpers.it("dialect parse vector '" .. v.id .. "'", function()
			helpers.assert_eq(ThinkingOff.parse_dialect(v.dialect) ~= nil, v.valid, v.id)
		end)
	end

	for _, v in ipairs(corpus.sampling_vectors) do
		helpers.it("sampling vector '" .. v.model .. "'", function()
			helpers.assert_eq(ThinkingOff.default_sampling_only(families, v.model), v.default_sampling_only, v.model)
		end)
	end

	for _, v in ipairs(corpus.refusal_store_vectors) do
		helpers.it("refusal store vector '" .. v.id .. "'", function()
			local refused, dropped = ThinkingOff.refusals_parse(v.stored, v.now, families.expiry_sec)
			helpers.assert_eq(dropped, v.dropped, v.id .. ": dropped")
			local ok, why = deep_equal(refused, v.refused)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	helpers.it("the refusal store is bounded", function()
		local refused = {}
		for i = 1, ThinkingOff.MAX_REFUSALS do
			helpers.assert_true(ThinkingOff.record_refusal(refused, "p", "m" .. i, "thinking", 1))
		end
		helpers.assert_eq(ThinkingOff.record_refusal(refused, "p", "one-more", "thinking", 1), false, "a full store refuses a new pair")
		helpers.assert_true(ThinkingOff.record_refusal(refused, "p", "m1", "reasoning", 1), "a known pair still records")
	end)

	helpers.it("every shipped dialect parses", function()
		for id, provider in pairs(providers) do
			helpers.assert_true(ThinkingOff.parse_dialect(provider.thinking_dialect) ~= nil, id)
		end
	end)

	helpers.it("a merged field shares no table with the catalogue", function()
		local fields = { a = { b = 1 } }
		local body = {}
		ThinkingOff.merge(body, fields)
		body.a.b = 2
		helpers.assert_eq(fields.a.b, 1, "the template keeps its value")
	end)
end)
