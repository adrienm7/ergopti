--- infra/input_event.lua

--- ==============================================================================
--- MODULE: struct input_event Codec (Linux)
--- DESCRIPTION:
--- The kernel's `struct input_event` in both directions: bytes off a grabbed
--- /dev/input/eventN, and bytes onto /dev/uinput. One layout, one arithmetic,
--- one place.
---
--- WHY THIS EXISTS:
--- The layout was written out three times — the reader's decoder, the writer's
--- encoder, and a second decoder inside a reader instance nothing called. All
--- three hardcoded 24 bytes with the type field at offset 17, which is the
--- 64-bit shape and only the 64-bit shape. A 32-bit userspace has an 8-byte
--- timeval, so the struct is 16 bytes and EVERY field lands somewhere else: the
--- driver would not fail, it would read garbage keycodes and type nonsense.
---
--- FEATURES & RATIONALE:
--- 1. The size is measured, not assumed. `ffi.sizeof("struct input_event")` is
---    the compiler's own answer, so the 32-bit case is correct without anyone
---    having to think about it. The constant below is only what a runtime with
---    no FFI falls back to, and it is stated as such rather than as the truth.
--- 2. Offsets are derived from the size. Everything after the timeval is fixed
---    at 8 bytes (u16 type, u16 code, s32 value), so the timeval width is the
---    single unknown and one subtraction resolves it.
--- 3. Hand-rolled little-endian, not string.pack. LuaJIT is Lua 5.1 and has no
---    string.pack; a version branch here would mean the branch CI does not run
---    is the one that ships on a user's machine.
--- 4. Byte strings, not FFI structs. Keeping the boundary at plain Lua strings
---    is what lets the whole codec be driven from a test on an interpreter with
---    no FFI at all — which is the interpreter this repo is developed on.
--- ==============================================================================

local M = {}




-- ==========================================
-- ==========================================
-- ======= 1/ Layout ========================
-- ==========================================
-- ==========================================

-- Everything after the timeval: __u16 type, __u16 code, __s32 value.
local PAYLOAD_BYTES = 8

-- The struct size on a 64-bit kernel: a 16-byte timeval plus the payload. Used
-- only when the runtime cannot measure the real thing; see native_size().
M.SIZE_64BIT = 24

-- Linux input event types (input-event-codes.h).
M.EV_SYN = 0x00
M.EV_KEY = 0x01

-- SYN_REPORT: the marker that makes everything written before it visible to the
-- application. Without it the kernel buffers the event and nothing happens,
-- while every write still reports success.
M.SYN_REPORT = 0x00

-- Key event values.
M.VALUE_UP     = 0
M.VALUE_DOWN   = 1
M.VALUE_REPEAT = 2

--- Cached result of the FFI measurement: nil until probed, false when there is
--- no FFI to ask.
local _measured = nil

--- The struct size this runtime should use.
---
--- Asks LuaJIT's FFI for `sizeof(struct input_event)` once, and falls back to the
--- 64-bit size when there is no FFI — a runtime with no FFI also has no device to
--- read, so the fallback only ever serves tests and the value it serves is the
--- one those tests are written against.
--- @return integer Size in bytes.
function M.native_size()
	if _measured ~= nil then
		return _measured or M.SIZE_64BIT
	end

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then
		_measured = false
		return M.SIZE_64BIT
	end

	-- Declared here rather than in the reader so the measurement does not depend
	-- on which module happened to load first. A redefinition raises instead of
	-- being a no-op, and that is not an error worth reporting.
	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		struct timeval { long tv_sec; long tv_usec; };
		struct input_event {
			struct timeval time;
			unsigned short type;
			unsigned short code;
			int value;
		};
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		_measured = false
		return M.SIZE_64BIT
	end

	local ok_size, size = pcall(ffi.sizeof, "struct input_event")
	_measured = (ok_size and type(size) == "number" and size >= PAYLOAD_BYTES + 8) and size or false
	return _measured or M.SIZE_64BIT
end

--- Test seam: forgets the measured size so a test can exercise both branches.
function M._reset_measurement()
	_measured = nil
end





-- ===========================================
-- ===========================================
-- ======= 2/ Little-endian primitives =======
-- ===========================================
-- ===========================================

--- Packs an unsigned integer into `width` little-endian bytes.
--- Values are masked rather than validated: every caller passes a kernel
--- constant or an evdev code, and a silent truncation is visible byte for byte
--- in the tests.
--- @param value integer
--- @param width integer Number of bytes.
--- @return string
function M.pack_uint_le(value, width)
	local bytes = {}
	local v = value
	for i = 1, width do
		bytes[i] = string.char(v % 256)
		v = math.floor(v / 256)
	end
	return table.concat(bytes)
end

--- Packs a signed 32-bit integer little-endian (two's complement).
--- @param value integer
--- @return string
function M.pack_i32_le(value)
	if value < 0 then value = value + 0x100000000 end
	return M.pack_uint_le(value, 4)
end

--- Decodes a two-byte little-endian unsigned integer.
--- @param data string Binary string.
--- @param offset integer 1-based byte offset.
--- @return integer|nil
function M.unpack_u16_le(data, offset)
	local lo = data:byte(offset)
	local hi = data:byte(offset + 1)
	if not lo or not hi then return nil end
	return lo + hi * 256
end

--- Decodes a four-byte little-endian signed integer.
--- @param data string Binary string.
--- @param offset integer 1-based byte offset.
--- @return integer|nil
function M.unpack_i32_le(data, offset)
	local b0 = data:byte(offset)
	local b1 = data:byte(offset + 1)
	local b2 = data:byte(offset + 2)
	local b3 = data:byte(offset + 3)
	if not b0 or not b1 or not b2 or not b3 then return nil end
	local val = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
	if val >= 0x80000000 then val = val - 0x100000000 end
	return val
end




-- ==========================================
-- ==========================================
-- ======= 3/ The struct ====================
-- ==========================================
-- ==========================================

--- Encodes one `struct input_event`.
---
--- The timestamp is zero: the kernel stamps events arriving from uinput itself,
--- so sending zeros is both correct and deterministic — which is what makes the
--- byte-level tests possible at all.
--- @param ev_type integer EV_KEY / EV_SYN.
--- @param code integer Event code.
--- @param value integer Event value (0 release, 1 press, 2 autorepeat).
--- @param size integer|nil Struct size; defaults to this runtime's measurement.
--- @return string A `size`-byte struct.
function M.encode(ev_type, code, value, size)
	local total = size or M.native_size()
	return M.pack_uint_le(0, total - PAYLOAD_BYTES)
		.. M.pack_uint_le(ev_type, 2)
		.. M.pack_uint_le(code, 2)
		.. M.pack_i32_le(value)
end

--- Decodes one `struct input_event` from its bytes.
---
--- Offsets are derived from the size rather than written down: the payload is
--- always the last 8 bytes, whatever the timeval width, so a 32-bit kernel needs
--- no special case and cannot be forgotten.
--- @param data string The struct bytes.
--- @param size integer|nil Struct size; defaults to this runtime's measurement.
--- @return table|nil { type = integer, code = integer, value = integer }.
function M.decode(data, size)
	if type(data) ~= "string" then return nil end
	local total = size or M.native_size()
	if #data < total then return nil end

	local at = total - PAYLOAD_BYTES + 1
	local ev_type = M.unpack_u16_le(data, at)
	local code    = M.unpack_u16_le(data, at + 2)
	local value   = M.unpack_i32_le(data, at + 4)
	if not ev_type or not code or not value then return nil end
	return { type = ev_type, code = code, value = value }
end

return M
