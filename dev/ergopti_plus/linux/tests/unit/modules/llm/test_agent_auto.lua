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
--- next keystroke.
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
		if post.body.messages[1].content == prompt then list[#list + 1] = post end
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

--- The posts that ask System 2 for actions.
--- @param world table
--- @return integer
local function system2_posts(world)
	local count = 0
	for _, post in ipairs(world.posts) do
		if post.body.messages[1].content:find("You prepare actions", 1, true) then count = count + 1 end
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

	helpers.it("a hotstring preview, live mode, another AI tooltip or an excluded app block it", function()
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
		Scenario.run({ stored = auto({ ["llm.trigger.debounce_ms"] = 500 }) }, function(world)
			type_and_pause(world)
			helpers.assert_eq(#world.posts, 1, "the menu's prediction went first")
			helpers.assert_eq(#triages(world), 0, "and its request blocks the triage")
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
