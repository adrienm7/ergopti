--- tests/fixtures/native_relative_timer_siblings.lua
--- Actual FIFO/hash, loopback curl, shell child and EventLoop relative timers.
--- All clocks, backends, processes, pipes, sockets and signals are native.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_relative_timer_siblings%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv, ffi = require("luv"), require("ffi")
ffi.cdef("int mkfifo(const char *pathname, unsigned int mode);")
local Scheduler = require("adapters.timer_scheduler")
local Digest = require("adapters.file_digest")
local Http = require("adapters.http_client")
local Shell = require("adapters.shell_runner")
local Loop = require("adapters.event_loop")
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-relative-siblings-XXXXXX"))
local checks, failures, handles, paths, tokens, pids = 0, 0, {}, {}, {}, {}
local ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

-- Passive private observations: original native functions, callbacks, metadata
-- and result tuples are forwarded once unchanged; no deadline/clock refresh added.
local pack = function(...) return { n = select("#", ...), ... } end
local unpack_values = table.unpack or unpack
local active_http_trace
local function observe_http(phase, delay)
 pcall(function()
  local trace = active_http_trace
  if not trace or #trace.events >= 64 then return end
  local now, cached = uv.hrtime() / 1000000, uv.now()
  if type(now) ~= "number" or type(cached) ~= "number" then return end
  trace.events[#trace.events + 1] = { phase = phase, time = now - trace.start,
   cached = cached - trace.cached, delay = type(delay) == "number" and delay or -1 }
 end)
end
local function flush_http_trace()
 local trace = active_http_trace
 active_http_trace = nil
 if not trace then return end
 pcall(function()
  io.stderr:write("PRIVATE_RELATIVE_HTTP_TRACE mode=", trace.mode, " clock=", trace.clock, "\n")
  for _, row in ipairs(trace.events) do
   io.stderr:write(string.format("PRIVATE_RELATIVE_HTTP_TRACE phase=%s t_ms=%.3f cached_delta_ms=%.3f delay_ms=%.3f\n",
    row.phase, row.time, row.cached, row.delay))
  end
 end)
end
local NativeTimer = require("infra.native_timer")
local original_native_start, original_spawn = NativeTimer.start, uv.spawn
NativeTimer.start = function(...)
 local delay = select(3, ...)
 observe_http("timer-enter", delay)
 local results = pack(original_native_start(...))
 observe_http("timer-return", delay)
 return unpack_values(results, 1, results.n)
end
uv.spawn = function(...)
 observe_http("spawn-enter")
 local results = pack(original_spawn(...))
 observe_http("spawn-return")
 return unpack_values(results, 1, results.n)
end

local function retain(handle) handles[#handles + 1] = handle; return handle end
local function close(handle) if not uv.is_closing(handle) then uv.close(handle) end end
local function elapsed(start) return (uv.hrtime() - start) / 1000000 end
local function remember_processes()
	local count = 0
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "process" and not uv.is_closing(handle) then
			count = count + 1
			pids[uv.process_get_pid(handle)] = true
		end
	end)
	assert(count > 0, "fixture acquired no native child to verify retirement")
end
local function await(predicate)
	local deadline = uv.hrtime() + 2000000000
	repeat
		uv.run("nowait")
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native sibling fixture exceeded two seconds")
end

