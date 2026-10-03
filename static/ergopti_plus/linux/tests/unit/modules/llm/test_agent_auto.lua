--- tests/unit/modules/llm/test_agent_auto.lua

--- ==============================================================================
--- MODULE: AI Agent Automatic Mode And Learning (Linux)
--- DESCRIPTION:
--- In the automatic mode (llm.agent_mode = "auto"), a typing pause on a long
--- enough sentence sends ONE System 1 triage; above the threshold of its
--- intent in the application, System 2 proposes actions in the tooltip. The
--- threshold is learnt per (application, intent): accepting lowers it,
--- dismissing raises it, and it survives a restart in the XDG state folder.
---
--- The real engine, agent settings, connectors, learning store and remote
--- client run; only the boundaries are scripted (tests/support/agent_scenario.lua).
---
--- ROOT CAUSE ENCODED:
--- The automatic mode must never cover another tooltip, never triage a
--- sentence twice, never look at an excluded application, and give way to the
--- next keystroke. The automatic next-word prediction is the exception: it
--- appears ~500 ms after typing stops, before the agent's pause is over, so
--- counting it as "another tooltip" starved the automatic mode. The agent now
--- runs beside it and its actions replace it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scenario = require("tests.support.agent_scenario")
local Agent = require("llm.agent")
local Json = require("json")

local SENTENCE = "On se voit jeudi 14h avec Paul"
local ANSWER = 'ACTIONS: [{"type":"calendar","title":"Paul","start":"2026-10-01T14:00"}]'

-- The automatic mode with both systems on Cerebras; the menu's own prediction
-- waits long enough never to fire during a scenario
local AUTO = {
	["llm.agent_system1"] = "cerebras",
	["llm.agent_system2"] = "cerebras",
	["llm.agent_mode"] = "auto",
	["llm.trigger.debounce_ms"] = 10000,
}

--- @param extra table|nil Preferences added to AUTO.
--- @return table
local function auto(extra)
	local stored = {}
	for key, value in pairs(AUTO) do stored[key] = value end
	for key, value in pairs(extra or {}) do stored[key] = value end
	return stored
end

