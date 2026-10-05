--- tests/hardware/run_finite_process_port_native.lua

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$"),
	"launch with an absolute script path")
local shared_root = driver_root .. "/../_shared/lua"
package.path = driver_root .. "/?.lua;" .. shared_root .. "/?.lua;" .. package.path

local uv = require("luv")
local NativeProcess = require("adapters.owned_process")
local Worker = require("native_worker_owner")
local Port = require("llm.finite_process_port")
local port, passed = Port.new(Worker, NativeProcess, uv, 25), 0
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat uv.run("nowait"); if predicate() then return true end; uv.sleep(2) until uv.hrtime() >= deadline
	return false
end
local function test(name, body)
	body()
	assert(await(function() return not uv.loop_alive() end), "native handles remain after " .. name)
	passed = passed + 1; print("PASS " .. name)
end
test("finite helper preserves real output after native exit and shared timer retirement", function()
	local result, callbacks, observed_settled = nil, 0, false
	local operation = port.start("python3", { "-c", "import sys; print('finite-shared'); sys.stderr.write('diagnostic')" },
		{ owner = "finite-native-normal", timeout_ms = 1000, authorized = function() return true end },
		function(value) result, callbacks = value, callbacks + 1 end)
	operation:on_settled(function() observed_settled = true end)
	assert(operation.started and not operation:is_settled() and result == nil)
	assert(await(function() return operation:is_settled() end))
	assert(observed_settled and callbacks == 1 and result.ok and result.exit_code == 0)
	assert(result.stdout == "finite-shared\n" and result.stderr == "diagnostic")
end)
test("shared finite deadline retires a real ready SIGTERM-resistant child", function()
	local result, output, callbacks = nil, "", 0
	local operation = port.start("python3", { "-c",
		"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(30)" },
		{ owner = "finite-native-deadline", timeout_ms = 500, on_output = function(chunk) output = output .. chunk end },
		function(value) result, callbacks = value, callbacks + 1 end)
	assert(operation.started and await(function() return output:find("ready\n", 1, true) ~= nil end), "actual child must install handler before deadline")
	assert(await(function() return operation:is_settled() end))
	assert(callbacks == 1 and result and not result.ok and result.error == "cancelled", "shared deadline returns honest cancelled native receipt")
end)
test("explicit cancel retains child retirement before same-owner successor", function()
	local output, callbacks = "", 0
	local operation = port.start("python3", { "-c", "import time; print('ready',flush=True); time.sleep(30)" },
		{ owner = "finite-native-cancel", timeout_ms = 1000, on_output = function(chunk) output = output .. chunk end },
		function() callbacks = callbacks + 1 end)
	assert(operation.started and await(function() return output:find("ready\n", 1, true) ~= nil end))
	assert(operation:cancel() == false and not operation:is_settled())
	local blocked = port.start("python3", { "-c", "raise Exception('must not execute')" },
		{ owner = "finite-native-cancel", timeout_ms = 1000 }, function() end)
	assert(blocked:is_settled() and not blocked.started and blocked.result.error == "finite_process_owner_busy")
	assert(await(function() return operation:is_settled() end) and callbacks == 0)
	local result
	local successor = port.start("python3", { "-c", "print('successor')" }, { owner = "finite-native-cancel", timeout_ms = 1000 }, function(value) result = value end)
	assert(successor.started and await(function() return successor:is_settled() end) and result and result.ok and result.stdout == "successor\n")
end)
test("real missing binary refuses and retires all shared and native handles", function()
	local result
	local operation = port.start("/nonexistent/ergopti-finite-shared-fixture", {},
		{ owner = "finite-native-absent", timeout_ms = 1000 }, function(value) result = value end)
	assert(not operation.started and await(function() return operation:is_settled() end))
	assert(result and not result.ok and result.error == "native process dispatch failed")
end)
print(string.format("Finite shared process native: %d passed, 0 failed.", passed))
