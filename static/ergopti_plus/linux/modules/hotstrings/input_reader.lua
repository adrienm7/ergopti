--- static/ergopti_plus/linux/modules/hotstrings/input_reader.lua

--- ==============================================================================
--- MODULE: Input Reader (Linux)
--- DESCRIPTION:
--- Reads raw keyboard events from a Linux evdev input device file
--- (/dev/input/eventN) and translates kernel keycodes to character strings for
--- the hotstring engine. No external library is required: the Linux input_event
--- struct is parsed directly from a binary file handle.
---
--- FEATURES & RATIONALE:
--- 1. Direct evdev access: opening /dev/input/eventN in binary mode gives us the
---    kernel event stream without depending on X11, Wayland, or libinput APIs.
--- 2. Struct layout: each input_event is 24 bytes on 64-bit Linux:
---      timeval  (tv_sec 8 bytes + tv_usec 8 bytes) = 16 bytes
---      __u16 type  = 2 bytes
---      __u16 code  = 2 bytes
---      __s32 value = 4 bytes
--- 3. EV_KEY filtering: only type=1 (EV_KEY) events with value=1 (keydown) are
---    forwarded to the engine; key-repeat (value=2) is ignored to avoid
---    double-expansions on held keys.
--- 4. Modifier tracking: Shift state is tracked so uppercase letters and shifted
---    symbols are mapped correctly.
--- 5. Blocking read loop: the daemon blocks on io.read() — no busy-polling, no
---    CPU waste. The loop exits on file error or when M.stop() sets the halt flag.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")

local LOG = "modules.hotstrings.input_reader"


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Linux input_event struct size on a 64-bit kernel (bytes).
local INPUT_EVENT_SIZE = 24

-- Offset of the type field within the struct (after 16-byte timeval).
local OFFSET_TYPE  = 17   -- bytes 17-18 (1-indexed)
local OFFSET_CODE  = 19   -- bytes 19-20
local OFFSET_VALUE = 21   -- bytes 21-24

-- Linux input event types (from input-event-codes.h).
local EV_KEY = 1

-- Linux key event values.
local KEY_DOWN   = 1   -- initial press
local KEY_UP     = 0   -- release
local KEY_REPEAT = 2   -- auto-repeat (ignored)

-- Kernel keycodes for modifier keys.
local KEY_LEFTSHIFT  = 42
local KEY_RIGHTSHIFT = 54
local KEY_LEFTCTRL   = 29
local KEY_RIGHTCTRL  = 97
local KEY_LEFTALT    = 56
local KEY_RIGHTALT   = 100  -- AltGr
local KEY_BACKSPACE  = 14
local KEY_SPACE      = 57
local KEY_ENTER      = 28
local KEY_TAB        = 15


-- =========================================
-- =========================================
-- ======= 3/ Keycode Tables ===============
-- =========================================
-- =========================================

-- QWERTY unshifted keycode → character.
-- Keycodes from input-event-codes.h KEY_* values.
local QWERTY_UNSHIFTED = {
	[2]  = "1", [3]  = "2", [4]  = "3", [5]  = "4", [6]  = "5",
	[7]  = "6", [8]  = "7", [9]  = "8", [10] = "9", [11] = "0",
	[12] = "-", [13] = "=",
	[16] = "q", [17] = "w", [18] = "e", [19] = "r", [20] = "t",
	[21] = "y", [22] = "u", [23] = "i", [24] = "o", [25] = "p",
	[26] = "[", [27] = "]",
	[30] = "a", [31] = "s", [32] = "d", [33] = "f", [34] = "g",
	[35] = "h", [36] = "j", [37] = "k", [38] = "l", [39] = ";",
	[40] = "'",
	[44] = "z", [45] = "x", [46] = "c", [47] = "v", [48] = "b",
	[49] = "n", [50] = "m", [51] = ",", [52] = ".", [53] = "/",
	[57] = " ",
}

