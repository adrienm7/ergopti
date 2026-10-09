--- tests/unit/modules/llm/test_agent_flow.lua

--- ==============================================================================
--- MODULE: AI Agent On Action (Linux)
--- DESCRIPTION:
--- llm_agent_selection and llm_agent_command send one request to the System 2
--- backend (llm.agent_system2, not the AI menu's) with the shared System 2
--- prompt and the local context, validate the actions the model proposes and
--- offer them as tooltip candidates. Accepting one runs its connector; nothing
--- is typed.
---
--- The real engine, agent settings, connectors and remote client run; only the
--- boundaries are scripted (tests/support/agent_scenario.lua).
---
--- ROOT CAUSE ENCODED:
--- The agent's shared core existed with no Linux caller: the three catalogue
--- actions were listed and ran nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scenario = require("tests.support.agent_scenario")
local Agent = require("llm.agent")

local SELECTION = "On se voit jeudi 14h avec Paul pour le devis"
local ANSWER = 'ACTIONS: [{"type":"calendar","title":"Devis avec Paul","start":"2026-10-01T14:00"},'
	.. '{"type":"mail","to":["paul@example.com"],"subject":"Devis","body":"Bonjour Paul,\\nÀ jeudi."}]'
local CEREBRAS_URL = "https://api.cerebras.ai/v1/chat/completions"

helpers.describe("AI agent: missing local model admission", function()
	helpers.it("asks tags before local System 2 and offers the exact model without sending selection text", function()
		Scenario.run({ local_backend = true, selection = SELECTION,
			stored = { ["llm.agent_system2"] = "local" }, download_choice = true }, function(world)
			helpers.assert_true(world.handlers.llm_agent_selection("tap_3"))
			world.scheduler.test.advance(1)
			helpers.assert_eq(#world.probes, 1)
			helpers.assert_eq(#world.posts, 0)
			world.probes[1].callback({ ok = true, status = 200, body = '{"models":[]}' })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.model_offers, 1)
			helpers.assert_true(world.model_offers[1].text:find("qwen2.5:7b", 1, true) ~= nil)
			helpers.assert_eq(#world.model_installs, 1)
			helpers.assert_eq(world.model_installs[1].model, "qwen2.5:7b")
			helpers.assert_eq(world.model_installs[1].base_url, "http://127.0.0.1:11434")
			helpers.assert_eq(#world.typed, 0)
		end)
	end)

	helpers.it("runs the actual local agent after the listing acknowledges its model", function()
		Scenario.run({ local_backend = true, selection = SELECTION,
			stored = { ["llm.agent_system2"] = "local" } }, function(world)
			helpers.assert_true(world.handlers.llm_agent_selection("tap_3"))
			world.scheduler.test.advance(1)
			world.probes[1].callback({ ok = true, status = 200,
				body = '{"models":[{"name":"qwen2.5:7b"}]}' })
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(world.posts[1].body.model, "qwen2.5:7b")
			world.respond(1, ANSWER)
			helpers.assert_eq(#world.offered(), 2)
			helpers.assert_eq(#world.model_offers, 0)
			helpers.assert_eq(#world.model_installs, 0)
		end)
	end)

	helpers.it("a withdrawn local agent preflight cannot offer or start a download", function()
		Scenario.run({ local_backend = true, selection = SELECTION,
			stored = { ["llm.agent_system2"] = "local" }, download_choice = true }, function(world)
			helpers.assert_true(world.handlers.llm_agent_selection("tap_3"))
			world.scheduler.test.advance(1)
			local probe = world.probes[1]
			world.engine.dismiss()
			probe.callback({ ok = true, status = 200, body = '{"models":[]}' })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.model_offers, 0)
			helpers.assert_eq(#world.model_installs, 0)
		end)
	end)
end)

--- The System 2 prompt the scenario's context must produce.
--- @param world table
--- @param source string
--- @return string
local function expected_prompt(world, source)
	return Agent.system2_prompt(world.config, {
		source = source, app = world.window.app, window = world.window.title, now = "2026-09-29T14:05",
		weekday = "Tuesday", timezone = "Europe/Paris", language = require("infra.i18n").get_locale(),
		tools = world.tools,
	})
end





-- ==============================================
-- ==============================================
-- ======= 1/ The selection, end to end =========
-- ==============================================
-- ==============================================

helpers.describe("AI agent: the selection's actions offered and run", function()

	helpers.it("registers the three actions", function()
		Scenario.run({}, function(world)
			for _, id in ipairs({ "llm_agent_selection", "llm_agent_command", "llm_agent_auto_toggle" }) do
				helpers.assert_eq(type(world.handlers[id]), "function", id)
			end
		end)
	end)

	helpers.it("asks System 2, offers the valid actions and runs the accepted one's connector", function()
		Scenario.run({ selection = SELECTION }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), true)
			helpers.assert_eq(world.reads, 1, "the selection is read once")
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 1, "one request")
			local post = world.posts[1]
			helpers.assert_eq(post.url, CEREBRAS_URL, "System 2's backend")
			helpers.assert_eq(post.body.model, "qwen-3.8-27b", "the provider's default model")
			helpers.assert_eq(post.body.messages[1].role, "system")
			helpers.assert_eq(post.body.messages[1].content, expected_prompt(world, "selection"),
				"now, weekday, time zone, application, window and tools filled")
			helpers.assert_eq(post.body.messages[2].content, Agent.system2_user_text(world.config, SELECTION))
			helpers.assert_eq(post.body.max_tokens, world.config.system2.max_tokens)
			helpers.assert_eq(post.body.stream, false)
			helpers.assert_eq(world.shown and world.shown.meta.loading, true, "the tooltip says it is working")

			world.respond(1, ANSWER)
			helpers.assert_eq(table.concat(world.offered(), "|"), table.concat({
				Scenario.text("llm.agent.label.calendar", { "Devis avec Paul", "2026-10-01 14:00" }),
				Scenario.text("llm.agent.label.mail_to", { "Devis", "paul@example.com" }),
			}, "|"), "two candidates, labelled")
			helpers.assert_eq(#world.runs, 0, "nothing runs before acceptance")

			helpers.assert_eq(world.engine.handle_shortcut({ key = "1", mods = {} }), true, "1 accepts")
			helpers.assert_eq(#world.typed, 0, "nothing is typed")
			helpers.assert_eq(#world.runs, 1, "the calendar connector runs")
			helpers.assert_eq(world.runs[1].executable, "xdg-open")
			helpers.assert_eq(world.runs[1].args[1], "/run/user/1000/ergopti-agent.TEST/event.ics")
			local action = { type = "calendar", title = "Devis avec Paul", start = "2026-10-01T14:00",
				["end"] = "2026-10-01T15:00" }
			helpers.assert_eq(world.written[1].content,
				Agent.ics(world.config, action, "0123456789abcdef@ergopti", "20260929T120500Z"),
				"the validated action, its end defaulted")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the offer is gone")
			helpers.assert_eq(#world.notices, 0, "no notice before the connector answers")
			world.runs[1].callback({ ok = true, code = 0 })
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.done_calendar", { "Devis avec Paul" }))
		end)
	end)

	helpers.it("Tab runs the selected action, Down moves the selection", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, ANSWER)
			local EvdevCodes = require("infra.evdev_codes")
			helpers.assert_eq(world.engine.handle_shortcut({ code = EvdevCodes.KEY_DOWN, mods = {} }), true)
			helpers.assert_eq(world.engine.handle_shortcut({ code = EvdevCodes.KEY_TAB, mods = {} }), true)
			helpers.assert_eq(#world.runs, 1)
			helpers.assert_eq(world.runs[1].executable, "xdg-open", "the mail draft, without xdg-email")
			helpers.assert_contains(world.runs[1].args[1], "mailto:paul@example.com?subject=Devis&body=")
			world.runs[1].callback({ ok = true, code = 0 })
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.done_mail"))
		end)
	end)

	helpers.it("drops the invalid actions and logs why, never offering them", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, 'ACTIONS: [{"type":"calendar","title":"Sans date"},{"type":"shell","cmd":"rm -rf ~"},'
				.. '{"type":"shortcut","name":"Pas un outil"},{"type":"reminder","title":"Appeler Paul"}]')
			helpers.assert_eq(table.concat(world.offered(), "|"), Scenario.text("llm.agent.label.reminder",
				{ "Appeler Paul" }), "only the valid reminder")
		end)
	end)

	helpers.it("tells the user when the model proposes nothing or cannot be read", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, "ACTIONS: []")
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_action"))
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(2)
			world.respond(2, "I cannot help with that.")
			helpers.assert_eq(world.notices[2], Scenario.text("llm.agent.failed"))
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
		end)
	end)

	helpers.it("a failing connector is told, and logged with its reason", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, ANSWER)
			world.engine.accept(1)
			world.runs[1].callback({ ok = false, code = 4, error = "exit code 4" })
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.connector_failed"))
		end)
		Scenario.run({ selection = SELECTION, run_fails = true }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, ANSWER)
			world.engine.accept(1)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.connector_failed"),
				"a program that cannot start is a failure too")
		end)
	end)

	helpers.it("typing while it runs drops the answer", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.type("x")
			world.respond(1, ANSWER)
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
		end)
	end)
