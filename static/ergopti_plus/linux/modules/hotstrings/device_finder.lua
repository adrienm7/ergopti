--- modules/hotstrings/device_finder.lua

--- ==============================================================================
--- MODULE: Device Finder (Linux)
--- DESCRIPTION:
--- Locates the input device the daemon should read by parsing
--- /proc/bus/input/devices. This allows the daemon to start without manual
--- --device configuration in most setups while still accepting an explicit path
--- as an override.
---
--- FEATURES & RATIONALE:
--- 1. /proc/bus/input/devices parsing: this virtual file lists every registered
---    input device with its capabilities bitmask (EV= line). Keyboards report
---    EV=120013, which includes EV_KEY (0x1), EV_MSC (0x10), EV_LED (0x11),
---    and EV_REP (0x14). The finder matches any device with bit 0 set in the
---    EV mask (EV_KEY present) and at least one handler matching event[0-9]+.
--- 2. The remap daemon's output wins outright. Its device carries POST-remap
---    keycodes — what the application actually receives — so reading anything
---    else means the engine resolves characters the user never typed. Picking it
---    is a rule, not a heuristic: it is matched by exact name before any ranking
---    runs.
--- 3. Synthetic devices are excluded, and that is a correctness fix rather than
---    tidiness. Our own uinput device is called "Ergopti Virtual Keyboard", so
---    the name heuristic below ranked it in the PREFERRED tier: whenever it
---    enumerated first the daemon read back its own injections and expanded them
---    again. Devices registered under /devices/virtual/ are dropped, with a name
---    fallback for kernels that report no sysfs line.
--- 4. Pure seams for the two halves. parse_devices() takes text and select()
---    takes descriptors, so the whole selection can be driven from fixtures
---    without a /proc to read — the reason this module had no regression test
---    for the bug in point 3.
--- 5. No external tools: the entire detection is done with Lua file I/O so the
---    module has zero runtime dependencies beyond the standard library.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")
local DeviceNames = require("infra.device_names")

local LOG = "modules.hotstrings.device_finder"


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Path to the kernel virtual file listing all input devices.
local PROC_INPUT_DEVICES = "/proc/bus/input/devices"

-- Base directory for evdev character devices.
local DEV_INPUT_DIR = "/dev/input/"

-- EV capability bit index for EV_KEY (bit 1 of the EV= hex mask).
-- A device has EV_KEY if (ev_mask & 0x2) ~= 0.
local EV_KEY_BIT = 0x2

-- EV_REL (relative axes: a mouse) and EV_ABS (absolute: a touchpad or tablet).
-- A pointer is a device with buttons AND one of these; a keyboard has neither.
local EV_REL_BIT = 0x4
local EV_ABS_BIT = 0x8


-- =========================================
-- =========================================
-- ======= 3/ Parser =======================
-- =========================================
-- =========================================