-- QWERTY shifted keycode → character.
local QWERTY_SHIFTED = {
	[2]  = "!", [3]  = "@", [4]  = "#", [5]  = "$", [6]  = "%",
	[7]  = "^", [8]  = "&", [9]  = "*", [10] = "(", [11] = ")",
	[12] = "_", [13] = "+",
	[16] = "Q", [17] = "W", [18] = "E", [19] = "R", [20] = "T",
	[21] = "Y", [22] = "U", [23] = "I", [24] = "O", [25] = "P",
	[26] = "{", [27] = "}",
	[30] = "A", [31] = "S", [32] = "D", [33] = "F", [34] = "G",
	[35] = "H", [36] = "J", [37] = "K", [38] = "L", [39] = ":",
	[40] = '"',
	[44] = "Z", [45] = "X", [46] = "C", [47] = "V", [48] = "B",
	[49] = "N", [50] = "M", [51] = "<", [52] = ">", [53] = "?",
}

-- AZERTY unshifted (French keyboard layout).
-- Only rows that differ from QWERTY are listed; others fall through to QWERTY.
local AZERTY_UNSHIFTED = {
	[2]  = "&", [3]  = "\xc3\xa9", [4]  = '"',   [5]  = "'",  [6]  = "(",
	[7]  = "-", [8]  = "\xc3\xa8", [9]  = "_",   [10] = "\xc3\xa7", [11] = "\xc3\xa0",
	[12] = ")",  [13] = "=",
	[16] = "a", [17] = "z", [18] = "e", [19] = "r", [20] = "t",
	[21] = "y", [22] = "u", [23] = "i", [24] = "o", [25] = "p",
	[30] = "q", [31] = "s", [32] = "d", [33] = "f", [34] = "g",
	[35] = "h", [36] = "j", [37] = "k", [38] = "l", [39] = "m",
	[40] = "\xc3\xb9",
	[44] = "w", [45] = "x", [46] = "c", [47] = "v", [48] = "b",
	[49] = "n", [50] = ",", [51] = ";", [52] = ":", [53] = "!",
	[57] = " ",
}

-- AZERTY shifted.
local AZERTY_SHIFTED = {
	[2]  = "1", [3]  = "2",  [4]  = "3", [5]  = "4", [6]  = "5",
	[7]  = "6", [8]  = "7",  [9]  = "8", [10] = "9", [11] = "0",
	[12] = "\xc2\xb0", [13] = "+",
	[16] = "A", [17] = "Z", [18] = "E", [19] = "R", [20] = "T",
	[21] = "Y", [22] = "U", [23] = "I", [24] = "O", [25] = "P",
	[30] = "Q", [31] = "S", [32] = "D", [33] = "F", [34] = "G",
	[35] = "H", [36] = "J", [37] = "K", [38] = "L", [39] = "M",
	[40] = "%",
	[44] = "W", [45] = "X", [46] = "C", [47] = "V", [48] = "B",
	[49] = "N", [50] = "?", [51] = ".", [52] = "/", [53] = "\xc2\xa7",
}

-- Available layout tables, keyed by layout name.
local LAYOUTS = {
	qwerty = { unshifted = QWERTY_UNSHIFTED, shifted = QWERTY_SHIFTED },
	azerty = { unshifted = AZERTY_UNSHIFTED, shifted = AZERTY_SHIFTED },
}


-- =========================================
-- =========================================
-- ======= 4/ Struct Decoder ===============
-- =========================================
-- =========================================

--- Decodes a two-byte little-endian unsigned integer from a binary string.
--- @param data   string Binary string.
--- @param offset number 1-based byte offset.
--- @return integer
local function decode_u16_le(data, offset)
	local lo = data:byte(offset)
	local hi = data:byte(offset + 1)
	return lo + hi * 256
end

--- Decodes a four-byte little-endian signed integer from a binary string.
--- @param data   string Binary string.
--- @param offset number 1-based byte offset.
--- @return integer
local function decode_s32_le(data, offset)
	local b0 = data:byte(offset)
	local b1 = data:byte(offset + 1)
	local b2 = data:byte(offset + 2)
	local b3 = data:byte(offset + 3)
	local val = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
	-- Convert to signed 32-bit.
	if val >= 0x80000000 then val = val - 0x100000000 end
	return val
end

