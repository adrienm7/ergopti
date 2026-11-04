--- tests/unit/modules/llm/agent/test_agent_learning_store.lua

--- ==============================================================================
--- MODULE: Agent Learning Store Tests (macOS)
--- DESCRIPTION:
--- Pins the shared map behind the automatic mode's learned thresholds
--- (_shared/lua/llm/agent_learning_store.lua): an unseen pair keeps the
--- configured threshold, accepting lowers and dismissing raises it within the
--- bounds, each entry keeps its thresholds under the driver's field name, the
--- recency counter orders the applications, and the least recently used one is
--- dropped past MAX_APPS.
--- ==============================================================================

local helpers = require("tests.helpers")
local LearningStore = require("llm.agent_learning_store")

local CONFIG = {
	system1 = { threshold = 0.6 },
	learning = { step = 0.05, min_threshold = 0.3, max_threshold = 0.9 },
}

helpers.describe("agent learning store (macOS)", function()
	helpers.it("refuses a store without its field name", function()
		helpers.assert_eq(pcall(LearningStore.new, ""), false)
		helpers.assert_eq(pcall(LearningStore.new), false)
	end)

	helpers.it("keeps the configured threshold for an unseen pair, whatever the application", function()
		local store = LearningStore.new("intents")
		local map = store.new_map()
		helpers.assert_eq(store.threshold(map, CONFIG, "Mail", "reply"), 0.6)
		helpers.assert_eq(store.threshold(map, CONFIG, nil, "reply"), 0.6)
		helpers.assert_eq(map.clock, 0)
	end)

	helpers.it("lowers on accept and raises on dismiss, within the bounds", function()
		local store = LearningStore.new("intents")
		local map = store.new_map()
		local after, before = store.record(map, CONFIG, "Mail", "reply", true)
		helpers.assert_eq(before, 0.6)
		helpers.assert_eq(after, 0.55)
		helpers.assert_eq(store.threshold(map, CONFIG, "Mail", "reply"), 0.55)
		helpers.assert_eq(store.threshold(map, CONFIG, "Mail", "other"), 0.6)
		for _ = 1, 20 do store.record(map, CONFIG, "Mail", "reply", true) end
		helpers.assert_eq(store.threshold(map, CONFIG, "Mail", "reply"), 0.3)
		for _ = 1, 40 do store.record(map, CONFIG, "Mail", "reply", false) end
		helpers.assert_eq(store.threshold(map, CONFIG, "Mail", "reply"), 0.9)
	end)

	helpers.it("keeps the thresholds under the driver's field name", function()
		local map = LearningStore.new("thresholds").new_map()
		LearningStore.new("thresholds").record(map, CONFIG, "Mail", "reply", false)
		helpers.assert_eq(map.apps.Mail.thresholds.reply, 0.65)
		helpers.assert_eq(map.apps.Mail.intents, nil)
		helpers.assert_eq(map.apps.Mail.used, 1)
	end)

	helpers.it("drops the least recently used application past MAX_APPS", function()
		local store = LearningStore.new("intents")
		local map = store.new_map()
		for index = 1, LearningStore.MAX_APPS do store.record(map, CONFIG, "App" .. index, "reply", true) end
		-- App1 becomes the most recent, so App2 is now the oldest.
		store.record(map, CONFIG, "App1", "reply", true)
		local _, _, dropped = store.record(map, CONFIG, "Newest", "reply", true)
		helpers.assert_eq(dropped, 1)
		helpers.assert_eq(map.apps.App2, nil)
		helpers.assert_true(map.apps.App1 ~= nil)
		helpers.assert_true(map.apps.Newest ~= nil)
		local count = 0
		for _ in pairs(map.apps) do count = count + 1 end
		helpers.assert_eq(count, LearningStore.MAX_APPS)
	end)
end)
