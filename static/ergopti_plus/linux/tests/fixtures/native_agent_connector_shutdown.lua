--- tests/fixtures/native_agent_connector_shutdown.lua

--- ==============================================================================
--- MODULE: Native Agent Connector Shutdown Regression
--- DESCRIPTION:
--- Runs a harmless private Python tool through the real connector and executes
--- the actual Main shutdown registry. Quiescence cannot leave the tool alive or
--- let it publish a marker or callback after the event loop has returned.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_agent_connector_shutdown%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv, Json = require("luv"), require("json")
local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-agent-lifetime-XXXXXX"))
for name, value in pairs({ XDG_CONFIG_HOME = scratch .. "/.config", XDG_DATA_HOME = scratch .. "/.local/share",
	XDG_STATE_HOME = scratch .. "/.local/state", ERGOPTI_AGENT_SHUTDOWN_PROBE_DIR = scratch }) do
	assert(uv.os_setenv(name, value))
end
local Shell = require("adapters.shell_runner")
local Connectors = require("modules.llm.agent_connectors")
local Loop, Coordinator = require("adapters.event_loop"), require("infra.shutdown_coordinator")
local function read(path)
	local file = io.open(path, "rb"); if not file then return nil end
	local data = file:read("*a"); assert(file:close()); return data
end
local function write(path, data)
	local file = assert(io.open(path, "wb")); assert(file:write(data)); assert(file:close())
