--- tools/test/managed_ollama_restart_envelope_test.lua
--- The removed detached-command helper is replaced by the canonical foreground owner.
--- Receive the actual manager/API/adapter/receipt with explicit controlled ports.
local root, production = assert(arg[1]), assert(arg[2])
local Ports = assert(loadfile(root .. "/tools/test/fixtures/managed_ollama_foreground_ports.lua"))()
local NONCE, BINARY, LOG, PORT, LAUNCH = Ports.NONCE, Ports.BINARY, Ports.LOG, Ports.PORT, Ports.LAUNCH
local assertions, cases = 0, 0
local function check(actual, expected) assert(actual == expected, "restart envelope receiving assertion failed"); assertions = assertions + 1 end
local function case(run) cases = cases + 1; run() end
local function frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. NONCE .. " " .. role .. "\n" end
local function receiving(options) return Ports.new(root, production, options) end

local function native_case(pull_supported)
	local state = receiving({ pull_supported = pull_supported })
	check(state.restart(), true)
	check(#state.calls, 1)
	check(state.calls[1][1], BINARY); check(state.calls[1][2], LOG); check(state.calls[1][3], PORT)
	check(state.calls[1][4], "native_managed"); check(state.calls[1][5], NONCE)
	check(#state.tasks, 1)
	local task = state.tasks[1]
	check(task.executable, "/bin/sh"); check(task.arguments[1], "-c"); check(task.arguments[2], LAUNCH)
	check(type(task.streaming), "function"); check(task.private, true); check(task.owned, true); check(task.environment, nil)
	check(task.arguments[2]:find("OLLAMA_MODELS", 1, true), nil)
	check(task.arguments[2]:find("HTTP_PROXY", 1, true), nil)
	check(task.arguments[2]:find("nohup", 1, true), nil); check(task.arguments[2]:find("pkill", 1, true), nil)
	check(state.operation.command, state.observed); check(state.retries, 0)
	task.emit(frame("ACTIVE") .. frame("READY"):sub(1, -2))
	check(state.retries, 0)
	task.emit("\n")
	check(state.retries, 1); check(state.operation.command, nil)
	check(state.api.migration_idle(), false)
	task.emit(frame("RETIRED 0"))
	check(state.api.migration_idle(), false)
	task.complete()
	check(state.api.migration_idle(), true)
	check(#state.tasks, 1); check(task.terminate_calls, 0); check(state.pull_calls, 0)
end

-- Keep the five historical input families; detached alternatives now refuse.
case(function() native_case(true) end)
case(function() native_case(false) end)
case(function()
	local state = receiving({ absent = true, pull_supported = true })
	check(state.restart(), false); check(#state.calls, 0); check(#state.tasks, 0)
	check(state.result, false); check(state.reason, "server executable resolution")
	check(state.errors[1][2], "absent-binary")
end)
case(function()
	local state = receiving({ refused = true, pull_supported = true })
	check(state.restart(), false); check(#state.calls, 1)
	check(state.calls[1][1], BINARY); check(state.calls[1][2], LOG); check(state.calls[1][3], PORT)
	check(#state.tasks, 0); check(state.result, false); check(state.reason, "server command creation")
	check(state.errors[1][2], "guarded-unavailable")
end)
case(function()
	local state = receiving({ foreign = true, pull_supported = true })
	check(state.restart(), false); check(#state.calls, 0); check(#state.tasks, 0); check(state.pull_calls, 0)
	check(state.result, false); check(state.reason, "external runtime requires manual service management")
	check(state.notices[1], "ollama.external_manual_start_body"); check(state.api.migration_idle(), true)
end)
print(string.format("PASS %d cases / %d assertions", cases, assertions))
