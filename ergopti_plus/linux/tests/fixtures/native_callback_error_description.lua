--- tests/fixtures/native_callback_error_description.lua
--- ==============================================================================
--- MODULE: Native Callback Error Description Regression
--- DESCRIPTION:
--- Runs one actual libuv callback path per interpreter so an uncaught native
--- callback error cannot prevent the remaining registered cases from executing.
--- Bounded real successor/watchdog timers prove continuation and exact cleanup.
--- A supplied throwing error-object formatter is an explicit callback input.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_callback_error_description%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local Scheduler = require("adapters.timer_scheduler")
local Loop = require("adapters.event_loop")
local scenario = assert(arg[1])
local bad_calls, sibling_calls, watchdog_calls, formatter_calls = 0, 0, 0, 0
local object = arg[2] == "string" and "owned ordinary callback failure" or setmetatable({}, { __tostring = function() formatter_calls = formatter_calls + 1; error("owned error formatter failure", 0) end })
local bad_token, sibling
local function bad()
	bad_calls = bad_calls + 1
	if bad_calls == 1 then
		-- A timer armed before run admission can stop the loop before any idle
		-- callback. Start continuation only after this actual failing callback.
		sibling = Scheduler.after(0.005, function()
			sibling_calls = sibling_calls + 1
			if bad_token then assert(Scheduler.cancel(bad_token)) end
			if Loop.isRunning() then Loop.stop() else uv.stop() end
		end)
	end
	error(object, 0)
end
local watchdog = assert(uv.new_timer())
assert(uv.timer_start(watchdog, 30, 0, function()
	watchdog_calls = watchdog_calls + 1
	Scheduler.cancelAll()
	if Loop.isRunning() then Loop.stop() else uv.stop() end
end) == 0)
print("START actual native " .. scenario)
local options = {}
if scenario == "after" then bad_token = Scheduler.after(0.001, bad)
elseif scenario == "every" then bad_token = Scheduler.every(0.001, bad)
elseif scenario == "idle" then options.onIdle = bad
elseif scenario == "periodic" then options.onPeriodic, options.periodSec = bad, 0.001
elseif scenario == "registered idle" then Loop.add_idle_handler(bad); options.onIdle = function() end
elseif scenario == "deferred" then assert(Loop.defer(bad)); options.onIdle = function() end
else error("unknown scenario") end
local ok, err
if scenario == "after" or scenario == "every" then ok, err = pcall(uv.run)
else ok, err = pcall(Loop.run, options) end
if sibling then
	assert(Scheduler.cancel(sibling))
	sibling = nil
end
Scheduler.cancelAll()
for _ = 1, 4 do uv.run("nowait") end
local resources = {}
uv.walk(function(handle) resources[#resources + 1] = handle end)
assert(#resources == 1 and resources[1] == watchdog and not uv.is_closing(watchdog), "callback failure lost ownership")
assert(uv.timer_stop(watchdog) == 0)
uv.close(watchdog)
for _ = 1, 4 do uv.run("nowait") end
local count = 0
uv.walk(function() count = count + 1 end)
print(string.format("RETURN ok=%s bad=%d sibling=%d watchdog=%d active=%d residual=%d formatter=%d", tostring(ok), bad_calls, sibling_calls, watchdog_calls, Scheduler.activeCount(), count, formatter_calls))
assert(ok and bad_calls > 0 and sibling_calls == 1 and watchdog_calls == 0 and count == 0 and Scheduler.activeCount() == 0 and formatter_calls == 0)
