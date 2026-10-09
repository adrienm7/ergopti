--- tests/unit/modules/llm/test_ai_agent_local_model.lua

--- ==============================================================================
--- MODULE: AI Agent Local Model (macOS)
--- DESCRIPTION:
--- Runs the agent on the local backend (Ollama) over the real runner, shared
--- logic, prediction engine and local transport (tests/support/agent_world.lua):
--- the model a System names must be one the local server lists before any
--- chat request is sent, a missing one is named with a Download button that
--- hands it to the AI menu's download owner, and a failed answer logs the
--- server's own error.
---
--- ROOT CAUSES ENCODED:
--- 1. "local" without a model resolves to agent.json's default_models.local
---    (qwen2.5:7b), which nothing ever pulls: the agent posted it blindly and
---    Ollama answered HTTP 404 {"error":"model 'qwen2.5:7b' not found"}.
--- 2. The transport logged the empty transport error instead of that body, and
---    the user only read "The agent could not answer", with nothing to press.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")

local CONFIG = World.CONFIG
local SELECTION = World.SELECTION
local DEFAULT_MODEL = CONFIG.default_models["local"]
local TWO_ACTIONS = World.TWO_ACTIONS
local build_world, trigger = World.build_world, World.trigger

--- Answers a captured local chat request with a model's text.
--- @param post table
--- @param content string
local function answer_local(post, content)
	post.callback({ ok = true, status = 200, body = require("json").encode({ message = { content = content } }) })
end

--- Answers a captured local chat request with an HTTP failure.
--- @param post table
--- @param status number
--- @param body string
local function fail_local(post, status, body)
	post.callback({ ok = false, status = status, body = body, error = "", headers = {} })
end

--- Asserts that no log line holds the private selection.
--- @param world table
local function assert_selection_never_logged(world)
	for _, line in ipairs(world.logs) do
		helpers.assert_true(not line.text:find(SELECTION, 1, true), "a log line holds the selection: " .. line.text)
	end
end