--- Parses the text of /proc/bus/input/devices into device descriptor tables.
--- Each descriptor has:
---   name     string   Human-readable device name.
---   sysfs    string   Value of the `S: Sysfs=` line, "" when absent.
---   ev_mask  number   Decoded EV= bitmask (hex string → number).
---   handlers table    Array of handler strings (e.g. {"kbd", "event3"}).
--- @param text string  Raw file content.
--- @return table       Array of device descriptor tables.
function M.parse_devices(text)
	if type(text) ~= "string" then
		Logger.error(LOG, "parse_devices(): expected string, got %s.", type(text))
		return {}
	end

	local devices = {}
	local current = nil

	-- The trailing newline makes the final block flush through the same branch as
	-- every other one, instead of needing a copy of the flush after the loop.
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		-- Blank line separates device blocks.
		if line:match("^%s*$") then
			if current then
				devices[#devices + 1] = current
				current = nil
			end
		else
			-- Start a new block on the "I:" identity line.
			if line:match("^I:") then
				current = { name = "", sysfs = "", ev_mask = 0, handlers = {} }
			end
			if current then
				-- N: Name="..."
				local name = line:match('^N:%s*Name="(.*)"')
				if name then current.name = name end

				-- S: Sysfs=/devices/... — the kernel's own answer to "is this
				-- device real", and the only classification that stays correct as
				-- new virtual-device owners appear.
				local sysfs = line:match("^S:%s*Sysfs=(.*)")
				if sysfs then current.sysfs = (sysfs:gsub("%s+$", "")) end

				-- B: EV=<hex>
				local ev_hex = line:match("^B:%s*EV=(%x+)")
				if ev_hex then
					current.ev_mask = tonumber(ev_hex, 16) or 0
				end

				-- H: Handlers=kbd event3 ...
				local handlers_str = line:match("^H:%s*Handlers=(.*)")
				if handlers_str then
					for h in handlers_str:gmatch("%S+") do
						current.handlers[#current.handlers + 1] = h
					end
				end
			end
		end
	end

	Logger.done(LOG, "Parsed %d device block(s).", #devices)
	return devices
end

--- Reads and parses /proc/bus/input/devices.
--- @return table Array of device descriptor tables, empty when unreadable.
local function read_proc_devices()
	Logger.trace(LOG, "Parsing '%s'…", PROC_INPUT_DEVICES)
	local fh, err = io.open(PROC_INPUT_DEVICES, "r")
	if not fh then
		Logger.warn(LOG, "read_proc_devices(): cannot open '%s' — %s.", PROC_INPUT_DEVICES, tostring(err))
		return {}
	end
	local text = fh:read("*a")
	fh:close()
	return M.parse_devices(text or "")
end

--- Extracts the /dev/input/eventN path from a device descriptor's handlers.
--- Returns nil if no eventN handler is present.
--- @param dev table Device descriptor.
--- @return string|nil
local function event_path(dev)
	for _, h in ipairs(dev.handlers) do
		local event_name = h:match("^(event%d+)$")
		if event_name then
			return DEV_INPUT_DIR .. event_name
		end
	end
	return nil
end

--- True when a bit of the EV capability mask is set.
--- LuaJIT has no native `&` (that is Lua 5.3+), so the test is arithmetic.
--- @param mask integer
--- @param bit integer
--- @return boolean
local function has_bit(mask, bit)
	return math.floor(mask / bit) % 2 == 1
end

--- Whether a path is an evdev node the kernel says can produce key events.
---
--- Added 2026-08-05, after a real Linux runner showed the hook happily starting
--- on `/dev/null`. The only check before it was "is this readable", and every
--- character device is: the daemon would then sit in its read loop forever,
--- waiting for events that cannot arrive, reporting itself as running. On Windows
--- the same test passed for the wrong reason — the open failed there.
---
--- Answered from /proc/bus/input/devices rather than by an ioctl, because this
--- runs BEFORE the descriptor is opened and because the kernel's own EV bitmask
--- is the authority on what a node can emit. A path that is not an evdev node at
--- all simply does not appear there, which is the /dev/null case.
--- @param path string|nil An absolute device path.
--- @param devices table|nil Pre-parsed descriptors; reads /proc when omitted.
---   The seam this module's header promises: it lets the rule be driven from
---   fixture text, which is the only way to cover it from a machine that has no
---   /proc to read.
--- @return boolean ok, string|nil reason Why it was refused.
function M.is_key_device(path, devices)
	if type(path) ~= "string" or path == "" then
		return false, "no device path"
	end
	local basename = path:match("([^/]+)$")
	if not basename or not basename:match("^event%d+$") then
		return false, path .. " is not an /dev/input/eventN node"
	end
	for _, dev in ipairs(type(devices) == "table" and devices or read_proc_devices()) do
		for _, handler in ipairs(dev.handlers) do
			if handler == basename then
				if has_bit(dev.ev_mask, EV_KEY_BIT) then return true, nil end
				return false, path .. " (" .. tostring(dev.name) .. ") reports no EV_KEY capability"
			end
		end
	end
	return false, path .. " is not listed in " .. PROC_INPUT_DEVICES
end

--- Returns true when the device name looks like a keyboard.
--- Prefers devices with "keyboard" or "kbd" in their name.
--- @param name string Device name string.
--- @return boolean
local function is_likely_keyboard(name)
	local lower = name:lower()
	return lower:find("keyboard") ~= nil or lower:find("kbd") ~= nil
end

--- True when the device is software-synthesised rather than physical hardware.
--- @param dev table Device descriptor.
--- @return boolean
local function is_synthetic(dev)
	return DeviceNames.is_virtual_sysfs(dev.sysfs) or DeviceNames.is_synthetic_name(dev.name)
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Chooses the device to read from a parsed descriptor list.
---
--- Selection rules, in order:
---   1. The remap daemon's output device, matched by exact name. It carries the
---      keycodes the application receives, which is the only stream the engine
---      can resolve characters from correctly.
---   2. A physical device whose name says "keyboard" or "kbd".
---   3. Any other physical EV_KEY device.
--- Synthetic devices never reach rules 2 and 3 — reading one means reading our
--- own injections back.
--- @param devices table Array of descriptors from parse_devices().
--- @return string|nil path, string|nil reason  Device path and the rule that chose it.
function M.select(devices)
	local remap    = nil   -- the remap daemon's output
	local preferred = nil  -- physical, keyboard-named
	local fallback  = nil  -- physical, anything else with EV_KEY

	for _, dev in ipairs(devices) do
		-- Must have EV_KEY capability. LuaJIT has no native `&` bitwise operator
		-- (that's Lua 5.3+), so the single-bit test is spelled out arithmetically.
		if math.floor(dev.ev_mask / EV_KEY_BIT) % 2 == 0 then goto next_dev end

		local path = event_path(dev)
		if not path then goto next_dev end

		if dev.name == DeviceNames.REMAP_OUTPUT then
			if not remap then remap = path end
			Logger.debug(LOG, "Remap output device: '%s' → %s", dev.name, path)
			goto next_dev
		end

		if is_synthetic(dev) then
			Logger.debug(LOG, "Skipping synthetic device: '%s' (sysfs=%s)", dev.name, dev.sysfs)
			goto next_dev
		end

		Logger.debug(LOG, "EV_KEY device: '%s' → %s", dev.name, path)

		if is_likely_keyboard(dev.name) then
			-- Take the first named-keyboard device.
			if not preferred then preferred = path end
		else
			if not fallback then fallback = path end
		end

		::next_dev::
	end

	if remap     then return remap,     "remap_output" end
	if preferred then return preferred, "named_keyboard" end
	if fallback  then return fallback,  "any_key_device" end
	return nil, nil
end


--- Chooses the pointer to watch, if there is one.
---
--- The daemon does not grab this device and never will: a pointer it consumed
--- would be a desktop with no working mouse. It watches it for one fact — a
--- button press — because a click moves the caret, and every character buffered
--- before it belongs to a different position, often in a different line. Without
--- this, clicking into the middle of a word and typing expands against a buffer
--- describing text that is now somewhere else.
--- @param devices table Array of descriptors from parse_devices().
--- @return string|nil path
function M.select_pointer(devices)
	local named, fallback = nil, nil

	for _, dev in ipairs(devices) do
		-- Buttons AND an axis. A keyboard has EV_KEY and neither axis; a volume
		-- rocker has EV_KEY alone; only a pointer has both.
		if has_bit(dev.ev_mask, EV_KEY_BIT)
			and (has_bit(dev.ev_mask, EV_REL_BIT) or has_bit(dev.ev_mask, EV_ABS_BIT))
			and not is_synthetic(dev)
		then
			local path = event_path(dev)
			if path then
				local lower = dev.name:lower()
				if lower:find("mouse") or lower:find("touchpad") or lower:find("trackpoint") then
					if not named then named = path end
				elseif not fallback then
					fallback = path
				end
			end
		end
	end

	return named or fallback
end

--- Finds the pointer device to watch, or nil when this machine has none.
--- @return string|nil
function M.find_pointer()
	local ok, devices = pcall(read_proc_devices)
	if not ok then return nil end
	local path = M.select_pointer(devices)
	if path then
		Logger.info(LOG, "Watching pointer device: %s.", path)
	else
		-- Not an error. A headless machine or a laptop with the touchpad disabled
		-- has none, and the only consequence is that a click cannot invalidate the
		-- buffer — which is the behaviour this driver had all along.
		Logger.info(LOG, "No pointer device found — a click will not reset the buffer.")
	end
	return path
end

--- Finds the device path the daemon should read.
--- Returns the path to a /dev/input/eventN device, or nil on failure.
--- @return string|nil  Absolute device path, e.g. "/dev/input/event3".
function M.find_keyboard()
	Logger.start(LOG, "Searching for keyboard device…")

	local ok, devices = pcall(read_proc_devices)
	if not ok then
		Logger.error(LOG, "find_keyboard(): parse failed — %s.", tostring(devices))
		return nil
	end

	local result, reason = M.select(devices)
	if result then
		Logger.success(LOG, "Keyboard device selected: %s (%s).", result, reason)
	else
		Logger.warn(LOG, "find_keyboard(): no suitable keyboard device found.")
	end
	return result
end

return M
