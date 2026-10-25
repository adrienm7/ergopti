--- tests/hardware/run_process_snapshot_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Process Snapshot Receipts
--- DESCRIPTION:
--- Drives production app launch/quit polling around owned native processes,
--- which the snapshot reads from the real /proc in the daemon's own process.
--- A refused process table (the snapshot pointed at a path the kernel answers
--- ENOENT for) cannot synthesize lifecycle events or seed startup ownership. A
--- real launch/quit control proves successful snapshots still work, a real
--- zombie is an exited application before its parent reaps it, and the
--- kernel's own name bytes (parentheses, spaces, COMMAND) survive. No process
--- rows or syscalls are forged; focus/title/input behavior is not exercised.
--- ==============================================================================

local uv = require("luv")
local Life = require("adapters.process_lifecycle")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-process-snapshot-XXXXXX"))
local marker_a, marker_b = "epA" .. root:sub(-6), "epB" .. root:sub(-6)
local marker_z = "epZ" .. root:sub(-6)
local literal_names = { " ep lead", "ep trail ", " ep both ", "   " }
local tracked_names = {
	[marker_a] = true, [marker_b] = true, [marker_z] = true, COMMAND = true,
	["ep pair"] = true, [" ep pair "] = true, ["ep) (x y"] = true,
}
for _, name in ipairs(literal_names) do
	tracked_names[name] = true
	tracked_names[name:match("^%s*(.-)%s*$")] = true -- also observe trimmed aliases.
end
local children = {}
local checks, failures = 0, 0

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local value = file:read("*a")
	file:close()
	return value
end

local function pump_until(predicate)
	local deadline = uv.hrtime() + 2000000000
	repeat uv.run("nowait"); uv.sleep(1) until predicate() or uv.hrtime() >= deadline
	assert(predicate(), "owned native process did not acknowledge its transition")
end