--- Parses one 24-byte input_event buffer into a table with fields:
---   ev_type  (uint16), ev_code (uint16), ev_value (int32).
--- Returns nil when the buffer is too short.
--- @param data string 24-byte binary string.
--- @return table|nil
local function parse_event(data)
	if #data < INPUT_EVENT_SIZE then return nil end
	return {
		ev_type  = decode_u16_le(data, OFFSET_TYPE),
		ev_code  = decode_u16_le(data, OFFSET_CODE),
		ev_value = decode_s32_le(data, OFFSET_VALUE),
	}
end


-- =========================================
-- =========================================
-- ======= 5/ Reader Instance ==============
-- =========================================
-- =========================================

--- Creates a new input reader bound to a device path and layout.
--- @param device_path string Absolute path, e.g. "/dev/input/event3".
--- @param layout      string "qwerty" or "azerty" (default "qwerty").
--- @param on_char     function Callback invoked with (char_string) on each keydown.
--- @param on_control  function|nil Optional callback for control keys: (key_name).
--- @return table Reader object exposing :start() and :stop().
function M.new(device_path, layout, on_char, on_control)
	local layout_tables = LAYOUTS[layout] or LAYOUTS["qwerty"]
	local _halt         = false
	local _shift_held   = false
	local _fh           = nil

	local reader = {}

	--- Opens the device and enters the blocking read loop.
	--- Calls on_char(ch) for each printable keydown event.
	--- Returns when the device is closed or M.stop() is called.
	function reader:start()
		Logger.start(LOG, "Opening device '%s' (layout=%s)…", device_path, layout or "qwerty")

		local fh, err = io.open(device_path, "rb")
		if not fh then
			Logger.error(LOG, "start(): cannot open '%s' — %s.", device_path, tostring(err))
			return
		end
		_fh   = fh
		_halt = false

		Logger.success(LOG, "Device '%s' opened — entering event loop.", device_path)

		while not _halt do
			local ok, data = pcall(function() return fh:read(INPUT_EVENT_SIZE) end)
			if not ok or not data or #data < INPUT_EVENT_SIZE then
				if not _halt then
					Logger.warn(LOG, "start(): device read ended (ok=%s).", tostring(ok))
				end
				break
			end

			local ev = parse_event(data)
			if ev and ev.ev_type == EV_KEY then
				local code  = ev.ev_code
				local value = ev.ev_value

				-- Track Shift state.
				if code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT then
					_shift_held = (value == KEY_DOWN or value == KEY_REPEAT)
					goto continue
				end

				-- Track other modifiers (Ctrl, Alt) — suppress character output
				-- when held so hotstrings do not fire inside keyboard shortcuts.
				if code == KEY_LEFTCTRL  or code == KEY_RIGHTCTRL or
				   code == KEY_LEFTALT   or code == KEY_RIGHTALT  then
					-- State tracking handled implicitly — no char emitted.
					goto continue
				end

				-- Only forward keydown events (not repeat, not keyup).
				if value ~= KEY_DOWN then goto continue end

				-- Special control keys: notify the caller via on_control.
				if code == KEY_BACKSPACE and on_control then
					pcall(on_control, "backspace")
					goto continue
				end
				if code == KEY_ENTER and on_control then
					pcall(on_control, "enter")
					goto continue
				end
				if code == KEY_TAB and on_control then
					pcall(on_control, "tab")
					goto continue
				end

				-- Resolve printable character from layout table.
				local table_to_use = _shift_held
					and layout_tables.shifted
					or  layout_tables.unshifted
				local ch = table_to_use[code]

				if ch and on_char then
					Logger.debug(LOG, "Key code=%d → char='%s' shift=%s.", code, ch, tostring(_shift_held))
					pcall(on_char, ch)
				end
			end

			::continue::
		end

		pcall(function() fh:close() end)
		_fh = nil
		Logger.info(LOG, "Device '%s' closed.", device_path)
	end

	--- Signals the read loop to exit on the next iteration.
	function reader:stop()
		_halt = true
		-- Close the file handle to unblock the blocking fh:read() call.
		if _fh then
			pcall(function() _fh:close() end)
			_fh = nil
		end
		Logger.info(LOG, "Reader stop requested.")
	end

	return reader
end

return M
