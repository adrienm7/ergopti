--- tests/unit/modules/llm/test_agent_providers_round.lua

--- ==============================================================================
--- MODULE: AI Agent over Jev, Backboard and the Prediction Tooltip (macOS)
--- DESCRIPTION:
--- Runs the automatic mode over the real runner, shared logic, prediction
--- engine and remote backend (tests/support/agent_world.lua), with the HTTP
--- transport faked:
--- - System 1 through a decisions provider (TypeSafe's Jev) posts Jev's choice
---   question about the app and the sentence to the provider's full endpoint,
---   with a Bearer key, and triages from its answer, with or without `choice`;
--- - System 1 through Backboard with a "typesafe/" model sends the questions in
---   system_one and reads the answers wherever Backboard put them, logging
---   where; when they are nowhere, it logs the reply's top-level keys only;
--- - System 2 through Backboard is a plain Backboard message;
--- - an automatic next-word prediction no longer holds the automatic mode back:
---   its tooltip is replaced by the agent's actions.
---
--- ROOT CAUSES ENCODED:
--- 1. The prediction tooltip appears about 500 ms after the last keystroke,
---    before the agent's 900 ms pause: "no other AI tooltip" blocked the
---    automatic mode almost every time.
--- 2. Jev is not a chat model: sending it the triage prompt could never work.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local World = require("tests.support.agent_world")

local Agent = require("llm.agent")
local Formats = require("llm.remote_formats")

local CONFIG = World.CONFIG
local SENTENCE = "Rappelle-moi d'appeler Paul demain à 9h"
local REMINDER = 'ACTIONS: [{"type":"reminder","title":"Appeler Paul","due":"2026-09-30T09:00"}]'
local STATE = "App: Notes\nText: " .. SENTENCE

local CATALOGUE = (function()
	local fh = assert(io.open(helpers.shared("modules/llm/api_providers.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end)()

--- Builds an automatic-mode world whose API entries hold a Jev key and a
--- Backboard key beside the Cerebras one, and records the agent's log lines.
--- @param options table Overrides of World.build_world.
--- @return table world
local function auto_world(options)
	options.mode = "auto"
	local world = World.build_world(options)
	local api = require("modules.llm").api_remote
	api.set_entries({
		{ id = "agent-cerebras", provider = "cerebras", token = "agent-token", model = World.MODEL },
		{ id = "jev", provider = "typesafe", token = "jev-key", model = "jev-latest" },
		{ id = "bb", provider = "backboard", token = "bb-key", model = "openai/gpt-4o-mini" },
		{ id = "or-jev", provider = "openrouter_jev", token = "or-key" },
	})
	api.set_active_entry_id("agent-cerebras")
	-- New entries retire the readiness the world set: the backend is warm again
	local _, ready_index = World.get_upvalue(api.is_ready, "_is_ready")
	debug.setupvalue(api.is_ready, ready_index, true)
	world.logs = {}
	local Logger = package.loaded["infra.logger"]
	for _, level in ipairs({ "info", "warn" }) do
		Logger[level] = function(_, fmt, ...)
			world.logs[#world.logs + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	return world
end

--- The log lines of one level holding a text.
local function logged(world, level, text)
	for _, line in ipairs(world.logs) do
		if line.level == level and line.text:find(text, 1, true) then return line.text end
	end
	return nil
end

--- Types a sentence and lets the typing pause elapse.
local function pause_after(world, buffer)
	world.runner.observe_typing(buffer)
	World.settle(world)
end

--- Answers a captured request with a JSON body.
local function reply(post, body)
	post.callback({ ok = true, status = 200, body = json.encode(body), headers = {} })
end

local JEV_ANSWERS = { intent = { type = "choice", choice = "reminder",
	probabilities = { none = 0.05, calendar = 0.03, reminder = 0.9, mail = 0.01, shortcut = 0.01 } } }

helpers.describe("AI agent System 1 through Jev (macOS)", function()
	helpers.it("asks a decisions provider Jev's question, then wakes System 2", function()
		local world = auto_world({ system1 = "typesafe" })
		pause_after(world, "Bonjour. " .. SENTENCE)
		helpers.assert_eq(#world.posts, 1, "one System 1 request")
		local post = world.posts[1]
		helpers.assert_eq(post.url, CATALOGUE.providers.typesafe.base_url, "the full endpoint")
		helpers.assert_eq(post.headers.Authorization, "Bearer jev-key")
		helpers.assert_eq(json.encode(post.body),
			json.encode(Formats.decisions_body("jev-latest", STATE, Agent.jev_questions(CONFIG))))

		reply(post, { answers = JEV_ANSWERS })
		helpers.assert_eq(#world.posts, 2, "System 2 is asked")
		helpers.assert_eq(world.posts[2].url, "https://api.cerebras.ai/v1/chat/completions")
		World.answer(world.posts[2], REMINDER)
		helpers.assert_eq(world.renders[#world.renders].texts[1], "⏰ Appeler Paul — 2026-09-30 09:00")
	end)

	helpers.it("reads the most probable intent when Jev names no choice", function()
		local world = auto_world({ system1 = "openrouter_jev" })
		pause_after(world, SENTENCE)
		helpers.assert_eq(world.posts[1].url, CATALOGUE.providers.openrouter_jev.base_url)
		helpers.assert_eq(world.posts[1].body.model, CATALOGUE.providers.openrouter_jev.default_model)
		reply(world.posts[1], { answers = { intent = { probabilities = { none = 0.2, reminder = 0.8 } } } })
		helpers.assert_eq(#world.posts, 2, "0.8 for reminder clears the threshold")

		local low = auto_world({ system1 = "typesafe" })
		pause_after(low, SENTENCE)
		reply(low.posts[1], { answers = { intent = { choice = "none", probabilities = { none = 0.95 } } } })
		helpers.assert_eq(#low.posts, 1, "none wakes nothing")
	end)

	helpers.it("asks Jev through Backboard and reads each answer location", function()
		local locations = {
			system_one = { system_one = { answers = JEV_ANSWERS } },
			answers = { answers = JEV_ANSWERS },
			content = { content = json.encode({ answers = JEV_ANSWERS }) },
		}
		for where, body in pairs(locations) do
			local world = auto_world({ system1 = "backboard|typesafe/jev-1.13" })
			pause_after(world, SENTENCE)
			helpers.assert_eq(world.posts[1].url, CATALOGUE.providers.backboard.base_url .. "/assistants")
			helpers.assert_eq(world.posts[1].headers["X-API-Key"], "bb-key")
			reply(world.posts[1], { assistant_id = "asst-" .. where })
			local message = world.posts[2]
			helpers.assert_eq(message.url, CATALOGUE.providers.backboard.base_url .. "/threads/messages")
			helpers.assert_eq(message.body.llm_provider, "typesafe")
			helpers.assert_eq(message.body.model_name, "jev-1.13")
			helpers.assert_eq(message.body.content, STATE)
			helpers.assert_eq(message.body.system_prompt, "")
			helpers.assert_eq(json.encode(message.body.system_one.questions), json.encode(Agent.jev_questions(CONFIG)),
				"the questions travel in system_one")
			reply(message, body)
			helpers.assert_true(logged(world, "info", "answers read from '" .. where .. "'") ~= nil,
				where .. ": the location is logged")
			helpers.assert_eq(#world.posts, 3, where .. ": System 2 is asked")
		end
	end)

	helpers.it("logs only the top-level keys when Backboard returns no answers", function()
		local world = auto_world({ system1 = "backboard|typesafe/jev-1.13" })
		pause_after(world, SENTENCE)
		reply(world.posts[1], { assistant_id = "asst-x" })
		reply(world.posts[2], { thread_id = "t-1", content = "private words", status = "done" })
		local line = logged(world, "warn", "no answers in the reply")
		helpers.assert_true(line ~= nil, "a warning names the reply")
		helpers.assert_true(line:find("content, status, thread_id", 1, true) ~= nil, "its top-level keys: " .. line)
		helpers.assert_nil(line:find("private words", 1, true), "never its content")
		helpers.assert_eq(#world.posts, 2, "nothing is woken")
	end)

	helpers.it("uses the chat triage for any other Backboard model, and Backboard for System 2", function()
		local world = auto_world({ system1 = "backboard", system2 = "backboard" })
		pause_after(world, SENTENCE)
		reply(world.posts[1], { assistant_id = "asst-chat" })
		local triage = world.posts[2]
		helpers.assert_nil(triage.body.system_one, "no Jev questions")
		helpers.assert_eq(triage.body.system_prompt, Agent.system1_prompt(CONFIG, { app = "Notes", tools = { "Mode focus" } }))
		helpers.assert_eq(triage.body.content, SENTENCE)
		reply(triage, { content = "INTENT: reminder\nPROBABILITY: 0.9" })
		helpers.assert_eq(#world.posts, 3, "System 2 reuses the assistant: no second creation")
		helpers.assert_eq(world.posts[3].url, CATALOGUE.providers.backboard.base_url .. "/threads/messages")
		helpers.assert_eq(world.posts[3].body.content, Agent.system2_user_text(CONFIG, SENTENCE))
		reply(world.posts[3], { content = REMINDER })
		helpers.assert_eq(world.renders[#world.renders].texts[1], "⏰ Appeler Paul — 2026-09-30 09:00")
	end)
end)

--- Captures the prediction backend's requests too.
--- @param world table
local function capture_predictions(world)
	world.predictions = {}
	local api = require("modules.llm").api_remote
	local client = World.get_upvalue(api.cancel_streaming, "_infer_client")
	assert(type(client) == "table", "the prediction client must be reachable")
	client.post = function(url, headers, body, callback)
		world.predictions[#world.predictions + 1] = { url = url, headers = headers, body = json.decode(body),
			callback = callback }
		return true
	end
	local state = World.get_upvalue(world.engine.perform_check, "_state")
	assert(type(state) == "table", "the engine state must be reachable")
	world.state = state
end

--- Fires the agent's pause timer alone, leaving the prediction's own timers.
--- @param world table
local function fire_pause(world)
	local delay = CONFIG.system1.pause_ms / 1000
	for index = world.timer_baseline + 1, #_G.hs.timer.__timers do
		local timer = _G.hs.timer.__timers[index]
		if timer.running and timer.fired == 0 and timer.delay == delay then
			timer:fire()
			return
		end
	end
	error("the agent's pause timer is not armed")
end

helpers.describe("AI agent over the automatic prediction (macOS)", function()
	helpers.it("triages while a prediction is shown, and its actions replace that tooltip", function()
		local world = auto_world({ system1 = "cerebras" })
		capture_predictions(world)
		world.runner.observe_typing(SENTENCE)
		world.state.llm_buffer = SENTENCE
		world.engine.perform_check(false)
		helpers.assert_eq(#world.predictions, 1, "the automatic prediction is requested")
		helpers.assert_eq(world.engine.ai_activity(), "automatic")
		World.answer(world.predictions[1], "et confirmer le devis")
		helpers.assert_eq(world.engine.is_visible(), true, "the prediction tooltip is shown")
		local prediction_renders = #world.renders

		fire_pause(world)
		helpers.assert_eq(#world.posts, 1, "the prediction tooltip does not hold System 1 back")
		World.answer(world.posts[1], "INTENT: reminder\nPROBABILITY: 0.9")
		helpers.assert_eq(#world.posts, 2, "System 2 is asked")
		World.answer(world.posts[2], REMINDER)
		helpers.assert_true(#world.renders > prediction_renders, "the agent paints")
		local last = world.renders[#world.renders]
		helpers.assert_eq(#last.texts, 1)
		helpers.assert_eq(last.texts[1], "⏰ Appeler Paul — 2026-09-30 09:00", "the actions replace the prediction")
		helpers.assert_eq(world.engine.ai_activity(), "explicit", "the tooltip is the agent's now")
	end)

	helpers.it("triages while the prediction request is still in flight", function()
		local world = auto_world({ system1 = "cerebras" })
		capture_predictions(world)
		world.runner.observe_typing(SENTENCE)
		world.state.llm_buffer = SENTENCE
		world.engine.perform_check(false)
		fire_pause(world)
		helpers.assert_eq(#world.posts, 1, "an automatic request in flight does not hold System 1 back")
	end)

	helpers.it("still waits for an explicit AI action and a hotstring tooltip", function()
		local world = auto_world({ system1 = "cerebras" })
		capture_predictions(world)
		world.runner.observe_typing(SENTENCE)
		world.state.llm_buffer = SENTENCE
		world.engine.perform_check(true)
		helpers.assert_eq(world.engine.ai_activity(), "explicit", "a forced prediction is explicit")
		fire_pause(world)
		helpers.assert_eq(#world.posts, 0, "an explicit prediction holds the agent back")

		local covered = auto_world({ system1 = "cerebras" })
		covered.hotstring_visible = true
		pause_after(covered, SENTENCE)
		helpers.assert_eq(#covered.posts, 0, "a hotstring tooltip holds the agent back")
	end)

	helpers.it("runs with the AI menu off", function()
		local world = auto_world({ system1 = "cerebras" })
		world.engine.set_llm_enabled(false)
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 1, "the automatic mode does not use the AI menu")
	end)
end)
