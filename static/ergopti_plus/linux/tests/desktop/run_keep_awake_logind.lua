--- tests/desktop/run_keep_awake_logind.lua

--- ==============================================================================
--- MODULE: Keep Awake Against a Real logind
--- DESCRIPTION:
--- Drives the real modules/keep_awake.lua and the gesture manager's pause and
--- stop paths against a real systemd-logind on the system bus: each phase reads
--- logind's own inhibitor list (`systemd-inhibit --list`), never a stand-in.
--- Phases: toggle on then off, on then pause, on then quit (stop_programs), and
--- a child daemon killed with SIGKILL while it holds the inhibitor.
--- Exit 0 = every phase acquired and released the inhibitor; 1 = a failure.
--- ==============================================================================

require("compat.utf8").install()
local uv = require("luv")

local CHILD = arg[1] == "--child"
local DEADLINE_MS = 10000
local POLL_MS = 100

--- Counts the Ergopti idle inhibitors logind currently holds.
--- @return integer count
local function held()
	local pipe = assert(io.popen("systemd-inhibit --list --no-pager --no-legend 2>/dev/null"))
	local text = pipe:read("*a")
	pipe:close()
	local count = 0
	for line in text:gmatch("[^\n]+") do
		if line:match("^Ergopti%s") and line:find("idle", 1, true) then count = count + 1 end
	end
	return count
end

--- Runs the loop until predicate() holds or the deadline passes.
--- @param predicate function Condition polled every POLL_MS.
--- @return boolean met
local function wait_for(predicate)
	local met = false
	local timer = uv.new_timer()
	local started = uv.now()
	timer:start(0, POLL_MS, function()
		if predicate() then met = true end
		if met or uv.now() - started > DEADLINE_MS then timer:stop(); uv.stop() end
	end)
	uv.run()
	timer:close()
	return met
end

local KeepAwake = require("modules.keep_awake")

if CHILD then
	assert(KeepAwake.toggle(), "the child inhibitor must start")
	assert(wait_for(function() return held() == 1 end), "the child never held the inhibitor")
	io.stdout:write("HELD\n")
	io.stdout:flush()
	uv.run()
	os.exit(0)
end

local Gestures = require("modules.gestures.manager")
local failures = 0

--- Acquires the inhibitor, releases it through one path and checks logind.
--- @param name string Phase name for the receipt.
--- @param release function The release path under test.
local function phase(name, release)
	assert(held() == 0, name .. ": an inhibitor was already held")
	local admitted = KeepAwake.toggle()
	local acquired = admitted and wait_for(function() return held() == 1 end)
	release()
	local released = acquired and wait_for(function() return held() == 0 end)
	-- The owner settles once the process exit, group absence and pipe closures land.
	local settled = false
	KeepAwake.when_settled(function() settled = true end)
	wait_for(function() return settled end)
	local ok = acquired and released and settled
	print(string.format("%s %s: acquired=%s released=%s settled=%s", ok and "PASS" or "FAIL", name,
		tostring(acquired), tostring(released), tostring(settled)))
	if not ok then failures = failures + 1 end
end

print(string.format("session: XDG_SESSION_TYPE=%s DISPLAY=%s WAYLAND_DISPLAY=%s",
	tostring(os.getenv("XDG_SESSION_TYPE")), tostring(os.getenv("DISPLAY")), tostring(os.getenv("WAYLAND_DISPLAY"))))
phase("toggle-off", function() KeepAwake.toggle() end)
phase("pause", function() Gestures.set_program_paused(true); Gestures.set_program_paused(false) end)
phase("quit", function() Gestures.stop_programs() end)

-- Daemon termination: the private stdin pipe dies with the process.
local script = debug.getinfo(1, "S").source:sub(2)
local child = assert(io.popen("luajit " .. script .. " --child & echo $!; wait", "r"))
local pid = tonumber(child:read("*l"))
local ready = child:read("*l")
local acquired = ready == "HELD" and held() == 1
os.execute("kill -KILL " .. tostring(pid))
child:close()
local released = wait_for(function() return held() == 0 end)
print(string.format("%s daemon-sigkill: acquired=%s released=%s", (acquired and released) and "PASS" or "FAIL",
	tostring(acquired), tostring(released)))
if not (acquired and released) then failures = failures + 1 end
os.exit(failures == 0 and 0 or 1)
