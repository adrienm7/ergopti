--- tests/fixtures/native_shell_async_admission.lua
--- ==============================================================================
--- MODULE: Native ShellRunner Admission Ownership Regression
--- DESCRIPTION:
--- Explicitly simulates native constructor refusal and handle invalidation.
--- Libuv handles, EINVAL receipts, child groups, output, deadlines, cancellation
--- and reaping are real. No ordinary native allocation failure is claimed.
--- ==============================================================================
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_shell_async_admission%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Shell = require("adapters.shell_runner")
local checks, failures = 0, 0
local originals = { spawn = uv.spawn, timer_start = uv.timer_start, read_start = uv.read_start,
	new_pipe = uv.new_pipe, new_timer = uv.new_timer }

local function drain()
	local deadline = uv.hrtime() + 1000000000
	repeat
		uv.run("nowait")
		if not uv.loop_alive() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native admission fixture did not drain within one second")
end

local function absent(pid)
	local accepted, _, code = uv.kill(-pid, 0)
	assert(accepted == nil and code == "ESRCH", "native child group survived production cleanup")
	assert(not uv.fs_stat("/proc/" .. pid), "native child was not reaped")
end

local function check(name, test)
	checks = checks + 1
	local state = { allocations = {}, callbacks = 0 }
	uv.spawn = function(...)
		local process, pid, code = originals.spawn(...)
		state.pid, state.process = pid, process
		return process, pid, code
	end
	local ok, err = xpcall(function() test(state) end, debug.traceback)
	for key, value in pairs(originals) do uv[key] = value end
	-- Cleanup is after all production ownership assertions, including red runs.
	if state.token then state.token.cancel() end
	if state.pid then uv.kill(-state.pid, "sigkill") end
	for _, handle in ipairs(state.allocations) do if not uv.is_closing(handle) then uv.close(handle) end end
	drain()
	if state.pid then absent(state.pid) end
	local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
	assert(remaining == 0, "fixture left an owned native handle")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, operation in ipairs({ "timer", "stdout", "stderr", "second pipe raised", "timer allocation nil" }) do
	check(operation .. " refuses admission silently and retires native ownership", function(state)
		local reads, pipes, receipt = 0, 0, nil
		uv.new_pipe = function(...)
			pipes = pipes + 1
			if operation == "second pipe raised" and pipes == 2 then error("simulated second pipe allocation refusal") end
			local handle = originals.new_pipe(...); state.allocations[#state.allocations + 1] = handle; return handle
		end
		uv.new_timer = function(...)
			if operation == "timer allocation nil" then return nil end -- Explicit simulation.
			local handle = originals.new_timer(...); state.allocations[#state.allocations + 1] = handle; return handle
		end
		local function invalidate(handle, start, ...)
			uv.close(handle) -- Explicit simulated invalidation, actual native start receipt.
			local accepted, message, code = start(handle, ...)
			receipt = { accepted = accepted, message = message, code = code }
			return accepted, message, code
		end
		uv.timer_start = function(handle, ...)
			if operation == "timer" then return invalidate(handle, originals.timer_start, ...) end
			return originals.timer_start(handle, ...)
		end
		uv.read_start = function(handle, ...)
			reads = reads + 1
			if (operation == "stdout" and reads == 1) or (operation == "stderr" and reads == 2) then
				return invalidate(handle, originals.read_start, ...)
			end
			return originals.read_start(handle, ...)
		end
		local ran, token, reason = pcall(Shell.run_async, "/bin/sleep", { "30" }, { timeout_ms = 500 },
			function() state.callbacks = state.callbacks + 1 end)
		if ran and type(token) == "table" then state.token = token end
		if operation == "timer" or operation == "stdout" or operation == "stderr" then
			assert(receipt and receipt.accepted == nil and receipt.code == "EINVAL", "missing actual native refusal")
		else assert(receipt == nil, "constructor refusal reached native admission") end
		assert(ran and token == nil and type(reason) == "string" and reason ~= "",
			"startup failure did not return the production nil/error refusal contract")
		assert(state.callbacks == 0, "startup refusal also published a callback")
		local expected_allocations = operation == "second pipe raised" and 1 or operation == "timer allocation nil" and 2 or 3
		assert(#state.allocations == expected_allocations, "fixture did not acquire the expected real allocations")
		for _, handle in ipairs(state.allocations) do assert(uv.is_closing(handle), "production retained a native allocation") end
		if operation == "stdout" or operation == "stderr" then
			assert(state.pid, "native reader refusal must occur after actual child dispatch")
		else assert(state.pid == nil, "pre-spawn refusal still dispatched a child") end
		drain()
		if state.pid then absent(state.pid) end
		assert(state.callbacks == 0, "late real child exit published a refused run")
	end)
end

check("native zero-valued receipts preserve exact successful streams once", function(state)
	local results, receipts = {}, {}
	for _, method in ipairs({ "timer_start", "read_start" }) do
		uv[method] = function(...)
			local accepted, message, code = originals[method](...)
			receipts[#receipts + 1] = { accepted = accepted }
			return accepted, message, code
		end
	end
	state.token = assert(Shell.run_async("/bin/sh", { "-c", "printf done; printf warning >&2" }, { timeout_ms = 500 },
		function(result) results[#results + 1] = result end))
	assert(#receipts == 3, "positive native timer and both readers must be admitted")
	for _, receipt in ipairs(receipts) do assert(receipt.accepted == 0, "fixture did not observe real zero-valued native receipts") end
	assert(state.pid, "positive control acquired no actual child")
	drain(); absent(state.pid)
	assert(#results == 1 and results[1].ok and results[1].code == 0 and results[1].stdout == "done"
		and results[1].stderr == "warning" and results[1].error == nil)
end)

check("actual deadline retires a signal-resistant child and publishes once", function(state)
	local results, start, cpu = {}, uv.hrtime(), os.clock()
	state.token = assert(Shell.run_async("/bin/sh", { "-c", "trap '' TERM; exec sleep 10" }, { timeout_ms = 60 },
		function(result) results[#results + 1] = result end))
	assert(state.pid, "deadline control acquired no actual child")
	drain(); absent(state.pid)
	local elapsed, cpu_ms = (uv.hrtime() - start) / 1000000, (os.clock() - cpu) * 1000
	assert(elapsed >= 45 and elapsed < 1000 and cpu_ms < 80, "native deadline wait lost its relative/CPU bound")
	assert(#results == 1 and not results[1].ok and results[1].error == "timeout")
end)

check("actual cancellation fences delivery and reaps its child", function(state)
	state.token = assert(Shell.run_async("/bin/sleep", { "10" }, { timeout_ms = 500 },
		function() state.callbacks = state.callbacks + 1 end))
	assert(state.pid, "cancel control acquired no actual child")
	state.token.cancel(); state.token.cancel()
	drain(); absent(state.pid)
	assert(state.callbacks == 0, "cancelled native run delivered a callback")
end)

print(string.format("Native ShellRunner admission: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
