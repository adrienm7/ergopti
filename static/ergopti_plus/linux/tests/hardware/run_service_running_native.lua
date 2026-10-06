--- tests/hardware/run_service_running_native.lua

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$"),
	"launch with an absolute script path")
local shared_root = driver_root .. "/../_shared/lua"
package.path = driver_root .. "/?.lua;" .. shared_root .. "/?.lua;" .. package.path

local uv = require("luv")
local callbacks = {}
local native = setmetatable({}, { __index = uv })
function native.close(handle, callback)
	return uv.close(handle, function()
		callbacks[#callbacks + 1] = { callback = callback, delivered = false }
	end)
end
local previous = package.loaded.luv
package.loaded.luv = native
local Native = require("adapters.owned_process")
package.loaded.luv = previous
local Worker = require("native_worker_owner")
local Port = require("llm.process_port")
local port, passed = Port.new(Worker, Native, uv, 25), 0
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat uv.run("nowait"); if predicate() then return true end; uv.sleep(2) until uv.hrtime() >= deadline
	return false
end
local function release()
	for _, receipt in ipairs(callbacks) do
		if not receipt.delivered then receipt.delivered = true; receipt.callback() end
	end
end
local function test(name, body)
	body()
	assert(await(function() return not uv.loop_alive() end), "native handles remain after " .. name)
	passed = passed + 1; print("PASS " .. name)
end
test("real child exit loses running authority while actual close callbacks remain debt", function()
	local output, deliveries = "", 0
	local op = port.start_service("python3", { "-c", "import os,time; print('ready:%d'%os.getpid(),flush=True); time.sleep(.25)" },
		{ owner = "actual-running-exit", timeout_ms = false, authorized = function() return true end,
			on_output = function(chunk) output = output .. chunk end }, function() deliveries = deliveries + 1 end)
	assert(op.started and await(function() return output:find("ready:", 1, true) ~= nil end))
	assert(op:is_running(), "actual live child owns running lifecycle")
	local pid = tonumber(output:match("ready:(%d+)")); assert(pid and uv.kill(pid, 0) == 0)
	assert(await(function() return not op:is_running() and #callbacks >= 3 end), "actual native exit must be observed before handoff")
	assert(op:is_current() and not op:is_settled() and deliveries == 0, "close ACK debt must not hide known exit")
	local receipt, _, code = uv.kill(pid, 0); assert(receipt == nil and code == "ESRCH", "actual leader physically reaped")
	local rejected = port.start_service("python3", { "-c", "raise RuntimeError('must not run')" },
		{ owner = "actual-running-exit", timeout_ms = false, authorized = function() return true end }, function() end)
	assert(not rejected.started and rejected.result.error == "service_process_owner_busy")
	assert(await(function() release(); return op:is_settled() end) and deliveries == 1 and not op:is_running())
end)
test("real native output terminal loses running authority before retained close ACKs", function()
	local output, result = "", nil
	local op = port.start_service("python3", { "-c", "import os,sys,time; print('ready:%d'%os.getpid(),file=sys.stderr,flush=True); time.sleep(.15); print('x'*128,flush=True); time.sleep(30)" },
		{ owner = "actual-running-terminal", timeout_ms = false, max_output_bytes = 32,
			authorized = function() return true end, on_output = function(chunk) output = output .. chunk end },
		function(value) result = value end)
	assert(op.started and await(function() return output:find("ready:", 1, true) ~= nil end))
	assert(op:is_running())
	local before = #callbacks
	assert(await(function() return not op:is_running() and #callbacks > before end))
	assert(op:is_current() and not op:is_settled() and result == nil, "terminal receipt is not running or settlement")
	assert(await(function() release(); return op:is_settled() end))
	assert(result and not result.ok and result.error == "process output exceeds its bound", "actual overflow refusal retained")
end)
print(string.format("Actual service running controls: %d passed, 0 failed.", passed))
