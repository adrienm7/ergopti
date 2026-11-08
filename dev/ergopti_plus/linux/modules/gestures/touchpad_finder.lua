--- modules/gestures/touchpad_finder.lua

--- ==============================================================================
--- MODULE: Touchpad Selection and Capability
--- DESCRIPTION:
--- Finds the touchpad among the input devices, and reports how many fingers it
--- can actually express — before any finger touches it.
---
--- WHY NOT REUSE device_finder.find_pointer():
--- That selector returns the FIRST device in /proc order whose name contains
--- mouse, touchpad or trackpoint, so a plugged-in USB mouse can win over the
--- built-in touchpad. And its parser reads only `N:`, `S:`, `B: EV=` and
--- `H: Handlers=` — never `B: ABS=` or `B: PROP=` — so it cannot confirm a device
--- has multitouch slots at all, nor reject a semi-MT pad that reports only a
--- bounding box. Gestures need both answers, so they need their own selector.
---
--- WHY /proc AND NOT AN ioctl:
--- The kernel publishes the same capability bits both ways. `EVIOCGBIT(EV_KEY)`
--- means computing an ioctl request number by hand — the encoding is
--- straightforward but a mistake in it does NOT fail loudly: the call returns
--- arbitrary bits, and the menu then greys the wrong rows or offers gestures the
--- hardware can never produce. /proc/bus/input/devices carries the same bitmaps
--- as text, is readable without any FFI, and can be pinned by a fixture taken
--- from a real machine. When something is going to be wrong, it should be wrong
--- somewhere a test can see.
---
--- HOW THE FINGER COUNT IS KNOWN IN ADVANCE:
--- `input_mt_init_slots()` only advertises BTN_TOOL_TRIPLETAP when the device has
--- at least 3 slots, QUADTAP at 4 and QUINTTAP at 5. So the presence of those
--- bits in `B: KEY=` is the hardware's own statement about what it can count.
--- Microsoft's Precision Touchpad spec requires a minimum of only three
--- simultaneous contacts, so a fully conformant pad may stop at three — and on
--- such a machine twenty of the declared slots are unreachable no matter what the
--- software does. Saying so is the point of this module.
---
--- THE WORD-SIZE AMBIGUITY:
--- Procfs bitmap words can be either 32 or 64 bits. A word wider than
--- eight hex digits proves a 64-bit kernel; otherwise both interpretations
--- are considered, and ambiguous device capabilities require an fd probe.
--- ==============================================================================

local M = {}

local Errors = require("adapter_errors")
local Logger = require("logger.shim")

local LOG = "gestures.touchpad_finder"

-- Where the kernel describes every input device it has.
local DEVICES_PATH = "/proc/bus/input/devices"

-- Default width for callers examining known 64-bit procfs fixtures. Device
-- selection checks both widths when the bitmap does not prove its width.
local BITS_PER_WORD = 64

-- The kernel codes, read from the decoder rather than repeated here.
--
-- They were written out in both files, and nothing held the two lists equal — so
-- a corrected code in one would have left the other reading the wrong bit, and
-- the symptom would be a capability answer that is merely wrong rather than
-- absent. One source (rule 5.2); the decoder owns them because it is the module
-- that has to know the whole protocol.
local Decoder = require("modules.gestures.mt_decoder")

-- The multitouch slot axis. A device without it cannot report per-finger
-- positions and is not a touchpad for our purposes, whatever it is called.
local ABS_MT_SLOT = Decoder.ABS_MT_SLOT
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = Decoder.ABS_MT_POSITION_X, Decoder.ABS_MT_POSITION_Y

-- Device properties, from include/uapi/linux/input-event-codes.h.
local INPUT_PROP_POINTER   = 0x00
local INPUT_PROP_BUTTONPAD = 0x02
local INPUT_PROP_SEMI_MT   = 0x03

