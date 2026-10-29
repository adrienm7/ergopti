--- tests/unit/ui/menu/menu_llm/backend/test_ai_health_watch_repaint.lua

--- ==============================================================================
--- MODULE: AI health watch repaints the AI title dot
--- DESCRIPTION:
--- The menubar keeps a static prebuilt menu. A backend (local API, MLX, Ollama)
--- turns ready after the build that painted a red dot, and nothing rebuilt the
--- menu, so the dot stayed red while predictions worked. The watch re-reads the
--- health after each build and repaints once when the dot would differ.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "ui.menu.menu_llm", "adapters.timer_scheduler" }

--- Loads the menu with a manual timer so each tick is driven by the test.
local function with_watch(fn)
	return helpers.with_fresh_modules(MODULES, function()
		local timers = { armed = 0, cancelled = 0, tick = nil }
		package.loaded["adapters.timer_scheduler"] = {
			every = function(_, tick)
				timers.armed = timers.armed + 1
				timers.tick = tick
				return { id = timers.armed }, true
			end,
			cancel = function() timers.cancelled = timers.cancelled + 1; timers.tick = nil; return true end,
			after = function() return {}, true end,
		}
		local MenuLlm = require("ui.menu.menu_llm")
		local ok, err = pcall(fn, MenuLlm, timers)
		MenuLlm.__stop_health_watch_for_test()
		if not ok then error(err, 0) end
	end)
end




-- ======================================================
-- ======================================================
-- ======= 1/ Repaint on readiness change ===============
-- ======================================================
-- ======================================================

helpers.describe("menu_llm — AI health watch", function()
	helpers.it("repaints once when the backend turns ready after the build", function()
		with_watch(function(MenuLlm, timers)
			local status, repaints = "unreachable", 0
			MenuLlm.__watch_health_for_test("unreachable", function() return status end,
				function() repaints = repaints + 1 end)
			helpers.assert_eq(timers.armed, 1, "a red dot must arm the watch")
			timers.tick()
			helpers.assert_eq(repaints, 0, "an unchanged dot must not rebuild the menu")
			status = "ready"
			timers.tick()
			helpers.assert_eq(repaints, 1, "the dot turning green must rebuild the menu")
			timers.tick()
			helpers.assert_eq(repaints, 1, "a dot already repainted must not rebuild again")
		end)
	end)

	helpers.it("keeps one timer across rebuilds and stops when the AI is off", function()
		with_watch(function(MenuLlm, timers)
			local read = function() return "ready" end
			MenuLlm.__watch_health_for_test("warming", read, function() end)
			MenuLlm.__watch_health_for_test("ready", read, function() end)
			helpers.assert_eq(timers.armed, 1, "rebuilds must reuse the running watch")
			MenuLlm.__watch_health_for_test(nil, read, function() end)
			helpers.assert_eq(timers.cancelled, 1, "a build without a dot must stop the watch")
		end)
	end)
end)