end)





-- ===================================
-- ===================================
-- ======= 2/ Refusals ===============
-- ===================================
-- ===================================

helpers.describe("AI agent: what it refuses", function()

	helpers.it("without System 2: a notice and no request", function()
		Scenario.run({ selection = SELECTION, stored = { ["llm.agent_system2"] = "" } }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(world.reads, 0, "the selection is not even read")
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system2"))
		end)
	end)

	helpers.it("a provider with no default model and no model named counts as no System 2", function()
		Scenario.run({ selection = SELECTION, stored = { ["llm.agent_system2"] = "openai_compat" } }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system2"))
		end)
	end)

	helpers.it("the agent off or a pause refuse with their notice", function()
		Scenario.run({ selection = SELECTION, stored = { ["llm.agent_mode"] = "off" } }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.off_notice"))
		end)
		Scenario.run({ selection = SELECTION, paused = true }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.manual_prediction.paused"))
		end)
	end)

	-- The agent never uses the AI menu's switch nor its prediction backend: it
	-- was refused whenever the predictions were off.
	helpers.it("works with the AI menu off and without a prediction backend", function()
		Scenario.run({ command = "Écris à Paul", disabled = true, active_entry = false }, function(world)
			helpers.assert_eq(world.engine.is_enabled(), false, "the AI menu is off")
			helpers.assert_eq(world.engine.get_prediction_model(), nil, "no prediction backend is ready")
			helpers.assert_eq(world.handlers.llm_agent_command("tap_3"), true)
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 1, "System 2 is asked")
			helpers.assert_eq(world.posts[1].url, CEREBRAS_URL)
			world.respond(1, ANSWER)
			helpers.assert_eq(#world.offered(), 2, "and its actions offered")
			helpers.assert_eq(#world.notices, 0, "no refusal")
		end)
	end)

	helpers.it("a System 2 provider without a stored key counts as no System 2", function()
		Scenario.run({ selection = SELECTION, stored = { ["llm.agent_system2"] = "groq" } }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system2"))
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("nothing selected: a notice and no request", function()
		Scenario.run({}, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_selection"))
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("a secure field refuses silently", function()
		Scenario.run({ selection = SELECTION }, function(world)
			world.secure = true
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.reads, 0)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)





-- =====================================
-- =====================================
-- ======= 3/ The command dialog =======
-- =====================================
-- =====================================

helpers.describe("AI agent: a typed command", function()

	helpers.it("sends the command with its own source kind", function()
		Scenario.run({ command = "réunion demain 9h avec l'équipe produit" }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_command("tap_3"), true)
			helpers.assert_eq(world.dialogs[1].title, Scenario.text("dialog.agent.command_title"))
			helpers.assert_eq(world.dialogs[1].prompt, Scenario.text("dialog.agent.command_prompt"))
			world.wait_for(1)
			helpers.assert_eq(world.posts[1].body.messages[1].content, expected_prompt(world, "command"))
			helpers.assert_eq(world.posts[1].body.messages[2].content,
				Agent.system2_user_text(world.config, "réunion demain 9h avec l'équipe produit"))
		end)
	end)

	helpers.it("cancelling the dialog, or confirming nothing, does nothing", function()
		Scenario.run({ command = nil }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_command("tap_3"), false)
			helpers.assert_eq(#world.dialogs, 1)
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.notices, 0)
		end)
		Scenario.run({ command = "  " }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_command("tap_3"), false)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.notices, 0)
		end)
	end)
end)


helpers.describe("AI agent: native missing-model modal ownership", function()
	local function native_case(effect, refuse_regrab)
		local Hook = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local saved_hook, saved_grab = package.loaded["adapters.keyboard_hook"], Reader.grab
		package.loaded["adapters.keyboard_hook"] = Hook
		local observed, caught, world_active, desyncs = nil, nil, nil, 0
		if refuse_regrab then Reader.grab = function() return false end end
		Hook._test_drive({ { type = 1, code = 30, value = 1 } }, {
			onChar = function()
				local ok, err = xpcall(function()
					Scenario.run({ local_backend = true, selection = SELECTION,
						stored = { ["llm.agent_system2"] = "local" }, native_model_dialog = true,
						download_choice = true, on_model_confirm = effect }, function(world)
						world_active = world
						assert(world.handlers.llm_agent_selection("tap_3"))
						world.scheduler.test.advance(1)
						world.probes[1].callback({ ok = true, status = 200, body = '{"models":[]}' })
						observed = { offers = #world.model_offers, installs = #world.model_installs,
							posts = #world.posts, running = Hook.isRunning() }
					end)
				end, debug.traceback)
				if not ok then caught = err end
			end,
			onDesync = function()
				desyncs = desyncs + 1
				if world_active then world_active.engine.cancel() end
			end,
			onEmitRaw = function() return true end,
		}, true)
		Reader.grab, package.loaded["adapters.keyboard_hook"] = saved_grab, saved_hook
		helpers.assert_eq(caught, nil, "assertions inside the real runtime guard must be collected, never swallowed")
		helpers.assert_true(observed ~= nil, "the actual decoded reader event starts the scenario")
		observed.desyncs = desyncs
		return observed
	end

	helpers.it("real while_released resync cancellation preserves only its acknowledged consent", function()
		local actual = native_case(nil, false)
		helpers.assert_eq(actual.offers, 1, "actual confirm reaches the native shell boundary through ui.modal")
		helpers.assert_eq(actual.desyncs, 1, "the actual hook delivers the daemon cancellation after regrab")
		helpers.assert_eq(actual.installs, 1, "that bounded resynchronisation does not invalidate valid manual consent")
		helpers.assert_eq(actual.posts, 0, "missing-model inference still never carries private text")
		helpers.assert_true(actual.running)
	end)

	for _, effect in ipairs({ "new_action", "endpoint", "shutdown", "pause", "reinitialise" }) do
		helpers.it("actual modal affirmative cannot launch after " .. effect, function()
			local actual = native_case(function(world)
				if effect == "new_action" then world.engine.dismiss()
				elseif effect == "endpoint" then world.base_url = "http://127.0.0.1:11435"
				elseif effect == "shutdown" then world.engine.cancel()
				elseif effect == "pause" then world.paused = true
				elseif effect == "reinitialise" then world.engine.init() end
			end, false)
			helpers.assert_eq(actual.offers, 1)
			helpers.assert_eq(actual.installs, 0, "a genuine newer/lifecycle/endpoint state revokes consent before /api/pull")
			helpers.assert_eq(actual.posts, 0)
		end)
	end

	helpers.it("an emergency regrab refusal revokes the affirmative native receipt", function()
		local actual = native_case(nil, true)
		helpers.assert_eq(actual.offers, 1)
		helpers.assert_eq(actual.desyncs, 0, "failed restoration never fabricates acknowledged resync")
		helpers.assert_eq(actual.installs, 0)
		helpers.assert_eq(actual.running, false)
	end)
end)
