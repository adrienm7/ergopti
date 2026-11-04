--- tests/unit/adapters/runtime/test_event_clock.lua
local helpers = require("tests.helpers")
local Clock = require("adapters.event_clock")

helpers.describe("event clock (event-clock-window)", function()
	helpers.it("measures stale events against the recent floor and retires old samples", function()
		local previous_hs = hs
		local now = 100000000000
		hs = { timer = { absoluteTime = function() return now end } }
		Clock.reset()
		local function event(age_ms)
			return { timestamp = function() return now - age_ms * 1000000 end }
		end
		local ok, err = pcall(function()
			helpers.assert_eq(Clock.is_stale(event(10)), false)
			helpers.assert_eq(Clock.is_stale(event(509)), false)
			helpers.assert_eq(Clock.is_stale(event(510)), true)
			for _ = 1, Clock.FLOOR_WINDOW do Clock.is_stale(event(510)) end
			helpers.assert_eq(Clock.is_stale(event(510)), false,
				"after the old floor expires, a constant offset is not lateness")
		end)
		Clock.reset()
		hs = previous_hs
		if not ok then error(err, 0) end
	end)

	helpers.it("uses the Apple-silicon scale and declines timestamps it cannot prove", function()
		local previous_hs = hs
		local now = 125000000000
		hs = { timer = { absoluteTime = function() return now end } }
		Clock.reset()
		local ok, err = pcall(function()
			local stamp = 3000000000
			local stale, _, read_stamp = Clock.is_stale({ timestamp = function() return stamp end })
			helpers.assert_eq(stale, false)
			helpers.assert_eq(read_stamp, stamp)
			helpers.assert_eq(Clock.duration_ms(stamp, stamp + 24000000), 1000)
			helpers.assert_eq(Clock.is_stale({ timestamp = function() return 0 end }), false)
			helpers.assert_eq(Clock.is_stale({ timestamp = function() error("unavailable") end }), false)
		end)
		Clock.reset()
		hs = previous_hs
		if not ok then error(err, 0) end
	end)
end)
