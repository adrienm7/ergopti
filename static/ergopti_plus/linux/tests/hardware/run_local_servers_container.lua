--- tests/hardware/run_local_servers_container.lua

--- ==============================================================================
--- MODULE: Local Server Detection Container Control
--- DESCRIPTION:
--- Runs one detection of the AI menu's local servers through the production
--- local_servers module: the /proc command-line walk, the settings files, ss
--- for the listening ports, the shared discovery policy and curl against each
--- port. The parent (run_local_servers_container.py) starts the servers under
--- the names and flags of local_servers.json and checks what this control
--- prints: one ERGOPTI_LOCAL_SERVERS_RESULT line with every view, and the
--- detection's log lines.
--- ==============================================================================

local uv = require("luv")
local Json = require("json")

-- API keys live in the desktop secret service: this process gets the in-memory
-- one the unit runner uses, never a keyring the container does not run.
require("tests.support.secret_service_fake").isolate()
local Logger = require("logger.shim")
for _, level in ipairs({ "error", "warn", "info" }) do
	local original = Logger[level]
	Logger[level] = function(tag, format, ...)
		io.stdout:write("PROOF_LOG ", level:upper(), " ", tostring(tag), " ", string.format(format, ...), "\n")
		return original(tag, format, ...)
	end
end

local Servers = require("modules.llm.local_servers")
local EventLoop = require("adapters.event_loop")

local finished, changed = false, nil
local started = Servers.rescan(function() return true end, function(value) finished, changed = true, value end)
local deadline = uv.now() + 30000
local timer = uv.new_timer()
-- The daemon pumps deferred work from its idle callback; this loop does the same.
uv.timer_start(timer, 10, 10, function()
	EventLoop._run_idle_tick()
	if finished or uv.now() > deadline then uv.stop() end
end)
uv.run()
uv.timer_stop(timer); uv.close(timer)

local result = { started = started, finished = finished, changed = changed, views = Servers.views(), detected = Servers.detected() }
local retired
repeat
	retired = Servers.cancel()
	if not retired then uv.run("once") end
until retired or uv.now() > deadline + 5000
uv.run("nowait")
io.stdout:write("ERGOPTI_LOCAL_SERVERS_RESULT:", Json.encode(result), "\n")