local function fifo()
	local path = directory .. "/fifo-" .. checks
	assert(ffi.C.mkfifo(path, 384) == 0)
	paths[#paths + 1] = path
	return path
end

local function writer(path)
	local result, process = {}, nil
	process = assert(uv.spawn("python3", { args = { "-c",
		"import os,sys,time; time.sleep(.04); fd=os.open(sys.argv[1],os.O_WRONLY|os.O_NONBLOCK); os.write(fd,b'abc'); os.close(fd)", path },
		stdio = { nil, nil, nil } }, function(code, signal)
		result.code, result.signal = code, signal
		close(process)
	end))
	return result
end

local function server()
	local listener = retain(assert(uv.new_tcp()))
	assert(listener:bind("127.0.0.1", 0))
	local requests = 0
	assert(listener:listen(16, function(err)
		assert(not err, tostring(err))
		local socket = retain(assert(uv.new_tcp()))
		assert(listener:accept(socket))
		local input, handled = "", false
		socket:read_start(function(read_error, chunk)
			assert(not read_error, tostring(read_error))
			if not chunk then close(socket); return end
			input = input .. chunk
			if handled or not input:find("\r\n\r\n", 1, true) then return end
			handled, requests = true, requests + 1
			observe_http("server-request")
			assert(Scheduler.after(0.040, function()
				if uv.is_closing(socket) then return end
				observe_http("server-reply")
				socket:write("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc", function(write_error)
					assert(not write_error, tostring(write_error))
					socket:shutdown(function() close(socket) end)
				end)
			end).armed)
		end)
	end))
	return "http://127.0.0.1:" .. listener:getsockname().port, function() return requests end
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	pcall(flush_http_trace) -- Optional diagnostics cannot replace the original assertion failure.
	assert(Digest.cancel("clock-fixture") and Http.cancel("clock-fixture"))
	for _, token in ipairs(tokens) do token.cancel() end
	assert(Scheduler.cancelAll())
	for _, handle in ipairs(handles) do close(handle) end
	await(function() return not uv.loop_alive() end)
	local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
	assert(remaining == 0, "native sibling fixture retained a handle")
	for pid in pairs(pids) do assert(not uv.fs_stat("/proc/" .. pid), "native child was not reaped") end
	for _, path in ipairs(paths) do assert(uv.fs_unlink(path)) end
	handles, paths, tokens, pids = {}, {}, {}, {}
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, in_callback in ipairs({ false, true }) do
	local location = in_callback and "inside a callback" or "after blocking work"
	check("actual FIFO digest survives its new deadline " .. location, function()
		local path, result, writer_result, start = fifo(), { callbacks = 0 }, nil, nil
		local function arm()
			uv.sleep(160); start = uv.hrtime()
			assert(Digest.sha256(path, { owner = "clock-fixture", timeout_ms = 100 }, function(value, err)
				result.value, result.error, result.callbacks = value, err, result.callbacks + 1
			end))
			writer_result = writer(path)
			remember_processes()
		end
		uv.update_time()
		if in_callback then assert(Scheduler.after(0, arm).armed) else arm() end
		await(function() return result.callbacks > 0 and writer_result.code ~= nil end)
		local duration = elapsed(start)
		print(string.format("  FIFO digest %.2f ms, error %s", duration, tostring(result.error)))
		assert(result.callbacks == 1 and result.value == ABC and result.error == nil,
			"actual FIFO hash lost its new deadline: " .. tostring(result.error))
		assert(writer_result.code == 0 and writer_result.signal == 0, "native FIFO writer failed")
		assert(duration >= 25 and duration < 1000 and not Digest.isActive("clock-fixture"))
	end)

	check("actual loopback HTTP survives its new deadline " .. location, function()
		local url, requests = server()
		local results, start = {}, nil
		local function arm()
			uv.sleep(160); start = uv.hrtime()
			pcall(function()
				local clock = require("infra.monotonic").backend()
				active_http_trace = { start = start / 1000000, cached = uv.now(), events = {},
					mode = in_callback and "inside-callback" or "after-blocking",
					clock = clock == "luv.hrtime" and "luv.hrtime" or "Other" }
			end)
			observe_http("public-enter")
			assert(Http.get(url, {}, { owner = "clock-fixture", timeout_ms = 100 },
				function(result) observe_http("public-callback"); results[#results + 1] = result end))
			observe_http("public-return")
			remember_processes()
		end
		uv.update_time()
		if in_callback then assert(Scheduler.after(0, arm).armed) else arm() end
		await(function() return #results > 0 end)
		local duration = elapsed(start)
		print(string.format("  loopback HTTP %.2f ms, status %s", duration, tostring(results[1].status)))
		assert(#results == 1 and results[1].ok and results[1].status == 200 and results[1].body == "abc",
			"actual loopback HTTP lost its new deadline: " .. tostring(results[1].error))
		assert(requests() == 1 and duration >= 25 and duration < 1000)
		assert(not Http.isActive("clock-fixture"))
	end)

	check("actual ShellRunner child survives its new deadline " .. location, function()
		local results, start = {}, nil
		local function arm()
			uv.sleep(160); start = uv.hrtime()
			local token = assert(Shell.run_async("/bin/sh", { "-c", "sleep .04; printf done; printf warning >&2" },
				{ timeout_ms = 100 }, function(result) results[#results + 1] = result end))
			tokens[#tokens + 1] = token
			remember_processes()
		end
		uv.update_time()
		if in_callback then assert(Scheduler.after(0, arm).armed) else arm() end
		await(function() return #results > 0 end)
		local duration = elapsed(start)
		print(string.format("  ShellRunner child %.2f ms, error %s", duration, tostring(results[1].error)))
		assert(#results == 1 and results[1].ok and results[1].code == 0 and results[1].stdout == "done"
			and results[1].stderr == "warning", "actual shell child lost its new deadline: " .. tostring(results[1].error))
		assert(duration >= 25 and duration < 1000)
	end)
end

check("actual EventLoop periodic timer starts relative to run admission", function()
	uv.update_time(); uv.sleep(160)
	local calls, duration, start = 0, nil, uv.hrtime()
	Loop.run({ periodSec = 0.080, onPeriodic = function()
		calls, duration = calls + 1, elapsed(start); Loop.stop()
	end })
	print(string.format("  EventLoop first periodic %.2f ms", duration))
	assert(calls == 1 and not Loop.isRunning() and duration >= 65 and duration < 1000,
		"new EventLoop periodic timer fired against stale clock: " .. duration)
end)

check("unfed actual FIFO receives its full timeout and releases its native owner", function()
	local path, result = fifo(), { callbacks = 0 }
	uv.update_time(); uv.sleep(160)
	local start = uv.hrtime()
	assert(Digest.sha256(path, { owner = "clock-fixture", timeout_ms = 100 }, function(value, err)
		result.value, result.error, result.callbacks = value, err, result.callbacks + 1
	end))
	remember_processes()
	await(function() return result.callbacks > 0 and not uv.loop_alive() end)
	local duration = elapsed(start)
	print(string.format("  unfed FIFO timeout %.2f ms", duration))
	assert(duration >= 80 and duration < 1000, "new digest timeout expired against stale clock: " .. duration)
	assert(result.callbacks == 1 and result.value == nil and result.error == "timeout")
	assert(not Digest.isActive("clock-fixture"))
end)

check("actual sibling cancellation remains silent and retires native ownership", function()
	local path, callbacks = fifo(), 0
	local url = server()
	uv.update_time(); uv.sleep(160)
	assert(Digest.sha256(path, { owner = "clock-fixture", timeout_ms = 100 }, function() callbacks = callbacks + 1 end))
	assert(Http.get(url, {}, { owner = "clock-fixture", timeout_ms = 100 }, function() callbacks = callbacks + 1 end))
	local token = assert(Shell.run_async("/bin/sleep", { "10" }, { timeout_ms = 100 }, function() callbacks = callbacks + 1 end))
	tokens[#tokens + 1] = token
	remember_processes()
	assert(Digest.cancel("clock-fixture") and Http.cancel("clock-fixture")); token.cancel()
	uv.run("nowait")
	assert(callbacks == 0 and not Digest.isActive("clock-fixture") and not Http.isActive("clock-fixture"))
end)

assert(uv.fs_rmdir(directory))
print(string.format("native relative sibling checks: %d passed, %d failed", checks - failures, failures))
NativeTimer.start, uv.spawn = original_native_start, original_spawn
if failures > 0 then os.exit(1) end
