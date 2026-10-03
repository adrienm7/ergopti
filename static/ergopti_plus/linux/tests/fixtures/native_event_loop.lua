--- tests/fixtures/native_event_loop.lua

--- ==============================================================================
--- MODULE: Native Event Loop Integration Fixture
--- DESCRIPTION:
--- Exercises the real installed libuv loop in a separate process so unrelated
--- suite handles cannot keep its shutdown alive. The independent deadline is
--- unreferenced and every fixture-owned handle is closed before reporting.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_event_loop%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path

local luv = require("luv")
local native = require("adapters.event_loop")
local idle, periodic, leaked = 0, 0, 0
local timed_out = false
local watchdog = luv.new_timer()
luv.timer_start(watchdog, 2000, 0, function()
	timed_out = true
	native.stop()
end)
-- The deadline must not hold a successfully stopped loop open.
luv.unref(watchdog)

local ok, err = pcall(native.run, {
	onIdle = function()
		idle = idle + 1
		if periodic > 0 then native.stop() end
	end,
	onPeriodic = function()
		periodic = periodic + 1
		if idle > 0 then native.stop() end
	end,
	periodSec = 0.001,
})

native.stop()
luv.timer_stop(watchdog)
luv.close(watchdog)
luv.walk(function(handle)
	if handle ~= watchdog and not luv.is_closing(handle) then
		leaked = leaked + 1
		luv.close(handle)
	end
end)
luv.run("nowait")
assert(ok, tostring(err))
assert(not timed_out, "native callbacks exceeded their independent deadline")
assert(leaked == 0, "native loop leaked an owned handle")
assert(native.HAS_LUV and idle > 0 and periodic == 1, "native idle and timer callbacks must both run")
assert(not native.isRunning(), "native loop must finish stopped")
print("Native luv integration passed: idle and timer dispatch, bounded shutdown, no leaked handles.")
