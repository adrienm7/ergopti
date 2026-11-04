-- _shared/lua/test/llm_engine_transcript.lua

--- ==============================================================================
--- MODULE: Shared Engine Transcript Runner
--- DESCRIPTION:
--- Runs the end-to-end prediction transcripts of
--- _shared/tests/corpus/llm/request_plan_engine_transcripts.json against a
--- driver's real prediction engine, whose three ports (TimerScheduler,
--- HttpClient, TooltipRenderer) are replaced by recording fakes, and compares the
--- calls the engine made on those ports with the calls the corpus lists.
---
--- FEATURES & RATIONALE:
--- 1. The same events in, the same port calls out: a scenario is a list of steps
---    (a keystroke, elapsed time, a provider answer, live mode on, a deleted
---    prompt) and the list of port calls it must cause. Both drivers replay it
---    unchanged, so a driver that arms another delay, asks for another budget or
---    draws another info bar fails on its own port calls.
--- 2. A driver supplies a world: with_world(config, body) builds the engine on
---    fake ports and passes body an object with keystroke, elapse, answer,
---    toggle_live, delete_prompt, calls and base_tokens. The calls it records are
---    already normalized to the corpus vocabulary, so the engines' own timers
---    (watchdogs, spinners) never enter the comparison: only the timers of the
---    scenario's watch list do.
--- 3. Numbers that depend on a driver's settings are symbolic in the corpus
---    ("base", "batch:2", "rewrite") and resolved here from the shared token
---    budget, so a change to the shared rule moves every driver at once.
--- ==============================================================================

local TokenBudget = require("llm.request_plan.token_budget")
local Rewrite = require("llm.rewrite")

local Json = require("json")

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

local function read_json(path)
	local file = assert(io.open(path, "r"), "cannot open " .. path)
	local content = file:read("*a")
	assert(file:close())
	return assert(Json.decode(content), path .. " is not valid JSON")
end

--- Resolves a symbolic token budget of the corpus.
--- @param world table The driver's world (base_tokens).
--- @param symbol string "base", "batch:N" or "rewrite".
--- @param buffer string The last buffer typed.
--- @return number tokens
local function resolve_tokens(world, symbol, buffer)
	if symbol == "base" then return world.base_tokens(buffer) end
	if symbol == "rewrite" then return Rewrite.max_tokens(buffer) end
	local count = symbol:match("^batch:(%d+)$")
	if count then return TokenBudget.for_call(world.base_tokens(buffer), tonumber(count)) end
	error("unknown token symbol: " .. tostring(symbol))
end

--- Turns the corpus' expected calls into concrete ones.
--- @param world table (model_label, profile_label, base_tokens)
--- @param expected table The scenario's expected calls.
--- @param buffer string The last buffer typed.
--- @return table calls
local function concrete(world, expected, buffer)
	local calls = {}
	for index, call in ipairs(expected) do
		local copy = {}
		for key, value in pairs(call) do copy[key] = value end
		if type(copy.max_tokens) == "string" then copy.max_tokens = resolve_tokens(world, copy.max_tokens, buffer) end
		if copy.info then
			local info = {}
			for position, part in ipairs(copy.info) do
				local profile = part:match("^%$profile:(.+)$")
				if part == "$model" then
					info[position] = world.model_label
				elseif profile then
					info[position] = world.profile_label(profile)
				else
					info[position] = part
				end
			end
			copy.info = info
		end
		calls[index] = copy
	end
	return calls
end

--- Registers the transcripts of the corpus.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Path of request_plan_engine_transcripts.json.
--- @param with_world function with_world(config, body): runs body(world) on a fresh engine.
function M.run(helpers, corpus_path, with_world)
	local corpus = read_json(corpus_path)
	helpers.describe("Shared engine transcripts through the three ports", function()
		for _, scenario in ipairs(corpus.scenarios) do
			helpers.it("scenario '" .. scenario.id .. "'", function()
				with_world(scenario.config, function(world)
					local buffer = ""
					for _, step in ipairs(scenario.steps) do
						if step.keystroke then
							buffer = step.keystroke
							world.keystroke(buffer)
						elseif step.elapse_ms then
							world.elapse(step.elapse_ms)
						elseif step.answer then
							world.answer(step.answer.request, step.answer.text)
						elseif step.toggle_live then
							helpers.assert_eq(world.toggle_live(step.toggle_live), true, "live mode turns on")
						elseif step.delete_prompt then
							world.delete_prompt(step.delete_prompt)
						else
							error("unknown step in scenario " .. scenario.id)
						end
					end
					helpers.assert_eq(world.calls(), concrete(world, scenario.expect, buffer),
						"port calls of " .. scenario.id .. ": " .. Json.encode(world.calls()))
				end)
			end)
		end
	end)
end

return M
