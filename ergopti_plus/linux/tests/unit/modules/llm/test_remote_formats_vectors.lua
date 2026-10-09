--- tests/unit/modules/llm/test_remote_formats_vectors.lua

--- ==============================================================================
--- MODULE: Remote API Formats Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/remote_formats_vectors.json through the
--- shared request and answer shapes of the "backboard" and "decisions" provider
--- formats (_shared/lua/llm/remote_formats.lua), which macOS and Linux use and
--- the AutoHotkey port replays too.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local Formats = require("llm.remote_formats")
local Agent = require("llm.agent")

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

--- Asserts a value equals its vector, {absent = true} standing for nil.
local function assert_shape(actual, expected, id)
	if expected.absent then
		helpers.assert_nil(actual, id)
		return
	end
	local ok, why = deep_equal(actual, expected)
	helpers.assert_true(ok, id .. ": " .. tostring(why))
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("remote formats replay the shared corpus", function()
	local corpus = read_json("tests/corpus/llm/remote_formats_vectors.json")
	local agent = read_json("modules/llm/agent.json")

	helpers.it("key headers", function()
		local v = corpus.headers[1].expected
		helpers.assert_eq(Formats.BACKBOARD_KEY_HEADER, v.backboard)
		helpers.assert_eq(Formats.DECISIONS_KEY_HEADER, v.decisions)
		helpers.assert_eq(Formats.decisions_key_value("k"), v.bearer)
	end)
	for _, v in ipairs(corpus.split_model) do
		helpers.it("split model '" .. v.id .. "'", function()
			local provider, name = Formats.backboard_split_model(v.model)
			assert_shape(provider and { provider = provider, name = name } or nil, v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.assistant_request) do
		helpers.it("assistant request '" .. v.id .. "'", function()
			assert_shape(Formats.backboard_assistant_request(v.base_url), v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.assistant_id) do
		helpers.it("assistant id '" .. v.id .. "'", function()
			local id = Formats.backboard_assistant_id(v.response)
			assert_shape(id and { id = id } or nil, v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.message_request) do
		helpers.it("message request '" .. v.id .. "'", function()
			assert_shape(Formats.backboard_message_request(v.base_url, v.spec), v.expected, v.id)
		end)
	end
	helpers.it("the Jev message carries the agent's triage question", function()
		for _, v in ipairs(corpus.message_request) do
			if v.id == "jev" then
				local ok, why = deep_equal(v.spec.questions, Agent.jev_questions(agent))
				helpers.assert_true(ok, tostring(why))
			end
		end
	end)
	for _, v in ipairs(corpus.text) do
		helpers.it("text '" .. v.id .. "'", function()
			local text = Formats.backboard_text(v.response)
			assert_shape(text and { text = text } or nil, v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.decision_answers) do
		helpers.it("backboard decision answers '" .. v.id .. "'", function()
			local answers, where = Formats.backboard_decision_answers(v.response, json.decode)
			assert_shape(answers and { answers = answers, where = where } or nil, v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.decisions_body) do
		helpers.it("decisions body '" .. v.id .. "'", function()
			assert_shape(Formats.decisions_body(v.model, v.state, Agent.jev_questions(agent)), v.expected, v.id)
		end)
	end
	for _, v in ipairs(corpus.decisions_answers) do
		helpers.it("decisions answers '" .. v.id .. "'", function()
			local answers = Formats.decisions_answers(v.response)
			assert_shape(answers and { answers = answers } or nil, v.expected, v.id)
		end)
	end
end)
