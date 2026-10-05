--- tests/fixtures/native_process_allocations.lua
--- Native ProcessRunner partial-allocation ownership regression.
--- Constructor exceptions/refusals are simulated; acquired libuv handles,
--- foreign timer, child/output/reaping and cleanup are actual native operations.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_process_allocations%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Process, Timers = require("adapters.process_runner"), require("adapters.timer_scheduler")
local foreign = Timers.every(10, function() error("foreign timer unexpectedly fired") end)
assert(foreign.armed); uv.unref(foreign.timer)
local originals = { new_pipe = uv.new_pipe, new_timer = uv.new_timer, spawn = uv.spawn }
local checks, failures = 0, 0
for _, mode in ipairs({ "raised", "nil" }) do
	for _, slot in ipairs({ 2, 3 }) do
		checks = checks + 1
		local allocated, calls, spawns, callbacks, result = {}, 0, 0, 0, nil
		local function allocate(method, ...)
			calls = calls + 1
			if calls == slot then
				if mode == "raised" then error("explicit simulated constructor exception") end
				return nil -- Explicit simulated refusal, not spontaneous native pressure.
			end
			local handle = originals[method](...)
			allocated[#allocated + 1] = handle
			assert(type(handle) == "userdata" and not uv.is_closing(handle), "constructor must return an actual open native handle")
			return handle
		end
		uv.new_pipe = function(...) return allocate("new_pipe", ...) end
		uv.new_timer = function(...) return allocate("new_timer", ...) end
		uv.spawn = function(...) spawns = spawns + 1; return originals.spawn(...) end
		local ok, err = xpcall(function()
			local dispatched = Process.run("/bin/sh", { "-c", "printf native" }, {}, function(receipt)
				callbacks, result = callbacks + 1, receipt
			end)
			assert(not dispatched and callbacks == 1 and result.exit_code == -1
				and result.error == "libuv handle allocation failed" and result.stdout == "" and result.stderr == "",
				"constructor refusal changed the dispatch/callback receipt")
			assert(spawns == 0, "constructor refusal acquired a child")
			local retained = 0
			for _, handle in ipairs(allocated) do if not uv.is_closing(handle) then retained = retained + 1 end end
			assert(retained == 0, "production retained " .. retained .. " actual partial allocations")
			for _ = 1, 3 do uv.run("nowait") end
			local handles = 0
			uv.walk(function(handle)
				handles = handles + 1
				assert(handle == foreign.timer, "production retained an owned handle after drain")
			end)
			assert(handles == 1 and uv.is_active(foreign.timer) and Timers.activeCount() == 1,
				"constructor refusal damaged the foreign timer")
		end, debug.traceback)
		for key, value in pairs(originals) do uv[key] = value end
		-- Only after production assertions, clean leaks so red baselines finish safely.
		for _, handle in ipairs(allocated) do if not uv.is_closing(handle) then uv.close(handle) end end
		for _ = 1, 3 do uv.run("nowait") end
		local name = "slot=" .. slot .. " mode=" .. mode
		if ok then print("PASS " .. name) else
			failures = failures + 1
			io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
		end
	end
end
local pid, callbacks, result = nil, 0, nil
uv.spawn = function(...)
	local process, child_pid, error_message = originals.spawn(...)
	pid = child_pid
	return process, child_pid, error_message
end
assert(Process.run("/bin/sh", { "-c", "printf native; printf diagnostic >&2" }, {}, function(receipt)
	callbacks, result = callbacks + 1, receipt
end))
uv.spawn = originals.spawn
uv.run()
assert(callbacks == 1 and result.exit_code == 0 and result.error == nil
	and result.stdout == "native" and result.stderr == "diagnostic")
assert(type(pid) == "number" and uv.fs_stat("/proc/" .. pid) == nil, "actual child not reaped")
assert(uv.is_active(foreign.timer) and Timers.activeCount() == 1)
assert(Timers.cancel(foreign)); uv.run()
local handles = 0; uv.walk(function() handles = handles + 1 end)
assert(handles == 0, "fixture left native handles")
assert(checks == 4, "all native allocation controls must run")
print(string.format("ProcessRunner native allocation: %d checks, %d failures; actual output/reaping and foreign timer pass", checks, failures))
if failures > 0 then os.exit(1) end
