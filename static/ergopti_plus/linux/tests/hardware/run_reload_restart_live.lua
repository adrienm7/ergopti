--- tests/hardware/run_reload_restart_live.lua

--- ==============================================================================
--- MODULE: Reload as a Daemon Restart, Across Real Processes
--- DESCRIPTION:
--- Proves the pending-record protocol of docs/design/driver-control-pending-record.md
--- between real processes: the published POSIX tool (tools/control/
--- request_driver_reload.sh) writes a request and rings SIGUSR1; the running
--- process, through the production infra/driver_control.lua and
--- infra/daemon_restart.lua, writes the pending record (successor null, deadline)
--- and arms the real detached relay of modules/updater/restarter.lua, then exits;
--- the relay starts the launcher once that process has gone, and the successor,
--- a new pid, claims the record and completes it, refuses it with the reason of
--- its own boot, or reports a timeout when it was ready past the deadline.
---
--- The daemon here is a small host of those two owners, not the whole driver: no
--- keyboard, tray or systemd unit is involved. A systemd restart still needs a user
--- session with the unit installed. Missing native prerequisites fail.
--- ==============================================================================

local uv = require("luv")
local ffi = require("ffi")

ffi.cdef([[
	int setenv(const char *, const char *, int);
]])

local SCRIPT = debug.getinfo(1, "S").source:sub(2)
-- A Reload request settles once a successor is up; the tool waits this long.
local TOOL_TIMEOUT_SECONDS = 40
-- The lifetime the timeout case gives its pending record (the declaration's minimum).
local SHORT_TTL_SECONDS = 10





-- ==================================
-- ==================================
-- ======= 1/ The daemon host =======
-- ==================================
-- ==================================

--- Reads a whole file, or nil.
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function append(path, line)
	local handle = assert(io.open(path, "ab"))
	handle:write(line, "\n")
	handle:close()
end

local function exists(path) return uv.fs_stat(path) ~= nil end

--- One daemon generation: publishes the control session, settles the record it
--- owes, and on an admitted request restarts through the relay, then exits.
--- @param scratch string The fixture folder (pids, flags, the launcher).
local function run_daemon(scratch)
	local pid = uv.os_getpid()
	append(scratch .. "/pids", tostring(pid))
	-- The timeout case: this successor is ready only after the record's deadline.
	if exists(scratch .. "/late") then
		os.remove(scratch .. "/late")
		uv.sleep((SHORT_TTL_SECONDS + 2) * 1000)
	end
	local declaration = exists(scratch .. "/short_ttl.json") and (scratch .. "/short_ttl.json") or nil
	local DaemonRestart = require("infra.daemon_restart")
	local session
	local exiting = false
	session = assert(require("infra.driver_control").start({
		pid = pid,
		declaration = declaration,
		reload = function(reason)
			local how, detail = DaemonRestart.restart({
				reason = reason,
				args = {},
				installation = function() return { kind = "standalone", wrapper = scratch .. "/launcher" } end,
			})
			if how ~= "relay" then return false, detail end
			exiting = true
			return true
		end,
		boot_outcome = function()
			if exists(scratch .. "/refuse_boot") then
				os.remove(scratch .. "/refuse_boot")
				return false, "refused"
			end
			return true
		end,
	}))
	local usr1 = uv.new_signal()
	usr1:start("sigusr1", function()
		session:handle()
		if exiting then
			-- The shutdown the daemon runs after a relay restart: keep a successor's
			-- session, then end the process the relay waits for.
			session:stop()
			uv.stop()
		end
	end)
	local term = uv.new_signal()
	term:start("sigterm", function()
		session:stop()
		uv.stop()
	end)
	uv.run()
	os.exit(0)
end

if arg[1] == "daemon" then
	run_daemon(arg[2])
	return
end





-- ====================================
-- ====================================
-- ======= 2/ The orchestration =======
-- ====================================
-- ====================================

local _checks, _failures = 0, 0
local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

--- Runs a shell command; returns its output and exit status (LuaJIT's close gives no status).
local function capture(command)
	local handle = assert(io.popen("(" .. command .. "); echo \"exit=$?\"", "r"))
	local output = handle:read("*a")
	handle:close()
	local body, code = output:match("^(.-)exit=(%d+)%s*$")
	return body or output, tonumber(code)
end

local function setenv(name, value) assert(ffi.C.setenv(name, value, 1) == 0, "setenv " .. name) end

for _, tool in ipairs({ "setsid", "sed" }) do
	if capture("command -v " .. tool .. " 2>/dev/null") == "" then
		io.stderr:write("ENVIRONMENT: " .. tool .. " is not installed\n")
		os.exit(1)
	end
end

local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-reload-restart-XXXXXX"))
for _, dir in ipairs({ "/run", "/config", "/home" }) do assert(uv.fs_mkdir(scratch .. dir, 448)) end
setenv("XDG_RUNTIME_DIR", scratch .. "/run")
setenv("XDG_CONFIG_HOME", scratch .. "/config")
setenv("HOME", scratch .. "/home")

local root = SCRIPT:match("^(.*)/tests/hardware/[^/]+$")
assert(root and root:sub(1, 1) == "/", "run this file by its absolute path")
local tool = root .. "/../../../tools/control/request_driver_reload.sh"
local launcher = scratch .. "/launcher"
local handle = assert(io.open(launcher, "wb"))
handle:write("#!/bin/sh\n", "exec luajit ", quote(SCRIPT), " daemon ", quote(scratch),
	" >>", quote(scratch .. "/daemon.log"), " 2>&1\n")
handle:close()
assert(uv.fs_chmod(launcher, 448))

local function pids()
	local list = {}
	for line in (read(scratch .. "/pids") or ""):gmatch("%d+") do list[#list + 1] = tonumber(line) end
	return list
end

local function alive(pid)
	local status = read("/proc/" .. pid .. "/status")
	return status ~= nil and status:match("State:%s*(%u)") ~= "Z"
end

local session_path = scratch .. "/run/" .. require("app_dirs").folder_name .. "/control/session.json"
local function session_pid() return tonumber(((read(session_path) or ""):match('"pid":(%d+)'))) end

--- Waits until the session is published by the generation `count`.
local function wait_generation(count)
	for _ = 1, 400 do
		local list = pids()
		if #list >= count and session_pid() == list[count] then return list[count] end
		uv.sleep(50)
	end
	return nil
end

--- Runs the published tool once and decodes its last line.
local function request()
	local output, code = capture("sh " .. quote(tool) .. " " .. TOOL_TIMEOUT_SECONDS .. " 2>&1")
	local last = output:match("([^\n]*)\n?$") or ""
	local ok, decoded = pcall(require("json").decode, last)
	return ok and type(decoded) == "table" and decoded or {}, code, output
end

local function cleanup()
	for _, pid in ipairs(pids()) do if alive(pid) then os.execute("kill " .. pid .. " 2>/dev/null") end end
	os.execute("rm -rf " .. quote(scratch))
end

print("=== reload as a daemon restart, across real processes ===")
os.execute("setsid " .. quote(launcher) .. " </dev/null >/dev/null 2>&1 &")
local first = wait_generation(1)
if not check(first ~= nil, "the first daemon publishes its control session") then
	print(read(scratch .. "/daemon.log") or "")
	cleanup()
	os.exit(1)
end

-- 1. A completed reload: a new process claims the record and completes it.
local result, code = request()
local second = wait_generation(2)
check(code == 0 and result.state == "completed", "the tool reads completed: " .. tostring(result.state))
check(second ~= nil and second ~= first, "a new process replaced the first: " .. tostring(first) .. " -> " .. tostring(second))
check(result.successor_pid == second and result.driver_pid == second, "the successor completed the request itself")
check(not alive(first), "the replaced process has exited")

-- 2. The successor's own boot refuses the request.
assert(io.open(scratch .. "/refuse_boot", "wb")):close()
result, code = request()
local third = wait_generation(3)
check(code == 1 and result.state == "refused" and result.reason == "refused",
	"a successor whose boot refused answers refused: " .. tostring(result.state) .. "/" .. tostring(result.reason))
check(third ~= nil and result.driver_pid == third, "the refusal comes from the successor")

-- 3. A successor ready past the record's deadline reports a timeout, never completed.
local spec = require("json").decode(read(require("infra.paths").shared("modules/control/driver_control.json")))
spec.pending_ttl_seconds = SHORT_TTL_SECONDS
handle = assert(io.open(scratch .. "/short_ttl.json", "wb"))
handle:write(require("json").encode(spec))
handle:close()
-- The third generation read the shipped declaration; restart once so the
-- replaced process writes the short deadline.
result = request()
local fourth = wait_generation(4)
check(result.state == "completed" and fourth ~= nil, "a fourth generation runs with the short lifetime")
assert(io.open(scratch .. "/late", "wb")):close()
result, code = request()
local fifth = wait_generation(5)
check(code == 2 and result.state == "timeout" and result.reason == "deadline",
	"a successor ready past the deadline: " .. tostring(result.state) .. "/" .. tostring(result.reason))
check(fifth ~= nil, "the late successor still runs")
local stored = read(scratch .. "/run/" .. require("app_dirs").folder_name .. "/control/reload.result") or ""
check(stored:find('"state":"timeout"', 1, true) ~= nil and not stored:find('"completed"', 1, true),
	"the record says timeout, never completed")

cleanup()
print(string.format("%d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
