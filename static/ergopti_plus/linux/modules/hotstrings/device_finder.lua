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
--- 2. No remap daemon's output is preferred any more: the tap-holds run in
---    this daemon, on the physical keyboard it grabs. A remap daemon's output
---    is a uinput device like any other injector's, and is excluded as one.
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

local Logger = require("core.logger.engine.shim")
local DeviceNames = require("infra.device_names")
local NativePath = require("core.fs.engine.native_path")

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

-- EV_SW: tablet/lid/radio switches may share a node with extra keys.
local EV_SW_BIT = 0x20


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

	-- A final blank line flushes the last block even when the input has no
	-- trailing newline at all.
	for line in (text .. "\n\n"):gmatch("([^\n]*)\n") do
		-- Blank line separates device blocks.
		if line:match("^%s*$") then
			if current then
				devices[#devices + 1] = current
				current = nil
			end
		else
			-- Start a new block on the "I:" identity line.
			if line:match("^I:") then
				current = { name = "", sysfs = "", ev_mask = 0, key_mask_low = 0, key_mask_32 = 0, handlers = {} }
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
				-- Procfs separates kernel words with spaces but does not pad each
				-- word. Never concatenate them: that can turn a high-word bit
				-- into an unrelated low key. A short final word is conservative
				-- on 32-bit kernels, where KEY_Z lives in the preceding word.
				local key_hex = line:match("^B:%s*KEY=([%x%s]+)$")
				if key_hex then
					local words = {}
					for word in key_hex:gmatch("%x+") do words[#words + 1] = word end
					local last, previous = words[#words], words[#words - 1]
					current.key_mask_low = last and tonumber(last:sub(-12), 16) or 0
					if last and #last <= 8 and previous and #previous <= 8 then
						current.key_mask_32 = (tonumber(last, 16) or 0)
							+ ((tonumber(previous, 16) or 0) % 65536) * 2 ^ 32
					end
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
	local read_ok, text = pcall(fh.read, fh, "*a")
	local close_ok, closed = pcall(fh.close, fh)
	if not read_ok or type(text) ~= "string" or not close_ok or closed ~= true then
		Logger.warn(LOG, "read_proc_devices(): cannot complete reading '%s'.", PROC_INPUT_DEVICES)
		return {}
	end
	return M.parse_devices(text)
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
	local basename = NativePath.basename(path)
	-- Proc handlers name nodes in /dev/input, not arbitrary matching basenames.
	if not basename or not basename:match("^event%d+$") or path ~= DEV_INPUT_DIR .. basename then
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

--- Whether the keyboard-only output can preserve an event-type bitmap.
--- Shared by proc discovery and the acquired fd check before EVIOCGRAB.
--- @param mask number Event-type bitmap, not a key-code bitmap.
--- @return boolean ok, string|nil reason
function M.is_interceptable_event_mask(mask)
	if type(mask) ~= "number" or mask < 0 or mask > 0xffffffff or mask % 1 ~= 0 then
		return false, "invalid event capability bitmap"
	end
	if not has_bit(mask, EV_KEY_BIT) then return false, "reports no EV_KEY capability" end
	if has_bit(mask, EV_REL_BIT) or has_bit(mask, EV_ABS_BIT) then
		return false, "reports EV_REL/EV_ABS axes that the keyboard output cannot forward"
	end
	if has_bit(mask, EV_SW_BIT) then
		return false, "reports EV_SW switches that the keyboard output cannot forward"
	end
	return true
end

--- Whether the keyboard-only output can preserve a source under EVIOCGRAB.
--- The grab owns every event on the node, including axes/switches the keyboard
--- output cannot forward. Observe mode keeps using is_key_device instead.
--- @param path string|nil An absolute device path.
--- @param devices table|nil Pre-parsed descriptors; reads /proc once when omitted.
--- @return boolean ok, string|nil reason Why interception was refused.
function M.is_interceptable_key_device(path, devices)
	local snapshot = type(devices) == "table" and devices or read_proc_devices()
	local is_key, why = M.is_key_device(path, snapshot)
	if not is_key then return false, why end
	local basename = NativePath.basename(path)
	for _, dev in ipairs(snapshot) do
		for _, handler in ipairs(dev.handlers) do
			if handler == basename then
				local allowed, reason = M.is_interceptable_event_mask(dev.ev_mask)
				return allowed, reason and path .. " " .. reason or nil
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

-- Q, A and Z distinguish an alphanumeric keyboard from power/media keys,
-- even when its manufacturer/product name never says "keyboard".
local function has_typing_keys(dev)
	local mask = dev.key_mask_low
	return type(mask) == "number" and has_bit(mask, 2 ^ 16)
		and has_bit(mask, 2 ^ 30) and has_bit(mask, 2 ^ 44)
end

-- The procfs words alone cannot distinguish a 32-bit keyboard from some
-- 64-bit non-keyboards. Confirm only ambiguous candidates against their fd.
local function probe_typing_keys(path)
	local available, ffi = pcall(require, "ffi")
	if not available or type(ffi) ~= "table" or ffi.os ~= "Linux" then return nil end
	local declared, detail = pcall(ffi.cdef, [[
		int open(const char *path, int flags);
		int close(int fd);
		int ioctl(int fd, unsigned long request, ...);
	]])
	if not declared and not tostring(detail):find("redefin", 1, true) then return nil end
	local bound, open_port, ioctl_port, close_port = pcall(function() return ffi.C.open, ffi.C.ioctl, ffi.C.close end)
	if not bound then return nil end
	local opened, fd = pcall(open_port, path, 0x80800) -- O_NONBLOCK | O_CLOEXEC
	if not opened or fd == nil or fd < 0 then return nil end
	local called, matched = pcall(function()
		local bits = ffi.new("uint8_t[6]")
		-- EVIOCGBIT(EV_KEY, 6) covers KEY_Q=16, KEY_A=30 and KEY_Z=44.
		if tonumber(ioctl_port(fd, 0x80064521, bits)) ~= 6 then return nil end
		return tonumber(bits[2]) % 2 == 1
			and math.floor(tonumber(bits[3]) / 64) % 2 == 1
			and math.floor(tonumber(bits[5]) / 16) % 2 == 1
	end)
	local closed, acknowledged = pcall(close_port, fd)
	if not called or not closed or acknowledged ~= 0 then return nil end
	return matched
end

--- True when the device is software-synthesised rather than physical hardware.
--- @param dev table Device descriptor.
--- @return boolean
-- Only an absolute, canonical sysfs path can prove kernel origin.
local function qualified_sysfs(path)
	if type(path) ~= "string" or path:sub(1, 9) ~= "/devices/"
		or not path:match("/input/input%d+$") or path:sub(-1) == "/" or path:find("//", 1, true) or path:find("[%z\1-\31\127]") then return false end
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." then return false end
	end
	return true
end

local function is_synthetic(dev)
	-- A kernel sysfs path identifies the input owner; a physical HID name can
	-- legitimately contain the same words as an injector.
	if qualified_sysfs(dev.sysfs) then
		return dev.sysfs == "/devices/virtual" or DeviceNames.is_virtual_sysfs(dev.sysfs)
	end
	if type(dev.sysfs) == "string" and dev.sysfs ~= "" then return true end
	return DeviceNames.is_synthetic_name(dev.name)
end


--- Describes physical origin from one current kernel snapshot. Capability alone
--- does not prove that an explicitly pinned device is hardware rather than an
--- upstream remapper's uinput output; missing sysfs identity stays unqualified.
--- @param paths table Acquired canonical evdev device paths.
--- @param devices table|nil Pre-parsed kernel descriptors; reads /proc when absent.
--- @return table Dense origin records in the requested order.
function M.physical_sources(paths, devices)
	local records = {}
	for _, dev in ipairs(type(devices) == "table" and devices or read_proc_devices()) do
		local path = event_path(dev)
		if path then records[path] = dev end
	end
	local sources = {}
	for _, path in ipairs(paths) do
		local dev = records[path]
		local known = dev ~= nil and qualified_sysfs(dev.sysfs)
		sources[#sources + 1] = { path = path, sysfs = dev and dev.sysfs or "", name = dev and dev.name or "",
			physical = known and has_bit(dev.ev_mask, EV_KEY_BIT) and not is_synthetic(dev) or false }
	end
	return sources
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Chooses every keyboard stream to read from a parsed descriptor list.
---
--- Selection rules, in order:
---   1. Every physical device whose name says "keyboard" or whose key bitmap
---      includes the ordinary Q, A and Z typing keys.
---   2. Every other physical EV_KEY device when none is keyboard-named.
--- Axes and switches are excluded from both rules: the output cannot relay them.
--- Synthetic devices never reach either rule — reading one means reading our
--- own injections back.
--- @param devices table Array of descriptors from parse_devices().
--- @return table paths, string|nil reason Device paths and the rule that chose them.
function M.select_keyboards(devices, probe)
	local preferred = {}
	local fallback = {}

	for _, dev in ipairs(devices) do
		-- Must have EV_KEY capability. LuaJIT has no native `&` bitwise operator
		-- (that's Lua 5.3+), so the single-bit test is spelled out arithmetically.
		if math.floor(dev.ev_mask / EV_KEY_BIT) % 2 == 0 then goto next_dev end

		local path = event_path(dev)
		if not path then goto next_dev end

		if is_synthetic(dev) then
			Logger.debug(LOG, "Skipping synthetic device: '%s' (sysfs=%s)", dev.name, dev.sysfs)
			goto next_dev
		end

		if not M.is_interceptable_event_mask(dev.ev_mask) then goto next_dev end
		Logger.debug(LOG, "Physical EV_KEY device: '%s' → %s", dev.name, path)

		local named, typing = is_likely_keyboard(dev.name), has_typing_keys(dev)
		if not named and not typing and type(probe) == "function" and has_typing_keys({ key_mask_low = dev.key_mask_32 }) then
			local called, confirmed = pcall(probe, path)
			typing = called and confirmed == true
		end
		if named or typing then
			preferred[#preferred + 1] = path
		else
			fallback[#fallback + 1] = path
		end

		::next_dev::
	end

	local selected = #preferred > 0 and preferred or fallback
	table.sort(selected)
	if #selected > 0 then
		return selected, #preferred > 0 and "named_keyboards" or "any_key_devices"
	end
	return {}, nil
end

--- Chooses the first keyboard for legacy callers.
--- @param devices table Array of descriptors from parse_devices().
--- @return string|nil path, string|nil reason Device path and the rule that chose it.
function M.select(devices)
	local paths, reason = M.select_keyboards(devices)
	local legacy_reason = reason == "named_keyboards" and "named_keyboard"
		or reason == "any_key_devices" and "any_key_device" or reason
	return paths[1], legacy_reason
end


--- Chooses every pointer to watch.
---
--- The daemon does not grab this device and never will: a pointer it consumed
--- would be a desktop with no working mouse. It watches it for one fact — a
--- button press — because a click moves the caret, and every character buffered
--- before it belongs to a different position, often in a different line. Without
--- this, clicking into the middle of a word and typing expands against a buffer
--- describing text that is now somewhere else.
--- @param devices table Array of descriptors from parse_devices().
--- @return table paths
function M.select_pointers(devices)
	local named, fallback = {}, {}

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
					named[#named + 1] = path
				else
					fallback[#fallback + 1] = path
				end
			end
		end
	end

	for _, path in ipairs(fallback) do named[#named + 1] = path end
	table.sort(named)
	return named
end

--- Chooses the first pointer for legacy callers.
--- @param devices table Array of descriptors from parse_devices().
--- @return string|nil path
function M.select_pointer(devices)
	return M.select_pointers(devices)[1]
end

--- Finds all keyboard and pointer sources from one kernel snapshot.
--- @return table keyboards, table pointers, string|nil keyboard_reason
function M.find_devices()
	local ok, devices = pcall(read_proc_devices)
	if not ok then
		Logger.error(LOG, "find_devices(): parse failed — %s.", tostring(devices))
		return {}, {}, nil
	end
	local keyboards, reason = M.select_keyboards(devices, probe_typing_keys)
	local pointers = M.select_pointers(devices)
	Logger.info(LOG, "Input snapshot: %d keyboard source(s), %d pointer source(s).",
		#keyboards, #pointers)
	return keyboards, pointers, reason
end

--- Finds the pointer device to watch, or nil when this machine has none.
--- @return string|nil
function M.find_pointer()
	local pointers = M.find_pointers()
	local path = pointers[1]
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

--- Finds every pointer device to watch.
--- @return table paths
function M.find_pointers()
	local ok, devices = pcall(read_proc_devices)
	if not ok then return {} end
	return M.select_pointers(devices)
end

--- Finds the device path the daemon should read.
--- Returns the path to a /dev/input/eventN device, or nil on failure.
--- @return string|nil  Absolute device path, e.g. "/dev/input/event3".
function M.find_keyboard()
	Logger.start(LOG, "Searching for keyboard device…")
	local keyboards, _, reason = M.find_devices()
	local result = keyboards[1]
	if result then
		Logger.success(LOG, "Keyboard device selected: %s (%s).", result, reason)
	else
		Logger.warn(LOG, "find_keyboard(): no suitable keyboard device found.")
	end
	return result
end

return M
