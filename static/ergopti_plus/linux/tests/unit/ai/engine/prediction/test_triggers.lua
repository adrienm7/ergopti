--- tests/unit/ai/engine/prediction/test_triggers.lua

--- ==============================================================================
--- MODULE: Linux Automatic LLM Prediction Triggers
--- DESCRIPTION:
--- Pins ordinary inactivity, immediate word-end, and post-hotstring scheduling.
--- A setting is not parity if it only persists or ticks a menu row: each test
--- observes the production timer seam that can actually reach a model request.
--- ==============================================================================

local helpers = require("tests.helpers")
local ProfilesFixture = require("tests.support.llm_profiles_fixture")
local Fakes = helpers.load_module("tests.fakes")

local held = {}
local inventory_profiles

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["ai.engine.prediction.engine"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
	if inventory_profiles then inventory_profiles.assert_no_inventory(); inventory_profiles = nil end
end

local function fixture(values, preview_showing)
	local scheduler = Fakes.timer_scheduler()
	values = values or {}
	replace("ai.engine.settings.trigger_settings", {
		get = function(name)
			if values[name] ~= nil then return values[name] end
			if name == "debounce_ms" then return 500 end
			if name == "min_request_interval_ms" then return 300 end
			if name == "instant_on_word_end" or name == "after_hotstring" then return true end
			if name == "while_hotstring_tooltip" then return "wait" end
			return false
		end,
		set = function() return true end,
	})
	inventory_profiles = ProfilesFixture.without_inventory({
		init = function() return true end,
		is_enabled = function() return true end,
	})
	replace("ai.engine.settings.profiles", inventory_profiles)
	package.loaded["ai.engine.prediction.engine"] = nil
	local engine = require("ai.engine.prediction.engine")
	local fired = {}
	engine.init({ focus_id = function() return "owned-prediction-window" end, scheduler = scheduler,
		hotstring_preview_showing = preview_showing })
	engine.predict = function(context, output_context)
		fired[#fired + 1] = { context = context, output_context = output_context }
	end
	return engine, scheduler, fired
end

helpers.describe("prediction triggers: ordinary typing and word boundaries", function()
	helpers.it("rejects a scheduler handle that was never armed", function()
		local engine, _, fired = fixture()
		engine.init({ focus_id = function() return "owned-prediction-window" end, scheduler = {
			after = function() return { armed = false, fired = true } end,
			cancel = function() end,
		} })
		helpers.assert_eq(engine.on_hotstring_expired("hello", { app_id = "editor" }), false,
			"an unarmed timer must not be reported as a scheduled prediction")
		helpers.assert_eq(#fired, 0)
		restore()
	end)

	helpers.it("does not retain a debounce timer that fires before admission returns", function()
		local engine, _, fired = fixture()
		engine.init({ focus_id = function() return "owned-prediction-window" end, scheduler = {
			after = function(_, callback) callback(); return { armed = true } end,
			cancel = function() return true end,
		} })
		helpers.assert_eq(engine.on_hotstring_expired("hello", { app_id = "editor" }), false)
		helpers.assert_eq(engine.is_predicting(), false)
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

	helpers.it("retains refused debounce timer cancellation across withdrawal and configuration", function()
		local engine, scheduler = fixture({ instant_on_word_end = false })
		local cancel, refused = scheduler.cancel, true
		scheduler.cancel = function(handle) if refused then return false end; return cancel(handle) end
		engine.on_char("o", "hello", { app_id = "editor" })
		helpers.assert_true(scheduler.activeCount() > 0)
		engine.withdraw()
		local owner = { pending = function() return false end }
		helpers.assert_true(engine.acquire_configuration(owner))
		helpers.assert_nil(engine.configuration_snapshot(owner), "a live timer cannot disappear from configuration ownership")
		refused = false
		helpers.assert_true(engine.release_configuration(owner))
		restore()
	end)

	helpers.it("shutdown keeps a refused prediction timer until cancellation is acknowledged", function()
		local engine, scheduler = fixture({ instant_on_word_end = false })
		local original, refused = scheduler.cancel, true
		scheduler.cancel = function(handle) if refused then return false end; return original(handle) end
		engine.on_char("o", "hello", { app_id = "editor" })
		helpers.assert_eq(engine.shutdown_runtime(), false)
		helpers.assert_eq(engine.runtime_pending(), true)
		refused = false
		helpers.assert_true(engine.shutdown_runtime())
		helpers.assert_eq(engine.runtime_pending(), false)
		restore()
	end)

	helpers.it("does not allocate unbounded timers after persistent cancellation failure", function()
		local engine, scheduler, fired = fixture({ instant_on_word_end = false })
		local original, refused = scheduler.cancel, true
		scheduler.cancel = function(handle) if refused then return false end; return original(handle) end
		for index = 1, 20 do engine.on_char("a", string.rep("a", index), { app_id = "editor" }) end
		helpers.assert_true(scheduler.activeCount() <= 1, "a rejected timer must block allocating successors")
		refused = false
		engine.on_char("b", "fresh text", { app_id = "editor" })
		scheduler.test.advance(0.5)
		helpers.assert_eq(#fired, 1, "prediction resumes after timer cleanup succeeds")
		helpers.assert_eq(fired[1].context, "fresh text")
		engine.withdraw()
		helpers.assert_eq(engine.runtime_pending(), false)
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

	helpers.it("never covers the preview when post-hotstring chaining is disabled", function()
		local engine, scheduler, fired = fixture({ after_hotstring = false })
		engine.on_char("w", "btw", {
			app_id = "editor",
			hotstring_preview_visible = true,
		})
		helpers.assert_eq(scheduler.test.advance(1), 0)
		helpers.assert_eq(#fired, 0, "waiting is the default: the preview can still expand")
		helpers.assert_eq(engine.on_hotstring_expired("btw"), false)
		restore()
	end)

	helpers.it("uses ordinary debounce beside the preview when both are shown", function()
		local engine, scheduler, fired = fixture({ after_hotstring = false, while_hotstring_tooltip = "both" })
		engine.on_char("w", "btw", {
			app_id = "editor",
			hotstring_preview_visible = true,
		})
		helpers.assert_eq(scheduler.test.advance(0.5), 1)
		helpers.assert_eq(#fired, 1)
		helpers.assert_eq(engine.on_hotstring_expired("btw"), false)
		restore()
	end)

	helpers.it("drops a debounce armed before the preview appeared", function()
		local showing = false
		local engine, scheduler, fired = fixture({ instant_on_word_end = false }, function() return showing end)
		engine.on_char("t", "bt", { app_id = "editor" })
		-- The next keystroke's preview is drawn before its own on_char runs; the
		-- request armed by "t" must not fire over it.
		showing = true
		helpers.assert_eq(scheduler.test.advance(0.5), 1)
		helpers.assert_eq(#fired, 0, "a request armed earlier waits for the preview too")
		showing = false
		helpers.assert_true(engine.on_hotstring_expired("bt", { app_id = "editor" }))
		helpers.assert_eq(scheduler.test.advance(0), 1)
		helpers.assert_eq(#fired, 1, "the preview's expiry asks again")
		restore()
	end)

	helpers.it("lets a request armed before the preview fire beside it when both are shown", function()
		local engine, scheduler, fired = fixture({ instant_on_word_end = false, while_hotstring_tooltip = "both" },
			function() return true end)
		engine.on_char("t", "bt", { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0.5), 1)
		helpers.assert_eq(#fired, 1)
		restore()
	end)

	helpers.it("keeps an explicit trigger even while the preview shows", function()
		local engine, scheduler, fired = fixture({}, function() return true end)
		engine.on_char("/", "btw //", { app_id = "editor", hotstring_preview_visible = true })
		helpers.assert_eq(scheduler.test.advance(1), 1)
		helpers.assert_eq(#fired, 1, "a request the user typed a trigger for is not held")
		restore()
	end)
end)

helpers.describe("prediction triggers: preview expiry bridge", function()
	helpers.it("hides and rejects a preview whose expiry cannot be armed", function()
		local hidden = 0
		replace("core.events.timer_scheduler", {
			after = function() return { armed = false, fired = true } end,
			cancel = function() end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() return true end,
			hide = function() hidden = hidden + 1; return true end,
			is_visible = function() return hidden == 0 end,
			destroy = function() return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
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
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
	end)

	helpers.it("publishes expiry only after the rendered bubble's own delay", function()
		local scheduler = Fakes.timer_scheduler()
		local expired = 0
		replace("core.events.timer_scheduler", scheduler)
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() return true end,
			hide = function() return true end,
			is_visible = function() return true end,
			destroy = function() return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
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
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
	end)

	helpers.it("(preview-expiry-stale) ignores a cancelled timer after a newer preview", function()
		local callbacks, hidden, expired = {}, 0, 0
		replace("core.events.timer_scheduler", {
			after = function(_, callback) callbacks[#callbacks + 1] = callback; return { armed = true } end,
			cancel = function() return true end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end, show = function() return true end,
			hide = function() hidden = hidden + 1; return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_expire = function() expired = expired + 1 end })
		local candidate = { { replacement = "text", group = "rolls", fires = true } }
		assert(preview.show(candidate, "autocorrect")); assert(preview.show(candidate, "autocorrect"))
		callbacks[1]()
		local observed = { showing = preview.is_showing(), hidden = hidden, expired = expired }
		callbacks[2]()
		observed.after_showing, observed.after_expired = preview.is_showing(), expired
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq(observed, { showing = true, hidden = 0, expired = 0, after_showing = false, after_expired = 1 })
	end)

	helpers.it("(preview-expiry-stale) ignores queued timers after a cover or failed redraw", function()
		local callbacks, hidden, expired, draws = {}, 0, 0, 0
		replace("core.events.timer_scheduler", {
			after = function(_, callback) callbacks[#callbacks + 1] = callback; return { armed = true } end,
			cancel = function() return false end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() draws = draws + 1; return draws ~= 3 end,
			hide = function() hidden = hidden + 1; return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_expire = function() expired = expired + 1 end })
		local candidate = { { replacement = "text", group = "rolls", fires = true } }
		assert(preview.show(candidate, "autocorrect")); preview.note_covered(); callbacks[1]()
		local after_cover = hidden
		assert(preview.show(candidate, "autocorrect")); assert(preview.show(candidate, "autocorrect") == false)
		callbacks[2]()
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq({ after_cover = after_cover, hidden = hidden, expired = expired },
			{ after_cover = 0, hidden = 1, expired = 0 })
	end)

	helpers.it("(preview-expiry-stale) does not retain a timer that fires before after returns", function()
		local hidden, expired, cancelled = 0, 0, 0
		replace("core.events.timer_scheduler", {
			after = function(_, callback) callback(); return { armed = true } end,
			cancel = function() cancelled = cancelled + 1; return true end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end, show = function() return true end,
			hide = function() hidden = hidden + 1; return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_expire = function() expired = expired + 1 end })
		local accepted = preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
		local showing = preview.is_showing()
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq({ accepted = accepted, showing = showing, hidden = hidden, expired = expired, cancelled = cancelled },
			{ accepted = false, showing = false, hidden = 1, expired = 1, cancelled = 1 })
	end)

	helpers.it("(preview-expiry-stale) does not publish expiry over a reentrant replacement", function()
		local callbacks, expired = {}, 0
		replace("core.events.timer_scheduler", {
			after = function(_, callback) callbacks[#callbacks + 1] = callback; return { armed = true } end,
			cancel = function() return true end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end, show = function() return true end,
			hide = function() return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		local candidate = { { replacement = "text", group = "rolls", fires = true } }
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_hidden = function() preview.show(candidate, "autocorrect") end,
			on_expire = function() expired = expired + 1 end })
		assert(preview.show(candidate, "autocorrect")); callbacks[1]()
		local showing = preview.is_showing()
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq({ showing = showing, expired = expired }, { showing = true, expired = 0 })
	end)

	for _, action in ipairs({ "hide", "note_covered", "destroy" }) do
	helpers.it("(preview-cancel-reentry) keeps a replacement opened during " .. action, function()
		local preview, hidden, again = nil, 0, false
		local candidate = { { replacement = "text", group = "rolls", fires = true } }
		replace("core.events.timer_scheduler", {
			after = function() return { armed = true } end,
			cancel = function()
				if not again then again = true; preview.show(candidate, "autocorrect") end
				return true
			end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end, show = function() return true end,
			hide = function() hidden = hidden + 1; return true end,
			destroy = function() hidden = hidden + 1; return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end } })
		assert(preview.show(candidate, "autocorrect")); preview[action]()
		local showing = preview.is_showing()
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq({ showing = showing, hidden = hidden }, { showing = true, hidden = 0 })
	end)
	end

	helpers.it("(preview-hide-debt) delays expiry until a refused hide is acknowledged", function()
		local callback, expired, allowed, hides = nil, 0, false, 0
		replace("core.events.timer_scheduler", {
			after = function(_, fn) callback = fn; return { armed = true } end,
			cancel = function() return true end,
		})
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end, show = function() return true end,
			hide = function() hides = hides + 1; return allowed end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_expire = function() expired = expired + 1 end })
		assert(preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect"))
		callback()
		local before = { expired = expired, ready = preview.render_ready(), showing = preview.is_showing() }
		allowed = true
		local settled = preview.retry_render_cleanup()
		local after = { expired = expired, ready = preview.render_ready(), settled = settled, hides = hides }
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
		helpers.assert_eq(before, { expired = 0, ready = false, showing = false })
		helpers.assert_eq(after, { expired = 1, ready = true, settled = true, hides = 2 })
	end)

	helpers.it("(preview-destroy-expiry) retires its timer and rows before a new owner draws", function()
		local scheduler = Fakes.timer_scheduler()
		local hidden, expired = 0, 0
		replace("core.events.timer_scheduler", scheduler)
		replace("core.ui.adapters.graphics_renderer", {
			is_available = function() return true end,
			show = function() return true end,
			hide = function() hidden = hidden + 1; return true end,
			is_visible = function() return true end,
			destroy = function() return true end,
		})
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		local preview = require("core.ui.ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_expire = function() expired = expired + 1 end })
		helpers.assert_true(preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect"))
		preview.destroy()
		helpers.assert_eq(preview.is_showing(), false)
		helpers.assert_eq(preview.showing_rows(), nil)
		helpers.assert_eq(scheduler.test.advance(0.25), 0)
		helpers.assert_eq(hidden, 0, "the retired timer must not hide a successor")
		helpers.assert_eq(expired, 0)
		package.loaded["core.ui.ui.tooltip.preview"] = nil
		restore()
	end)
end)
