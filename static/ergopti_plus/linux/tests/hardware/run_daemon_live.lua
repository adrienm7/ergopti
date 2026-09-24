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
--- Then the tap-holds, which the daemon runs itself on the grabbed keyboard:
--- CapsLock held is Ctrl and tapped is Enter, left Alt held is the navigation
--- layer, Shift tapped copies — and no key the daemon pressed stays down.
---
--- Then the AI: with the API backend selected and an entry pointing at
--- tests/hardware/fake_llm_server.py (a Cerebras-style OpenAI-compatible API),
--- "//" asks for a prediction and Alt+1 accepts it. The check reads what the
--- server received (the key, the endpoint) and what the desktop received.
---
--- HOW TO RUN IT: through tests/hardware/run_daemon_live.sh, which provides the
--- X server, the buses, the window manager, a focused GTK field, the panel and
--- the fake API. Needs root (or the uinput/input groups) for /dev/uinput and
--- the grab. Exit 0 = both verified; 1 = a failure; 2 = no environment.
--- ==============================================================================

local EvdevCodes = require("infra.evdev_codes")
local EvdevReader = require("adapters.evdev_reader")

local TEST_KEYBOARD = "Ergopti E2E Keyboard"
local DAEMON_OUTPUT = require("infra.device_names").VIRTUAL_KEYBOARD

-- US evdev codes of the keys this harness types and decodes (Xvfb's default
-- keymap is US, so the decode below is exact rather than assumed).
local LETTERS = {
	[16] = "q", [17] = "w", [18] = "e", [19] = "r", [20] = "t", [21] = "y", [22] = "u", [23] = "i",
	[24] = "o", [25] = "p", [30] = "a", [31] = "s", [32] = "d", [33] = "f", [34] = "g", [35] = "h",
	[36] = "j", [37] = "k", [38] = "l", [44] = "z", [45] = "x", [46] = "c", [47] = "v", [48] = "b",
	[49] = "n", [50] = "m", [53] = "/",
}
local KEY_OF = { [" "] = 57 }
for code, char in pairs(LETTERS) do KEY_OF[char] = code end
local KEY_LEFTALT, KEY_1, KEY_TAB = 56, 2, 15
local KEY_CAPSLOCK, KEY_LEFTSHIFT, KEY_LEFTCTRL, KEY_ENTER, KEY_LEFT = 58, 42, 29, 28, 105

-- The fake API the AI phase talks to (run_daemon_live.sh starts it).
local LLM_PORT = os.getenv("ERGOPTI_LIVE_LLM_PORT")
local LLM_LOG = os.getenv("ERGOPTI_LIVE_LLM_LOG")
local LLM_REPLY = os.getenv("ERGOPTI_LIVE_LLM_REPLY")
local LLM_KEY = "live-test-key"

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

-- The AI configured as a user would leave it after "Add an API": enabled, the
-- API backend selected, one entry in the private keys file.
if LLM_PORT then
	os.execute("mkdir -p '" .. home .. "/.config/ergopti_plus'")
	local storage = io.open(home .. "/.config/ergopti_plus/storage.json", "w")
	storage:write('{"llm.enabled":true,"llm.models.selected":"api","llm.profiles.num_predictions":1}')
	storage:close()
	local keys = io.open(home .. "/.config/ergopti_plus/api_keys.json", "w")
	keys:write(string.format('{"version":1,"active_id":"live","entries":[{"id":"live","provider":"openai_compat",'
		.. '"label":"Live","token":"%s","model":"live-model","base_url":"http://127.0.0.1:%s/v1"}]}', LLM_KEY, LLM_PORT))
	keys:close()
	os.execute("chmod 600 '" .. home .. "/.config/ergopti_plus/api_keys.json'")
