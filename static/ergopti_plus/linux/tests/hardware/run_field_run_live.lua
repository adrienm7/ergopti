--- tests/hardware/run_field_run_live.lua

--- ==============================================================================
--- MODULE: The Linux Field Run, Between Real Processes
--- DESCRIPTION:
--- A daemon host starts the production infra/field_run.lua with its native ports
--- (an inotify watcher on the folder, libuv timers, real files) and the real
--- headless Debug field checks (the composer check over a private user XKB tree,
--- the network check over this machine's network); the collector's own
--- tools/dev/linux-field-run.sh writes the request, waits for the done marker,
--- copies the results and prints the marks. No window opens and nobody clicks.
--- The timed reload step restarts the host as the daemon restarts: its reload
--- owner stamps the request (infra/reload_timing.lua), stops the session, starts
--- a successor host and exits; the successor reports the reload at its start and
--- its field run resumes the run, so the collector reads one run across two
--- processes.
---
--- The host is not the whole daemon (no keyboard or tray). The network check's
--- verdict depends on this machine's network; the test requires a verdict for
--- every step, not a pass. Missing native prerequisites fail.
--- ==============================================================================

local uv = require("luv")
local ffi = require("ffi")

ffi.cdef([[
	int setenv(const char *, const char *, int);
]])

local SCRIPT = debug.getinfo(1, "S").source:sub(2)
local ROOT = SCRIPT:match("^(.*)/static/ergopti_plus/linux/tests/hardware/[^/]+$")

local function setenv(name, value) assert(ffi.C.setenv(name, value, 1) == 0, "setenv " .. name) end
local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

if arg[1] == "daemon" then
	-- As the daemon's boot completion does: the reload this start follows, if any.
	local reload_ms = require("infra.reload_timing").complete()
	local session
	local log = os.getenv("XDG_RUNTIME_DIR") .. "/../daemon.log"
	--- The daemon's reload owner, for this host: a restart into a successor host.
	local function reload()
		if not require("infra.reload_timing").mark() then return false, "failed" end
		local timer = uv.new_timer()
		timer:start(0, 0, function()
			timer:close()
			session:stop()
			os.execute("luajit " .. quote(SCRIPT) .. " daemon >>" .. quote(log) .. " 2>&1 &")
			uv.stop()
		end)
		return true
	end
	session = assert(require("infra.field_run").start({ pid = uv.os_getpid(), reload = reload, reload_ms = reload_ms }))
	local term = uv.new_signal()
	term:start("sigterm", function()
		session:stop()
		uv.stop()
	end)
	uv.run()
	os.exit(0)
end





-- ====================================
-- ====================================
-- ======= 1/ The orchestration =======
-- ====================================
-- ====================================

local _checks, _failures = 0, 0
local function check(condition, text)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

assert(ROOT, "run this file by its absolute path inside the clone")
local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-field-run-XXXXXX"))
for _, dir in ipairs({ "/run", "/config", "/home", "/report" }) do assert(uv.fs_mkdir(scratch .. dir, 448)) end
setenv("XDG_RUNTIME_DIR", scratch .. "/run")
setenv("XDG_CONFIG_HOME", scratch .. "/config")
setenv("HOME", scratch .. "/home")
setenv("ERGOPTI_XKB_USER_HOME", scratch .. "/home")

local host = io.popen("luajit " .. quote(SCRIPT) .. " daemon >" .. quote(scratch .. "/daemon.log")
	.. " 2>&1 & echo $!", "r")
local host_pid = tonumber(host:read("*l"))
host:close()
local ready = scratch .. "/run/" .. require("app_dirs").folder_name .. "/field-run/ready.json"
for _ = 1, 200 do
	if read(ready) then break end
	uv.sleep(50)
end
print("=== the Linux field run, between real processes ===")
if not check(read(ready) ~= nil, "the daemon host publishes its field run session") then
	print(read(scratch .. "/daemon.log") or "")
	os.execute("kill " .. host_pid .. " 2>/dev/null; rm -rf " .. quote(scratch))
	os.exit(1)
end

local handle = io.popen("bash -c " .. quote(". " .. quote(ROOT .. "/tools/dev/linux-field-run.sh")
	.. " && field_linux_run " .. quote(ROOT) .. " " .. quote(scratch .. "/report")) .. " 2>&1", "r")
local output = handle:read("*a")
handle:close()
io.write(output)

for index, step in ipairs({ "field_composer", "field_network", "driver_reload", "config_guard" }) do
	check(output:match("field run " .. step .. ": (%a[%w_]*)") ~= nil, "the collector prints a verdict for " .. step)
	check(read(string.format("%s/report/field_run/%02d_%s.json", scratch, index, step)) ~= nil,
		"and copies its result file")
end
check(output:match("field run field_composer: pass") ~= nil, "the composer check passes headless")
check(output:match("field run driver_reload: pass %(reloaded%)") ~= nil,
	"the host restarts and the successor resumes the run")
local reload_result = read(scratch .. "/report/field_run/03_driver_reload.json") or ""
-- A pass without reload_unmeasured: the successor read the predecessor's stamp.
check(reload_result:match('"reload_ms":%d+') ~= nil, "the reload step names the reload's duration")
local successor_pid = tonumber((read(ready) or ""):match('"pid":(%d+)'))
check(successor_pid ~= nil and successor_pid ~= host_pid, "the successor host publishes its own readiness")
check(output:match("field run config_guard: pass") ~= nil, "no step changed config.toml")
check(output:match("Field run summary: ") ~= nil and not output:match("interrupted"), "the run closed with a summary")
check(output:match("field_run=fr%-") ~= nil, "the collector names the request it ran")
local log = read(scratch .. "/daemon.log") or ""
check(not log:find("zenity", 1, true), "no window was asked for")

os.execute("kill " .. host_pid .. " " .. tostring(successor_pid or "") .. " 2>/dev/null")
for _ = 1, 100 do
	if not read(ready) then break end
	uv.sleep(50)
end
check(read(ready) == nil, "a stopping daemon withdraws its readiness")
os.execute("rm -rf " .. quote(scratch))
print(string.format("%d checks, %d failures", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