end
local function identity(pid)
	local stat = read("/proc/" .. pid .. "/stat")
	if not stat then return nil end
	local tail = assert(stat:match("^%d+ %(.+%) (.+)$"))
	local fields = {}; for value in tail:gmatch("%S+") do fields[#fields + 1] = value end
	return { state = fields[1], start_ticks = fields[20] }
end
local function absent(pid)
	local accepted, _, errno = uv.kill(-pid, 0)
	return accepted == nil and errno == "ESRCH"
end
local function await(predicate, pump)
	local limit = uv.hrtime() + 1000000000
	repeat
		if predicate() then return true end
		if pump then uv.run("nowait") end
		uv.sleep(2)
	until uv.hrtime() >= limit
	return predicate()
end
local function remove_tree(path)
	local scan = assert(uv.fs_scandir(path))
	while true do
		local name, kind = uv.fs_scandir_next(scan)
		if not name then break end
		local child = path .. "/" .. name
		if kind == "directory" then remove_tree(child) else assert(uv.fs_unlink(child)) end
	end
	assert(uv.fs_rmdir(path))
end
local original_spawn, children = uv.spawn, {}
uv.spawn = function(program, options, callback)
	local process, pid, code = original_spawn(program, options, callback)
	if process then
		local receipt = assert(identity(pid), "new owned child identity unavailable")
		children[#children + 1] = { pid = pid, start_ticks = receipt.start_ticks }
	end
	return process, pid, code
end
local watchdog, timed_out
local ok, why = xpcall(function()
	if arg[1] == "cold" then
		assert(not package.loaded["adapters.owned_process"], "cold load initialized a native process owner")
		assert(Connectors.shutdown())
		assert(not Connectors.run({ max_tools = 4 }, { type = "shortcut", name = "absent" }, function() error("late callback") end))
		assert(not package.loaded["adapters.owned_process"] and #children == 0)
		print("PASS native cold agent shutdown: no process backend acquisition")
		return
	end
	local tools = require("infra.config_paths").config(Connectors.TOOLS_DIR)
	assert(tools:sub(1, #scratch) == scratch, "tools escaped owned XDG configuration")
	assert(Shell.run("mkdir -p " .. Shell.quote(tools)))
	if arg[1] == "spawn-refused" then
		Connectors._set_deps_for_test({ tools_dir = function() return tools end,
			list_executables = function() return { "absent-tool" } end })
		local callbacks = 0
		assert(not Connectors.run({ max_tools = 4 }, { type = "shortcut", name = "absent-tool" }, function() callbacks = callbacks + 1 end))
		assert(callbacks == 0 and not Connectors.shutdown(), "failed spawn forgot pending pipe close acknowledgements")
		assert(await(function() return Connectors.shutdown() end, true), "failed native spawn retained cleanup debt")
		assert(callbacks == 0 and #children == 0, "failed spawn published after shutdown")
		print("PASS native refused agent tool: no child, pending pipes physically closed")
		return
	end
	write(tools .. "/held-tool", [[#!/usr/bin/python3
import json,os,sys,time
from pathlib import Path
root=Path(os.environ['ERGOPTI_AGENT_SHUTDOWN_PROBE_DIR'])
fields=Path('/proc/self/stat').read_text().rsplit(') ',1)[1].split()
(root/'ready.tmp').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'start_ticks':fields[19]}))
os.replace(root/'ready.tmp',root/'ready')
if sys.argv[1:] != ['normal']:
    while not (root/'release').exists(): time.sleep(.002)
    (root/'marker').write_text('owned synthetic tool acted after daemon shutdown')
print('tool-finished',flush=True)
]])
	assert(uv.fs_chmod(tools .. "/held-tool", 448))
	local callbacks, ready, completed_ok = 0, nil, nil
	watchdog = assert(uv.new_timer())
	require("infra.native_timer").start(uv, watchdog, 5000, 0, function() timed_out = true; Loop.stop() end)
	assert(Connectors.run({ max_tools = 4 }, { type = "shortcut", name = "held-tool", input = arg[1] == "normal" and "normal" or nil },
		function(success)
			callbacks = callbacks + 1
			completed_ok = success
		end))
	assert(await(function()
		local bytes = read(scratch .. "/ready"); if bytes then ready = assert(Json.decode(bytes)) end
		return ready ~= nil
	end, true), "native tool did not become ready")
	assert(#children == 1 and ready.pid == children[1].pid and ready.pgid == ready.pid
		and ready.start_ticks == children[1].start_ticks, "native identity receipt changed")
	if arg[1] == "normal" then
		assert(await(function() return callbacks == 1 end, true), "normal connector did not complete")
		assert(completed_ok == true, "normal tool failed")
		assert(Connectors.shutdown() and absent(ready.pid), "normal completion preceded physical retirement")
		print("PASS native normal agent tool: callback once after physical retirement")
		return
	end
	local text = assert(read(root .. "/ergopti_hotstrings.lua"))
	local capture = assert(text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
	local registry = assert(text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"))
	local stops = 0
	local env = setmetatable({ ShutdownCoordinator = Coordinator,
		package = { loaded = { ["modules.llm.agent_connectors"] = Connectors } }, keylogger = { stop = function() return true end }, privacy_owners = {},
		dyn_hotstrings = false, updater = false, file_watchers = false, process_lifecycle = false, webview_manager = false,
		tooltip_preview = false, gestures = false, input_capture_gate = false, prediction_engine = false,
		TimerScheduler = require("adapters.timer_scheduler"),
		require = function(name)
			if name == "modules.llm.agent_connectors" then return Connectors end
			assert(name == "modules.llm.agent_learning", "unexpected Main dependency")
			return { flush = function() end }
		end,
		keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
		event_loop = { stop = function() stops = stops + 1; Loop.stop() end },
	}, { __index = _G })
	local body = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
	local chunk
	if setfenv then chunk = assert(loadstring(body, "actual Main agent shutdown")); setfenv(chunk, env)
	else chunk = assert(load(body, "actual Main agent shutdown", "t", env)) end
	local shutdown, requested = chunk(), false
	Loop.run({ onIdle = function()
		if not requested then requested = true; shutdown.request("owned synthetic tool shutdown") else shutdown.poll() end
	end })
	assert(not timed_out, "native shutdown did not settle")
	local current = identity(ready.pid)
	local alive = current and current.start_ticks == ready.start_ticks and current.state ~= "Z" and current.state ~= "X"
	local report = { shutdown_complete = not shutdown.is_pending(), loop_stops = stops, callbacks_at_loop_return = callbacks,
		child_alive_after_loop = alive == true, child_pid = ready.pid, uv_alive_after_loop = uv.loop_alive() }
	assert(report.shutdown_complete and stops == 1 and callbacks == 0)
	if alive then
		-- Baseline counterfactual: only the owned child can see this release.
		-- No UV event may run before its independent post-shutdown marker.
		write(scratch .. "/release", "release after confirmed Main shutdown")
		report.marker_without_uv_pump = await(function() return read(scratch .. "/marker") ~= nil end, false)
		assert(await(function() return callbacks == 1 end, true))
	else
		report.marker_without_uv_pump = read(scratch .. "/marker") ~= nil
		assert(Connectors.shutdown() and absent(ready.pid), "helper shutdown did not physically settle")
	end
	print(Json.encode(report))
	assert(not report.marker_without_uv_pump and not alive, "agent tool acted after actual Main shutdown completed")
	print("PASS native Main agent shutdown: no late callback, exact group absent")
end, debug.traceback)
uv.spawn = original_spawn
if watchdog and not uv.is_closing(watchdog) then uv.timer_stop(watchdog); uv.close(watchdog) end
for _, child in ipairs(children) do
	local current = identity(child.pid)
	if current and current.start_ticks == child.start_ticks then uv.kill(-child.pid, "sigkill") end
end
assert(await(function() return not uv.loop_alive() end, true), "fixture cleanup retained native handles")
local remaining = 0; uv.walk(function() remaining = remaining + 1 end); assert(remaining == 0)
for _, child in ipairs(children) do
	local current = identity(child.pid)
	assert(not current or current.start_ticks ~= child.start_ticks, "owned child not reaped")
	assert(absent(child.pid), "owned native group survived cleanup")
end
remove_tree(scratch)
print("OWNED_CLEANUP", Json.encode({ handles = remaining, children_reaped = true, groups_absent = true }))
if not ok then io.stderr:write(tostring(why) .. "\n") end
os.exit(ok and 0 or 1)