--- Starts an owned python3 whose kernel name (comm) is exactly marker.
local function spawn(marker)
	local child = { ready = root .. "/ready-" .. marker:gsub("[^%w]", "_") .. "-" .. tostring(#children) }
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

--- Starts an owned parent that never reaps its child named marker: once the
--- go file exists the child exits and stays a zombie until the parent dies.
local function spawn_zombie_parent(marker)
	local parent = { ready = root .. "/zombie-ready", go = root .. "/zombie-go" }
	local program = table.concat({
		"import ctypes,os,sys,time",
		"pid = os.fork()",
		"if pid == 0:",
		"    assert ctypes.CDLL(None).prctl(15,sys.argv[1].encode(),0,0,0)==0",
		"    open(sys.argv[2],'w').write(str(os.getpid()))",
		"    while not os.path.exists(sys.argv[3]): time.sleep(0.01)",
		"    os._exit(0)",
		"time.sleep(60)",
	}, "\n")
	parent.handle = assert(uv.spawn("python3", { args = { "-c", program, marker, parent.ready, parent.go } }, function()
		parent.exited = true
		uv.close(parent.handle)
	end))
	children[#children + 1] = parent
	pump_until(function() return (read(parent.ready) or "") ~= "" end)
	parent.child_pid = tonumber(read(parent.ready))
	assert(parent.child_pid, "zombie fixture child did not publish its pid")
	return parent
end

--- The scheduler state the kernel reports for one pid, from its stat line.
local function state_of(pid)
	local line = read("/proc/" .. tostring(pid) .. "/stat") or ""
	return line:match("^.*%) (%u)")
end

assert(read("/proc/self/stat"), "the native process table is required")
local child_a = spawn(marker_a)
local launched, quit = {}, {}
Life.onAppLaunch(function(name) if tracked_names[name] then launched[#launched + 1] = name end end)
Life.onAppQuit(function(name) if tracked_names[name] then quit[#quit + 1] = name end end)

local function check(name, test)
	checks = checks + 1
	launched, quit = {}, {}
	Life.stop()
	Life._set_proc_root_for_test(nil)
	local ok, err = xpcall(test, debug.traceback)
	Life.stop()
	Life._set_proc_root_for_test(nil)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

-- A path the kernel refuses with ENOENT stands for an unreadable process table.
local refused = root .. "/no-process-table"

check("refused native process table retains the successful baseline", function()
	Life.start()
	Life._set_proc_root_for_test(refused)
	Life.tick(8)
	assert(#quit == 0 and #launched == 0, "a refused table synthesized events for a still-live process")
	Life._set_proc_root_for_test(nil)
	Life.tick(16)
	assert(#quit == 0 and #launched == 0, "table recovery synthesized a relaunch")
	assert(not child_a.exited, "owned process actually exited during the refusal test")
end)

check("refused native process table cannot seed startup ownership", function()
	Life._set_proc_root_for_test(refused)
	Life.start()
	Life._set_proc_root_for_test(nil)
	Life.tick(8)
	assert(#quit == 0 and #launched == 0, "a refused startup table treated an existing process as newly launched")
	assert(not child_a.exited)
end)

check("actual process launch and exit still deliver exactly one event", function()
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

check("an actual unreaped zombie is an exited application", function()
	local parent = spawn_zombie_parent(marker_z)
	Life.start()
	local file = assert(io.open(parent.go, "w"))
	assert(file:close())
	pump_until(function() return state_of(parent.child_pid) == "Z" end)
	Life.tick(8)
	assert(#quit == 1 and quit[1] == marker_z, "a zombie still read as a running application")
	assert(not parent.exited, "the parent must still hold the unreaped child")
	retire(parent)
	Life.tick(16)
	assert(#quit == 1 and #launched == 0, "reaping a zombie repeated or reversed its quit")
end)

check("actual process named COMMAND is data, never a header", function()
	Life.start()
	local command = spawn("COMMAND")
	Life.tick(8)
	assert(#launched == 1 and launched[1] == "COMMAND", "legitimate native process name was discarded")
	retire(command)
	Life.tick(16)
	assert(#quit == 1 and quit[1] == "COMMAND", "COMMAND retirement was never observed")
end)

check("actual process name with parentheses and spaces is read whole", function()
	Life.start()
	local child = spawn("ep) (x y")
	assert(read("/proc/" .. child.handle:get_pid() .. "/comm") == "ep) (x y\n", "the kernel must hold the exact name")
	Life.tick(8)
	assert(#launched == 1 and launched[1] == "ep) (x y", "the name ends at the stat line's last parenthesis")
	retire(child)
	Life.tick(16)
	assert(#quit == 1 and quit[1] == "ep) (x y")
end)

for index, name in ipairs(literal_names) do
	check("actual process whitespace name " .. index .. " retains its native bytes", function()
		Life.start()
		local child = spawn(name)
		assert(read("/proc/" .. child.handle:get_pid() .. "/comm") == name .. "\n",
			"the kernel must prove these are data bytes, not padding")
		Life.tick(8)
		assert(#launched == 1 and launched[1] == name, "process launch changed or discarded native whitespace")
		retire(child)
		Life.tick(16)
		assert(#quit == 1 and quit[1] == name, "process retirement changed or discarded native whitespace")
	end)
end

check("distinct native whitespace names cannot collapse into one process identity", function()
	local plain = spawn("ep pair")
	Life.start()
	local spaced = spawn(" ep pair ")
	Life.tick(8)
	assert(#launched == 1 and launched[1] == " ep pair ", "second native identity collapsed into its trimmed neighbor")
	retire(spaced)
	Life.tick(16)
	assert(#quit == 1 and quit[1] == " ep pair ", "neighbor masked the real process exit")
	retire(plain)
	Life.tick(24)
	assert(#quit == 2 and quit[2] == "ep pair", "remaining native identity did not retire independently")
end)

Life.stop()
for _, child in ipairs(children) do retire(child) end
uv.run("nowait")
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(not uv.loop_alive(), "fixture leaked native process ownership")
print(string.format("Native process snapshot receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
