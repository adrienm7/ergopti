--- tests/hardware/run_process_supervision_receipts.lua
--- ==============================================================================
--- MODULE: Native Process Supervision Receipt Regression
--- DESCRIPTION:
--- Simulates timer or stream invalidation by closing one actual libuv handle
--- before its native start. Child creation, pipes, returned EINVAL, process-group
--- retirement and cleanup are real. This does not establish that ordinary
--- production handles spontaneously become invalid (linux-process-supervision).
--- ==============================================================================

local uv = require("luv")
local Runner = require("adapters.process_runner")
local checks, failures = 0, 0

for _, operation in ipairs({ "timer", "stdout", "stderr" }) do
	checks = checks + 1
	local original_spawn, original_timer_start, original_read_start = uv.spawn, uv.timer_start, uv.read_start
	local pid, native_receipt, callbacks, result = nil, nil, 0, nil
	local reads = 0
	uv.spawn = function(...)
		local process, child_pid, code = original_spawn(...)
		pid = child_pid
		return process, child_pid, code
	end
	local function invalidate(handle, start, ...)
		uv.close(handle) -- Simulated invalidation of an actual native handle.
		local accepted, message, code = start(handle, ...)
		native_receipt = { accepted = accepted, message = message, code = code }
		return accepted, message, code
	end
	uv.timer_start = function(timer, ...)
		if operation == "timer" then return invalidate(timer, original_timer_start, ...) end
		return original_timer_start(timer, ...)
	end
	uv.read_start = function(pipe, ...)
		reads = reads + 1
		if (operation == "stdout" and reads == 1) or (operation == "stderr" and reads == 2) then
			return invalidate(pipe, original_read_start, ...)
		end
		return original_read_start(pipe, ...)
	end
	local ok, err = xpcall(function()
		local dispatched = Runner.run("/bin/sleep", { "30" }, { timeout_ms = 50 }, function(answer)
			callbacks, result = callbacks + 1, answer
		end)
		assert(pid and native_receipt and native_receipt.accepted == nil and native_receipt.code == "EINVAL",
			"fixture did not observe a native supervision refusal")
		assert(dispatched == false and callbacks == 1,
			"ProcessRunner accepted a child whose native " .. operation .. " supervision could not start")
		assert(result.exit_code == -1 and result.error == "process supervision could not start")
		local deadline = uv.hrtime() + 1000000000
		repeat
			uv.run("nowait")
			if not uv.loop_alive() then break end
			uv.sleep(5)
		until uv.hrtime() >= deadline
		assert(not uv.loop_alive(), "refused supervision left a live child or native handle")
		local absent, _, code = uv.kill(-pid, 0)
		assert(absent == nil and code == "ESRCH", "refused child group survived before fixture cleanup")
	end, debug.traceback)
	uv.spawn, uv.timer_start, uv.read_start = original_spawn, original_timer_start, original_read_start
	-- Own the cleanup even when an assertion fails against the unfixed source.
	if pid then uv.kill(-pid, "sigkill") end
	uv.run()
	assert(not uv.loop_alive(), "owned native handles survived fixture cleanup")
	if ok then
		assert(callbacks == 1, "late native exit published another callback")
		print("PASS " .. operation .. " native EINVAL refused (simulated invalidation; native child and cleanup)")
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. operation .. ": " .. tostring(err) .. "\n")
	end
end

local result, callbacks = nil, 0
assert(Runner.run("/bin/printf", { "%s", "native stdout" }, { timeout_ms = 1000 }, function(answer)
	result, callbacks = answer, callbacks + 1
end))
uv.run()
checks = checks + 1
assert(callbacks == 1 and result.exit_code == 0 and result.stdout == "native stdout" and result.error == nil,
	"native zero-valued start receipts must remain admissible")
assert(not uv.loop_alive(), "successful native child left handles active")
print("PASS native zero-valued supervision receipts preserve successful output")
print(string.format("Native process supervision receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
