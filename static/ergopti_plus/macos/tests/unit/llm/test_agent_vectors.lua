--- tests/unit/llm/test_agent_vectors.lua

--- ==============================================================================
--- MODULE: AI Agent Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/agent_vectors.json through the shared agent
--- helpers (_shared/lua/llm/agent.lua), which macOS and Linux use and the
--- AutoHotkey port replays too: the System 1 and System 2 prompts, the triage of
--- a chat model and of Jev, the local times, the validation of the actions a
--- model proposes, their labels and the files the connectors hand to the system.
--- ==============================================================================

local helpers = require("tests.helpers")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local json = require("json")
local Agent = require("llm.agent")
local Vision = require("llm.vision")

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

--- Asserts a triage equals its vector ({absent = true} for none).
local function assert_triage(actual, expected, id)
	if expected.absent then
		helpers.assert_nil(actual, id)
	else
		helpers.assert_true(actual ~= nil, id .. " must be readable")
		helpers.assert_eq(actual.intent, expected.intent, id .. ": intent")
		helpers.assert_eq(actual.probability, expected.probability, id .. ": probability")
	end
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("agent helpers replay the shared agent corpus", function()
	local corpus = read_json("tests/corpus/llm/agent_vectors.json")
	local config = read_json("modules/llm/agent.json")

	for _, v in ipairs(corpus.system1_prompt) do
		helpers.it("system1 prompt '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.system1_prompt(config, v.ctx), v.prompt, v.id)
		end)
	end
	for _, v in ipairs(corpus.system2_prompt) do
		helpers.it("system2 prompt '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.system2_prompt(config, v.ctx), v.prompt, v.id)
		end)
	end
	for _, v in ipairs(corpus.system2_user_text) do
		helpers.it("system2 user text '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.system2_user_text(config, v.text), v.user_text, v.id)
		end)
	end
	for _, v in ipairs(corpus.system1_answers) do
		helpers.it("system1 answer '" .. v.id .. "'", function()
			assert_triage(Agent.parse_system1(config, v.raw), v.triage, v.id)
		end)
	end
	for _, v in ipairs(corpus.jev_answers) do
		helpers.it("jev answer '" .. v.id .. "'", function()
			assert_triage(Agent.parse_jev(config, v.response), v.triage, v.id)
		end)
	end
	for _, v in ipairs(corpus.jev_questions) do
		helpers.it("jev questions '" .. v.id .. "'", function()
			local ok, why = deep_equal(Agent.jev_questions(config), v.questions)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end
	for _, v in ipairs(corpus.should_act) do
		helpers.it("should act '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.should_act(v.triage, v.threshold), v.act, v.id)
		end)
	end
	for _, v in ipairs(corpus.datetimes) do
		helpers.it("datetime '" .. v.id .. "'", function()
			local minutes = Agent.parse_datetime(v.text)
			helpers.assert_eq(minutes ~= nil, v.expected.valid, v.id)
			if minutes then helpers.assert_eq(Agent.format_datetime(minutes), v.expected.round_trip, v.id) end
		end)
	end
	for _, v in ipairs(corpus.datetime_add) do
		helpers.it("datetime add '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.format_datetime(Agent.parse_datetime(v.text) + v.minutes), v.result, v.id)
		end)
	end
	for _, v in ipairs(corpus.actions) do
		helpers.it("actions '" .. v.id .. "'", function()
			local actions, rejected = Agent.parse_actions(config, v.raw, json.decode_lossless,
				{ tools = corpus.tools, is_null = json.is_null })
			helpers.assert_eq(actions ~= nil, v.expected.readable, v.id .. ": readable")
			if actions then
				local ok, why = deep_equal(actions, v.expected.actions)
				helpers.assert_true(ok, v.id .. ": " .. tostring(why))
				helpers.assert_eq(#rejected, v.expected.rejected, v.id .. ": rejected")
			end
		end)
	end
	for _, v in ipairs(corpus.labels) do
		helpers.it("label '" .. v.id .. "'", function()
			local key, args = Agent.label(v.action)
			helpers.assert_eq(key, v.expected.key, v.id)
			local ok, why = deep_equal(args, v.expected.args)
			helpers.assert_true(ok, v.id .. ": " .. tostring(why))
		end)
	end
	for _, v in ipairs(corpus.ics) do
		helpers.it("ics '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.ics(config, v.action, v.uid, v.stamp), v.ics, v.id)
		end)
	end
	for _, v in ipairs(corpus.mailto) do
		helpers.it("mailto '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.mailto(v.action), v.url, v.id)
		end)
	end
	for _, v in ipairs(corpus.applescript) do
		helpers.it("applescript '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.applescript_string(v.text), v.literal, v.id)
		end)
	end
	for _, v in ipairs(corpus.resolve_model) do
		helpers.it("resolve model '" .. v.id .. "'", function()
			local providers = read_json("modules/llm/api_providers.json")
			helpers.assert_eq(Agent.resolve_model(Vision.parse(v.value), config, providers), v.expected.model, v.id)
		end)
	end
	for _, v in ipairs(corpus.learn) do
		helpers.it("learn '" .. v.id .. "'", function()
			helpers.assert_eq(Agent.learn(config, v.threshold, v.accepted), v.threshold_after, v.id)
		end)
	end
end)




-- ============================================
-- ======= 2/ Safety invariants ===============
-- ============================================

helpers.describe("agent actions stay inside the closed schema", function()
	helpers.it("refuses a type, a field or a shortcut the schema does not name", function()
		local config = read_json("modules/llm/agent.json")
		local opts = { tools = { "Mode focus" }, is_null = json.is_null }
		local _, unknown_type = Agent.validate_action(config, { type = "shell", command = "rm -rf /" }, opts)
		helpers.assert_contains(unknown_type, "unknown type")
		local _, unknown_field = Agent.validate_action(config, { type = "reminder", title = "x", run = "y" }, opts)
		helpers.assert_contains(unknown_field, "unknown field")
		local _, foreign_tool = Agent.validate_action(config, { type = "shortcut", name = "Erase disk" }, opts)
		helpers.assert_contains(foreign_tool, "not one of the user's tools")
	end)
end)
