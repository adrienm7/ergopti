--- tests/hardware/run_reload_restart_systemd.lua

--- ==============================================================================
--- MODULE: Reload as a Daemon Restart, Through the systemd User Unit Path
--- DESCRIPTION:
--- The systemd half of docs/design/driver-control-pending-record.md, between real
--- processes. The daemon runs inside a real cgroup named after the unit
--- (ergopti-hotstrings.service), so modules/updater/restarter.lua reads a real
--- /proc/self/cgroup and takes the unit path: it runs
--- `systemctl --user --no-block restart ergopti-hotstrings.service` and the
--- daemon does not end itself. The published request tool rings it; the
--- successor, a new pid started in the same unit, completes the request.
---
--- What plays systemd: no user manager runs here (the container did not boot
--- with systemd), so a `systemctl` first in PATH records the call and does what
--- the manager does for that unit: TERM every process of the unit's cgroup, wait
--- for them, start the unit's launcher back in it. Real systemd stays a field
--- check on a user session. The fixture needs a cgroup folder the test user may
--- write (ERGOPTI_TEST_UNIT_CGROUP, ending in /ergopti-hotstrings.service, and a
--- writable sibling for the stand-in's own process); without one it fails.
--- ==============================================================================

local uv = require("luv")
local ffi = require("ffi")

ffi.cdef([[
	int setenv(const char *, const char *, int);
]])

local SCRIPT = debug.getinfo(1, "S").source:sub(2)
local UNIT = "ergopti-hotstrings.service"
local TOOL_TIMEOUT_SECONDS = 40





-- ==================================
-- ==================================
-- ======= 1/ The daemon host =======
-- ==================================
-- ==================================

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

--- One daemon generation inside the unit: on an admitted request it asks for the
--- restart and keeps running until the manager stops it, as under systemd.
local function run_daemon(scratch)
	local pid = uv.os_getpid()
	append(scratch .. "/pids", tostring(pid))
	local DaemonRestart = require("infra.daemon_restart")
	local session
	session = assert(require("infra.driver_control").start({
		pid = pid,
		reload = function(reason)
			local how, detail = DaemonRestart.restart({ reason = reason, args = {} })
			append(scratch .. "/how", tostring(how))
			if how ~= "systemd" then return false, detail end
			return true
		end,
	}))
	local term = uv.new_signal()
	term:start("sigterm", function()
		session:stop()
		uv.stop()
	end)
	local usr1 = uv.new_signal()
	usr1:start("sigusr1", function() session:handle() end)
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
local function setenv(name, value) assert(ffi.C.setenv(name, value, 1) == 0, "setenv " .. name) end

--- Runs a shell command; returns its output and exit status (LuaJIT's close gives no status).
local function capture(command)
	local handle = assert(io.popen("(" .. command .. "); echo \"exit=$?\"", "r"))
	local output = handle:read("*a")
	handle:close()
	local body, code = output:match("^(.-)exit=(%d+)%s*$")
	return body or output, tonumber(code)
end

local function fail_environment(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(1)
end

local cgroup = os.getenv("ERGOPTI_TEST_UNIT_CGROUP") or ""
if cgroup:sub(-#UNIT - 1) ~= "/" .. UNIT then
	fail_environment("ERGOPTI_TEST_UNIT_CGROUP must name a cgroup folder ending in /" .. UNIT)
end
local outside = cgroup:gsub("/[^/]+$", "") .. "/manager.scope"
for _, procs in ipairs({ cgroup .. "/cgroup.procs", outside .. "/cgroup.procs" }) do
	local handle = io.open(procs, "a")
	if not handle then fail_environment(procs .. " is not writable by the test user") end
	handle:close()
end

local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-reload-systemd-XXXXXX"))
for _, dir in ipairs({ "/run", "/config", "/home", "/bin" }) do assert(uv.fs_mkdir(scratch .. dir, 448)) end
setenv("XDG_RUNTIME_DIR", scratch .. "/run")
setenv("XDG_CONFIG_HOME", scratch .. "/config")
setenv("HOME", scratch .. "/home")

local root = SCRIPT:match("^(.*)/tests/hardware/[^/]+$")
assert(root and root:sub(1, 1) == "/", "run this file by its absolute path")
local tool = root .. "/../../../tools/control/request_driver_reload.sh"

-- The unit's ExecStart: the daemon host, started inside the unit's cgroup.
local launcher = scratch .. "/launcher"
local handle = assert(io.open(launcher, "wb"))
handle:write("#!/bin/sh\n", "echo $$ > ", quote(cgroup .. "/cgroup.procs"), "\n",
	"exec luajit ", quote(SCRIPT), " daemon ", quote(scratch), " >>", quote(scratch .. "/daemon.log"), " 2>&1\n")
handle:close()
assert(uv.fs_chmod(launcher, 448))

-- The stand-in for the user manager: only the call the restarter makes is known.
local manager = scratch .. "/bin/systemctl"
handle = assert(io.open(manager, "wb"))
handle:write("#!/bin/sh\n",
	"printf '%s\\n' \"$*\" >> ", quote(scratch .. "/systemctl.calls"), "\n",
	"[ \"$*\" = \"--user --no-block restart ", UNIT, "\" ] || exit 1\n",
	-- --no-block: the job runs after this call returns, from outside the unit.
	"(\n",
	"  echo $(sh -c 'echo $PPID') > ", quote(outside .. "/cgroup.procs"), "\n",
	"  for p in $(cat ", quote(cgroup .. "/cgroup.procs"), "); do kill -TERM \"$p\" 2>/dev/null; done\n",
	"  while [ -n \"$(cat ", quote(cgroup .. "/cgroup.procs"), ")\" ]; do sleep 0.1; done\n",
	"  exec ", quote(launcher), "\n",
	") </dev/null >/dev/null 2>&1 &\n",
	"exit 0\n")
handle:close()
assert(uv.fs_chmod(manager, 448))
setenv("PATH", scratch .. "/bin:" .. (os.getenv("PATH") or ""))

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
local function wait_generation(count)
	for _ = 1, 400 do
		local list = pids()
		if #list >= count and tonumber(((read(session_path) or ""):match('"pid":(%d+)'))) == list[count] then
			return list[count]
		end
		uv.sleep(50)
	end
	return nil
end

local function cleanup()
	for _, pid in ipairs(pids()) do if alive(pid) then os.execute("kill " .. pid .. " 2>/dev/null") end end
	os.execute("rm -rf " .. quote(scratch))
end

print("=== reload as a daemon restart, through the systemd user unit path ===")
os.execute(quote(launcher) .. " </dev/null >/dev/null 2>&1 &")
local first = wait_generation(1)
if not check(first ~= nil, "the first daemon runs inside the unit and publishes its session") then
	print(read(scratch .. "/daemon.log") or "")
	cleanup()
	os.exit(1)
end
check((read("/proc/" .. first .. "/cgroup") or ""):find("/" .. UNIT, 1, true) ~= nil,
	"its /proc cgroup names the unit, as under systemd")

local output, code = capture("sh " .. quote(tool) .. " " .. TOOL_TIMEOUT_SECONDS .. " 2>&1")
local ok, result = pcall(require("json").decode, output:match("([^\n]*)\n?$") or "")
result = ok and type(result) == "table" and result or {}
local second = wait_generation(2)
check((read(scratch .. "/how") or ""):match("^systemd") ~= nil, "the restarter took the unit path, not the relay")
check((read(scratch .. "/systemctl.calls") or "") == "--user --no-block restart " .. UNIT .. "\n",
	"it asked the user manager for exactly one non-blocking restart of the unit")
check(code == 0 and result.state == "completed", "the tool reads completed: " .. tostring(result.state))
check(second ~= nil and second ~= first, "a new process replaced the first: " .. tostring(first) .. " -> " .. tostring(second))
check(result.successor_pid == second and result.driver_pid == second, "the successor completed the request itself")
check(not alive(first), "the replaced daemon is gone once the manager restarted the unit")
check(second ~= nil and (read("/proc/" .. second .. "/cgroup") or ""):find("/" .. UNIT, 1, true) ~= nil,
	"the successor runs inside the unit too")

cleanup()
print(string.format("%d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
