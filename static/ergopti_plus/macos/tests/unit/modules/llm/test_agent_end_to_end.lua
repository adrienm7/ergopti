--- tests/unit/modules/llm/test_agent_end_to_end.lua

--- ==============================================================================
--- MODULE: AI Agent End to End (llm_agent_selection, llm_agent_command)
--- DESCRIPTION:
--- Runs the agent actions without a model: the real gesture action registry,
--- agent runner, shared agent logic, prediction engine refusals and tooltip
--- surface, and remote backend (Cerebras, OpenAI dialect). Only the boundaries
--- are faked: the HTTP transport (requests are captured and answered with
--- canned bodies), the selection reader, the command dialog, the connectors,
--- the clock, the time zone, the focused window and the tooltip canvas.
---
--- ROOT CAUSE ENCODED:
--- The agent only works when every layer agrees: the refusals come before
--- anything is read, the request goes to System 2's own backend with the
--- system2 prompt filled with the moment, the time zone, the application and
--- the window, the answer is validated before anything is offered, each
--- candidate runs its own action, and only after the user accepted it.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")

local Agent = require("llm.agent")

local CONFIG = World.CONFIG
local SELECTION = World.SELECTION
local NOW = World.NOW
local MODEL = World.MODEL
local TWO_ACTIONS = World.TWO_ACTIONS
local build_world, trigger, answer, accept = World.build_world, World.trigger, World.answer, World.accept

