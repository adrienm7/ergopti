--- tests/hardware/run_service_process_port_native.lua

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$"),
	"launch with an absolute script path")
local shared_root = driver_root .. "/../_shared/lua"
package.path = driver_root .. "/?.lua;" .. shared_root .. "/?.lua;" .. package.path

local uv = require("luv")
local NativeProcess = require("adapters.owned_process")
local Worker = require("native_worker_owner")
local Port = require("llm.finite_process_port")
local timers, timer_port = {}, {}
function timer_port.new_timer() local handle = uv.new_timer(); timers[#timers + 1] = handle; return handle end
function timer_port.timer_start(...) return uv.timer_start(...) end
function timer_port.timer_stop(...) return uv.timer_stop(...) end
function timer_port.close(...) return uv.close(...) end
local port, passed = Port.new(Worker, NativeProcess, timer_port, 25), 0
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat uv.run("nowait"); if predicate() then return true end; uv.sleep(2) until uv.hrtime() >= deadline
	return false
end
local function absent(pid)
	local receipt, _, code = uv.kill(-pid, 0)
	return receipt == nil and code == "ESRCH"
end
local function test(name, body)
	body()
	assert(await(function() return not uv.loop_alive() end), "native handles remain after " .. name)
	passed = passed + 1; print("PASS " .. name)
end
test("literal false survives real elapsed time with referenced monitor then retires exact group", function()
	local output, callbacks, retired = "", 0, 0
	local options = { owner = "service-native-lifetime", timeout_ms = false, capture_tail = true,
		authorized = function() return true end, on_output = function(chunk) output = output .. chunk end }
	local operation = port.start_service("python3", { "-c", "import os,time; print('ready:%d:%d' % (os.getpid(),os.getpgrp()),flush=True); time.sleep(30)" }, options,
		function() callbacks = callbacks + 1 end)
	operation:on_settled(function() retired = retired + 1 end)
	assert(operation.started and await(function() return output:find("ready:", 1, true) ~= nil end))
	local pid, group = output:match("ready:(%d+):(%d+)"); pid, group = tonumber(pid), tonumber(group)
	assert(pid and pid == group and uv.kill(-pid, 0) == 0, "real detached native group receipt")
	options.timeout_ms = 1
	local deadline = uv.hrtime() + 350000000
	repeat uv.run("nowait"); uv.sleep(2) until uv.hrtime() >= deadline
	assert(operation:is_current() and not operation:is_settled() and uv.has_ref(timers[#timers]), "service survives without unref or finite timeout")
	assert(operation:cancel() == false and not operation:is_settled(), "signal does not retire native group")
	assert(await(function() return operation:is_settled() end) and absent(pid), "native ESRCH must follow exact cleanup")
	assert(callbacks == 0 and retired == 1)
end)
test("actual service natural exit delivers full output only after both owners settle", function()
	local result, callbacks, retired = nil, 0, false
	local operation = port.start_service("python3", { "-c", "import sys; print('service-exit'); sys.stderr.write('service-diagnostic')" },
		{ owner = "service-native-exit", timeout_ms = false, authorized = function() return true end },
		function(value) result, callbacks = value, callbacks + 1 end)
	operation:on_settled(function() retired = true end)
	assert(operation.started and result == nil and not operation:is_settled())
	assert(await(function() return operation:is_settled() end) and retired and callbacks == 1)
	assert(result.ok and result.stdout == "service-exit\n" and result.stderr == "service-diagnostic")
end)
test("source revocation retires real service leader and stubborn descendant group", function()
	local output, source, callbacks = "", true, 0
	local script = "import os,signal,time; r,w=os.pipe(); child=os.fork();\nif child == 0:\n os.close(r); signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(w,b'R'); os.close(w); time.sleep(30); os._exit(0)\nos.close(w); os.read(r,1); os.close(r); print('ready:%d:%d' % (os.getpid(),child),flush=True); time.sleep(30)"
	local operation = port.start_service("python3", { "-c", script },
		{ owner = "service-native-source", timeout_ms = false, authorized = function() return source end,
			on_output = function(chunk) output = output .. chunk end }, function() callbacks = callbacks + 1 end)
	assert(operation.started and await(function() return output:find("ready:", 1, true) ~= nil end))
	local leader, child = output:match("ready:(%d+):(%d+)"); leader, child = tonumber(leader), tonumber(child)
	assert(leader and child and uv.kill(child, 0) == 0 and uv.kill(-leader, 0) == 0, "actual live descendant receipt")
	source = false; assert(not operation:is_current() and not operation:is_settled())
	assert(await(function() return operation:is_settled() end) and absent(leader), "remaining descendants retain group debt until actual ESRCH")
	local receipt, _, code = uv.kill(child, 0); assert(receipt == nil and code == "ESRCH" and callbacks == 0)
end)
test("real service missing binary refuses and retires every physical and shared handle", function()
	local result
	local operation = port.start_service("/nonexistent/ergopti-service-fixture", {},
		{ owner = "service-native-absent", timeout_ms = false, authorized = function() return true end }, function(value) result = value end)
	assert(not operation.started and await(function() return operation:is_settled() end))
	assert(result and not result.ok and result.error == "native process dispatch failed")
end)
print(string.format("Service shared process native: %d passed, 0 failed.", passed))