--- The posts whose system prompt is the System 1 triage's.
--- @param world table
--- @return table
local function triages(world)
	local list = {}
	local prompt = Agent.system1_prompt(world.config, { app = world.window.app, tools = world.tools })
	for _, post in ipairs(world.posts) do
		if post.body.messages and post.body.messages[1].content == prompt then list[#list + 1] = post end
	end
	return list
end

--- Types the sentence, then waits past the pause.
--- @param world table
--- @param app string|nil
local function type_and_pause(world, app, sentence)
	world.type(sentence or SENTENCE, app)
	world.scheduler.test.advance(1)
end

helpers.describe("AI agent: automatic missing local model", function()
	helpers.it("notifies once per model and never interrupts typing with a download dialog", function()
		Scenario.run({ local_backend = true, stored = auto({ ["llm.agent_system1"] = "local",
			["llm.agent_system2"] = "local" }), download_choice = true }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#world.probes, 1)
			world.probes[1].callback({ ok = true, status = 200, body = '{"models":[]}' })
			local notices = #world.notices
			helpers.assert_true(notices > 0)
			helpers.assert_true(world.notices[notices]:find("qwen2.5:7b", 1, true) ~= nil)
			type_and_pause(world, nil, " et budget")
			helpers.assert_eq(#world.probes, 2)
			world.probes[2].callback({ ok = true, status = 200, body = '{"models":[]}' })
			helpers.assert_eq(#world.notices, notices)
			helpers.assert_eq(#world.model_offers, 0)
			helpers.assert_eq(#world.model_installs, 0)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)

--- The posts that ask System 2 for actions.
--- @param world table
--- @return integer
local function system2_posts(world)
	local count = 0
	for _, post in ipairs(world.posts) do
		local messages = post.body.messages
		if messages and messages[1].content:find("You prepare actions", 1, true) then count = count + 1 end
	end
	return count
end





-- =============================================
-- =============================================
-- ======= 1/ Triage, then System 2 ============
-- =============================================
-- =============================================

helpers.describe("AI agent automatic mode: a pause, a triage, then actions", function()

	helpers.it("triages the sentence once, and above the threshold asks System 2", function()
		Scenario.run({ stored = auto() }, function(world)
			world.type(SENTENCE)
			world.scheduler.test.advance(0.5)
			helpers.assert_eq(#world.posts, 0, "nothing before the pause")
			world.scheduler.test.advance(0.5)
			helpers.assert_eq(#world.posts, 1, "one triage")
			local post = world.posts[1]
			helpers.assert_eq(post.url, "https://api.cerebras.ai/v1/chat/completions")
			helpers.assert_eq(post.body.messages[1].content,
				Agent.system1_prompt(world.config, { app = "Mail", tools = world.tools }), "the triage prompt")
			helpers.assert_eq(post.body.messages[2].content, SENTENCE, "the sentence alone")
			helpers.assert_eq(post.body.max_tokens, world.config.system1.max_tokens)
			helpers.assert_eq(world.shown, nil, "a triage shows nothing")

			world.respond(1, "INTENT: calendar\nPROBABILITY: 0.9")
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "System 2 is asked")
			helpers.assert_contains(world.posts[2].body.messages[1].content, "SOURCE is text the user is typing in Mail",
				"with the typing source")
			helpers.assert_eq(world.posts[2].body.messages[2].content, Agent.system2_user_text(world.config, SENTENCE))
			world.respond(2, ANSWER)
			helpers.assert_eq(table.concat(world.offered(), "|"),
				Scenario.text("llm.agent.label.calendar", { "Paul", "2026-10-01 14:00" }))
			helpers.assert_eq(#world.notices, 0, "the automatic mode says nothing")
		end)
	end)

	helpers.it("below the threshold, or for no intent, nothing follows", function()
		Scenario.run({ stored = auto() }, function(world)
			type_and_pause(world)
			world.respond(1, "INTENT: calendar\nPROBABILITY: 0.5")
			world.scheduler.test.advance(3)
			helpers.assert_eq(#world.posts, 1, "no System 2")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
		end)
		Scenario.run({ stored = auto() }, function(world)
			type_and_pause(world)
			world.respond(1, "INTENT: none\nPROBABILITY: 0.99")
			world.scheduler.test.advance(3)
			helpers.assert_eq(#world.posts, 1)
		end)
	end)

	helpers.it("never triages the same sentence twice, nor a short one", function()
		Scenario.run({ stored = auto() }, function(world)
			type_and_pause(world)
			world.respond(1, "INTENT: none\nPROBABILITY: 0.9")
			world.engine.on_hotstring_expired(world.buffer, { app_id = "thunderbird" })
			world.scheduler.test.advance(1)
			helpers.assert_eq(#triages(world), 1, "the same sentence is not asked again")
		end)
		Scenario.run({ stored = auto() }, function(world)
			world.type("Oui merci")
			world.scheduler.test.advance(1)
			helpers.assert_eq(#world.posts, 0, "below system1.min_chars")
		end)
	end)

	helpers.it("a keystroke withdraws the triage in flight and its answer is dropped", function()
		Scenario.run({ stored = auto() }, function(world)
			type_and_pause(world)
			local cancels = world.cancels or 0
			world.type(" ")
			helpers.assert_true((world.cancels or 0) > cancels, "the request is cancelled")
			world.respond(1, "INTENT: calendar\nPROBABILITY: 0.99")
			world.scheduler.test.advance(3)
			helpers.assert_eq(system2_posts(world), 0, "no System 2 for a stale triage")
			helpers.assert_eq(#triages(world), 1, "and a trailing space is not a new sentence")
		end)
	end)

	helpers.it("a hotstring preview, live mode, an excluded app, a pause or a secure field block it", function()
		Scenario.run({ stored = auto() }, function(world)
			world.preview = true
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 0, "the preview has the screen")
		end)
		Scenario.run({ stored = auto() }, function(world)
			helpers.assert_eq(world.engine.set_live("translate_en"), true)
			type_and_pause(world)
			helpers.assert_eq(#triages(world), 0, "live mode disables the automatic agent")
		end)
		Scenario.run({ stored = auto({ ["llm.agent_disabled_apps"] = { "thunderbird" } }) }, function(world)
			type_and_pause(world, "thunderbird")
			helpers.assert_eq(#world.posts, 0, "an excluded application is never looked at")
			type_and_pause(world, "gedit")
			helpers.assert_eq(#world.posts, 1, "another one is")
		end)
		Scenario.run({ stored = auto(), paused = true }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 0, "never while paused")
		end)
		Scenario.run({ stored = auto() }, function(world)
			world.secure = true
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 0, "never in a secure field")
		end)
	end)

	helpers.it("only in the automatic mode", function()
		Scenario.run({ stored = auto({ ["llm.agent_mode"] = "action" }) }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ The toggle action =============
-- ==========================================
-- ==========================================

helpers.describe("AI agent automatic mode: the toggle", function()

	helpers.it("switches auto and action, from off to auto, and tells the user", function()
		Scenario.run({ stored = auto({ ["llm.agent_mode"] = "off" }) }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_auto_toggle("tap_3"), true)
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), "auto", "from off to auto")
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.auto_on"))
			helpers.assert_eq(world.handlers.llm_agent_auto_toggle("tap_3"), true)
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), "action")
			helpers.assert_eq(world.notices[2], Scenario.text("llm.agent.auto_off"))
		end)
	end)

	helpers.it("without System 1 it is refused and nothing changes", function()
		Scenario.run({ stored = auto({ ["llm.agent_mode"] = "action", ["llm.agent_system1"] = "" }) }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_auto_toggle("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system1"))
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), "action", "unchanged")
		end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 3/ Learning ======================
-- ==========================================
-- ==========================================

--- Reads the learning file.
--- @param path string
--- @return table|nil
local function read_learning(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return Json.decode(text)
end

--- Offers the automatic suggestion in `app`.
--- @param world table
--- @param app string
--- @param probability number
local function offer(world, app, probability, sentence)
	local before = #world.posts
	world.buffer = ""
	type_and_pause(world, app, sentence)
	world.respond(before + 1, "INTENT: calendar\nPROBABILITY: " .. tostring(probability))
	-- System 2 waits for the backend's minimum interval, far below the menu's
	-- prediction delay.
	for _ = 1, 6 do
		if world.posts[before + 2] then break end
		world.scheduler.test.advance(0.5)
	end
	if world.posts[before + 2] then world.respond(before + 2, ANSWER) end
end

helpers.describe("AI agent learning: a threshold per application and intent", function()

	helpers.it("accepting lowers it, dismissing raises it, and it survives a restart", function()
		local path = os.tmpname()
		os.remove(path)
		Scenario.run({ stored = auto(), learning_path = path }, function(world)
			local Learning = require("modules.llm.agent_learning")
			local base = world.config.system1.threshold
			offer(world, "thunderbird", 0.9)
			helpers.assert_eq(#world.engine.get_suggestions(), 1)
			world.engine.accept(1)
			helpers.assert_eq(Learning.threshold(world.config, "thunderbird", "calendar"),
				Agent.learn(world.config, base, true), "accepted")
			offer(world, "gedit", 0.9, "Rendez-vous chez le dentiste lundi")
			world.engine.withdraw()
			helpers.assert_eq(Learning.threshold(world.config, "gedit", "calendar"),
				Agent.learn(world.config, base, false), "dismissed")
			helpers.assert_eq(Learning.threshold(world.config, "slack", "calendar"), base, "another app keeps its own")
			helpers.assert_eq(Learning.threshold(world.config, "thunderbird", "mail"), base, "and another intent")

			world.scheduler.test.advance(3)
			local saved = read_learning(path)
			helpers.assert_not_nil(saved, "saved after the debounce")
			helpers.assert_eq(saved.apps.thunderbird.thresholds.calendar, Agent.learn(world.config, base, true))
			Learning._reset_for_test({ path = path, scheduler = world.scheduler })
			helpers.assert_eq(Learning.threshold(world.config, "gedit", "calendar"),
				Agent.learn(world.config, base, false), "reloaded")
		end)
		os.remove(path)
	end)

	helpers.it("typing over an automatic suggestion dismisses it; a learnt threshold gates the next one", function()
		Scenario.run({ stored = auto() }, function(world)
			local Learning = require("modules.llm.agent_learning")
			for _ = 1, 10 do Learning.record(world.config, "thunderbird", "calendar", false) end
			helpers.assert_eq(Learning.threshold(world.config, "thunderbird", "calendar"),
				world.config.learning.max_threshold, "bounded")
			offer(world, "thunderbird", 0.9)
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "0.9 is below the learnt 0.95")
			offer(world, "gedit", 0.9, "Rendez-vous chez le dentiste lundi")
			helpers.assert_eq(#world.engine.get_suggestions(), 1, "the default threshold elsewhere")
			world.type("x", "gedit")
			helpers.assert_eq(Learning.threshold(world.config, "gedit", "calendar"),
				Agent.learn(world.config, world.config.system1.threshold, false), "typing over it is a dismissal")
		end)
	end)

	helpers.it("an action the user asked for teaches nothing", function()
		Scenario.run({ selection = SENTENCE, stored = auto() }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.wait_for(1)
			world.respond(1, ANSWER)
			world.engine.withdraw()
			local Learning = require("modules.llm.agent_learning")
			helpers.assert_eq(Learning.threshold(world.config, "thunderbird", "calendar"), world.config.system1.threshold)
		end)
	end)

	helpers.it("keeps at most MAX_APPS applications, dropping the least recently used", function()
		Scenario.run({}, function(world)
			local Learning = require("modules.llm.agent_learning")
			for index = 1, Learning.MAX_APPS + 1 do
				Learning.record(world.config, "app" .. index, "mail", true)
			end
			local lowered = Agent.learn(world.config, world.config.system1.threshold, true)
			helpers.assert_eq(Learning.threshold(world.config, "app1", "mail"), world.config.system1.threshold,
				"the oldest is forgotten")
			helpers.assert_eq(Learning.threshold(world.config, "app2", "mail"), lowered)
			helpers.assert_eq(Learning.threshold(world.config, "app" .. (Learning.MAX_APPS + 1), "mail"), lowered)
		end)
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 4/ Beside the automatic prediction =======
-- ==================================================
-- ==================================================

-- The menu's automatic prediction fires before the agent's pause is over, one
-- variant at a time
local WITH_PREDICTION = { ["llm.trigger.debounce_ms"] = 500, ["llm.profiles.num_predictions"] = 1 }

--- Types the sentence and lets the automatic prediction answer.
--- @param world table
local function type_with_prediction(world)
	world.type(SENTENCE)
	world.scheduler.test.advance(0.5)
	helpers.assert_eq(#world.posts, 1, "the prediction is sent first")
	world.respond(1, " et on en parle")
	helpers.assert_true(#world.offered() >= 1, "the prediction is on offer")
end

helpers.describe("AI agent automatic mode: beside the automatic prediction", function()

	helpers.it("triages while the prediction is shown, and its actions replace the prediction", function()
		Scenario.run({ stored = auto(WITH_PREDICTION) }, function(world)
			type_with_prediction(world)
			local prediction = table.concat(world.offered(), "|")
			world.wait_for(2)
			helpers.assert_eq(#triages(world), 1, "the prediction does not block the triage")
			helpers.assert_eq(table.concat(world.offered(), "|"), prediction, "the prediction stays meanwhile")
			world.respond(2, "INTENT: calendar\nPROBABILITY: 0.9")
			world.wait_for(3)
			helpers.assert_eq(system2_posts(world), 1, "System 2 is asked")
			helpers.assert_eq(table.concat(world.offered(), "|"), prediction, "still the prediction until it answers")
			world.respond(3, ANSWER)
			helpers.assert_eq(table.concat(world.offered(), "|"),
				Scenario.text("llm.agent.label.calendar", { "Paul", "2026-10-01 14:00" }), "the actions replace it")
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	helpers.it("waits for the prediction's request on the same backend instead of cancelling it", function()
		Scenario.run({ stored = auto(WITH_PREDICTION) }, function(world)
			world.type(SENTENCE)
			world.scheduler.test.advance(1.5)
			helpers.assert_eq(#world.posts, 1, "the prediction is still in flight: no triage yet")
			helpers.assert_eq(world.cancels or 0, 0, "and nothing was cancelled")
			world.respond(1, " et on en parle")
			world.wait_for(2)
			helpers.assert_eq(#triages(world), 1, "the triage goes once the backend is free")
		end)
	end)

	helpers.it("an answer that holds no action leaves the prediction alone", function()
		Scenario.run({ stored = auto(WITH_PREDICTION) }, function(world)
			type_with_prediction(world)
			local prediction = table.concat(world.offered(), "|")
			world.wait_for(2)
			world.respond(2, "INTENT: calendar\nPROBABILITY: 0.9")
			world.wait_for(3)
			world.respond(3, "ACTIONS: []")
			helpers.assert_eq(table.concat(world.offered(), "|"), prediction)
		end)
	end)

	helpers.it("a keystroke cancels both the prediction and the agent's request", function()
		Scenario.run({ stored = auto(WITH_PREDICTION) }, function(world)
			type_with_prediction(world)
			world.wait_for(2)
			world.respond(2, "INTENT: calendar\nPROBABILITY: 0.9")
			world.wait_for(3)
			local cancels = world.cancels or 0
			world.type(" ")
			helpers.assert_true((world.cancels or 0) > cancels, "System 2's request is withdrawn")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the prediction is dismissed")
			world.respond(3, ANSWER)
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "a stale answer shows nothing")
		end)
	end)

	helpers.it("an explicit AI request on screen still blocks it", function()
		Scenario.run({ stored = auto(), selection = "Autre chose" }, function(world)
			world.handlers.llm_agent_selection("tap_3")
			world.type(SENTENCE)
			world.handlers.llm_agent_selection("tap_3")
			world.scheduler.test.advance(1)
			helpers.assert_eq(#triages(world), 0, "the agent's own offer has the screen")
		end)
	end)

	helpers.it("runs with the AI menu switched off", function()
		Scenario.run({ stored = auto(), disabled = true }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#triages(world), 1, "the triage is sent")
			world.respond(1, "INTENT: calendar\nPROBABILITY: 0.9")
			world.wait_for(2)
			world.respond(2, ANSWER)
			helpers.assert_eq(#world.offered(), 1, "and the actions offered")
		end)
	end)
end)





-- =============================================
-- =============================================
-- ======= 5/ Jev as System 1 ==================
-- =============================================
-- =============================================

local TYPESAFE_ENTRY = { id = "typesafe-1", provider = "typesafe", label = "TypeSafe (Jev)", token = "ts-key",
	model = "", base_url = "" }
local BACKBOARD_ENTRY = { id = "backboard-1", provider = "backboard", label = "Backboard", token = "bb-key",
	model = "", base_url = "" }
local JEV_ANSWERS = { intent = { choice = "calendar", probabilities = { none = 0.05, calendar = 0.9, mail = 0.05 } } }

--- The providers' base URLs.
--- @return table
local function base_urls()
	local fh = assert(io.open(require("tests.helpers").driver_root() .. "/../_shared/modules/llm/api_providers.json"))
	local root = Json.decode(fh:read("*a"))
	fh:close()
	return { typesafe = root.providers.typesafe.base_url, backboard = root.providers.backboard.base_url }
end

helpers.describe("AI agent automatic mode: Jev as System 1", function()
	local urls = base_urls()
	local Formats = require("llm.remote_formats")

	helpers.it("through TypeSafe: the jev question to the full endpoint, then System 2", function()
		Scenario.run({ stored = auto({ ["llm.agent_system1"] = "typesafe" }),
			entries = { Scenario.ENTRY, TYPESAFE_ENTRY } }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 1, "one decision")
			local post = world.posts[1]
			helpers.assert_eq(post.url, urls.typesafe)
			helpers.assert_eq(post.headers.Authorization, "Bearer ts-key")
			helpers.assert_eq(post.body, Formats.decisions_body("jev-latest", "App: Mail\nText: " .. SENTENCE,
				Agent.jev_questions(world.config)), "the sentence and its application, the jev question")
			world.respond_json(1, { answers = JEV_ANSWERS })
			world.wait_for(2)
			helpers.assert_eq(system2_posts(world), 1, "above the threshold, System 2 is asked")
			world.respond(2, ANSWER)
			helpers.assert_eq(#world.offered(), 1)
		end)
	end)

	helpers.it("an answer without `choice` takes the most probable intent", function()
		Scenario.run({ stored = auto({ ["llm.agent_system1"] = "typesafe" }),
			entries = { Scenario.ENTRY, TYPESAFE_ENTRY } }, function(world)
			type_and_pause(world)
			world.respond_json(1, { answers = { intent = { probabilities = { none = 0.2, mail = 0.8 } } } })
			world.wait_for(2)
			helpers.assert_eq(system2_posts(world), 1, "mail at 0.8 wakes System 2")
		end)
		Scenario.run({ stored = auto({ ["llm.agent_system1"] = "typesafe" }),
			entries = { Scenario.ENTRY, TYPESAFE_ENTRY } }, function(world)
			type_and_pause(world)
			world.respond_json(1, { answers = { intent = { probabilities = { none = 0.9, mail = 0.1 } } } })
			world.scheduler.test.advance(3)
			helpers.assert_eq(system2_posts(world), 0, "none wins: nothing follows")
		end)
	end)

	helpers.it("through Backboard with a TypeSafe model: system_one questions, then System 2", function()
		Scenario.run({ stored = auto({ ["llm.agent_system1"] = "backboard|typesafe/jev-1.13" }),
			entries = { Scenario.ENTRY, BACKBOARD_ENTRY } }, function(world)
			type_and_pause(world)
			helpers.assert_eq(world.posts[1].url, Formats.backboard_assistant_request(urls.backboard).url)
			world.respond_json(1, { assistant_id = "asst-1" })
			local message = Formats.backboard_message_request(urls.backboard, { assistant_id = "asst-1",
				model = "typesafe/jev-1.13", system = "", text = "App: Mail\nText: " .. SENTENCE,
				questions = Agent.jev_questions(world.config) })
			helpers.assert_eq(world.posts[2].url, message.url)
			helpers.assert_eq(world.posts[2].headers["X-API-Key"], "bb-key")
			helpers.assert_eq(world.posts[2].body, message.body)
			world.respond_json(2, { answers = JEV_ANSWERS })
			world.wait_for(3)
			helpers.assert_eq(system2_posts(world), 1)
		end)
	end)

	helpers.it("any other Backboard model triages with the chat prompt", function()
		Scenario.run({ stored = auto({ ["llm.agent_system1"] = "backboard" }),
			entries = { Scenario.ENTRY, BACKBOARD_ENTRY } }, function(world)
			type_and_pause(world)
			world.respond_json(1, { assistant_id = "asst-1" })
			helpers.assert_eq(world.posts[2].body.system_prompt,
				Agent.system1_prompt(world.config, { app = "Mail", tools = world.tools }))
			helpers.assert_eq(world.posts[2].body.system_one, nil)
			world.respond_json(2, { content = "INTENT: calendar\nPROBABILITY: 0.9" })
			world.wait_for(3)
			helpers.assert_eq(system2_posts(world), 1, "System 2 is asked")
		end)
	end)

	helpers.it("a Jev provider is never System 2", function()
		Scenario.run({ selection = SENTENCE, stored = { ["llm.agent_system2"] = "typesafe" },
			entries = { Scenario.ENTRY, TYPESAFE_ENTRY } }, function(world)
			helpers.assert_eq(world.handlers.llm_agent_selection("tap_3"), false)
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system2"))
			helpers.assert_eq(#world.posts, 0)
			local Settings = require("modules.llm.agent_settings")
			helpers.assert_eq(Settings.set_spec("system2", "typesafe"), false, "the menu cannot store it")
			helpers.assert_eq(Settings.set_spec("system1", "typesafe"), true, "System 1 can")
			local offered = {}
			for _, choice in ipairs(Settings.backend_choices("system2")) do offered[choice.value] = true end
			helpers.assert_true(not offered.typesafe and not offered.openrouter_jev and offered.backboard)
		end)
	end)
end)
