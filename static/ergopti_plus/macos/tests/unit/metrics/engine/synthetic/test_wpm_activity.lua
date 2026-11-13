--- tests/unit/metrics/engine/synthetic/test_wpm_activity.lua

--- Real keystats callbacks own the real input timestamp and independent holds.

local helpers = require("tests.helpers")
local fixtures = require("tests.support.keystats_provenance_fixture")
local Model = require("metrics.engine.wpm_widget_model")

helpers.describe("keystats WPM activity", function()
	helpers.it("(wpm-source-parity) preserves priorities, physical provenance and reset ownership", function()
		local fixture = fixtures.load_keystats()
		fixture.hs.caffeinate = { watcher = { new = function()
			return { start = function(self) return self end, stop = function(self) return self end }
		end } }
		fixture.start()
		local now = 10000
		fixture.hs.timer.absoluteTime = function() return now * 1000000 end
		local hold = require("core.timing.engine.timings").ms("ui", "wpm_color_hold_ms")
		local canon = require("metrics.ui.wpm.shared").canon()
		local log = package.loaded["metrics.engine.journal.log_manager"]
		log.append_log = function() return true end
		local function key_event(event)
			function event:getType() return fixture.hs.eventtap.event.types.keyDown end
			function event:getKeyCode() return 0 end
			function event:getFlags() return {} end
			function event:getCharacters() return "a" end
			return event
		end
		local errors = {}
		package.loaded["core.logger.engine.logger"].error = function(_, message) errors[#errors + 1] = message end
		local physical = key_event(fixtures.physical_key(fixture.hs, "a"))
		fixture.dispatch(physical)
		helpers.assert_eq(fixture.keystats.get_live_stats().last_input_time, 10)
		helpers.assert_true(fixture.keystats.notify_synthetic("AI", "llm", 0, "stream"))
		now = 10000 + hold / 4
		helpers.assert_true(fixture.keystats.notify_synthetic("expand", "hotstring", 0, "magickey"))
		now = 10000 + hold / 2
		helpers.assert_true(fixture.keystats.notify_synthetic("correct", "hotstring", 0, "autocorrection"))
		now = 10000 + hold * 3 / 4
		helpers.assert_true(fixture.keystats.notify_synthetic("repeat", "hotstring", 0, "repeat_key"))
		fixture.dispatch(key_event(fixtures.tagged_key(fixture.synthetic_input, "wpm-test", "replacement", "x")))
		fixture.drain()
		helpers.assert_eq(errors, {}, "both physical and tagged callbacks must complete without hidden failures")
		local function source(at)
			now = at
			local live = fixture.keystats.get_live_stats()
			helpers.assert_eq(live.last_input_time, 10, "logical text and tagged echoes are not real input")
			return Model.active_source(live, hold / 1000, now / 1000, canon)
		end
		helpers.assert_eq(source(now), "llm", "AI wins even with a stream variant and newer sources")
		helpers.assert_eq(source(10000 + hold), "magickey")
		helpers.assert_eq(source(10000 + hold * 5 / 4), "autocorrection")
		helpers.assert_eq(source(10000 + hold * 3 / 2), "none")
		helpers.assert_true(fixture.keystats.notify_synthetic("", "llm", 1))
		helpers.assert_eq(source(now), "none", "deletion-only output cannot hold AI colour")
		helpers.assert_true(fixture.keystats.reset_session())
		helpers.assert_eq(fixture.keystats.get_live_stats().last_input_time, nil)
		helpers.assert_eq(#fixture.keystats.get_live_stats().source_holds, 0)
		helpers.assert_true(fixture.keystats.notify_synthetic("AI", "llm", 0))
		helpers.assert_true(fixture.keystats.stop())
		helpers.assert_eq(fixture.keystats.get_live_stats().last_input_time, nil)
		helpers.assert_eq(#fixture.keystats.get_live_stats().source_holds, 0, "stop retires held sources")
		helpers.assert_true(fixture.keystats.start())
		helpers.assert_eq(#fixture.keystats.get_live_stats().source_holds, 0, "restart cannot revive old colour")
		helpers.assert_true(fixture.keystats.stop())
	end)
	helpers.it("(wpm-source-parity) the user's metrics pause retires held sources", function()
		-- The Mac check « WPM … pause/restart removes old holds » (TODO, To confirm
		-- on the Mac): the metrics pause of the menu, not only a session reset or a
		-- stop, must leave no source colour to paint once collection resumes.
		local fixture = fixtures.load_keystats()
		fixture.hs.caffeinate = { watcher = { new = function()
			return { start = function(self) return self end, stop = function(self) return self end }
		end } }
		fixture.start()
		local now = 10000
		fixture.hs.timer.absoluteTime = function() return now * 1000000 end
		package.loaded["metrics.engine.journal.log_manager"].append_log = function() return true end
		-- The fixture's context tracker carries no foreground interval to close.
		local tracker = package.loaded["metrics.engine.context_tracker"]
		tracker.suspend_collection_context = function() end
		tracker.resume_collection_context = function() end
		helpers.assert_true(fixture.keystats.notify_synthetic("AI", "llm", 0, "stream"))
		helpers.assert_true(fixture.keystats.notify_synthetic("correct", "hotstring", 0, "autocorrection"))
		helpers.assert_true(#fixture.keystats.get_live_stats().source_holds > 0, "two sources are held before the pause")
		fixture.keystats.suspend_collection()
		helpers.assert_eq(#fixture.keystats.get_live_stats().source_holds, 0, "the pause retires held sources")
		fixture.keystats.resume_collection()
		helpers.assert_eq(#fixture.keystats.get_live_stats().source_holds, 0, "resuming cannot revive old colour")
		helpers.assert_true(fixture.keystats.stop())
	end)
end)
