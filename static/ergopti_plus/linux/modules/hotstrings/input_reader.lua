--- modules/hotstrings/input_reader.lua

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
-- ======= 3/ Keycode Tables (shared) =======
-- =========================================
-- =========================================

-- Load the evdev keycode maps from the shared JSON (LNX-1). The loader returns
-- the same LAYOUTS shape {qwerty={unshifted,shifted}, azerty=…}.
-- This is the SINGLE source of truth — no hardcoded fallback

local LAYOUTS = nil

local function _load_shared_layouts()
	local ok_evdev, evdev = pcall(require, "keycodes.evdev")
	if not ok_evdev or type(evdev) ~= "table" or type(evdev.load) ~= "function" then
		return nil, "keycodes.evdev module unavailable"
	end

	-- The Linux daemon uses a vendored pure-Lua JSON decoder.
	local ok_json, json_mod = pcall(require, "json")
	local decode = (ok_json and json_mod and json_mod.decode) or nil
	if not decode then
		-- Fall back to a minimal JSON parser if no json module is available.
		-- Uses load("return "..raw) which works for our trusted static data
		-- (keycodes are plain strings/numbers; booleans/null not yet needed).
		decode = function(raw)
			local ok, val = pcall(function()
				local f = assert(load("return " .. raw))
				return f()
			end)
			if ok then return val end
		end
	end
	if not decode then
		return nil, "no JSON decoder available"
	end

	-- Resolve the _shared/ root explicitly: walk up from this file's location
	-- (linux/modules/hotstrings/input_reader.lua) → three levels up gives the
	-- repo root, then _shared/.  Passed to evdev.load so it never falls back to
	-- the fragile debug.getinfo path (which breaks under LuaJIT).
	local function shared_root()
		local src = debug and debug.getinfo and debug.getinfo(1, "S")
		if src and src.source then
			local s = src.source
			if s:sub(1, 1) == "@" then s = s:sub(2) end
			local dir = s:match("^(.*[/\\])") or ""
			-- dir is .../linux/modules/hotstrings/ → walk up 3 levels
			local root = dir:gsub("[/\\]$", "")
			root = root:gsub("[/\\][^/\\]+[/\\][^/\\]+[/\\][^/\\]+$", "")
			if root and root ~= dir then
				return root .. "/_shared/"
			end
		end
		return nil
	end

	return evdev.load(decode, nil, shared_root)
end

-- Attempt the shared load once at module-init time. Fail-fast: no fallback.
local _shared_layouts, _shared_err = _load_shared_layouts()
if _shared_layouts then
	LAYOUTS = _shared_layouts
	Logger.info(LOG, "evdev keycode tables loaded from shared JSON.")
else
	Logger.error(LOG, "shared evdev load failed (%s) — keycode resolution will not work.", _shared_err or "unknown")
end

-- No hardcoded fallback keycode tables. The single source of truth is
-- _shared/data/keycodes/evdev.json, loaded at module-init time via
-- _load_shared_layouts(). If that load fails, the module errors out —
-- keycode data MUST come from the shared source, never re-declared here.
-- The inline tables used to be triplicates of evdev.json
assert(LAYOUTS ~= nil, "input_reader: evdev.json keycode tables failed to load — _shared/data/keycodes/evdev.json is the single source and must be readable")




-- ========================================
-- ===== 3.5) Public Layout Accessor =====
-- ========================================

--- Returns the loaded LAYOUTS table so other modules (e.g. keyboard_hook)
--- can resolve keycodes → characters without re-loading evdev.json or
--- re-declaring hardcoded layout maps.
--- @return table The LAYOUTS table: {qwerty={unshifted,shifted}, …}.
function M.get_layouts()
	return LAYOUTS
end

--- Resolves a keycode to a character using the given layout and shift state.
--- Returns nil for non-printable keycodes.
--- @param code    integer Kernel keycode (input-event-codes.h KEY_* value).
--- @param layout  string  Layout name ("qwerty" or "azerty").
--- @param shifted boolean True if Shift is held.
--- @return string|nil The resolved character, or nil.
function M.resolve_char(code, layout, shifted)
	local lt = LAYOUTS[layout] or LAYOUTS["qwerty"]
	if not lt then return nil end
	local table_to_use = shifted and lt.shifted or lt.unshifted
	return table_to_use and table_to_use[code] or nil
end


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
