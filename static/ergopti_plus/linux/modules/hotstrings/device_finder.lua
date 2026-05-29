--- static/ergopti_plus/linux/modules/hotstrings/device_finder.lua

--- ==============================================================================
--- MODULE: Device Finder (Linux)
--- DESCRIPTION:
--- Locates the most suitable keyboard input device under /dev/input/ by parsing
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
--- 2. Name-based heuristics: devices whose name contains "keyboard" or "kbd"
---    (case-insensitive) are ranked first, providing a better default than
---    picking the first EV_KEY device (which might be a power button).
--- 3. No external tools: the entire detection is done with Lua file I/O so the
---    module has zero runtime dependencies beyond the standard library.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")

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


-- =========================================
-- =========================================
-- ======= 3/ Parser =======================
-- =========================================
-- =========================================

--- Parses /proc/bus/input/devices into a list of device descriptor tables.
--- Each descriptor has:
---   name     string   Human-readable device name.
---   ev_mask  number   Decoded EV= bitmask (hex string → number).
---   handlers table    Array of handler strings (e.g. {"kbd", "event3"}).
--- @return table  Array of device descriptor tables.
local function parse_proc_devices()
	Logger.trace(LOG, "Parsing '%s'…", PROC_INPUT_DEVICES)
	local fh, err = io.open(PROC_INPUT_DEVICES, "r")
	if not fh then
		Logger.warn(LOG, "parse_proc_devices(): cannot open '%s' — %s.", PROC_INPUT_DEVICES, tostring(err))
		return {}
	end

	local devices = {}
	local current = nil

	for line in fh:lines() do
		-- Blank line separates device blocks.
		if line:match("^%s*$") then
			if current then
				devices[#devices + 1] = current
				current = nil
			end
		else
			-- Start a new block on the "I:" identity line.
			if line:match("^I:") then
				current = { name = "", ev_mask = 0, handlers = {} }
			end
			if current then
				-- N: Name="..."
				local name = line:match('^N:%s*Name="(.*)"')
				if name then current.name = name end

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
	-- Flush the last block (file may not end with a blank line).
	if current then devices[#devices + 1] = current end

	fh:close()
	Logger.done(LOG, "Found %d device block(s) in /proc/bus/input/devices.", #devices)
	return devices
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

--- Returns true when the device name looks like a keyboard.
--- Prefers devices with "keyboard" or "kbd" in their name.
--- @param name string Device name string.
--- @return boolean
local function is_likely_keyboard(name)
	local lower = name:lower()
	return lower:find("keyboard") ~= nil or lower:find("kbd") ~= nil
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Finds the best keyboard device path.
--- Returns the path to a /dev/input/eventN device, or nil on failure.
---
--- Selection criteria (in priority order):
---   1. Devices whose name contains "keyboard" or "kbd" with EV_KEY bit set.
---   2. Any device with EV_KEY bit set and an eventN handler.
--- @return string|nil  Absolute device path, e.g. "/dev/input/event3".
function M.find_keyboard()
	Logger.start(LOG, "Searching for keyboard device…")

	local ok, devices = pcall(parse_proc_devices)
	if not ok then
		Logger.error(LOG, "find_keyboard(): parse failed — %s.", tostring(devices))
		return nil
	end

	local preferred = nil   -- keyboard-named device
	local fallback  = nil   -- any EV_KEY device

	for _, dev in ipairs(devices) do
		-- Must have EV_KEY capability.
		if (dev.ev_mask & EV_KEY_BIT) == 0 then goto next_dev end

		local path = event_path(dev)
		if not path then goto next_dev end

		Logger.debug(LOG, "EV_KEY device: '%s' → %s", dev.name, path)

		if is_likely_keyboard(dev.name) then
			-- Take the first named-keyboard device.
			if not preferred then preferred = path end
		else
			if not fallback then fallback = path end
		end

		::next_dev::
	end

	local result = preferred or fallback
	if result then
		Logger.success(LOG, "Keyboard device selected: %s.", result)
	else
		Logger.warn(LOG, "find_keyboard(): no suitable keyboard device found.")
	end
	return result
end

return M
