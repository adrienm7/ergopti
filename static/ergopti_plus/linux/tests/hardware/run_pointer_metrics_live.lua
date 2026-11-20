--- tests/hardware/run_pointer_metrics_live.lua

--- ==============================================================================
--- MODULE: The Daemon Counts A Real Mouse And Touchpad Into The Metrics Store
--- DESCRIPTION:
--- Run by run_pointer_metrics_live.sh under Xvfb, with a session bus, the
--- accessibility bus, a window manager and a focused GTK window. The harness
--- creates a keyboard, a mouse and a touchpad through uinput, starts the REAL
--- daemon on them (--device for the keyboard, --pointer for the pointer, which
--- the finder skips as virtual otherwise), uses the pointer, stops the daemon
--- and reads the rows its keystats wrote to metrics.sqlite. The daemon runs
--- twice, once per pointer: it pins one.
---
--- Xvfb reads no evdev device, so the harness plays the desktop's part: before
--- each movement report it puts the X cursor where the desktop would have put
--- it (xdotool), the position pointer_metrics reads to measure the distance in
--- screen pixels, and an xinput on the daemon's PATH answers the libinput
--- tap-to-click properties the X server would have applied to the touchpad.
---
--- WHAT IT ASSERTS (pointer_metrics.lua, keystats' mouse columns):
--- 1. Clicks: a left and a right press count, a middle press does not.
--- 2. Scrolls: each classic vertical and horizontal wheel report counts once;
---    the high-resolution reports repeat the same turns and add nothing.
--- 3. Distance: the straight lines between the cursor positions read on the
---    movement frames, in pixels (a 500 + 300 + 500 px path).
--- 4. Touchpad: a one-finger tap, a two-finger tap and a clickpad press made
---    during a touch count as three clicks, though each touch's landing
---    withdraws the field's verdict before its click (tap-click-touch-context);
---    the same three made in a password field add nothing.
--- 5. The rows are stored: the daemon's stop flushes them to metrics.sqlite.
--- Exit 0 = every check held; 1 = a failure; 2 = no environment.
--- ==============================================================================

local EvdevCodes = require("platform.input.evdev_codes")
local InputEvent = require("platform.input.event")
local Shell = require("core.process.adapters.shell_runner")
local Timings = require("core.timing.engine.timings")

local EXPECTED_CHECKS = 16
local TEST_KEYBOARD = "Ergopti Metrics Keyboard"
local TEST_MOUSE = "Ergopti Metrics Mouse"
local TEST_TOUCHPAD = "Ergopti Metrics Touchpad"
-- The cursor path: three legs of 500, 300 and 500 px (3-4-5 triangles), so the
-- stored integer distance is exact.
local PATH = { { 100, 100 }, { 400, 500 }, { 400, 200 }, { 100, 600 } }
local EXPECTED_DISTANCE = 1300
-- Longer than pointer_metrics.POSITION_SAMPLE_MS, so each frame reads the cursor.
local STEP_SECONDS = 0.15
-- A tap's touch: well inside libinput's 180 ms tap timeout (tap_detector).
local TAP_SECONDS = 0.05
-- The guard reads the focus past its settle delay, then waits on the
-- accessibility bus: a second and a half covers both on a loaded runner.
local REREAD_SECONDS = Timings.ms("privacy", "focus_settle_ms") / 1000 + 1.5

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

print("=== the daemon counts a real mouse and touchpad into the metrics store ===")
if not os.getenv("DISPLAY") then abort("no display server; run under run_pointer_metrics_live.sh") end
for _, tool in ipairs({ "xdotool", "sqlite3", "python3" }) do
	if not Shell.has_command(tool) then abort(tool .. " is missing") end
end
local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then abort("no LuaJIT FFI on this interpreter") end





-- =========================================================
-- =========================================================
-- ======= 1/ A keyboard, a mouse and a touchpad ===========
-- =========================================================
-- =========================================================

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

-- The touchpad: a two-slot clickpad declared as the kernel's MT drivers do
-- (run_touchpad_capability.lua), with a resolution, so the tap detector judges
-- a finger's travel in millimetres.
-- The writers above may have declared the same libc functions already.
local declared_c, declaration = pcall(ffi.cdef, [[
	int open(const char *pathname, int flags);
	int close(int fd);
	int ioctl(int fd, unsigned long request, ...);
	long write(int fd, const void *buf, size_t count);
]])
if not declared_c and not tostring(declaration):find("redefin", 1, true) then abort("ffi: " .. tostring(declaration)) end
ffi.cdef([[
	struct ergopti_pad_setup { unsigned short bustype; unsigned short vendor; unsigned short product;
		unsigned short version; char name[80]; unsigned int ff_effects_max; };
	struct ergopti_pad_abs { unsigned short code; int value; int minimum; int maximum; int fuzz; int flat;
		int resolution; };
	struct ergopti_pad_event { long sec; long usec; unsigned short type; unsigned short code; int value; };
]])
local UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_SET_PROPBIT = 0x40045564, 0x40045565, 0x40045567, 0x4004556e
local UI_ABS_SETUP, UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x401c5504, 0x405c5503, 0x5501, 0x5502
local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local ABS_X, ABS_Y = 0x00, 0x01
local ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
local BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP = 0x14a, 0x145, 0x14d
local INPUT_PROP_POINTER, INPUT_PROP_BUTTONPAD = 0x00, 0x02
-- 100 x 70 mm at 12 units per millimetre.
local PAD_RESOLUTION, PAD_MAX_X, PAD_MAX_Y = 12, 1200, 840

local pad_fd = ffi.C.open("/dev/uinput", 2049) -- O_WRONLY | O_NONBLOCK
if pad_fd < 0 then abort("could not open /dev/uinput for the touchpad") end
local function pad_ioctl(request, value)
	return ffi.C.ioctl(pad_fd, request, ffi.cast("int", value)) >= 0
end
local declared = pad_ioctl(UI_SET_EVBIT, EV_KEY) and pad_ioctl(UI_SET_EVBIT, EV_ABS) and pad_ioctl(UI_SET_EVBIT, EV_SYN)
	and pad_ioctl(UI_SET_PROPBIT, INPUT_PROP_POINTER) and pad_ioctl(UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD)
for _, key in ipairs({ EvdevCodes.BTN_LEFT, BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP }) do
	declared = declared and pad_ioctl(UI_SET_KEYBIT, key)
end
for _, axis in ipairs({ ABS_X, ABS_Y, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID }) do
	local abs = ffi.new("struct ergopti_pad_abs")
	abs.code = axis
	if axis == ABS_MT_SLOT then abs.maximum = 1
	elseif axis == ABS_MT_TRACKING_ID then abs.maximum = 65535
	else
		abs.maximum = (axis == ABS_X or axis == ABS_MT_POSITION_X) and PAD_MAX_X or PAD_MAX_Y
		abs.resolution = PAD_RESOLUTION
	end
	declared = declared and pad_ioctl(UI_SET_ABSBIT, axis) and ffi.C.ioctl(pad_fd, UI_ABS_SETUP, abs) >= 0
end
local pad_setup = ffi.new("struct ergopti_pad_setup")
pad_setup.bustype, pad_setup.vendor, pad_setup.product, pad_setup.version = 0x18, 0x06cb, 0xce2d, 1
ffi.copy(pad_setup.name, TEST_TOUCHPAD)
if not declared or ffi.C.ioctl(pad_fd, UI_DEV_SETUP, pad_setup) < 0 or ffi.C.ioctl(pad_fd, UI_DEV_CREATE) < 0 then
	ffi.C.close(pad_fd)
	abort("uinput refused the touchpad")
end

--- Writes one evdev frame to the touchpad: its reports, then SYN_REPORT.
--- @param reports table { { type, code, value }, ... }
local function pad_frame(reports)
	reports[#reports + 1] = { EV_SYN, 0, 0 }
	for _, report in ipairs(reports) do
		local event = ffi.new("struct ergopti_pad_event")
		event.type, event.code, event.value = report[1], report[2], report[3]
		assert(tonumber(ffi.C.write(pad_fd, event, ffi.sizeof(event))) == ffi.sizeof(event), "a touchpad report")
	end
end

local keyboard_node = await(function() return node_for(TEST_KEYBOARD) end, 5)
local mouse_node = await(function() return node_for(TEST_MOUSE) end, 5)
local pad_node = await(function() return node_for(TEST_TOUCHPAD) end, 5)
if not keyboard_node or not mouse_node or not pad_node then abort("the test devices got no /dev/input node") end
print("  test keyboard: " .. keyboard_node .. ", test mouse: " .. mouse_node .. ", test touchpad: " .. pad_node)





-- ===================================
-- ===================================
-- ======= 2/ The daemon =============
-- ===================================
-- ===================================

local interpreter = arg and arg[-1] or "luajit"
local _runs = {}
-- The password window's process, once it is opened (section 4).
local _password_pid = nil

--- Whether a run's daemon process is alive (LuaJIT's os.execute answers 0, Lua 5.4 true).
local function running(run)
	if not run.pid then return false end
	local status = os.execute("kill -0 " .. run.pid .. " 2>/dev/null")
	return status == true or status == 0
end

local function dump_log(run)
	local text = read_file(run.log) or ""
	local lines = {}
	for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
	print("  --- daemon log (" .. run.pointer .. "): pointer and metrics lines, then the tail ---")
	for _, line in ipairs(lines) do
		local lower = line:lower()
		if lower:find("pointer") or lower:find("keystats") or lower:find("metrics") or lower:find("error")
			or lower:find("secure") or lower:find("focus") or lower:find("at%-spi") or lower:find("privacy")
			or lower:find("atspi") or lower:find("accessib") or lower:find("tap") then
			print("  " .. line)
		end
	end
	for i = math.max(1, #lines - 30), #lines do print("  " .. lines[i]) end
end

local function cleanup()
	for _, run in ipairs(_runs) do
		if running(run) then os.execute("kill " .. run.pid .. " 2>/dev/null") end
		os.execute("rm -rf " .. Shell.quote(run.home))
	end
	if _password_pid then os.execute("kill " .. _password_pid .. " 2>/dev/null") end
	pcall(Mouse.close)
	pcall(Keyboard.close)
	ffi.C.ioctl(pad_fd, UI_DEV_DESTROY)
	ffi.C.close(pad_fd)
end

--- Starts the daemon on the keyboard and one pointer, in a private home, and
--- waits until it is ready.
--- @param pointer string The pinned pointer's event node.
--- @param path_prefix string|nil A directory put first on the daemon's PATH.
--- @return table run { pointer, home, log, pid }
local function start_daemon(pointer, path_prefix)
	local home = os.tmpname()
	os.remove(home)
	assert(Shell.run("mkdir -p " .. Shell.quote(home)), "private home")
	local run = { pointer = pointer, home = home, log = home .. "/daemon.log" }
	_runs[#_runs + 1] = run
	local environment = string.format("HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s",
		Shell.quote(home), Shell.quote(home .. "/.config"), Shell.quote(home .. "/.local/share"))
	if path_prefix then environment = environment .. " PATH=" .. Shell.quote(path_prefix .. ":" .. os.getenv("PATH")) end
	-- A configuration file keeps the setup wizard closed. Metrics collection ships
	-- off and is switched on as a user would, through the canonical preferences.
	assert(Shell.run(environment .. " " .. Shell.quote(interpreter) .. " -e "
		.. Shell.quote('require("tests.support.live_preferences").daemon(); '
			.. 'assert(require("infra.metrics_preferences").set("metrics.enabled", true), '
			.. '"metrics collection must be switched on")')),
		"the live daemon configuration must be prepared before input starts")
	os.execute(string.format("%s %s ergopti_hotstrings.lua --verbose --device %s --pointer %s"
		.. " --config tests/e2e/fixtures/daemon_keys.toml > %s 2>&1 & echo $! > %s",
		environment, Shell.quote(interpreter), Shell.quote(keyboard_node), Shell.quote(pointer),
		Shell.quote(run.log), Shell.quote(home .. "/pid")))
	run.pid = (read_file(home .. "/pid") or ""):match("%d+")
	local ready = await(function()
		return (read_file(run.log) or ""):find("Daemon ready", 1, true) ~= nil or nil
	end, 90)
	-- The first periodic tick probes the sound, network and window stacks and
	-- holds the loop for seconds without them: input sent meanwhile is read in
	-- one burst, its cursor reads and focus answers all late.
	local settled = ready and await(function()
		return (read_file(run.log) or ""):find("Window topology and capture-program presence", 1, true) ~= nil or nil
	end, 60)
	if not ready or not settled then
		dump_log(run)
		cleanup()
		print("  FAIL the daemon never reported itself ready")
		os.exit(1)
	end
	return run
end

--- Whether the privacy gate has admitted the focused field. Metrics are
--- recorded only then (--verbose logs the verdict).
--- @param run table
--- @return boolean
local function admitted(run)
	return (read_file(run.log) or ""):find("Focused field admitted", 1, true) ~= nil
end

--- Waits until the gate has read the focus again. Every click, a touch's
--- landing included, withdraws the verdict until then, and the logger folds a
--- verdict line repeated within its window (logger SPEC 4.2), so a later
--- admission is not visible in the log: the wait is the settle delay and the
--- probe's own time.
local function reread()
	sleep(REREAD_SECONDS)
end

--- Stops a run's daemon (SIGTERM is the session's end: keystats.stop flushes
--- the pending rows) and reads the mouse columns it stored.
--- @param run table
--- @return table totals { rows, clicks, scrolls, distance }
local function stop_and_read(run)
	os.execute("kill " .. run.pid .. " 2>/dev/null")
	local stopped = await(function() return not running(run) end, 30)
	check(stopped == true, "the daemon on " .. run.pointer .. " stops on SIGTERM")
	local store = nil
	local found = io.popen("find " .. Shell.quote(run.home) .. " -name metrics.sqlite -type f 2>/dev/null")
	if found then store = found:read("*l"); found:close() end
	check(type(store) == "string" and store ~= "", "the daemon on " .. run.pointer .. " wrote its metrics store")
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
	local result = { rows = totals[1], clicks = totals[2], scrolls = totals[3], distance = totals[4] }
	print(string.format("  stored: rows=%s clicks=%s scrolls=%s distance=%s px", tostring(result.rows),
		tostring(result.clicks), tostring(result.scrolls), tostring(result.distance)))
	return result
end





-- ===================================
-- ===================================
-- ======= 3/ The mouse, used ========
-- ===================================
-- ===================================

-- The cursor starts where the path does: a position read at the daemon's start
-- then seeds the same point the first movement measures from.
assert(Shell.run(string.format("xdotool mousemove %d %d", PATH[1][1], PATH[1][2])), "xdotool moves the X cursor")
local mouse_run = start_daemon(mouse_node)
check((read_file(mouse_run.log) or ""):find("Pinned pointer device: " .. mouse_node, 1, true) ~= nil,
	"the daemon pins the virtual mouse it was given")

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
check(await(function() return admitted(mouse_run) end, 30) == true, "the privacy gate admits the focused GTK field")
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
	reread()
	click(button)
end

print("--- the mouse's stored rows ---")
local mouse = stop_and_read(mouse_run)
check(type(mouse.rows) == "number" and mouse.rows >= 1, "pointer activity is stored as typing rows")
check(mouse.clicks == 2, "a left and a right press count as two clicks, the middle one as none")
check(mouse.scrolls == 5, "five classic wheel reports count, the high-resolution repeats add nothing")
check(mouse.distance == EXPECTED_DISTANCE,
	string.format("the distance is the cursor's %d px path, not the device units", EXPECTED_DISTANCE))
if _failures > 0 then dump_log(mouse_run) end





-- =====================================
-- =====================================
-- ======= 4/ The touchpad, used =======
-- =====================================
-- =====================================

-- The X server's libinput driver would report the pad's tap setting; Xvfb has
-- none, so this xinput answers what it would: tapping on, the lrm map.
local shim = os.tmpname()
os.remove(shim)
assert(Shell.run("mkdir -p " .. Shell.quote(shim)), "the xinput directory")
local xinput = assert(io.open(shim .. "/xinput", "w"))
xinput:write(table.concat({
	"#!/bin/sh",
	"case \"$1\" in",
	"\tlist) echo 41 ;;",
	"\tlist-props) printf \"Device '%s':\\n\\tDevice Enabled (150):\\t1\\n\\tlibinput Tapping Enabled (300):\\t1\\n"
		.. "\\tlibinput Tapping Button Mapping Enabled (301):\\t1, 0\\n\\tDevice Node (270):\\t\\\"%s\\\"\\n\" "
		.. Shell.quote(TEST_TOUCHPAD) .. " " .. Shell.quote(pad_node) .. " ;;",
	"\t*) exit 1 ;;",
	"esac",
	"",
}, "\n"))
xinput:close()
assert(Shell.run("chmod +x " .. Shell.quote(shim .. "/xinput")), "an executable xinput")

local pad_run = start_daemon(pad_node, shim)
check((read_file(pad_run.log) or ""):find("Pinned pointer device: " .. pad_node, 1, true) ~= nil,
	"the daemon pins the virtual touchpad it was given")

local _tracking_id = 100

--- Lands fingers (one per slot), holds them, then lifts them: a tap.
--- @param fingers integer 1 or 2.
--- @param during function|nil Called while the fingers are down.
local function touch(fingers, during)
	local landing, lifting = {}, {}
	for slot = 0, fingers - 1 do
		_tracking_id = _tracking_id + 1
		landing[#landing + 1] = { EV_ABS, ABS_MT_SLOT, slot }
		landing[#landing + 1] = { EV_ABS, ABS_MT_TRACKING_ID, _tracking_id }
		landing[#landing + 1] = { EV_ABS, ABS_MT_POSITION_X, 400 + slot * 240 }
		landing[#landing + 1] = { EV_ABS, ABS_MT_POSITION_Y, 400 }
		lifting[#lifting + 1] = { EV_ABS, ABS_MT_SLOT, slot }
		lifting[#lifting + 1] = { EV_ABS, ABS_MT_TRACKING_ID, -1 }
	end
	local tool = fingers == 1 and BTN_TOOL_FINGER or BTN_TOOL_DOUBLETAP
	landing[#landing + 1] = { EV_KEY, BTN_TOUCH, 1 }
	landing[#landing + 1] = { EV_KEY, tool, 1 }
	landing[#landing + 1] = { EV_ABS, ABS_X, 400 }
	landing[#landing + 1] = { EV_ABS, ABS_Y, 400 }
	lifting[#lifting + 1] = { EV_KEY, tool, 0 }
	lifting[#lifting + 1] = { EV_KEY, BTN_TOUCH, 0 }
	pad_frame(landing)
	if during then during() end
	sleep(TAP_SECONDS)
	pad_frame(lifting)
	sleep(STEP_SECONDS)
end

--- The three touchpad clicks: a left tap, a right tap and a clickpad press.
--- @param ready function|nil Waited on before each, as a user's next click is.
local function three_clicks(ready)
	for _, gesture in ipairs({
		function() touch(1) end,
		function() touch(2) end,
		function()
			touch(1, function()
				sleep(TAP_SECONDS)
				pad_frame({ { EV_KEY, EvdevCodes.BTN_LEFT, 1 } })
				pad_frame({ { EV_KEY, EvdevCodes.BTN_LEFT, 0 } })
			end)
		end,
	}) do
		if ready then ready() end
		gesture()
	end
end

print("--- tapping and pressing the touchpad ---")
check(await(function() return admitted(pad_run) end, 30) == true, "the privacy gate admits the focused GTK field")
-- Each touch's landing withdraws the verdict: the next one waits for a read.
three_clicks(reread)
check((read_file(pad_run.log) or ""):find("Tap-to-click on " .. pad_node .. ": on, lrm map (xinput)", 1, true) ~= nil,
	"the daemon reads the tap setting the X server applies to the pad")

-- A password field over the GTK window: a touch begins in it, and none of its
-- clicks may be recorded.
local password_ready = os.tmpname()
os.remove(password_ready)
os.execute("python3 tests/hardware/atspi_fixture_app.py metrics-password password --lifetime-seconds 60"
	.. " --ready-file " .. Shell.quote(password_ready) .. " >/dev/null 2>&1 & echo $! > "
	.. Shell.quote(password_ready .. ".pid"))
_password_pid = (read_file(password_ready .. ".pid") or ""):match("%d+")
local password_focused = await(function() return read_file(password_ready) ~= nil or nil end, 20)
check(password_focused == true, "a password field takes the focus")
-- Past the guard's settle delay, so the password field has been read.
reread()
three_clicks()

print("--- the touchpad's stored rows ---")
local pad = stop_and_read(pad_run)
check(pad.clicks == 3, "the two taps and the clickpad press count as three clicks, in the field each touch began"
	.. " in; the three made in the password field add nothing")
if pad.clicks ~= 3 then dump_log(pad_run) end
os.execute("rm -rf " .. Shell.quote(shim) .. " " .. Shell.quote(password_ready) .. " "
	.. Shell.quote(password_ready .. ".pid"))
cleanup()
check(_checks + 1 == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", _checks + 1, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