helpers.describe("AI agent end to end (llm_agent_selection, llm_agent_command)", function()
	helpers.it("sends the selection to System 2 and runs the accepted action", function()
		local world = build_world()
		helpers.assert_eq(trigger(world, "llm_agent_selection"), true)
		helpers.assert_eq(#world.notices, 0, "no refusal: " .. tostring(world.notices[1]))
		helpers.assert_eq(world.loadings, 1, "the loading row shows while System 2 thinks")
		helpers.assert_eq(#world.posts, 1, "one request")
		local post = world.posts[1]
		helpers.assert_true(post.url:find("https://api.cerebras.ai/v1/chat/completions", 1, true) == 1,
			"System 2's backend answers: " .. tostring(post.url))
		helpers.assert_eq(post.body.model, MODEL, "the provider's default model")
		helpers.assert_eq(post.body.reasoning_effort, "none", "the model's extras apply")
		local expected_prompt = Agent.system2_prompt(CONFIG, {
			source = "selection", app = "Notes", window = "Réunion devis",
			now = os.date("%Y-%m-%dT%H:%M", NOW), weekday = "Tuesday", timezone = "Europe/Paris",
			language = "fr", tools = { "Mode focus" },
		})
		helpers.assert_eq(post.body.messages[1].content, expected_prompt, "the system2 prompt, filled")
		helpers.assert_true(expected_prompt:find("2026-09-29T10:30", 1, true) ~= nil, "now is filled")
		helpers.assert_true(expected_prompt:find("Europe/Paris", 1, true) ~= nil, "the time zone is filled")
		helpers.assert_true(expected_prompt:find("Réunion devis", 1, true) ~= nil, "the window is filled")
		helpers.assert_eq(post.body.messages[2].content, Agent.system2_user_text(CONFIG, SELECTION))
		helpers.assert_eq(post.body.max_tokens, CONFIG.system2.max_tokens)
		helpers.assert_true(post.body.stream ~= true, "no streaming")

		answer(post, TWO_ACTIONS)
		local render = world.renders[#world.renders]
		helpers.assert_eq(#render.texts, 2, "two candidates")
		helpers.assert_eq(render.texts[1], "📅 Devis avec Paul — 2026-10-01 14:00")
		helpers.assert_eq(render.texts[2], "✉️ Devis → paul@example.com")
		helpers.assert_eq(#world.runs, 0, "nothing runs before the user accepts")

		helpers.assert_eq(accept(world, 1), true)
		helpers.assert_eq(#world.runs, 1)
		local action = world.runs[1].action
		helpers.assert_eq(action.type, "calendar")
		helpers.assert_eq(action.title, "Devis avec Paul")
		helpers.assert_eq(action["end"], "2026-10-01T15:00", "the end is defaulted")
		world.runs[1].on_done(true)
		helpers.assert_eq(world.notices[#world.notices], "Ajouté au calendrier : Devis avec Paul")
	end)

	helpers.it("runs the mail candidate with its own action", function()
		local world = build_world()
		trigger(world, "llm_agent_selection")
		answer(world.posts[1], TWO_ACTIONS)
		accept(world, 2)
		helpers.assert_eq(world.runs[1].action.type, "mail")
		world.runs[1].on_done(true)
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.done_mail"))
	end)

	helpers.it("sends System 2 to the local server with its default or named model", function()
		local world = build_world({ system2 = "local" })
		trigger(world, "llm_agent_selection")
		-- Only a model the local server lists is requested (ai-agent-local-model)
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(World.list_local_models(world, { CONFIG.default_models["local"], "qwen3:14b" }), true)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(world.posts[1].url:find("/api/chat", 1, true) ~= nil, "the local server answers")
		helpers.assert_eq(world.posts[1].body.model, CONFIG.default_models["local"])
		helpers.assert_eq(world.posts[1].body.options.num_predict, CONFIG.system2.max_tokens)
		helpers.assert_eq(world.posts[1].body.messages[2].content, Agent.system2_user_text(CONFIG, SELECTION))
		world.posts[1].callback({ status = 200, body = '{"message":{"content":' .. require("json").encode(TWO_ACTIONS) .. '}}' })
		helpers.assert_eq(#world.renders[#world.renders].texts, 2)

		world.runner.set_system2("local|qwen3:14b")
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(world.posts[2].body.model, "qwen3:14b")
	end)

	helpers.it("refuses without System 2, before reading anything", function()
		local world = build_world({ system2 = "" })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 0, "no request")
		helpers.assert_nil(world.reads, "the selection is not read")
		helpers.assert_eq(world.notices[1], world.i18n.get("llm.agent.no_system2"))
	end)

	helpers.it("refuses while its mode is off", function()
		local world = build_world({ mode = "off" })
		trigger(world, "llm_agent_command")
		helpers.assert_eq(#world.posts + #world.dialogs, 0)
		helpers.assert_eq(world.notices[1], world.i18n.get("llm.agent.off_notice"))
	end)

	helpers.it("runs with the AI menu off and its prediction backend not ready", function()
		local world = build_world()
		world.engine.set_llm_enabled(false)
		-- "No Model" in the AI menu: the prediction backend cannot answer
		local api = require("modules.llm").api_remote
		api.set_active_entry_id("")
		helpers.assert_eq(api.is_ready(), false, "the prediction backend is not ready")
		helpers.assert_eq(trigger(world, "llm_agent_selection"), true)
		helpers.assert_eq(#world.notices, 0, "no refusal: " .. tostring(world.notices[1]))
		helpers.assert_eq(#world.posts, 1, "System 2 is asked")
		helpers.assert_eq(world.posts[1].url, "https://api.cerebras.ai/v1/chat/completions")
		answer(world.posts[1], TWO_ACTIONS)
		helpers.assert_eq(#world.renders[#world.renders].texts, 2, "the actions are offered")
		accept(world, 1)
		helpers.assert_eq(world.runs[1].action.type, "calendar", "the accepted action runs")

		world.dialog_answer = { "OK", "réunion demain 9h" }
		helpers.assert_eq(trigger(world, "llm_agent_command"), true)
		helpers.assert_eq(#world.posts, 2, "the command action too")
	end)

	helpers.it("refuses while paused, and without an API entry or key for System 2", function()
		local world = build_world()
		package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end }
		trigger(world, "llm_agent_selection")
		package.loaded["modules.shortcuts.script_control"] = nil
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_nil(world.reads, "nothing is read while paused")
		helpers.assert_eq(world.notices[1], world.i18n.get("llm.manual_prediction.paused"))

		world.runner.set_system2("openai")
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(world.notices[2], world.i18n.get("llm.agent.no_system2"), "no API entry for OpenAI")

		local api = require("modules.llm").api_remote
		api.set_entries({ { id = "keyless", provider = "openai", token = "", model = "gpt-4o-mini" } })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(world.notices[3], world.i18n.get("llm.agent.no_system2"), "an entry without a key")

		world.runner.set_system2("typesafe")
		api.set_entries({ { id = "jev", provider = "typesafe", token = "k", model = "jev-latest" } })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(world.notices[4], world.i18n.get("llm.agent.no_system2"), "Jev is not a chat model")
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_nil(world.reads)
	end)

	helpers.it("tells the user to select a text first", function()
		local world = build_world({ selection = "" })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 0)
		helpers.assert_eq(world.notices[1], world.i18n.get("llm.agent.no_selection"))
	end)

	helpers.it("sends a typed command, and nothing when the dialog is cancelled", function()
		local world = build_world()
		world.dialog_answer = { "Cancel", "réunion demain" }
		helpers.assert_eq(trigger(world, "llm_agent_command"), true)
		helpers.assert_eq(#world.dialogs, 1)
		helpers.assert_eq(world.dialogs[1].title, world.i18n.get("dialog.agent.command_title"))
		helpers.assert_eq(world.dialogs[1].message, world.i18n.get("dialog.agent.command_prompt"))
		helpers.assert_eq(#world.posts + #world.notices + world.loadings, 0, "a cancelled dialog does nothing")

		world.dialog_answer = { "OK", "   " }
		trigger(world, "llm_agent_command")
		helpers.assert_eq(#world.posts + #world.notices, 0, "an empty command does nothing")

		world.dialog_answer = { "OK", " réunion demain 9h avec l’équipe produit " }
		trigger(world, "llm_agent_command")
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_eq(world.posts[1].body.messages[2].content,
			Agent.system2_user_text(CONFIG, "réunion demain 9h avec l’équipe produit"))
		helpers.assert_true(world.posts[1].body.messages[1].content:find(CONFIG.source_kinds.command, 1, true) ~= nil,
			"the prompt names a command")
	end)

	helpers.it("drops invalid actions and says when none is left", function()
		local world = build_world()
		trigger(world, "llm_agent_selection")
		answer(world.posts[1], 'ACTIONS: [{"type":"calendar","title":"Devis","start":"jeudi 14h"},'
			.. '{"type":"shortcut","name":"rm -rf /"},{"type":"reminder","title":"Rappeler Paul"}]')
		local render = world.renders[#world.renders]
		helpers.assert_eq(#render.texts, 1, "only the valid reminder is offered")
		helpers.assert_eq(render.texts[1], world.i18n.format("llm.agent.label.reminder", "Rappeler Paul"))

		trigger(world, "llm_agent_selection")
		answer(world.posts[2], 'ACTIONS: [{"type":"calendar","title":"Devis"}]')
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.no_action"))
		trigger(world, "llm_agent_selection")
		answer(world.posts[3], "Je ne sais pas.")
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.failed"))
		trigger(world, "llm_agent_selection")
		world.posts[4].callback({ ok = false, status = 500, body = "{}", headers = {} })
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.failed"))
	end)

	helpers.it("reports a connector failure, and a refused Automation permission", function()
		local world = build_world()
		trigger(world, "llm_agent_selection")
		answer(world.posts[1], TWO_ACTIONS)
		accept(world, 1)
		world.runs[1].on_done(false, { reason = "exit 1" })
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.connector_failed"))

		trigger(world, "llm_agent_selection")
		answer(world.posts[2], TWO_ACTIONS)
		accept(world, 2)
		world.runs[2].on_done(false, { reason = "automation refused", permission = "Mail" })
		helpers.assert_eq(world.notices[#world.notices], world.i18n.format("llm.agent.permission_needed", "Mail"))
		helpers.assert_eq(world.settings_opened, true, "System Settings opens at Automation")
	end)

	helpers.it("ignores the answer of a superseded run", function()
		local world = build_world()
		trigger(world, "llm_agent_selection")
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 2)
		answer(world.posts[1], TWO_ACTIONS)
		helpers.assert_eq(#world.renders, 0, "the stale answer shows nothing")
		answer(world.posts[2], TWO_ACTIONS)
		helpers.assert_eq(#world.renders, 1)
	end)
end)
