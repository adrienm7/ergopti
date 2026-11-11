--- tests/hardware/phys_keyboard.lua

--- ==============================================================================
--- MODULE: Physical Keyboard Stand-In and Input Latency Probe
--- DESCRIPTION:
--- Run as root by phys_live_guest.sh on a real kernel. It creates a keyboard-only
--- uinput device (the production writer, through keyboard_source_writer), writes
--- its /dev/input node to a file, then serves commands read from a FIFO:
---
---   probe <label> <count> <interval_ms>
---     taps KEY_Z <count> times and times each press from its write on the
---     test keyboard to its re-emission on the daemon's own output keyboard.
---     The daemon grabs the source, so a press seen on its output went through
---     its real event loop. Writes <out_dir>/<label>.txt with
---     `n= seen= missing= p50_ms= p90_ms= max_ms=`.
---   quit
---
--- FEATURES & RATIONALE:
--- 1. One owner for the device. The uinput descriptor lives in this process, so
---    every probe is emitted by the process that created the keyboard.
--- 2. The output node is resolved by name for every probe: each daemon
---    generation (a systemd or relay restart) creates its own output device.
--- 3. A press that never comes back within its window is counted missing, not
---    waited for: a stalled loop shows as a missing count and a large maximum.
--- ==============================================================================

local Names = require("infra.device_names")
local Monotonic = require("infra.monotonic")
local EvdevReader = require("adapters.evdev_reader")

local NODE_FILE, CONTROL_FIFO, OUT_DIR = arg[1], arg[2], arg[3]
assert(NODE_FILE and CONTROL_FIFO and OUT_DIR, "usage: phys_keyboard.lua <node_file> <control_fifo> <out_dir>")

-- One name per holder: a keyboard left by another run never answers for this one.
local TEST_KEYBOARD = "Ergopti Phys Keyboard " .. require("luv").os_getpid()
local KEY_Z = 44
local EV_KEY = 1
-- A press slower than this is reported missing; the probe then moves on.
local ECHO_WINDOW_MS = 2000
local OUT_SLOT = "phys-output"

local function node_for(name)
	local fh = io.open("/proc/bus/input/devices", "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	for block in (text .. "\n\n"):gmatch("I:.-\n\n") do
		if block:find('N: Name="' .. name .. '"', 1, true) then
			local event = (block:match("H: Handlers=([^\n]*)") or ""):match("(event%d+)")
			if event then return "/dev/input/" .. event end
		end
	end
	return nil
end

local function write_file(path, text)
	local fh = assert(io.open(path, "wb"))
	fh:write(text)
	fh:close()
end

local Keyboard = require("tests.hardware.keyboard_source_writer").load(TEST_KEYBOARD)
assert(Keyboard.is_available(), "/dev/uinput is not writable")
Keyboard.use_ffi_backend()
EvdevReader.use_ffi_backend()
assert(Keyboard.open(), "could not create the test keyboard")
local node
for _ = 1, 100 do
	node = node_for(TEST_KEYBOARD)
	if node then break end
	os.execute("sleep 0.05")
end
assert(node, "the test keyboard got no /dev/input node")
write_file(NODE_FILE, node .. "\n")

--- Waits for KEY_Z value 1 on the output; drains everything else.
local function await_echo(deadline_ms)
	while Monotonic.now_ms() < deadline_ms do
		local left = math.max(1, math.floor(deadline_ms - Monotonic.now_ms()))
		if EvdevReader.wait_readable(math.min(left, 20), OUT_SLOT) then
			local event = EvdevReader.read_event(OUT_SLOT)
			while event do
				if event.type == EV_KEY and event.code == KEY_Z and event.value == 1 then return true end
				event = EvdevReader.read_event(OUT_SLOT)
			end
		end
	end
	return false
end

local function probe(label, count, interval_ms)
	local output = node_for(Names.VIRTUAL_KEYBOARD)
	local report = OUT_DIR .. "/" .. label .. ".txt"
	if not output or EvdevReader.open(output, OUT_SLOT) ~= true then
		write_file(report, string.format("n=%d seen=0 missing=%d p50_ms=nan p90_ms=nan max_ms=nan output=absent\n",
			count, count))
		return
	end
	local samples, missing = {}, 0
	for _ = 1, count do
		local started = Monotonic.now_ms()
		Keyboard.emit(KEY_Z, 1)
		if await_echo(started + ECHO_WINDOW_MS) then
			samples[#samples + 1] = Monotonic.now_ms() - started
		else
			missing = missing + 1
		end
		Keyboard.emit(KEY_Z, 0)
		os.execute(string.format("sleep %.3f", interval_ms / 1000))
	end
	EvdevReader.close(OUT_SLOT)
	table.sort(samples)
	local p50 = #samples > 0 and samples[math.max(1, math.ceil(#samples / 2))] or 0 / 0
	local p90 = #samples > 0 and samples[math.max(1, math.ceil(#samples * 0.9))] or 0 / 0
	local max = #samples > 0 and samples[#samples] or 0 / 0
	write_file(report, string.format("n=%d seen=%d missing=%d p50_ms=%.1f p90_ms=%.1f max_ms=%.1f output=%s\n",
		count, #samples, missing, p50, p90, max, output))
end

-- Read/write open: the FIFO never reports end-of-file between writers.
local control = assert(io.open(CONTROL_FIFO, "r+"))
for line in control:lines() do
	local command, label, count, interval = line:match("^(%S+)%s*(%S*)%s*(%d*)%s*(%d*)$")
	if command == "quit" then break end
	if command == "probe" and label ~= "" then
		probe(label, tonumber(count) or 20, tonumber(interval) or 20)
		write_file(OUT_DIR .. "/" .. label .. ".done", "")
	end
end
control:close()
Keyboard.close()
