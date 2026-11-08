--- tests/unit/modules/keystats/synthetic/test_wpm_activity.lua

--- Real keystats callbacks own the real input timestamp and independent holds.

local helpers = require("tests.helpers")
local fixtures = require("tests.support.keystats_provenance_fixture")
local Model = require("wpm_widget.model")

helpers.describe("keystats WPM activity", function()
	helpers.it("(wpm-source-parity) preserves priorities, physical provenance and reset ownership", function()
		local fixture = fixtures.load_keystats()
		fixture.hs.caffeinate = { watcher = { new = function()
			return { start = function(self) return self end, stop = function(self) return self end }
		end } }
		fixture.start()
		local now = 10000
		fixture.hs.timer.absoluteTime = function() return now * 1000000 end
		local hold = require("infra.timings").ms("ui", "wpm_color_hold_ms")
		local canon = require("ui.wpm.shared").canon()
		local log = package.loaded["modules.keystats.log_manager"]
		log.append_log = function() return true end
		local function key_event(event)
			function event:getType() return fixture.hs.eventtap.event.types.keyDown end
			function event:getKeyCode() return 0 end
			function event:getFlags() return {} end
			function event:getCharacters() return "a" end
			return event
		end
		local errors = {}
		package.loaded["infra.logger"].error = function(_, message) errors[#errors + 1] = message end
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
end)
