--- tests/fixtures/native_relative_timers.lua
--- Real libuv timers and subprocesses after blocking work, including callbacks.
--- No backend, clock, process, allocation or signal receipt is mocked.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_relative_timers%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Scheduler = require("adapters.timer_scheduler")
local Process = require("adapters.process_runner")
local checks, failures = 0, 0

local function await(predicate)
	local deadline = uv.hrtime() + 2000000000
	repeat
		uv.run("nowait")
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native fixture exceeded its two-second deadline")
end

local function elapsed(start) return (uv.hrtime() - start) / 1000000 end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	assert(Scheduler.cancelAll())
	await(function() return not uv.loop_alive() end)
	assert(Scheduler.activeCount() == 0, "scheduler retained native ownership")
	local remaining = 0
	uv.walk(function() remaining = remaining + 1 end)
	assert(remaining == 0, "fixture retained native process, pipe or timer handles")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, method in ipairs({ "after", "every" }) do
	for _, in_callback in ipairs({ false, true }) do
		check(method .. " receives its full delay " .. (in_callback and "inside a callback" or "after blocking work"), function()
			local calls, delay, token = 0, nil, nil
			local function arm()
				uv.sleep(160) -- actual blocking work leaves libuv's cached loop time stale
				local start = uv.hrtime()
				token = Scheduler[method](0.080, function()
					calls, delay = calls + 1, elapsed(start)
					if method == "every" then assert(Scheduler.cancel(token)) end
				end)
				assert(token.armed, "native scheduler refused the timer")
			end
			uv.update_time()
			if in_callback then assert(Scheduler.after(0, arm).armed) else arm() end
			await(function() return calls > 0 end)
			print(string.format("  %s native delay %.2f ms", method, delay))
			assert(delay >= 65 and delay < 1000, "new 80 ms timer fired outside its relative delay: " .. delay)
			assert(calls == 1, "timer callback repeated after retirement")
		end)
	end
end

for _, in_callback in ipairs({ false, true }) do
	check("valid child survives its new deadline " .. (in_callback and "inside a callback" or "after blocking work"), function()
		local results, start, pid = {}, nil, nil
		local function arm()
			uv.sleep(160)
			start = uv.hrtime()
			assert(Process.run("/bin/sh", { "-c", "sleep 0.04; printf done; printf warning >&2" },
				{ timeout_ms = 100 }, function(result) results[#results + 1] = result end))
			uv.walk(function(handle)
				if uv.handle_get_type(handle) == "process" and not uv.is_closing(handle) then
					pid = uv.process_get_pid(handle)
				end
			end)
		end
		uv.update_time()
		if in_callback then assert(Scheduler.after(0, arm).armed) else arm() end
		await(function() return #results > 0 and not uv.loop_alive() end)
		local duration = elapsed(start)
		print(string.format("  native child completed %.2f ms exit %s", duration, tostring(results[1].exit_code)))
		assert(#results == 1 and results[1].exit_code == 0 and results[1].error == nil,
			"valid 40 ms child lost its newly armed 100 ms deadline: " .. tostring(results[1].error))
		assert(results[1].stdout == "done" and results[1].stderr == "warning", "native streams lost output")
		assert(duration >= 25 and duration < 1000)
		assert(pid and not uv.fs_stat("/proc/" .. pid), "completed native child was not reaped")
	end)
end

check("new deadline waits, kills a signal-resistant child and reaps it once", function()
	uv.update_time()
	uv.sleep(160)
	local results, pid = {}, nil
	local start, cpu = uv.hrtime(), os.clock()
	assert(Process.run("/bin/sh", { "-c", "trap '' TERM; exec sleep 10" }, { timeout_ms = 100 },
		function(result) results[#results + 1] = result end))
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "process" and not uv.is_closing(handle) then pid = uv.process_get_pid(handle) end
	end)
	await(function() return #results > 0 and not uv.loop_alive() end)
	local duration, cpu_ms = elapsed(start), (os.clock() - cpu) * 1000
	print(string.format("  native deadline %.2f ms wall, %.2f ms CPU", duration, cpu_ms))
	assert(duration >= 80 and duration < 1000, "100 ms deadline expired relative to stale loop time: " .. duration)
	assert(cpu_ms < 80, "waiting for the native deadline busy-spun")
	assert(#results == 1 and results[1].exit_code == -1 and results[1].error:find("did not finish", 1, true))
	assert(pid and not uv.fs_stat("/proc/" .. pid), "deadline child was not reaped")
end)

check("delayed native timers remain individually and collectively cancellable", function()
	uv.update_time()
	uv.sleep(160)
	local callbacks = 0
	local one = Scheduler.after(0.080, function() callbacks = callbacks + 1 end)
	local repeat_timer = Scheduler.every(0.080, function() callbacks = callbacks + 1 end)
	assert(one.armed and repeat_timer.armed and Scheduler.activeCount() == 2)
	assert(Scheduler.cancel(one) and Scheduler.cancelAll())
	await(function() return not uv.loop_alive() end)
	assert(callbacks == 0 and not one.armed and not repeat_timer.armed)
end)

print(string.format("native relative timer checks: %d passed, %d failed", checks - failures, failures))
if failures > 0 then os.exit(1) end
