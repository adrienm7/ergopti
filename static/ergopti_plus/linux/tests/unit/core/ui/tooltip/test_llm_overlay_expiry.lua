--- tests/unit/core/ui/tooltip/test_llm_overlay_expiry.lua

--- ==============================================================================
--- MODULE: An AI Suggestion Left Alone Runs Out
--- DESCRIPTION:
--- Windows and macOS give a prediction the shared [timing] llm_timeout_sec less
--- the shared decrement; the Linux bubble stayed until the next activity
--- (TWL-003). The overlay now arms that lifetime at the offer's first shown
--- answer, keeps it across the offer's redraws, and a hide cancels it.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==========================================
-- ==========================================
-- ======= 1/ Lifetime of an AI offer =======
-- ==========================================
-- ==========================================

--- Runs a body with a recording scheduler and a fresh overlay.
--- @param body function Receives (overlay, timers, expired).
local function with_overlay(body)
	local saved = package.loaded["core.events.timer_scheduler"]
	local timers, expired = {}, { count = 0 }
	local ok, err = pcall(function()
		package.loaded["core.events.timer_scheduler"] = {
			after = function(delay, callback)
				local handle = { armed = true, delay = delay, callback = callback }
				timers[#timers + 1] = handle
				return handle
			end,
			cancel = function(handle) handle.armed = false; return true end,
		}
		local overlay = helpers.load_module("core.ui.ui.tooltip.llm")
		overlay.init({
			style = {},
			renderer = { show = function() return true end, hide = function() return true end },
			anchor_provider = function() return { type = "window", x = 0, y = 0, h = 0 } end,
			screen_provider = function() return { x = 0, y = 0, w = 100, h = 100 } end,
			on_expire = function() expired.count = expired.count + 1 end,
		})
		body(overlay, timers, expired)
	end)
	package.loaded["core.events.timer_scheduler"] = saved
	if not ok then error(err, 0) end
end

helpers.describe("AI overlay: an offer left alone runs out (twl-003-llm-timeout)", function()
	helpers.it("arms the shared lifetime once per offer and tells its owner", function()
		with_overlay(function(overlay, timers, expired)
			overlay.show({ { to_type = "…", deletes = 0 } }, { loading = true })
			helpers.assert_eq(#timers, 0, "a loading placeholder starts no lifetime")
			overlay.show({ { to_type = "que tout", deletes = 0 } }, {})
			overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
			helpers.assert_eq(#timers, 1, "a redraw of the same offer keeps its origin")
			local Config = require("core.ui.ui.tooltip.config")
			helpers.assert_eq(timers[1].delay, Config.llm_timeout_seconds())
			helpers.assert_true(timers[1].delay > 0 and timers[1].delay < 20)
			timers[1].callback()
			helpers.assert_eq(expired.count, 1, "the owner dismisses the offer")
		end)
	end)

	helpers.it("a hide cancels the lifetime and the next offer arms its own", function()
		with_overlay(function(overlay, timers, expired)
			overlay.show({ { to_type = "a", deletes = 0 } }, {})
			helpers.assert_true(overlay.hide())
			helpers.assert_eq(timers[1].armed, false)
			timers[1].callback()
			helpers.assert_eq(expired.count, 0, "a cancelled lifetime tells nobody")
			overlay.show({ { to_type = "b", deletes = 0 } }, {})
			helpers.assert_eq(#timers, 2)
		end)
	end)

	helpers.it("the daemon dismisses the engine's offer when it runs out", function()
		local fh = assert(io.open("ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local init = source:match("llm_overlay%.init(%b())")
		helpers.assert_true(init ~= nil and init:find("on_expire", 1, true) ~= nil
			and init:find("prediction_engine.dismiss()", 1, true) ~= nil, "on_expire dismisses the offer")
	end)
end)
