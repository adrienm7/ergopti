--- tests/unit/modules/llm/test_agent_automatic_mode.lua

--- ==============================================================================
--- MODULE: AI Agent Automatic Mode and Learning (macOS)
--- DESCRIPTION:
--- Runs the automatic mode of the agent over the real runner, shared logic,
--- prediction engine and remote backend (tests/support/agent_world.lua): a
--- pause in the typing sends the sentence to System 1, a triage above the
--- threshold of its intent in the application wakes System 2, and its
--- actions are offered. Accepting one lowers that threshold, dismissing one
--- raises it, and the thresholds survive a reload from the storage adapter.
---
--- ROOT CAUSES ENCODED:
--- 1. The automatic mode must stay silent unless asked: nothing below the
---    threshold, never the same sentence twice, nothing a keystroke made
---    stale, never over a hotstring tooltip or live mode, never in an excluded
---    application.
--- 2. The automatic mode needs System 1: the toggle refuses without it and
---    changes nothing.
--- 3. What was learned belongs to one application and one intent, and is kept
---    in the local state store, not config.toml.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")

local Agent = require("llm.agent")

local CONFIG = World.CONFIG
local SENTENCE = "Rappelle-moi d'appeler Paul demain à 9h"
local REMINDER = 'ACTIONS: [{"type":"reminder","title":"Appeler Paul","due":"2026-09-30T09:00"}]'

--- Builds an automatic-mode world.
--- @param options table|nil Overrides of World.build_world.
--- @return table world
local function auto_world(options)
	options = options or {}
	options.mode = options.mode or "auto"
	if options.system1 == nil then options.system1 = "cerebras" end
	local world = World.build_world(options)
	world.learning = require("modules.llm.agent_learning")
	return world
end

--- Types a buffer and lets the typing pause elapse.
--- @param world table
--- @param buffer string
local function pause_after(world, buffer)
	world.runner.observe_typing(buffer)
	World.settle(world)
end

--- Answers a System 1 request with a triage.
local function triage(post, intent, probability)
	World.answer(post, "INTENT: " .. intent .. "\nPROBABILITY: " .. tostring(probability))
end

