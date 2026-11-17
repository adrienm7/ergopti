--- tests/hardware/run_pointer_metrics_live.lua

--- ==============================================================================
--- MODULE: The Daemon Counts A Real Mouse Into The Metrics Store
--- DESCRIPTION:
--- Run by run_pointer_metrics_live.sh under Xvfb, with a session bus, the
--- accessibility bus, a window manager and a focused GTK window. The harness
--- creates a keyboard and a mouse through uinput, starts the REAL daemon on them
--- (--device for the keyboard, --pointer for the mouse, which the finder skips
--- as virtual otherwise), moves, clicks and scrolls the mouse, stops the daemon
--- and reads the rows its keystats wrote to metrics.sqlite.
---
--- Xvfb reads no evdev device, so the harness plays the desktop's part: before
--- each movement report it puts the X cursor where the desktop would have put
--- it (xdotool), the position pointer_metrics reads to measure the distance in
--- screen pixels.
---
--- WHAT IT ASSERTS (pointer_metrics.lua, keystats' mouse columns):
--- 1. Clicks: a left and a right press count, a middle press does not.
--- 2. Scrolls: each classic vertical and horizontal wheel report counts once;
---    the high-resolution reports repeat the same turns and add nothing.
--- 3. Distance: the straight lines between the cursor positions read on the
---    movement frames, in pixels (a 500 + 300 + 500 px path).
--- 4. The rows are stored: the daemon's stop flushes them to metrics.sqlite.
--- Exit 0 = every check held; 1 = a failure; 2 = no environment.
--- ==============================================================================

local EvdevCodes = require("platform.input.evdev_codes")
local InputEvent = require("platform.input.event")
local Monotonic = require("core.logger.engine.monotonic")
local Shell = require("core.process.adapters.shell_runner")

local EXPECTED_CHECKS = 9
local TEST_KEYBOARD = "Ergopti Metrics Keyboard"
local TEST_MOUSE = "Ergopti Metrics Mouse"
-- The cursor path: three legs of 500, 300 and 500 px (3-4-5 triangles), so the
-- stored integer distance is exact.
local PATH = { { 100, 100 }, { 400, 500 }, { 400, 200 }, { 100, 600 } }
local EXPECTED_DISTANCE = 1300
-- Longer than pointer_metrics.POSITION_SAMPLE_MS, so each frame reads the cursor.
local STEP_SECONDS = 0.15

local _checks, _failures = 0, 0

--- @param condition boolean
--- @param what string
--- @return boolean
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print("  ok   " .. what)
	else
		_failures = _failures + 1
		print("  FAIL " .. what)
	end
	io.stdout:flush()
	return condition
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- @param seconds number
local function sleep(seconds)
	os.execute(string.format("sleep %.3f", seconds))
end

--- The /dev/input node of a device, by exact name.
--- @param name string
--- @return string|nil
local function node_for(name)
	local fh = io.open("/proc/bus/input/devices", "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	for block in text:gmatch("I:.-\n\n") do
		if block:find('N: Name="' .. name .. '"', 1, true) then
			local event = (block:match("H: Handlers=([^\n]*)") or ""):match("(event%d+)")
			if event then return "/dev/input/" .. event end
		end
	end
	return nil
end

--- @param predicate function
--- @param seconds number
--- @return any
local function await(predicate, seconds)
	for _ = 1, math.floor(seconds * 10) do
		local value = predicate()
		if value then return value end
		sleep(0.1)
	end
	return nil
end

--- The whole text of a file, or nil.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

print("=== the daemon counts a real mouse into the metrics store ===")
if not os.getenv("DISPLAY") then abort("no display server; run under run_pointer_metrics_live.sh") end
for _, tool in ipairs({ "xdotool", "sqlite3" }) do
	if not Shell.has_command(tool) then abort(tool .. " is missing") end
end





-- =========================================
-- =========================================
-- ======= 1/ A keyboard and a mouse =======
-- =========================================
-- =========================================

-- The keyboard the daemon is pinned to (keys only, as a physical keyboard).
local Keyboard = require("tests.hardware.keyboard_source_writer").load(TEST_KEYBOARD)
if not Keyboard.is_available() then abort("/dev/uinput is not writable") end
Keyboard.use_ffi_backend()
if not Keyboard.open() then abort("could not create the test keyboard") end

-- The mouse: a private instance of the production writer, whose device carries
-- the buttons and every relative axis a wheel mouse reports, under a test name.
local Names = require("platform.input.device_names")
local writer_chunk = assert(loadfile("platform/input/uinput_writer.lua"))
local production_name = Names.VIRTUAL_KEYBOARD
Names.VIRTUAL_KEYBOARD = TEST_MOUSE
local loaded, Mouse = pcall(writer_chunk)
Names.VIRTUAL_KEYBOARD = production_name
if not loaded then abort("the mouse writer did not load: " .. tostring(Mouse)) end
Mouse.use_ffi_backend()
if not Mouse.open() then abort("could not create the test mouse") end

local keyboard_node = await(function() return node_for(TEST_KEYBOARD) end, 5)
local mouse_node = await(function() return node_for(TEST_MOUSE) end, 5)
if not keyboard_node or not mouse_node then abort("the test devices got no /dev/input node") end
print("  test keyboard: " .. keyboard_node .. ", test mouse: " .. mouse_node)





-- ===================================
-- ===================================
-- ======= 2/ The daemon =============
-- ===================================
-- ===================================

-- The cursor starts where the path does: a position read at the daemon's start
-- then seeds the same point the first movement measures from.
assert(Shell.run(string.format("xdotool mousemove %d %d", PATH[1][1], PATH[1][2])), "xdotool moves the X cursor")
local home = os.tmpname()
os.remove(home)
assert(Shell.run("mkdir -p " .. Shell.quote(home)), "private home")
local log = home .. "/daemon.log"
local interpreter = arg and arg[-1] or "luajit"
local environment = string.format("HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s",
	Shell.quote(home), Shell.quote(home .. "/.config"), Shell.quote(home .. "/.local/share"))
-- A configuration file keeps the setup wizard closed. Metrics collection ships
-- off and is switched on as a user would, through the canonical preferences.
assert(Shell.run(environment .. " " .. Shell.quote(interpreter) .. " -e "
	.. Shell.quote('require("tests.support.live_preferences").daemon(); '
		.. 'assert(require("infra.metrics_preferences").set("metrics.enabled", true), '
		.. '"metrics collection must be switched on")')),
	"the live daemon configuration must be prepared before input starts")
os.execute(string.format("%s %s ergopti_hotstrings.lua --verbose --device %s --pointer %s"
	.. " --config tests/e2e/fixtures/daemon_keys.toml > %s 2>&1 & echo $! > %s",
	environment, Shell.quote(interpreter), Shell.quote(keyboard_node), Shell.quote(mouse_node),
	Shell.quote(log), Shell.quote(home .. "/pid")))
local pid = (read_file(home .. "/pid") or ""):match("%d+")

--- Whether the daemon process is alive (LuaJIT's os.execute answers 0, Lua 5.4 true).
local function running()
	if not pid then return false end
	local status = os.execute("kill -0 " .. pid .. " 2>/dev/null")
	return status == true or status == 0
end

local function dump_log()
	local text = read_file(log) or ""
	local lines = {}
	for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
	print("  --- daemon log: pointer and metrics lines, then the tail ---")
	for _, line in ipairs(lines) do
		local lower = line:lower()
		if lower:find("pointer") or lower:find("keystats") or lower:find("metrics") or lower:find("error")
			or lower:find("secure") or lower:find("focus") or lower:find("at%-spi") or lower:find("privacy")
			or lower:find("atspi") or lower:find("accessib") then
			print("  " .. line)
		end
	end
	for i = math.max(1, #lines - 30), #lines do print("  " .. lines[i]) end
end

local function cleanup()
	if running() then os.execute("kill " .. pid .. " 2>/dev/null") end
	pcall(Mouse.close)
	pcall(Keyboard.close)
	os.execute("rm -rf " .. Shell.quote(home))
end

local ready = await(function()
	local text = read_file(log) or ""
	return text:find("Daemon ready", 1, true) ~= nil or nil
end, 90)
if not ready then
	dump_log()
	cleanup()
	print("  FAIL the daemon never reported itself ready")
	os.exit(1)
end
local watched = (read_file(log) or ""):find("Pinned pointer device: " .. mouse_node, 1, true) ~= nil
check(watched, "the daemon pins the virtual mouse it was given")

--- Whether the privacy gate's last verdict admits the focused field. Metrics
--- are recorded only then, and every click withdraws it until the focus is
--- read again (--verbose logs each verdict).
--- @return boolean
local function admitted()
	local last = nil
	for verdict in (read_file(log) or ""):gmatch("Focused field (%a+)") do last = verdict end
	return last == "admitted"
end





-- ===================================
-- ===================================
-- ======= 3/ The mouse, used ========
-- ===================================
-- ===================================

--- Puts the X cursor where the desktop would put it, then sends the report.
--- @param x integer
--- @param y integer
--- @param dx integer
--- @param dy integer
local function move(x, y, dx, dy)
	assert(Shell.run(string.format("xdotool mousemove %d %d", x, y)), "xdotool moves the X cursor")
	sleep(0.05)
	assert(Mouse.emit_relative(InputEvent.REL_X, dx), "a REL_X report")
	assert(Mouse.emit_relative(InputEvent.REL_Y, dy), "a REL_Y report")
	sleep(STEP_SECONDS)
end

--- @param code integer
local function click(code)
	assert(Mouse.emit(code, 1) and Mouse.emit(code, 0), "a button press and release")
	sleep(STEP_SECONDS)
end

print("--- moving, scrolling and clicking ---")
check(await(admitted, 30) == true, "the privacy gate admits the focused GTK field")
-- The first frame only seeds the position the next ones measure from.
move(PATH[1][1], PATH[1][2], 1, 1)
for index = 2, #PATH do
	move(PATH[index][1], PATH[index][2], PATH[index][1] - PATH[index - 1][1], PATH[index][2] - PATH[index - 1][2])
end
for _, report in ipairs({
	{ InputEvent.REL_WHEEL, 1 }, { InputEvent.REL_WHEEL_HI_RES, 120 },
	{ InputEvent.REL_WHEEL, -1 }, { InputEvent.REL_WHEEL_HI_RES, -120 },
	{ InputEvent.REL_WHEEL, 1 }, { InputEvent.REL_HWHEEL, 1 }, { InputEvent.REL_HWHEEL, -1 },
}) do
	assert(Mouse.emit_relative(report[1], report[2]), "a wheel report")
	sleep(STEP_SECONDS)
end
-- A click moves the caret, so the gate withdraws its verdict at each one: the
-- next click waits until the field is read again, as a user's would be.
for _, button in ipairs({ EvdevCodes.BTN_LEFT, EvdevCodes.BTN_RIGHT, EvdevCodes.BTN_MIDDLE }) do
	await(admitted, 10)
	click(button)
end





-- ===================================
-- ===================================
-- ======= 4/ The stored rows ========
-- ===================================
-- ===================================

print("--- the stored rows ---")
-- SIGTERM is the session's end: keystats.stop flushes the pending rows.
os.execute("kill " .. pid .. " 2>/dev/null")
local stopped = await(function() return not running() end, 30)
check(stopped == true, "the daemon stops on SIGTERM")
local store = nil
local found = io.popen("find " .. Shell.quote(home) .. " -name metrics.sqlite -type f 2>/dev/null")
if found then store = found:read("*l"); found:close() end
check(type(store) == "string" and store ~= "", "the daemon wrote its metrics store")
local totals = {}
if store then
	local query = io.popen("sqlite3 -separator ' ' " .. Shell.quote(store) .. " "
		.. Shell.quote("SELECT COUNT(*), COALESCE(SUM(mouse_clicks),0), COALESCE(SUM(mouse_scrolls),0),"
			.. " COALESCE(SUM(mouse_distance_px),0) FROM events_typing WHERE mouse_clicks > 0"
			.. " OR mouse_scrolls > 0 OR mouse_distance_px > 0;"))
	local line = query and query:read("*l") or ""
	if query then query:close() end
	for value in line:gmatch("%-?%d+") do totals[#totals + 1] = tonumber(value) end
end
local rows, clicks, scrolls, distance = totals[1], totals[2], totals[3], totals[4]
print(string.format("  stored: rows=%s clicks=%s scrolls=%s distance=%s px",
	tostring(rows), tostring(clicks), tostring(scrolls), tostring(distance)))
check(type(rows) == "number" and rows >= 1, "pointer activity is stored as typing rows")
check(clicks == 2, "a left and a right press count as two clicks, the middle one as none")
check(scrolls == 5, "five classic wheel reports count, the high-resolution repeats add nothing")
check(distance == EXPECTED_DISTANCE,
	string.format("the distance is the cursor's %d px path, not the device units", EXPECTED_DISTANCE))
if _failures > 0 then dump_log() end
cleanup()
check(_checks + 1 == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", _checks + 1, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
