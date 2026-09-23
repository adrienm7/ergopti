--- tests/hardware/run_daemon_live.lua

--- ==============================================================================
--- MODULE: The Whole Daemon, Live, Against A Real Kernel
--- DESCRIPTION:
--- Starts the REAL daemon (ergopti_hotstrings.lua, --tray) on a keyboard this
--- harness creates through uinput, types a trigger on that keyboard, and reads
--- back what the daemon's own virtual keyboard sends to the desktop.
---
--- WHY THIS EXISTS:
--- Every other check stops at a boundary: the engine against a scripted
--- keyboard, the tray against a probe menu, the injector against a recorder.
--- None started the program a user starts. This does, with everything it
--- touches real — the grab, uinput in both directions, the X keymap, the
--- accessibility bus (a fail-closed privacy gate: nothing expands unless the
--- focused field is known not to be a password), and the tray's D-Bus menu,
--- checked by tests/hardware/sni_host.py in the calling script.
---
--- HOW TO RUN IT: through tests/hardware/run_daemon_live.sh, which provides the
--- X server, the buses, the window manager, a focused GTK field and the panel.
--- Needs root (or the uinput/input groups) for /dev/uinput and the grab.
--- Exit 0 = the trigger expanded; 1 = it did not; 2 = no environment.
--- ==============================================================================

local EvdevCodes = require("infra.evdev_codes")
local EvdevReader = require("adapters.evdev_reader")

local TEST_KEYBOARD = "Ergopti E2E Keyboard"
local DAEMON_OUTPUT = require("infra.device_names").VIRTUAL_KEYBOARD

-- US evdev codes of the keys this harness types and decodes (Xvfb's default
-- keymap is US, so the decode below is exact rather than assumed).
local LETTERS = { [30] = "a", [32] = "d", [49] = "n" }
local KEY_OF = { a = 30, d = 32, n = 49, [" "] = 57 }

local function sleep(seconds) os.execute(string.format("sleep %.3f", seconds)) end
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- The /dev/input node of a device, by exact name.
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

local function await(predicate, seconds)
	for _ = 1, math.floor(seconds * 10) do
		local value = predicate()
		if value then return value end
		sleep(0.1)
	end
	return nil
end




-- =========================================
-- =========================================
-- ======= 1/ A physical keyboard ==========
-- =========================================
-- =========================================

-- A second instance of the production writer under a test name: the daemon's
-- own virtual keyboard keeps the production name, and the two must not be
-- confused. The daemon is pinned to this one with --device, because the
-- finder rightly skips uinput devices as synthetic.
local DeviceNames = require("infra.device_names")
local production_name = DeviceNames.VIRTUAL_KEYBOARD
DeviceNames.VIRTUAL_KEYBOARD = TEST_KEYBOARD
package.loaded["adapters.uinput_writer"] = nil
local Keyboard = require("adapters.uinput_writer")
DeviceNames.VIRTUAL_KEYBOARD = production_name
package.loaded["adapters.uinput_writer"] = nil

if not Keyboard.is_available() then abort("/dev/uinput is not writable") end
Keyboard.use_ffi_backend()
EvdevReader.use_ffi_backend()
if not Keyboard.open() then abort("could not create the test keyboard") end
local keyboard_node = await(function() return node_for(TEST_KEYBOARD) end, 5)
if not keyboard_node then abort("the test keyboard got no /dev/input node") end
print("  test keyboard: " .. keyboard_node)




-- =========================================
-- =========================================
-- ======= 2/ The daemon ===================
-- =========================================
-- =========================================

local home = os.tmpname()
os.remove(home)
os.execute("mkdir -p '" .. home .. "'")
local log = home .. "/daemon.log"
local interpreter = arg and arg[-1] or "luajit"
os.execute(string.format(
	"HOME='%s' %s ergopti_hotstrings.lua --tray --device '%s' --config tests/e2e/fixtures/daemon_keys.toml > '%s' 2>&1 & echo $! > '%s/pid'",
	home, interpreter, keyboard_node, log, home))
local pid_fh = io.open(home .. "/pid", "r")
local pid = pid_fh and pid_fh:read("*l") or nil
if pid_fh then pid_fh:close() end

local function stop_daemon()
	if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
end
local function dump_log()
	local fh = io.open(log, "r")
	if not fh then return end
	local text = fh:read("*a")
	fh:close()
	print("  --- daemon log (last lines) ---")
	local lines = {}
	for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
	for i = math.max(1, #lines - 40), #lines do print("  " .. lines[i]) end
end

local output_node = await(function() return node_for(DAEMON_OUTPUT) end, 20)
if not output_node then
	dump_log()
	stop_daemon()
	print("  FAIL the daemon never opened its output keyboard")
	os.exit(1)
end
print("  daemon output: " .. output_node)

-- Ready once the daemon holds the grab: a grab of our own then fails.
local probe_slot = "probe"
local grabbed = await(function()
	if not EvdevReader.open(keyboard_node, probe_slot) then return nil end
	local ours = EvdevReader.grab(probe_slot)
	if ours then EvdevReader.ungrab(probe_slot) end
	EvdevReader.close(probe_slot)
	return not ours
end, 20)
if not grabbed then
	dump_log()
	stop_daemon()
	print("  FAIL the daemon never grabbed the keyboard")
	os.exit(1)
end
print("  ok   the daemon grabbed the keyboard")
-- The secure-field probe settles after acquisition; give it that time.
sleep(1.5)




-- =========================================
-- =========================================
-- ======= 3/ Typing a trigger =============
-- =========================================
-- =========================================

local out_slot = "output"
if not EvdevReader.open(output_node, out_slot) then abort("cannot read the daemon's output keyboard") end

for char in ("adn "):gmatch(".") do
	Keyboard.emit(KEY_OF[char], 1)
	Keyboard.emit(KEY_OF[char], 0)
	sleep(0.03)
end

-- Decode what the desktop receives: US letters, Shift, Space, Backspace.
local text, shift = {}, false
local deadline = os.time() + 3
while os.time() <= deadline do
	if EvdevReader.wait_readable(200, out_slot) then
		local ev = EvdevReader.read_event(out_slot)
		while ev do
			if ev.type == 1 then
				if ev.code == EvdevCodes.KEY_LEFTSHIFT or ev.code == EvdevCodes.KEY_RIGHTSHIFT then
					shift = ev.value ~= 0
				elseif ev.value == 1 then
					if ev.code == EvdevCodes.KEY_BACKSPACE then table.remove(text)
					elseif ev.code == 57 then text[#text + 1] = " "
					elseif LETTERS[ev.code] then
						text[#text + 1] = shift and LETTERS[ev.code]:upper() or LETTERS[ev.code]
					else text[#text + 1] = "<" .. ev.code .. ">" end
				end
			end
			ev = EvdevReader.read_event(out_slot)
		end
	end
end
local got = table.concat(text)
print(string.format("  the desktop received %q", got))

-- Left running a little longer so the panel stand-in can finish reading the
-- tray menu, then stopped.
sleep(3)
stop_daemon()
Keyboard.close()

if got == "ADN " then
	print("  ok   typing \"adn \" on the keyboard reached the desktop as \"ADN \"")
	os.exit(0)
end
dump_log()
print("  FAIL expected \"ADN \"")
os.exit(1)
