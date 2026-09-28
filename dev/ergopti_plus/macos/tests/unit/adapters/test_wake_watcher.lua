--- tests/unit/adapters/test_wake_watcher.lua

--- ==============================================================================
--- MODULE: Wake Watcher Adapter
--- DESCRIPTION:
--- The automatic update checks re-evaluate their schedule when the Mac wakes: a
--- timer does not count the time asleep, so a check that fell due during the
--- sleep would otherwise wait for the next bounded re-evaluation. The adapter
--- turns hs.caffeinate.watcher's systemDidWake into one callback, ignores the
--- other power events, and logs a throwing callback instead of losing it.
--- ==============================================================================

local helpers = require("tests.helpers")

local WAKE, SLEEP = 1, 2

--- Loads a fresh adapter over a recording caffeinate watcher.
local function load_adapter()
	local native = { started = 0, stopped = 0, callback = nil }
	package.loaded["adapters.wake_watcher"] = nil
	local Adapter = helpers.load_with_stubs("adapters.wake_watcher", {
		caffeinate = {
			watcher = {
				systemDidWake = WAKE,
				systemWillSleep = SLEEP,
				new = function(callback)
					native.callback = callback
					local object = {}
					function object:start() native.started = native.started + 1; return self end
					function object:stop() native.stopped = native.stopped + 1; return self end
					return object
				end,
			},
		},
	})
	return Adapter, native
end

helpers.describe("adapters.wake_watcher", function()
	helpers.it("calls back on a wake only", function()
		local Adapter, native = load_adapter()
		local wakes = 0
		local watcher = Adapter.new(function() wakes = wakes + 1 end)
		helpers.assert_true(watcher.start(), "the watcher starts")
		helpers.assert_eq(native.started, 1)
		native.callback(SLEEP)
		helpers.assert_eq(wakes, 0, "going to sleep is not a wake")
		native.callback(WAKE)
		helpers.assert_eq(wakes, 1, "a wake calls back once")
		helpers.assert_true(watcher.stop(), "the watcher stops")
		helpers.assert_eq(native.stopped, 1)
	end)

	helpers.it("logs a throwing callback instead of losing it", function()
		local errors = {}
		local previous_logger = package.loaded["infra.logger"]
		package.loaded["infra.logger"] = nil
		local real_logger = require("infra.logger")
		local spy = setmetatable({}, { __index = real_logger })
		spy.error = function(_, fmt, ...)
			local formatted, text = pcall(string.format, fmt, ...)
			errors[#errors + 1] = formatted and text or tostring(fmt)
		end
		package.loaded["infra.logger"] = spy
		local finished, err = pcall(function()
			local Adapter, native = load_adapter()
			local watcher = Adapter.new(function() error("boom in the wake handler") end)
			helpers.assert_true(watcher.start())
			-- A throw escaping here would fail this case: the adapter must contain it.
			native.callback(WAKE)
			helpers.assert_eq(#errors, 1, "the throw is logged once")
			helpers.assert_contains(errors[1], "boom in the wake handler", "with its message")
		end)
		package.loaded["infra.logger"] = previous_logger
		package.loaded["adapters.wake_watcher"] = nil
		if not finished then error(err, 0) end
	end)

	helpers.it("refuses a missing callback", function()
		local Adapter = load_adapter()
		local ok = pcall(Adapter.new, nil)
		helpers.assert_eq(ok, false, "a watcher without a callback is a programming error")
	end)
end)
