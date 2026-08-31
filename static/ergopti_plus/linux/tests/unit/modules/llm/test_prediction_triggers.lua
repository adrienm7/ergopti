--- tests/unit/modules/llm/test_prediction_triggers.lua

--- ==============================================================================
--- MODULE: Linux Automatic LLM Prediction Triggers
--- DESCRIPTION:
--- Pins ordinary inactivity, immediate word-end, and post-hotstring scheduling.
--- A setting is not parity if it only persists or ticks a menu row: each test
--- observes the production timer seam that can actually reach a model request.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["modules.llm.prediction_engine"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

local function fixture(values)
	local scheduler = Fakes.timer_scheduler()
	values = values or {}
	replace("modules.llm.trigger_settings", {
		get = function(name)
			if values[name] ~= nil then return values[name] end
			if name == "debounce_ms" then return 500 end
			if name == "instant_on_word_end" or name == "after_hotstring" then return true end
			return false
		end,
		set = function() return true end,
	})
	replace("modules.llm.profiles", {
		init = function() end,
		is_enabled = function() return true end,
	})
	package.loaded["modules.llm.prediction_engine"] = nil
	local engine = require("modules.llm.prediction_engine")
	local fired = {}
	engine.init({ scheduler = scheduler })
	engine.predict = function(context, output_context)
		fired[#fired + 1] = { context = context, output_context = output_context }
	end
	return engine, scheduler, fired
end

helpers.describe("prediction triggers: ordinary typing and word boundaries", function()
	helpers.it("rejects a scheduler handle that was never armed", function()
		local engine, _, fired = fixture()
		engine.init({ scheduler = {
			after = function() return { armed = false, fired = true } end,
			cancel = function() end,
		} })
		helpers.assert_eq(engine.on_hotstring_expired("hello", { app_id = "editor" }), false,
			"an unarmed timer must not be reported as a scheduled prediction")
		helpers.assert_eq(#fired, 0)
		restore()
	end)

	helpers.it("debounces every ordinary character and cancels the stale snapshot", function()
		local engine, scheduler, fired = fixture({ instant_on_word_end = false })
		engine.on_char("o", "hello", { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0.499), 0)
		engine.on_char("!", "hello!", { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0.499), 0)
		helpers.assert_eq(scheduler.test.advance(0.001), 1)
		helpers.assert_eq(#fired, 1)
		helpers.assert_eq(fired[1].context, "hello!")
		restore()
	end)

	helpers.it("fires immediately when a boundary completes a word", function()
		local engine, scheduler, fired = fixture()
		engine.on_char(" ", "hello ", { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0), 1)
		helpers.assert_eq(#fired, 1)
		helpers.assert_eq(fired[1].context, "hello ")
		restore()
	end)

	helpers.it("does not mistake consecutive boundaries for another word end", function()
		local engine, scheduler, fired = fixture()
		engine.on_char(" ", "hello  ", { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0), 0)
		helpers.assert_eq(scheduler.test.advance(0.5), 1)
		helpers.assert_eq(#fired, 1)
		restore()
	end)
end)

helpers.describe("prediction triggers: hotstring preview ownership", function()
	helpers.it("waits for the preview expiry instead of racing its bubble", function()
		local engine, scheduler, fired = fixture()
		engine.on_char("w", "btw", {
			app_id = "editor",
			hotstring_preview_visible = true,
		})
		helpers.assert_eq(scheduler.test.advance(1), 0)
		helpers.assert_eq(#fired, 0)
		helpers.assert_true(engine.on_hotstring_expired("btw", { app_id = "editor" }))
		helpers.assert_eq(scheduler.test.advance(0), 1)
		helpers.assert_eq(fired[1].context, "btw")
		restore()
	end)

	helpers.it("uses ordinary debounce when post-hotstring chaining is disabled", function()
		local engine, scheduler, fired = fixture({ after_hotstring = false })
		engine.on_char("w", "btw", {
			app_id = "editor",
			hotstring_preview_visible = true,
		})
		helpers.assert_eq(scheduler.test.advance(0.5), 1)
		helpers.assert_eq(#fired, 1)
		helpers.assert_eq(engine.on_hotstring_expired("btw"), false)
		restore()
	end)
end)

helpers.describe("prediction triggers: preview expiry bridge", function()
	helpers.it("hides and rejects a preview whose expiry cannot be armed", function()
		local hidden = 0
		replace("adapters.timer_scheduler", {
			after = function() return { armed = false, fired = true } end,
			cancel = function() end,
		})
		replace("adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() return true end,
			hide = function() hidden = hidden + 1 end,
			is_visible = function() return hidden == 0 end,
			destroy = function() end,
		})
		package.loaded["ui.tooltip.preview"] = nil
		local preview = require("ui.tooltip.preview")
		preview.init({
			style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function()
				return { delay = 0.25, color = "#1e88e5", show_tooltip = true }
			end },
		})
		helpers.assert_eq(preview.show({
			{ trigger = "btw", replacement = "by the way", group = "rolls", fires = true },
		}, "autocorrect"), false)
		helpers.assert_eq(hidden, 1, "a preview without expiry ownership must not remain visible")
		package.loaded["ui.tooltip.preview"] = nil
		restore()
	end)

	helpers.it("publishes expiry only after the rendered bubble's own delay", function()
		local scheduler = Fakes.timer_scheduler()
		local expired = 0
		replace("adapters.timer_scheduler", scheduler)
		replace("adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() return true end,
			hide = function() end,
			is_visible = function() return true end,
			destroy = function() end,
		})
		package.loaded["ui.tooltip.preview"] = nil
		local preview = require("ui.tooltip.preview")
		preview.init({
			style = { positioning = { window_bottom_inset = 0 } },
			config = {
				resolve = function()
					return { delay = 0.25, color = "#1e88e5", show_tooltip = true }
				end,
			},
			on_expire = function() expired = expired + 1 end,
		})
		helpers.assert_true(preview.show({
			{ trigger = "btw", replacement = "by the way", group = "rolls", fires = true },
		}, "autocorrect"))
		helpers.assert_eq(scheduler.test.advance(0.249), 0)
		helpers.assert_eq(expired, 0)
		helpers.assert_eq(scheduler.test.advance(0.001), 1)
		helpers.assert_eq(expired, 1)
		package.loaded["ui.tooltip.preview"] = nil
		restore()
	end)
end)
