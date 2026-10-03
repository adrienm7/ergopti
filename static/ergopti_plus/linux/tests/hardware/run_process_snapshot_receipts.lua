--- tests/hardware/run_process_snapshot_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Process Snapshot Receipts
--- DESCRIPTION:
--- Drives production app launch/quit polling around owned native processes.
--- A controlled ps wrapper delegates unchanged argv to the real GNU tool, then
--- omits one actual row and exits nonzero or signals itself. Those partial
--- snapshots cannot synthesize lifecycle events. A real launch/quit control
--- proves successful snapshots still work. No ps rows or syscalls are forged;
--- focus/title/input behavior is not exercised or changed.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Life = require("adapters.process_lifecycle")
local real_ps = assert(Shell.exec_line("command -v ps"), "procps must be installed")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-process-snapshot-XXXXXX"))
local previous_path = assert(os.getenv("PATH"))
local marker_a, marker_b = "epA" .. root:sub(-6), "epB" .. root:sub(-6)
local children = {}
local checks, failures = 0, 0

local function write(path, value)
	local file = assert(io.open(path, "w"))
	assert(file:write(value))
	assert(file:close())
end

local function pump_until(predicate)
	local deadline = uv.hrtime() + 2000000000
	repeat uv.run("nowait"); uv.sleep(1) until predicate() or uv.hrtime() >= deadline
	assert(predicate(), "owned native process did not acknowledge its transition")
end

local function spawn(marker)
	local child = { ready = root .. "/ready-" .. marker }
	local program = "import ctypes,sys,time; assert ctypes.CDLL(None).prctl(15,sys.argv[1].encode(),0,0,0)==0; open(sys.argv[2],'w').close(); time.sleep(60)"
	child.handle = assert(uv.spawn("python3", { args = { "-c", program, marker, child.ready } }, function()
		child.exited = true
		uv.close(child.handle)
	end))
	children[#children + 1] = child
	pump_until(function() return uv.fs_stat(child.ready) ~= nil end)
	return child
end

local function retire(child)
	if not child.exited then assert(uv.process_kill(child.handle, "sigterm")) end
	pump_until(function() return child.exited end)
end

write(root .. "/ps", table.concat({
	"#!/bin/sh",
	"mode=$(cat " .. Shell.quote(root .. "/mode") .. ")",
	'if [ "$mode" = success ]; then exec ' .. Shell.quote(real_ps) .. ' "$@"; fi',
	'if [ "$mode" = header ]; then ' .. Shell.quote(real_ps) .. ' "$@" | head -n 1; exit 0; fi',
	Shell.quote(real_ps) .. ' "$@" | sed ' .. Shell.quote("/^" .. marker_a .. "$/d"),
	'case "$mode" in term) kill -TERM $$;; kill) kill -KILL $$;; *) exit "$mode";; esac',
	"",
}, "\n"))
assert(uv.fs_chmod(root .. "/ps", 448))
assert(uv.os_setenv("PATH", root .. ":" .. previous_path))
local child_a = spawn(marker_a)
local launched, quit = {}, {}
Life.onAppLaunch(function(name) if name == marker_a or name == marker_b then launched[#launched + 1] = name end end)
Life.onAppQuit(function(name) if name == marker_a or name == marker_b then quit[#quit + 1] = name end end)

local function mode(value) write(root .. "/mode", value) end

local function check(name, test)
	checks = checks + 1
	launched, quit = {}, {}
	Life.stop()
	local ok, err = xpcall(test, debug.traceback)
	Life.stop()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, failure in ipairs({ "1", "7", "127", "255", "term", "kill" }) do
	check("partial native ps " .. failure .. " retains the successful baseline", function()
		mode("success")
		Life.start()
		mode(failure)
		Life.tick(8)
		assert(#quit == 0 and #launched == 0, "failed partial snapshot synthesized events for a still-live process")
		mode("success")
		Life.tick(16)
		assert(#quit == 0 and #launched == 0, "CLI recovery synthesized a relaunch")
		assert(not child_a.exited, "owned process actually exited during the refusal test")
	end)
	check("partial native ps " .. failure .. " cannot seed startup ownership", function()
		mode(failure)
		Life.start()
		mode("success")
		Life.tick(8)
		assert(#quit == 0 and #launched == 0, "failed startup snapshot treated an existing process as newly launched")
		assert(not child_a.exited)
	end)
end

check("header-only native ps cannot erase the successful baseline", function()
	mode("success")
	Life.start()
	mode("header")
	Life.tick(8)
	mode("success")
	Life.tick(16)
	assert(#quit == 0 and #launched == 0)
end)

check("actual process launch and exit still deliver exactly one event", function()
	mode("success")
	Life.start()
	local child_b = spawn(marker_b)
	Life.tick(8)
	assert(#launched == 1 and launched[1] == marker_b and #quit == 0, "real process launch was not observed")
	retire(child_b)
	Life.tick(16)
	assert(#quit == 1 and quit[1] == marker_b, "real process exit was not observed")
	Life.tick(24)
	assert(#quit == 1 and #launched == 1, "stable native snapshot repeated settled events")
end)

Life.stop()
assert(uv.os_setenv("PATH", previous_path))
for _, child in ipairs(children) do retire(child) end
uv.run("nowait")
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(not uv.loop_alive(), "fixture leaked native process ownership")
print(string.format("Native process snapshot receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