helpers.describe("AI agent local model (ai-agent-local-model)", function()
	helpers.it("(ai-agent-local-model) sends nothing before the local server lists the model, then posts it", function()
		helpers.assert_eq(DEFAULT_MODEL, "qwen2.5:7b", "agent.json's local default, the model of the report")
		local world = build_world({ system2 = "local" })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 0, "no chat request names an unverified model")
		helpers.assert_eq(#world.gets, 1, "the local server is asked for its models")
		helpers.assert_true(world.gets[1].url:match("/api/tags$") ~= nil, world.gets[1].url)

		World.list_local_models(world, { "llama3.2:3b", DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1, "the listed model is requested")
		helpers.assert_true(world.posts[1].url:match("/api/chat$") ~= nil, world.posts[1].url)
		helpers.assert_eq(world.posts[1].body.model, DEFAULT_MODEL)
		answer_local(world.posts[1], TWO_ACTIONS)
		helpers.assert_eq(#world.renders[#world.renders].texts, 2, "the actions are offered")

		-- A verified model is not listed again; a named one is matched as the
		-- server names it, its implicit ":latest" tag included
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 1, "the verified model is not listed again")
		helpers.assert_eq(#world.posts, 2)
		world.runner.set_system2("local|Mistral")
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 2, "another model is verified first")
		World.list_local_models(world, { "mistral:latest" })
		helpers.assert_eq(world.posts[3].body.model, "Mistral")
		helpers.assert_eq(#world.alerts, 0, "nothing is missing")
	end)

	helpers.it("(ai-agent-local-model) names a model the local server lacks, never requests it, and downloads it", function()
		local world = build_world({ system2 = "local" })
		world.alert_answer = "first"
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { "llama3.2:3b" })
		helpers.assert_eq(#world.posts, 0, "the missing model is never requested")
		helpers.assert_eq(#world.alerts, 1, "the user is told, with a button")
		local alert = world.alerts[1]
		helpers.assert_eq(alert.title, world.i18n.get("llm.local_model.missing_title"))
		helpers.assert_eq(alert.message, world.i18n.format("llm.local_model.missing_body", DEFAULT_MODEL))
		helpers.assert_true(alert.message:find(DEFAULT_MODEL, 1, true) ~= nil, "the missing model is named")
		helpers.assert_eq(alert.buttons[1], world.i18n.get("menu.llm.btn_download"))
		helpers.assert_eq(alert.buttons[2], world.i18n.get("common.cancel"))
		helpers.assert_eq(#world.installs, 1, "the Download button hands the model to the download owner")
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
		for _, notice in ipairs(world.notices) do
			helpers.assert_true(notice ~= world.i18n.get("llm.agent.failed"), "no vague failure over the named one")
		end

		-- Once downloaded, the next request lists the models again and posts
		world.installs[1].on_done(true)
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 2)
		World.list_local_models(world, { DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_eq(world.posts[1].body.model, DEFAULT_MODEL)

		-- Cancel downloads nothing
		local declined = build_world({ system2 = "local" })
		trigger(declined, "llm_agent_selection")
		World.list_local_models(declined, {})
		helpers.assert_eq(#declined.alerts, 1)
		helpers.assert_eq(#declined.installs, 0, "Cancel downloads nothing")
	end)

	helpers.it("(ai-agent-local-model) reads a 404 model-not-found body, names the model and offers its download", function()
		local world = build_world({ system2 = "local" })
		world.alert_answer = "first"
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1)
		-- Removed since it was listed: Ollama 0.24's scheduler answer
		fail_local(world.posts[1], 404, '{"error":"model \\"qwen2.5:7b\\" not found, try pulling it first"}')
		helpers.assert_true(World.logged(world, "error", 'HTTP 404 (model "qwen2.5:7b" not found, try pulling it first)'),
			"the server's error is logged")
		helpers.assert_eq(#world.alerts, 1, "the missing model is named, with a button")
		helpers.assert_eq(world.alerts[1].message, world.i18n.format("llm.local_model.missing_body", DEFAULT_MODEL))
		helpers.assert_eq(#world.installs, 1)
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
		assert_selection_never_logged(world)

		-- The listing was stale: the next request verifies the model again
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 1, "not requested again before a new listing")
		helpers.assert_true(#world.gets >= 1 and not world.gets[#world.gets].answered, "a new listing is asked for")

		-- The chat handler's own wording (single quotes) is read as well
		local other = build_world({ system2 = "local|qwen3:14b" })
		trigger(other, "llm_agent_selection")
		World.list_local_models(other, { "qwen3:14b" })
		fail_local(other.posts[1], 404, '{"error":"model \'qwen3:14b\' not found"}')
		helpers.assert_eq(#other.alerts, 1)
		helpers.assert_eq(other.alerts[1].message, other.i18n.format("llm.local_model.missing_body", "qwen3:14b"))
	end)

	helpers.it("(ai-agent-local-model) logs the server's error body of any other failure, never the request", function()
		local world = build_world({ system2 = "local" })
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { DEFAULT_MODEL })
		fail_local(world.posts[1], 500, '{"error":"llama runner process has terminated: signal: killed"}')
		helpers.assert_true(World.logged(world, "error",
			"HTTP 500 (llama runner process has terminated: signal: killed)"), "the server's error is logged")
		helpers.assert_eq(#world.alerts, 0, "no download is offered for another failure")
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.failed"))
		assert_selection_never_logged(world)

		-- A plain-text 404 (a server without /api/chat) is not a missing model
		local old = build_world({ system2 = "local" })
		trigger(old, "llm_agent_selection")
		World.list_local_models(old, { DEFAULT_MODEL })
		fail_local(old.posts[1], 404, "404 page not found")
		helpers.assert_true(World.logged(old, "error", "HTTP 404 (404 page not found)"), "the body is logged")
		helpers.assert_eq(#old.alerts, 0, "no model is named when none is missing")
	end)

	helpers.it("(ai-agent-local-model) the automatic mode notifies once instead of opening a dialog while typing", function()
		local world = build_world({ system1 = "local", system2 = "cerebras", mode = "auto" })
		world.runner.observe_typing("Bonjour. Rappelle-moi d'appeler Paul demain à 9h")
		World.settle(world)
		helpers.assert_eq(#world.gets, 1, "System 1's local model is verified first")
		World.list_local_models(world, {})
		helpers.assert_eq(#world.posts, 0, "the missing model is never requested")
		helpers.assert_eq(#world.alerts, 0, "no dialog takes the keystrokes")
		helpers.assert_eq(#world.notifications, 1)
		local notification = world.notifications[1]
		helpers.assert_eq(notification.title, world.i18n.get("llm.local_model.missing_title"))
		helpers.assert_eq(notification.body, world.i18n.format("llm.local_model.missing_click", DEFAULT_MODEL))

		world.runner.observe_typing("Bonjour. Rappelle-moi d'appeler Paul demain à 10h")
		World.settle(world)
		World.list_local_models(world, {})
		helpers.assert_eq(#world.notifications, 1, "one notification per model")

		-- Its click opens the dialog, whose button downloads the model
		world.alert_answer = "first"
		notification.on_click()
		helpers.assert_eq(#world.alerts, 1)
		helpers.assert_eq(#world.installs, 1)
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
	end)
end)