end
local interpreter = arg and arg[-1] or "luajit"
os.execute(string.format(
	-- XDG roots pinned too: a runner's XDG_CONFIG_HOME survives sudo, and the
	-- daemon then read the runner's settings instead of the ones seeded here.
	"HOME='%s' XDG_CONFIG_HOME='%s/.config' XDG_DATA_HOME='%s/.local/share' %s ergopti_hotstrings.lua --tray --verbose"
		.. " --device '%s' --config tests/e2e/fixtures/daemon_keys.toml > '%s' 2>&1 & echo $! > '%s/pid'",
	home, home, home, interpreter, keyboard_node, log, home))
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
	-- The lines that decide whether text may expand, then the tail.
	print("  --- daemon log: privacy, focus and matching ---")
	local lines = {}
	for line in text:gmatch("[^\n]+") do
		lines[#lines + 1] = line
		local lower = line:lower()
		if lower:find("secure") or lower:find("focus") or lower:find("at%-spi") or lower:find("withheld")
			or lower:find("match") or lower:find("inject") or lower:find("capture") or lower:find("keylogger")
			or lower:find("error") or lower:find("predict") or lower:find("llm") or lower:find("api") then
			print("  " .. line)
		end
	end
	print("  --- daemon log (last lines) ---")
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
-- Typed only once the daemon says it is ready: until then its loop is not
-- draining the grabbed keyboard, and a fixed delay turned a slow boot into a
-- failure that described the harness rather than the daemon.
local ready = await(function()
	local fh = io.open(log, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text:find("Daemon ready", 1, true) ~= nil or nil
end, 60)
if not ready then
	dump_log()
	stop_daemon()
	print("  FAIL the daemon never reported itself ready")
	os.exit(1)
end
print("  ok   the daemon reported itself ready")
-- The secure-field probe settles after the first focus answer.
sleep(1.5)




-- =========================================
-- =========================================
-- ======= 3/ Typing a trigger =============
-- =========================================
-- =========================================

-- Re-resolved rather than reused: the daemon may recreate its virtual keyboard
-- after startup, and the node number moves with it.
local out_slot = "output"
local opened_output = await(function()
	local node = node_for(DAEMON_OUTPUT)
	return node and EvdevReader.open(node, out_slot) and node or nil
end, 10)
if not opened_output then
	dump_log()
	stop_daemon()
	os.execute("ls -l /dev/input; cat /proc/bus/input/devices | grep -A5 -i ergopti")
	print("  FAIL cannot read the daemon's output keyboard")
	os.exit(1)
end
print("  reading the daemon's output on " .. opened_output)

--- Types text on the test keyboard.
--- @param text string
local function type_text(text)
	for char in text:gmatch(".") do
		Keyboard.emit(KEY_OF[char], 1)
		Keyboard.emit(KEY_OF[char], 0)
		sleep(0.03)
	end
end

--- Decodes what the desktop receives for a while: US letters, Shift, Space,
--- Backspace, and whether any key went out while Alt was held.
--- @param seconds number
--- @return string text, string trail, table alt_chords
local function read_output(seconds)
	local text, shift, alt, trail, alt_chords = {}, false, false, {}, {}
	local deadline = os.time() + seconds
	while os.time() <= deadline do
		if EvdevReader.wait_readable(200, out_slot) then
			local ev = EvdevReader.read_event(out_slot)
			while ev do
				if ev.type == 0 and ev.code == 3 then
					-- SYN_DROPPED: this reader fell behind and the kernel dropped
					-- events. Said as what it is, never read as the daemon's text.
					trail[#trail + 1] = "DROPPED"
					text[#text + 1] = "<dropped>"
				end
				if ev.type == 1 then
					if ev.value ~= 2 then trail[#trail + 1] = ev.code .. (ev.value == 1 and "↓" or "↑") end
					if ev.code == EvdevCodes.KEY_LEFTSHIFT or ev.code == EvdevCodes.KEY_RIGHTSHIFT then
						shift = ev.value ~= 0
					elseif ev.code == KEY_LEFTALT then
						alt = ev.value ~= 0
					elseif ev.code == EvdevCodes.KEY_F24 then
						-- The injector's modifier mask: no text, and meant to sit inside Alt.
					elseif ev.value == 1 then
						if alt then alt_chords[#alt_chords + 1] = ev.code end
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
	return table.concat(text), table.concat(trail, " "), alt_chords
end

type_text("adn ")
local got, trail = read_output(3)
print(string.format("  the desktop received %q", got))
print("  key events: " .. trail)
local failures = {}
if got == "ADN " then
	print("  ok   typing \"adn \" on the keyboard reached the desktop as \"ADN \"")
else
	failures[#failures + 1] = "expected \"ADN \""
end




-- =========================================
-- =========================================
-- ======= 4/ Tap-holds ====================
-- =========================================
-- =========================================

--- Presses one key for `hold_s` seconds, with `inner` run while it is down.
local function press(code, hold_s, inner)
	Keyboard.emit(code, 1)
	sleep(hold_s)
	if inner then inner() end
	Keyboard.emit(code, 0)
	sleep(0.05)
end

--- The keys still down on the daemon's output keyboard.
local function keys_left_down()
	local down = EvdevReader.pressed_keys(out_slot, 767) or {}
	local codes = {}
	for code in pairs(down) do codes[#codes + 1] = code end
	table.sort(codes)
	return codes
end

local function expect_trail(label, got_trail, expected)
	print(string.format("  %s: %s", label, got_trail))
	if got_trail:find(expected, 1, true) then
		print("  ok   " .. label)
	else
		failures[#failures + 1] = string.format("%s: expected %q in %q", label, expected, got_trail)
	end
end

-- CapsLock held with A: Ctrl+A, and the lock itself never reaches the desktop.
press(KEY_CAPSLOCK, 0.4, function() press(KEY_OF.a, 0.05) end)
local _, caps_hold = read_output(1)
expect_trail("CapsLock held + A is Ctrl+A", caps_hold, "29↓ 30↓ 30↑ 29↑")
if caps_hold:find("58", 1, true) then failures[#failures + 1] = "CapsLock reached the desktop" end

-- CapsLock tapped after a trigger: a real Enter, which ends the hotstring. A
-- space first: Ctrl+A above moved the caret, and a word-only trigger rightly
-- does not fire where the daemon cannot tell a word starts.
type_text(" adn")
press(KEY_CAPSLOCK, 0.1)
local caps_text, caps_tap = read_output(2)
expect_trail("CapsLock tapped is Enter", caps_tap, "28↓ 28↑")
if not caps_text:find("ADN", 1, true) then
	failures[#failures + 1] = string.format("the Enter from CapsLock did not end \"adn\" (%q)", caps_text)
end

-- Left Alt held with J: the navigation layer's Ctrl+Left, and no Alt at all.
press(KEY_LEFTALT, 0.4, function() press(KEY_OF.j, 0.05) end)
local _, layer = read_output(1)
expect_trail("left Alt held + J is Ctrl+Left", layer, "29↓ 105↓ 105↑ 29↑")
if layer:find("56", 1, true) then failures[#failures + 1] = "the layer key sent an Alt" end

-- Shift tapped: copy, as Ctrl+C on the daemon's keyboard.
press(KEY_LEFTSHIFT, 0.1)
local _, shift_tap = read_output(1)
expect_trail("Shift tapped is copy", shift_tap, "29↓ 46↓ 46↑ 29↑")

-- Nothing the daemon pressed may stay down.
local stuck = keys_left_down()
if #stuck == 0 then
	print("  ok   no key is left down on the daemon's keyboard")
else
	failures[#failures + 1] = "keys left down on the daemon's keyboard: " .. table.concat(stuck, ", ")
end




-- =========================================
-- =========================================
-- ======= 5/ An AI prediction =============
-- =========================================
-- =========================================

--- The requests the fake API received.
--- @return table
local function api_requests()
	local requests = {}
	local fh = LLM_LOG and io.open(LLM_LOG, "r")
	if not fh then return requests end
	for line in fh:lines() do requests[#requests + 1] = line end
	fh:close()
	return requests
end

if LLM_PORT then
	type_text("bonjour //")
	local asked = await(function() return #api_requests() > 0 or nil end, 6)
	if not asked then
		failures[#failures + 1] = "\"//\" sent no request to the API"
	else
		local request = api_requests()[1]
		print("  the API received: " .. request:sub(1, 300))
		if not request:find('"authorization": "Bearer ' .. LLM_KEY .. '"', 1, true) then
			failures[#failures + 1] = "the request did not carry the entry's key"
		end
		if not request:find('"path": "/v1/chat/completions"', 1, true) then
			failures[#failures + 1] = "the request did not reach /v1/chat/completions"
		end
		-- The offer is drawn once the reply is parsed; then Alt+1 accepts it.
		-- Alt is Tab held, as on Windows: left Alt is the navigation layer.
		-- No pause after the 1: the injection is a burst, and a reader asleep
		-- meanwhile loses it to the evdev buffer's overflow.
		sleep(1.5)
		Keyboard.emit(KEY_TAB, 1)
		Keyboard.emit(KEY_1, 1)
		Keyboard.emit(KEY_1, 0)
		Keyboard.emit(KEY_TAB, 0)
		local ai_text, ai_trail, alt_chords = read_output(3)
		print(string.format("  after Alt+1 the desktop received %q", ai_text))
		print("  key events: " .. ai_trail)
		local expected = (LLM_REPLY:gsub("^%s+", ""))
		if not ai_text:find("bonjour " .. expected, 1, true) then
			failures[#failures + 1] = string.format("the desktop does not read \"bonjour %s\" (one space)", expected)
		end
		if ai_text:find("/", 1, true) then
			failures[#failures + 1] = "the \"//\" trigger was not erased on acceptance"
		end
		if #alt_chords > 0 then
			failures[#failures + 1] = string.format(
				"%d key(s) of the prediction went out while Alt was held (Alt+letter shortcuts)", #alt_chords)
		end
	end
end

-- Left running a little longer so the panel stand-in can finish reading the
-- tray menu, then stopped.
sleep(3)
stop_daemon()
Keyboard.close()

if #failures == 0 then
	print("  ok   the prediction was requested with the entry's key and typed on Alt+1")
	os.exit(0)
end
dump_log()
for _, failure in ipairs(failures) do print("  FAIL " .. failure) end
os.exit(1)
