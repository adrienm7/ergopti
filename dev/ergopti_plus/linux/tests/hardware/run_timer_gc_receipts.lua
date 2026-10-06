--- tests/hardware/run_timer_gc_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Timer Ownership Receipts
--- DESCRIPTION:
--- Drives the production TimerScheduler through actual libuv timers and Lua GC.
--- Dropping an opaque token cannot erase cancellation ownership. Native callback
--- observations also cover mixed timers, one-shot retirement and scheduler reuse.
--- No timer API is mocked and no input or graphical session is required.
--- ==============================================================================

local uv = require("luv")
local Scheduler = require("adapters.timer_scheduler")
local checks, failures = 0, 0

--- Runs real libuv events during a bounded observation interval.
--- @param milliseconds number
local function pump(milliseconds)
	local deadline = uv.hrtime() + milliseconds * 1000000
	repeat
		uv.run("nowait")
		uv.sleep(1)
	until uv.hrtime() >= deadline
	uv.run("nowait")
end

--- Reclaims only this standalone fixture's timers, including leaked tokens.
local function cleanup()
	Scheduler.cancelAll()
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "timer" and not uv.is_closing(handle) then
			uv.timer_stop(handle)
			uv.close(handle)
		end
	end)
	uv.run("nowait")
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	cleanup()
	if ok then
		print("PASS " .. name)
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, count in ipairs({ 1, 3, 12 }) do
	check(tostring(count) .. " unretained native repeaters remain cancellable after GC", function()
		local callbacks = 0
		for _ = 1, count do Scheduler.every(0.001, function() callbacks = callbacks + 1 end) end
		collectgarbage("collect")
		collectgarbage("collect")
		local retained = Scheduler.activeCount()
		assert(Scheduler.cancelAll() == true)
		pump(20)
		assert(callbacks == 0, "native callbacks survived bulk cancellation")
		assert(retained == count, "native ownership vanished after GC")
		assert(Scheduler.activeCount() == 0 and not uv.loop_alive(), "cancelled native handles remain live")
	end)
end

check("mixed unretained native timers retire as a group", function()
	local callbacks = 0
	Scheduler.after(0.005, function() callbacks = callbacks + 1 end)
	Scheduler.every(0.001, function() callbacks = callbacks + 1 end)
	Scheduler.after(0.010, function() callbacks = callbacks + 1 end)
	Scheduler.every(0.002, function() callbacks = callbacks + 1 end)
	collectgarbage("collect")
	local retained = Scheduler.activeCount()
	assert(Scheduler.cancelAll() == true)
	pump(25)
	assert(retained == 4 and callbacks == 0, "mixed native ownership was lost")
	assert(not uv.loop_alive(), "mixed cancellation leaked a native handle")
end)

check("native one-shot completion releases an unretained token", function()
	local callbacks = 0
	local tokens = setmetatable({}, { __mode = "v" })
	tokens[1] = Scheduler.after(0.001, function() callbacks = callbacks + 1 end)
	collectgarbage("collect")
	assert(Scheduler.activeCount() == 1)
	pump(20)
	collectgarbage("collect")
	assert(callbacks == 1 and Scheduler.activeCount() == 0)
	assert(tokens[1] == nil and not uv.loop_alive(), "settled native one-shot retained its token")
end)

check("native repeater runs before explicit cancellation and stays retired afterward", function()
	local callbacks = 0
	local handle = Scheduler.every(0.001, function() callbacks = callbacks + 1 end)
	pump(20)
	assert(callbacks > 0, "positive native repeating control never fired")
	assert(Scheduler.cancel(handle) == true and Scheduler.cancel(handle) == true)
	local previous = callbacks
	pump(20)
	assert(callbacks == previous and Scheduler.activeCount() == 0 and not uv.loop_alive())
end)

check("native scheduler remains usable after bulk cancellation", function()
	local callbacks = 0
	Scheduler.every(0.001, function() callbacks = callbacks + 100 end)
	collectgarbage("collect")
	assert(Scheduler.cancelAll() == true and Scheduler.cancelAll() == true)
	Scheduler.after(0.001, function() callbacks = callbacks + 1 end)
	pump(20)
	assert(callbacks == 1, "cancelled timer contaminated the successor")
	assert(Scheduler.activeCount() == 0 and not uv.loop_alive())
end)

print(string.format("Native timer ownership: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