-- The finger-count bits, derived from the decoder's own map so the two cannot
-- disagree about which code means how many fingers. Sorted by finger count
-- because the kernel's numbering is not: QUINTTAP was retrofitted into a free
-- code and sits below QUADTAP.
local FINGER_BITS = {}
for code, fingers in pairs(Decoder.FINGER_COUNT_CODES) do
	FINGER_BITS[#FINGER_BITS + 1] = { fingers = fingers, bit = code }
end
table.sort(FINGER_BITS, function(a, b) return a.fingers < b.fingers end)

M.ABS_MT_SLOT = ABS_MT_SLOT
M.FINGER_BITS = FINGER_BITS




-- =============================================
-- =============================================
-- ======= 1/ Reading a printed bitmap =========
-- =============================================
-- =============================================

--- Whether a bit is set in a bitmap as /proc prints it.
---
--- Words are most-significant-first, so the word holding bit N is counted from
--- the RIGHT. Tested by division rather than by a bitwise AND: LuaJIT is
--- 5.1-based and has no `&`.
--- @param bitmap string e.g. "e520 10000 0 0 0 0 0 0 0"
--- @param bit integer
--- @return boolean
function M.bit_set(bitmap, bit, word_bits)
	if type(bitmap) ~= "string" or type(bit) ~= "number" then return false end

	local words = {}
	for word in bitmap:gmatch("%x+") do words[#words + 1] = word end
	if #words == 0 then return false end

	word_bits = word_bits or BITS_PER_WORD
	local word_index = math.floor(bit / word_bits)
	local bit_index  = bit % word_bits

	-- Counted from the right: the last printed word is word 0.
	local position = #words - word_index
	if position < 1 then return false end

	-- Exact for any width: test the single hex digit holding the bit rather
	-- than dividing the whole word. Lua numbers are doubles, exact only to
	-- 2^53, so a full 64-bit /proc word with high bits set rounds, and a
	-- low-bit test on the rounded value answers wrongly — under-reporting
	-- the finger count, which hides working gestures. (LuaJIT has no `&` to
	-- do better with; trimming to the one digit that holds the bit is exact
	-- everywhere, on every interpreter.)
	local digits = words[position]
	local nibble = math.floor(bit_index / 4)
	local from_end = #digits - nibble
	if from_end < 1 then return false end
	local digit = tonumber(digits:sub(from_end, from_end), 16)
	if not digit then return false end
	return math.floor(digit / (2 ^ (bit_index % 4))) % 2 == 1
end




-- =============================================
-- =============================================
-- ======= 2/ Parsing the device table =========
-- =============================================
-- =============================================

--- Splits /proc/bus/input/devices into one record per device.
--- @param text string
--- @return table Array of { name, handlers, ev, key, abs, prop }
function M.parse_devices(text)
	local devices = {}
	if type(text) ~= "string" then return devices end

	local current = nil
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if line:match("^I:") then
			current = { name = "", handlers = "", ev = "", key = "", abs = "", prop = "" }
			devices[#devices + 1] = current
		elseif current then
			local name = line:match('^N:%s*Name="(.*)"%s*$')
			if name then current.name = name end
			local handlers = line:match("^H:%s*Handlers=(.*)$")
			if handlers then current.handlers = handlers end
			local kind, bits = line:match("^B:%s*(%u+)=(.*)$")
			if kind then
				if kind == "EV" then current.ev = bits
				elseif kind == "KEY" then current.key = bits
				elseif kind == "ABS" then current.abs = bits
				elseif kind == "PROP" then current.prop = bits end
			end
		end
	end

	return devices
end

--- The event node a device's handlers line names, e.g. "/dev/input/event7".
--- @param handlers string
--- @return string|nil
local function event_node(handlers)
	local node = tostring(handlers):match("(event%d+)")
	if not node then return nil end
	return "/dev/input/" .. node
end

-- Confirm ambiguous procfs words against the kernel's actual fd capabilities.
-- A 32-bit userspace process can run on a 64-bit kernel, so its ABI is not
-- evidence of procfs word size. A failed probe never admits a device.
local function probe_capabilities(path)
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
	local called, result = pcall(function()
		local abs, keys = ffi.new("uint8_t[8]"), ffi.new("uint8_t[42]")
		if tonumber(ioctl_port(fd, 0x80084523, abs)) ~= 8 then return nil end
		-- The slot and key count are independent: a refused key bitmap leaves
		-- the count unknown, without discarding an already confirmed touchpad.
		local key_called, key_bytes = pcall(ioctl_port, fd, 0x802a4521, keys)
		local function bit_set(bytes, bit)
			return math.floor(tonumber(bytes[math.floor(bit / 8)]) / 2 ^ (bit % 8)) % 2 == 1
		end
		local maximum = 0
		if key_called and tonumber(key_bytes) == 42 then
			for _, entry in ipairs(FINGER_BITS) do
				if bit_set(keys, entry.bit) and entry.fingers > maximum then maximum = entry.fingers end
			end
		end
		return { slot = bit_set(abs, ABS_MT_SLOT), max_fingers = maximum }
	end)
	local closed, acknowledged = pcall(close_port, fd)
	if not called or not closed or acknowledged ~= 0 then return nil end
	return result
end

local function proven_64(device)
	for _, field in ipairs({ "ev", "key", "abs", "prop" }) do
		for word in tostring(device[field] or ""):gmatch("%x+") do
			if #word > 8 then return true end
		end
	end
	return false
end

--- Describes one device as a candidate touchpad.
--- @param device table
--- @return table { path, name, is_touchpad, semi_mt, max_fingers, reason }
function M.describe(device, probe)
	local out = {
		path        = event_node(device.handlers or ""),
		name        = device.name or "",
		is_touchpad = false,
		semi_mt     = false,
		max_fingers = 0,
		reason      = nil,
	}

	if not out.path then
		out.reason = Errors.TOUCHPAD_NO_EVENT_NODE
		return out
	end

	-- Multitouch slots are the defining test, not the device's NAME: a name can
	-- say "Touchpad" on something that reports a single point, and a real pad can
	-- be named after its chipset.
	local wide = proven_64(device)
	local slot64 = M.bit_set(device.abs or "", ABS_MT_SLOT, 64)
	local slot32 = M.bit_set(device.abs or "", ABS_MT_SLOT, 32)
	local capabilities
	if not wide and slot64 ~= slot32 and type(probe) == "function" then
		local called, result = pcall(probe, out.path)
		if called and type(result) == "table" then capabilities = result end
	end
	local slot = wide and slot64 or (slot64 == slot32 and slot64)
	if not wide and slot64 ~= slot32 then slot = capabilities and capabilities.slot == true end
	if not slot then
		out.reason = Errors.TOUCHPAD_NO_MULTITOUCH_SLOT
		return out
	end

	if not (M.bit_set(device.prop or "", INPUT_PROP_POINTER)
		or M.bit_set(device.prop or "", INPUT_PROP_BUTTONPAD)) then
		out.reason = Errors.TOUCHPAD_NOT_POINTING_DEVICE
		return out
	end

	out.is_touchpad = true
	-- Semi-MT hardware reports a bounding box rather than real positions, so two
	-- fingers apart and two fingers together look the same. Flagged rather than
	-- rejected: the finger COUNT is still trustworthy, and taps only need that.
	out.semi_mt = M.bit_set(device.prop or "", INPUT_PROP_SEMI_MT)

	local maximum64, maximum32 = 0, 0
	for _, entry in ipairs(FINGER_BITS) do
		if M.bit_set(device.key or "", entry.bit, 64) then maximum64 = math.max(maximum64, entry.fingers) end
		if M.bit_set(device.key or "", entry.bit, 32) then maximum32 = math.max(maximum32, entry.fingers) end
	end
	if wide or maximum64 == maximum32 then
		out.max_fingers = maximum64
	else
		if not capabilities and type(probe) == "function" then
			local called, result = pcall(probe, out.path)
			if called and type(result) == "table" then capabilities = result end
		end
		local maximum = capabilities and capabilities.max_fingers
		if type(maximum) == "number" and maximum >= 0 and maximum <= 5 and maximum % 1 == 0 then
			out.max_fingers = maximum
		end
	end

	return out
end




-- =============================================
-- =============================================
-- ======= 3/ Choosing one =====================
-- =============================================
-- =============================================

--- Every touchpad the machine has, best first.
---
--- "Best" is the one that can count the most fingers, because that is the only
--- ranking that matters to this feature; ties break by device path, which is
--- stable across boots for built-in hardware. (table.sort is not stable, so a
--- bare max_fingers comparison lets equal pads come out in whatever order the
--- implementation walks them — which differs between interpreters — and the
--- boot then flips between pads and their gesture sets with it.)
--- @param text string|nil Contents of /proc/bus/input/devices; read when nil.
--- @return table Array of describe() results.
function M.list(text, probe)
	if text == nil then
		probe = probe or probe_capabilities
		local fh = io.open(DEVICES_PATH, "r")
		if not fh then
			Logger.error(LOG, "Cannot read %s — no touchpad can be found.", DEVICES_PATH)
			return {}
		end
		local read_ok, content = pcall(fh.read, fh, "*a")
		local close_ok, closed = pcall(fh.close, fh)
		if not read_ok or type(content) ~= "string" or not close_ok or closed ~= true then
			Logger.error(LOG, "Cannot complete reading %s — no touchpad can be found.", DEVICES_PATH)
			return {}
		end
		text = content
	end

	local found = {}
	for _, device in ipairs(M.parse_devices(text)) do
		local described = M.describe(device, probe)
		if described.is_touchpad then found[#found + 1] = described end
	end

	table.sort(found, function(a, b)
		if a.max_fingers ~= b.max_fingers then return a.max_fingers > b.max_fingers end
		if a.path ~= b.path then return (a.path or "") < (b.path or "") end
		return (a.name or "") < (b.name or "")
	end)
	return found
end

--- The touchpad to read, or nil with the reason there is none.
--- @param text string|nil
--- @return table|nil touchpad, string|nil reason
function M.find(text, probe)
	local found = M.list(text, probe)
	if #found == 0 then
		return nil, "no device reports multitouch slots"
	end

	local chosen = found[1]
	Logger.info(LOG, "Touchpad selected: %s (%s), up to %d finger(s)%s.",
		chosen.path, chosen.name, chosen.max_fingers,
		chosen.semi_mt and ", semi-MT" or "")
	return chosen, nil
end

--- Whether a gesture slot can ever fire on this hardware (gestures/slot_report.lua).
M.slot_is_reachable = require("modules.gestures.slot_report").slot_is_reachable

--- Reads how many device units make a millimetre on the touchpad's MT axes.
---
--- EVIOCGABS answers the kernel's struct input_absinfo (value, minimum,
--- maximum, fuzz, flat, resolution as six int32); the resolution is in units
--- per millimetre for ABS_MT_POSITION_*. Incremental swipes count their steps
--- in millimetres, as the macOS trackpad reports them, so one sensitivity means
--- the same travel on both systems. A pad that reports 0 has no scale: nil.
--- @param path string The touchpad's event node.
--- @return number|nil units_x Units per millimetre along x.
--- @return number|nil units_y Units per millimetre along y.
function M.read_resolution(path)
	local available, ffi = pcall(require, "ffi")
	if not available or type(ffi) ~= "table" or ffi.os ~= "Linux" or type(path) ~= "string" then return nil end
	local declared, detail = pcall(ffi.cdef, [[
		int open(const char *path, int flags);
		int close(int fd);
		int ioctl(int fd, unsigned long request, ...);
	]])
	if not declared and not tostring(detail):find("redefin", 1, true) then return nil end
	local fd = ffi.C.open(path, 0x80800) -- O_NONBLOCK | O_CLOEXEC
	if fd == nil or fd < 0 then return nil end
	local function resolution(code)
		local info = ffi.new("int32_t[6]")
		-- _IOR('E', 0x40 + code, struct input_absinfo): 24 bytes.
		local request = 0x80184540 + code
		if ffi.C.ioctl(fd, request, info) ~= 0 then return nil end
		local units = tonumber(info[5])
		return units > 0 and units or nil
	end
	local ok, x, y = pcall(function() return resolution(ABS_MT_POSITION_X), resolution(ABS_MT_POSITION_Y) end)
	ffi.C.close(fd)
	if not ok then return nil end
	return x, y
end

return M