helpers.describe("AI agent automatic mode (macOS)", function()
	helpers.it("triages the sentence after a pause, then offers System 2's actions", function()
		local world = auto_world()
		pause_after(world, "Bonjour. " .. SENTENCE)
		helpers.assert_eq(#world.posts, 1, "one System 1 request")
		local post = world.posts[1]
		helpers.assert_eq(post.body.messages[1].content,
			Agent.system1_prompt(CONFIG, { app = "Notes", tools = { "Mode focus" } }), "the system1 prompt")
		helpers.assert_eq(post.body.messages[2].content, SENTENCE, "the current sentence only")
		helpers.assert_eq(post.body.max_tokens, CONFIG.system1.max_tokens)

		triage(post, "reminder", 0.9)
		helpers.assert_eq(#world.posts, 2, "System 2 is asked")
		helpers.assert_true(world.posts[2].body.messages[1].content:find(CONFIG.source_kinds.typing, 1, true) ~= nil,
			"the prompt names typing")
		helpers.assert_eq(world.posts[2].body.messages[2].content, Agent.system2_user_text(CONFIG, SENTENCE))
		helpers.assert_eq(world.loadings, 0, "no loading row while typing")

		World.answer(world.posts[2], REMINDER)
		helpers.assert_eq(#world.renders, 1)
		helpers.assert_eq(world.renders[1].texts[1], "⏰ Appeler Paul — 2026-09-30 09:00")
		helpers.assert_eq(#world.notices, 0, "the automatic mode shows no notice")
	end)

	helpers.it("stays silent below the threshold, and on a sentence already triaged", function()
		local world = auto_world()
		pause_after(world, SENTENCE)
		triage(world.posts[1], "reminder", 0.5)
		helpers.assert_eq(#world.posts, 1, "no System 2 request under the threshold")
		pause_after(world, SENTENCE .. " ")
		helpers.assert_eq(#world.posts, 1, "the same sentence is not triaged twice")
		pause_after(world, "court")
		helpers.assert_eq(#world.posts, 1, "a sentence under min_chars is not triaged")
		triage(world.posts[1], "none", 0.99)
		helpers.assert_eq(#world.posts, 1)
	end)

	helpers.it("drops what a keystroke made stale", function()
		local world = auto_world()
		pause_after(world, SENTENCE)
		world.runner.observe_typing(SENTENCE .. " e")
		triage(world.posts[1], "reminder", 0.95)
		helpers.assert_eq(#world.posts, 1, "the stale triage wakes nothing")

		local other = auto_world()
		pause_after(other, SENTENCE)
		triage(other.posts[1], "reminder", 0.95)
		other.runner.observe_typing(SENTENCE .. " e")
		World.answer(other.posts[2], REMINDER)
		helpers.assert_eq(#other.renders, 0, "the stale actions are not offered")

		local covered = auto_world()
		pause_after(covered, SENTENCE)
		triage(covered.posts[1], "reminder", 0.95)
		covered.hotstring_visible = true
		World.answer(covered.posts[2], REMINDER)
		helpers.assert_eq(#covered.renders, 0, "a hotstring tooltip shown meanwhile wins")
	end)

	helpers.it("never triages over a hotstring tooltip, in live mode, or in an excluded application", function()
		local world = auto_world()
		world.hotstring_visible = true
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 0, "a hotstring tooltip wins")
		world.hotstring_visible = false

		world.engine.get_live_prompt = function() return { profile_id = "rewrite" } end
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 0, "live mode disables the automatic mode")
		world.engine.get_live_prompt = function() return nil end

		helpers.assert_eq(world.runner.set_disabled_apps({ { name = "Notes" } }), true)
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 0, "an excluded application is never read")
		world.runner.set_disabled_apps({})

		world.runner.set_mode("action")
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 0, "the action mode never triages")
		world.runner.set_mode("auto")
		pause_after(world, SENTENCE)
		helpers.assert_eq(#world.posts, 1, "and the automatic mode does")
	end)

	helpers.it("toggles the automatic mode, and refuses it without System 1", function()
		local world = auto_world({ system1 = "", mode = "action" })
		local persisted = {}
		world.runner.set_mode_persister(function(mode)
			persisted[#persisted + 1] = mode
			return world.runner.set_mode(mode)
		end)
		World.trigger(world, "llm_agent_auto_toggle")
		helpers.assert_eq(world.notices[1], world.i18n.get("llm.agent.no_system1"))
		helpers.assert_eq(#persisted, 0, "nothing is persisted")
		helpers.assert_eq(select(2, world.runner.get_runtime_setting("llm_agent_mode")), "action", "the mode is unchanged")

		world.runner.set_system1("cerebras")
		World.trigger(world, "llm_agent_auto_toggle")
		helpers.assert_eq(persisted[1], "auto")
		helpers.assert_eq(world.notices[2], world.i18n.get("llm.agent.auto_on"))
		World.trigger(world, "llm_agent_auto_toggle")
		helpers.assert_eq(persisted[2], "action")
		helpers.assert_eq(world.notices[3], world.i18n.get("llm.agent.auto_off"))
		world.runner.set_mode_persister(nil)
	end)
end)

helpers.describe("AI agent learning (macOS)", function()
	helpers.it("an accepted suggestion lowers the threshold of its intent in its application", function()
		local world = auto_world()
		pause_after(world, SENTENCE)
		triage(world.posts[1], "reminder", 0.9)
		World.answer(world.posts[2], REMINDER)
		World.accept(world, 1)
		helpers.assert_eq(world.runs[1].action.type, "reminder")
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "reminder"), 0.65)
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "calendar"), CONFIG.system1.threshold,
			"another intent keeps its own")
		helpers.assert_eq(world.learning.threshold(CONFIG, "Mail", "reminder"), CONFIG.system1.threshold,
			"another application keeps its own")

		-- The lowered threshold decides the next triage
		pause_after(world, "Et rappelle-moi aussi le devis vendredi")
		triage(world.posts[3], "reminder", 0.66)
		helpers.assert_eq(#world.posts, 4, "0.66 now clears the learned threshold")
	end)

	helpers.it("a dismissed suggestion raises it, within the bounds", function()
		local world = auto_world()
		pause_after(world, SENTENCE)
		triage(world.posts[1], "reminder", 0.9)
		World.answer(world.posts[2], REMINDER)
		world.engine.reset()
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "reminder"), 0.75)
		for _ = 1, 10 do world.learning.record(CONFIG, "Notes", "reminder", false) end
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "reminder"), CONFIG.learning.max_threshold)
		for _ = 1, 20 do world.learning.record(CONFIG, "Notes", "reminder", true) end
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "reminder"), CONFIG.learning.min_threshold)
	end)

	helpers.it("keeps the thresholds in the local state store across a reload", function()
		local world = auto_world()
		world.learning.record(CONFIG, "Notes", "mail", true)
		world.learning.record(CONFIG, "Mail", "mail", false)
		helpers.assert_eq(world.learning.flush(), true)
		local Storage = require("adapters.storage")
		local ok, stored = Storage.read_exact(world.learning.STORAGE_KEY)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(type(stored), "table", "the map is in the storage adapter")
		world.learning.reset()
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "mail"), 0.65, "reloaded")
		helpers.assert_eq(world.learning.threshold(CONFIG, "Mail", "mail"), 0.75, "each application its own")
	end)

	helpers.it("reloads only flushed learning while a later change waits for its debounce", function()
		local world = auto_world()
		world.learning.record(CONFIG, "Notes", "mail", true)
		helpers.assert_eq(world.learning.flush(), true)
		local saved = world.learning.threshold(CONFIG, "Notes", "mail")
		local changed = world.learning.record(CONFIG, "Notes", "mail", false)
		helpers.assert_true(changed ~= saved, "the pending change must be observable in memory")
		local Storage = require("adapters.storage")
		local ok, stored = Storage.read_exact(world.learning.STORAGE_KEY)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(stored.apps.Notes.intents.mail, saved,
			"an unflushed map mutation must not update native persisted settings")
		world.learning.reset()
		helpers.assert_eq(world.learning.threshold(CONFIG, "Notes", "mail"), saved,
			"cancelled debounce must reload the acknowledged snapshot")
	end)

	helpers.it("keeps at most MAX_APPS applications, dropping the least recently used", function()
		local world = auto_world()
		local learning = world.learning
		for index = 1, learning.MAX_APPS + 1 do learning.record(CONFIG, "App" .. index, "mail", true) end
		helpers.assert_eq(learning.threshold(CONFIG, "App1", "mail"), CONFIG.system1.threshold, "the oldest is dropped")
		helpers.assert_eq(learning.threshold(CONFIG, "App2", "mail"), 0.65)
		helpers.assert_eq(learning.threshold(CONFIG, "App" .. (learning.MAX_APPS + 1), "mail"), 0.65)
	end)
end)
