--- tests/unit/modules/llm/vectors/test_thinking_off_vectors.lua

--- ==============================================================================
--- MODULE: Thinking-Off Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/thinking_off_vectors.json through the
--- shared resolver (_shared/lua/llm/thinking_off.lua), which macOS and Linux
--- use and the AutoHotkey port replays too: glob matching, the deep merge, the
--- shipped rules of every provider and the refusal of a malformed list.
---
--- ROOT CAUSE ENCODED:
--- Only Cerebras' default model had its reasoning turned off: every other
--- cloud model a user picked (gpt-5.x, the o-series, Claude 5, Gemini 2.5 and
--- 3, Grok, Qwen3 on Groq...) spent the small prediction budget thinking and
--- answered late or not at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local ThinkingOff = require("llm.thinking_off")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
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

helpers.describe("thinking_off replays the shared corpus (thinking-off-everywhere)", function()
	local corpus = read_json("tests/corpus/llm/thinking_off_vectors.json")
	local providers = read_json("modules/llm/api_providers.json").providers

	helpers.it("the corpus covers every format with a rule", function()
		helpers.assert_true(#corpus.provider_vectors >= 40, "the corpus must hold its provider vectors")
	end)

	for _, v in ipairs(corpus.glob_vectors) do
		helpers.it("glob '" .. v.glob .. "' against '" .. v.model .. "'", function()
			helpers.assert_eq(ThinkingOff.matches(v.glob, v.model), v.match, v.glob .. " / " .. v.model)
		end)
	end

	for _, v in ipairs(corpus.merge_vectors) do
		helpers.it("merge vector '" .. v.id .. "'", function()
			local ok, why = deep_equal(ThinkingOff.merge(v.body, v.fields), v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.provider_vectors) do
		helpers.it("provider vector '" .. v.id .. "'", function()
			local rules, reason = ThinkingOff.parse(providers[v.provider].thinking_off)
			helpers.assert_true(rules ~= nil, v.provider .. ": " .. tostring(reason))
			local index = ThinkingOff.apply(rules, v.model, v.body)
			helpers.assert_eq(index, v.rule, v.id .. ": rule index")
			local ok, why = deep_equal(v.body, v.expected)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end

	for _, v in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. v.id .. "'", function()
			local rules = ThinkingOff.parse(v.thinking_off)
			helpers.assert_eq(rules ~= nil, v.valid, v.id)
		end)
	end

	helpers.it("a merged rule shares no table with the catalogue", function()
		local rules = ThinkingOff.parse({ { models = { "m" }, fields = { a = { b = 1 } } } })
		local body = {}
		ThinkingOff.apply(rules, "m", body)
		body.a.b = 2
		helpers.assert_eq(rules[1].fields.a.b, 1, "the rule keeps its value")
	end)
end)
