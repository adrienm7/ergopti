--- tests/unit/platform/system/runtime/test_timer_scheduler_hotstring_clock.lua
local helpers = require("tests.helpers")

helpers.describe("hotstring clock sleep and clock changes (hotstring-clock-wake)", function()
	helpers.it("advances through sleep, tolerates rollback and ignores invalid samples and jitter", function()
		local saved = package.loaded["core.events.timer_scheduler"]
		local Scheduler = helpers.load_with_stubs("core.events.timer_scheduler")
		local awake, wall = 100, 1000
		local original_awake = Scheduler.awake_time
		Scheduler.awake_time = function() return awake end
		hs.timer.secondsSinceEpoch = function() return wall end
		local ok, err = pcall(function()
			helpers.assert_eq(Scheduler.hotstring_time(), 100)
			for _ = 1, 20 do
				awake, wall = awake + 1, wall + 1.05
				Scheduler.hotstring_time()
			end
			helpers.assert_eq(Scheduler.hotstring_time(), 120, "small sampling differences must not accumulate")
			awake, wall = 121, 900
			helpers.assert_eq(Scheduler.hotstring_time(), 121, "clock rollback cannot rewind deadlines")
			awake, wall = 122, 961
			helpers.assert_eq(Scheduler.hotstring_time(), 182, "one awake second plus sixty sleeping seconds")
			awake, wall = 123, 1322
			helpers.assert_eq(Scheduler.hotstring_time(), 543, "forward clock correction expires deadlines conservatively")
			awake, wall = 124, nil
			helpers.assert_eq(Scheduler.hotstring_time(), 544, "invalid civil time preserves awake progress")
			awake, wall = 125, 5000
			helpers.assert_eq(Scheduler.hotstring_time(), 545, "a restored sample rebases without inventing sleep")
			for _, invalid in ipairs({ math.huge, -math.huge, 0/0 }) do
				awake, wall = awake + 1, invalid
				helpers.assert_eq(Scheduler.hotstring_time(), awake + 420, "nonfinite wall samples do not poison the clock")
			end
			hs.timer.secondsSinceEpoch = function() error("clock unavailable") end
			awake = awake + 1
			helpers.assert_eq(Scheduler.hotstring_time(), awake + 420, "a throwing civil clock cannot stop deadlines")
		end)
		Scheduler.awake_time = original_awake
		package.loaded["core.events.timer_scheduler"] = saved
		if not ok then error(err, 0) end
	end)
end)
