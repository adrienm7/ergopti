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
--- THE WORD-SIZE ASSUMPTION, AND WHY IT IS SAFE:
--- The bitmaps are printed as space-separated hex words, most significant first,
--- with leading all-zero words omitted. The word is `unsigned long`, so 64 bits on
--- every machine this driver targets and 32 on a 32-bit kernel. There is no
--- reliable way to tell which from the text alone, because the omission of
--- leading zeros makes the word COUNT depend on content rather than on width.
--- This assumes 64.
---
--- What makes that assumption acceptable is the direction of its failure: an
--- unrecognised bit reports "unknown", and an unknown capability offers EVERY
--- gesture rather than none. A wrong parse can therefore fail to add a hint. It
--- can never take a working gesture away.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "gestures.touchpad_finder"

-- Where the kernel describes every input device it has.
local DEVICES_PATH = "/proc/bus/input/devices"

-- Bits per printed word. See the header for why this is an assumption and why
-- being wrong about it is safe.
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
function M.bit_set(bitmap, bit)
	if type(bitmap) ~= "string" or type(bit) ~= "number" then return false end

	local words = {}
	for word in bitmap:gmatch("%x+") do words[#words + 1] = word end
	if #words == 0 then return false end

	local word_index = math.floor(bit / BITS_PER_WORD)
	local bit_index  = bit % BITS_PER_WORD

	-- Counted from the right: the last printed word is word 0.
	local position = #words - word_index
	if position < 1 then return false end

	local value = tonumber(words[position], 16)
	if not value then return false end

	-- Lua numbers are doubles, exact to 2^53, so a bit above 52 cannot be tested
	-- by division on the whole word. Those are reached by trimming hex digits
	-- instead, which is exact for any width.
	if bit_index >= 52 then
		local digits = words[position]
		local nibble = math.floor(bit_index / 4)
		local from_end = #digits - nibble
		if from_end < 1 then return false end
		local digit = tonumber(digits:sub(from_end, from_end), 16)
		if not digit then return false end
		return math.floor(digit / (2 ^ (bit_index % 4))) % 2 == 1
	end

	return math.floor(value / (2 ^ bit_index)) % 2 == 1
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

--- Describes one device as a candidate touchpad.
--- @param device table
--- @return table { path, name, is_touchpad, semi_mt, max_fingers, reason }
function M.describe(device)
	local out = {
		path        = event_node(device.handlers or ""),
		name        = device.name or "",
		is_touchpad = false,
		semi_mt     = false,
		max_fingers = 0,
		reason      = nil,
	}

	if not out.path then
		out.reason = "no event node"
		return out
	end

	-- Multitouch slots are the defining test, not the device's NAME: a name can
	-- say "Touchpad" on something that reports a single point, and a real pad can
	-- be named after its chipset.
	if not M.bit_set(device.abs or "", ABS_MT_SLOT) then
		out.reason = "no ABS_MT_SLOT — cannot report per-finger positions"
		return out
	end

	if not (M.bit_set(device.prop or "", INPUT_PROP_POINTER)
		or M.bit_set(device.prop or "", INPUT_PROP_BUTTONPAD)) then
		out.reason = "not a pointing device"
		return out
	end

	out.is_touchpad = true
	-- Semi-MT hardware reports a bounding box rather than real positions, so two
	-- fingers apart and two fingers together look the same. Flagged rather than
	-- rejected: the finger COUNT is still trustworthy, and taps only need that.
	out.semi_mt = M.bit_set(device.prop or "", INPUT_PROP_SEMI_MT)

	for _, entry in ipairs(FINGER_BITS) do
		if M.bit_set(device.key or "", entry.bit) then
			if entry.fingers > out.max_fingers then out.max_fingers = entry.fingers end
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
--- ranking that matters to this feature; ties keep /proc order, which is stable
--- across boots for built-in hardware.
--- @param text string|nil Contents of /proc/bus/input/devices; read when nil.
--- @return table Array of describe() results.
function M.list(text)
	if text == nil then
		local fh = io.open(DEVICES_PATH, "r")
		if not fh then
			Logger.error(LOG, "Cannot read %s — no touchpad can be found.", DEVICES_PATH)
			return {}
		end
		text = fh:read("*a") or ""
		fh:close()
	end

	local found = {}
	for _, device in ipairs(M.parse_devices(text)) do
		local described = M.describe(device)
		if described.is_touchpad then found[#found + 1] = described end
	end

	table.sort(found, function(a, b) return a.max_fingers > b.max_fingers end)
	return found
end

--- The touchpad to read, or nil with the reason there is none.
--- @param text string|nil
--- @return table|nil touchpad, string|nil reason
function M.find(text)
	local found = M.list(text)
	if #found == 0 then
		return nil, "no device reports multitouch slots"
	end

	local chosen = found[1]
	Logger.info(LOG, "Touchpad selected: %s (%s), up to %d finger(s)%s.",
		chosen.path, chosen.name, chosen.max_fingers,
		chosen.semi_mt and ", semi-MT" or "")
	return chosen, nil
end

--- Whether a gesture slot can ever fire on this hardware.
---
--- Answers TRUE when the capability is unknown. A wrong parse must not remove a
--- gesture that works; the worst it may do is fail to explain one that cannot.
--- @param slot string e.g. "swipe_5_up", "tap_4"
--- @param max_fingers integer|nil 0 or nil means unknown.
--- @return boolean
function M.slot_is_reachable(slot, max_fingers)
	if type(max_fingers) ~= "number" or max_fingers <= 0 then return true end
	local needed = tostring(slot):match("^swipe_(%d)_") or tostring(slot):match("^tap_(%d)$")
	if not needed then return true end
	return tonumber(needed) <= max_fingers
end

return M
