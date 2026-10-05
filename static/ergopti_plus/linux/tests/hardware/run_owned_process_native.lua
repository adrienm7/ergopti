--- tests/hardware/run_owned_process_native.lua

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$"),
	"launch with an absolute script path")
local shared_root = driver_root .. "/../_shared/lua"
package.path = driver_root .. "/?.lua;" .. shared_root .. "/?.lua;" .. package.path

local uv = require("luv")
local Owner = require("adapters.owned_process")
local passed = 0
local WAIT_MS = 5000

--- Pumps the actual native loop until a receipt or a bounded diagnostic timeout.
--- @param predicate function
--- @return boolean
local function await(predicate)
	local deadline = uv.hrtime() + WAIT_MS * 1000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(2)
	until uv.hrtime() >= deadline
	return false
end

--- Runs a named check and requires no libuv resources remain afterward.
--- @param name string
--- @param check function
local function test(name, check)
	check()
	assert(await(function() return not uv.loop_alive() end), "native handle leaked after " .. name)
	passed = passed + 1
	print("PASS " .. name)
end

test("ordinary exit publishes captured bytes after every native close", function()
	local callbacks, settles, result = 0, 0, nil
	local operation = Owner.start("python3", { "-c", "import sys; print('owned'); sys.stderr.write('error-channel')" },
		{ owner = "normal", timeout_ms = 1000 }, function(value)
			callbacks, result = callbacks + 1, value
		end)
	assert(operation.started and not operation:is_settled() and result == nil)
	operation:on_settled(function() settles = settles + 1 end)
	assert(await(function() return operation:is_settled() end))
	assert(callbacks == 1 and settles == 1 and result.ok)
	assert(result.stdout == "owned\n" and result.stderr == "error-channel")
	assert(operation:cancel() == true)
end)

test("cancellation keeps ownership until actual exit and closes", function()
	local callbacks, ready, captured = 0, false, ""
	local operation = Owner.start("python3", { "-c", "import time; print('ready', flush=True); time.sleep(30)" },
		{ owner = "cancel", on_output = function(chunk)
			captured = captured .. chunk
			ready = captured:find("ready", 1, true) ~= nil
		end },
		function() callbacks = callbacks + 1 end)
	assert(operation.started)
	assert(await(function() return ready end), "the actual child did not acknowledge startup")
	assert(operation:cancel() == false)
	local refused = Owner.start("python3", { "-c", "raise Exception('must not run')" }, { owner = "cancel" }, function() end)
	assert(not refused.started and refused.error == "previous process cleanup pending")
	assert(await(function() return operation:is_settled() end))
	assert(callbacks == 0)
	local next_result
	local successor = Owner.start("python3", { "-c", "print('successor')" }, { owner = "cancel" }, function(value) next_result = value end)
	assert(successor.started and await(function() return successor:is_settled() end))
	assert(next_result.ok and next_result.stdout == "successor\n")
end)

test("deadline settles a real SIGTERM-resistant process", function()
	local result, captured = nil, ""
	local operation = Owner.start("python3", { "-c",
		"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(30)" },
		{ owner = "deadline", timeout_ms = 500, on_output = function(chunk) captured = captured .. chunk end },
		function(value) result = value end)
	assert(operation.started and await(function() return captured:find("ready\n", 1, true) ~= nil end),
		"the actual child must install its SIGTERM-resistant handler before deadline qualification")
	assert(await(function() return operation:is_settled() end))
	assert(result and not result.ok and result.error == "process deadline exceeded")
end)

test("a real signalled child does not report successful exit", function()
	local result
	local operation = Owner.start("python3", { "-c", "import os,signal; os.kill(os.getpid(),signal.SIGTERM)" },
		{ owner = "signal", timeout_ms = 1000 }, function(value) result = value end)
	assert(operation.started and await(function() return operation:is_settled() end))
	assert(result and not result.ok and result.exit_code == 143)
end)

test("real ENOENT is a refusal with no surviving native handles", function()
	local callbacks, result = 0, nil
	local operation = Owner.start("/nonexistent/ergopti-owned-process-fixture", {}, { owner = "absent" }, function(value)
		callbacks, result = callbacks + 1, value
	end)
	assert(not operation.started and await(function() return operation:is_settled() end))
	assert(callbacks == 1 and result and not result.ok and result.error == "native process dispatch failed")
end)

test("real output overflow preserves admitted bounded bytes", function()
	local result
	local operation = Owner.start("python3", { "-c", "import os,time; os.write(1,b'overflow'); time.sleep(30)" },
		{ owner = "overflow", timeout_ms = 1000, max_output_bytes = 4 }, function(value) result = value end)
	assert(operation.started and await(function() return operation:is_settled() end))
	assert(result and not result.ok and result.error == "process output exceeds its bound" and #result.stdout <= 4)
end)

test("explicit rolling diagnostics do not kill ordinary real daemon output", function()
	local result, streamed = nil, ""
	local operation = Owner.start("python3", { "-c", "import os; os.write(1,b'ABCDEFGHIJ')" },
		{ owner = "tail", timeout_ms = 1000, max_output_bytes = 4, capture_tail = true,
			on_output = function(chunk) streamed = streamed .. chunk end }, function(value) result = value end)
	assert(operation.started and await(function() return operation:is_settled() end))
	assert(result and result.ok and result.stdout == "GHIJ" and streamed == "ABCDEFGHIJ")
end)

local DESCENDANT = [[
import os, signal, sys, time
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(r)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if sys.argv[1] == "closed":
        os.close(1)
        os.close(2)
    os.write(w, b"ready")
    os.close(w)
    time.sleep(30)
    os._exit(0)
os.close(w)
os.read(r, 5)
os.close(r)
print("descendant:" + str(child), flush=True)
os._exit(0)
]]

	for _, mode in ipairs({ "inherited", "closed" }) do
	test("leader exit retires descendants with " .. mode .. " streams", function()
		local result, descendant, captured = nil, nil, ""
		local operation = Owner.start("python3", { "-c", DESCENDANT, mode }, {
			owner = "descendant-" .. mode, timeout_ms = 1000,
			on_output = function(chunk, channel)
				if channel == "stdout" then
					captured = captured .. chunk
					descendant = tonumber(captured:match("descendant:(%d+)\n")) or descendant
				end
			end,
		}, function(value) result = value end)
		assert(operation.started and await(function() return operation:is_settled() end))
		assert(result and not result.ok and result.error == "native process group outlived leader")
		assert(descendant, "the original leader did not provide its actual descendant identity")
		local present, _, code = uv.kill(descendant, 0)
		assert(present == nil and code == "ESRCH", "the descendant remains native-owned or unreaped")
	end)
end

test("source admission fences real output and physical cleanup", function()
	local current, outputs, callbacks = true, 0, 0
	local operation = Owner.start("python3", { "-c", "import time; print('ready',flush=True); time.sleep(0.05); print('stale',flush=True); time.sleep(30)" }, {
		owner = "source", timeout_ms = 1000,
		authorized = function() return current end,
		on_output = function() outputs = outputs + 1; current = false end,
	}, function() callbacks = callbacks + 1 end)
	assert(operation.started and await(function() return operation:is_settled() end))
	assert(outputs == 1 and callbacks == 0)
end)

print(string.format("Actual owned processes: %d passed, 0 failed", passed))
