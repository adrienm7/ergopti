--- tests/fixtures/native_owned_deadline.lua
--- Actual child deadlines after synchronous work; each invocation owns its loop.
local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(self_path:match("^(.*)/tests/fixtures/[^/]+$"))
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;" .. driver_root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local Owned = require("adapters.owned_process")
local Timer = require("infra.native_timer")
local mode = assert(arg[1])
local BUDGET_MS, BLOCKED_MS = 1000, 1250
local completed, operation

--- Pumps physical receipts without changing an operation's deadline.
--- @param predicate function
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native process did not acknowledge retirement")
end

--- Starts the same short-lived real child for all admission paths.
local function start()
	operation = Owned.start("python3", { "-c", "import os,time; time.sleep(0.04); print('PID:'+str(os.getpid()), flush=True)" },
		{ owner = "new-deadline", timeout_ms = BUDGET_MS }, function(result) completed = result end)
	assert(operation.started and not operation:is_settled())
end

if mode == "cold" then
	uv.update_time()
	uv.sleep(BLOCKED_MS)
	start()
elseif mode == "callback" then
	local trigger = uv.new_timer()
	Timer.start(uv, trigger, 1, 0, function()
		trigger:close()
		uv.sleep(BLOCKED_MS)
		start()
	end)
	await(function() return operation ~= nil end)
elseif mode == "existing" then
	local ready, old_result = false, nil
	uv.update_time()
	local old = Owned.start("python3", { "-c", "import time; print('ready',flush=True); time.sleep(30)" },
		{ owner = "existing-deadline", timeout_ms = BUDGET_MS,
			on_output = function(text) ready = ready or text:find("ready", 1, true) ~= nil end },
		function(result) old_result = result end)
	assert(old.started)
	await(function() return ready end)
	uv.sleep(BLOCKED_MS)
	start()
	uv.run("nowait")
	assert(old.result and old.result.error == "process deadline exceeded", "refresh must not restart an existing absolute deadline")
	await(function() return old:is_settled() end)
	assert(old_result and not old_result.ok and old_result.error == "process deadline exceeded")
else
	error("unknown deadline control")
end

await(function() return operation:is_settled() end)
assert(completed and completed.ok, "a new child lost its deadline before first loop tick: " .. tostring(completed and completed.error))
local pid = assert(tonumber(completed.stdout:match("^PID:(%d+)\n$")))
local sent, _, code = uv.kill(-pid, 0)
assert(sent == nil and code == "ESRCH", "the detached child group must be physically absent")
uv.run("nowait")
local retained = 0
uv.walk(function() retained = retained + 1 end)
assert(retained == 0 and not uv.loop_alive(), "owned deadline control leaked native handles")
print("PASS owned-deadline " .. mode .. ": child exit/group ESRCH/close ACKs; zero native handles")
