--- tests/unit/infra/test_input_event_codec.lua

--- ==============================================================================
--- MODULE: struct input_event Codec
--- DESCRIPTION:
--- The bytes the kernel hands us and the bytes we hand back, in both directions,
--- against buffers built by hand from input-event-codes.h.
---
--- WHY THIS IS THE ASSERTION:
--- The layout used to be written out three times — a decoder in the input reader,
--- an encoder in the uinput writer, and a second decoder inside a reader instance
--- nothing called. The test named for the first of those built a correct 24-byte
--- buffer over ten lines and then DISCARDED it, asserting only that requiring the
--- module returned a table. Every remaining case checked that pcall had not
--- thrown. So the offsets, the endianness, the signed conversion and the
--- short-buffer guard were all unverified, behind a green suite.
---
--- The other half of the defect is the one no assertion could have caught while
--- the size was a constant: 24 bytes with the type field at offset 17 is the
--- 64-bit shape and only that. A 32-bit userspace has an 8-byte timeval, so the
--- struct is 16 bytes and every field lands somewhere else — the driver would
--- not fail, it would read plausible garbage and type it. The codec derives its
--- offsets from the size for exactly that reason, and the 16-byte cases below are
--- what stop anyone reintroducing the constant.
---
--- Round-trip is asserted in both directions on purpose. An encoder and a decoder
--- that share a mistake agree with each other perfectly.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The two struct shapes. 24 is a 64-bit kernel (16-byte timeval + 8-byte
-- payload); 16 is a 32-bit userspace (8-byte timeval + the same payload).
local SIZE_64 = 24
local SIZE_32 = 16

--- Builds one input_event by hand, from the field order in input-event-codes.h.
--- Deliberately NOT by calling the encoder: a fixture produced by the code under
--- test asserts only that the code agrees with itself.
--- @param size integer Struct size in bytes.
--- @param ev_type integer
--- @param code integer
--- @param value integer Signed 32-bit.
--- @return string
local function build(size, ev_type, code, value)
	local bytes = {}
	for _ = 1, size - 8 do bytes[#bytes + 1] = "\0" end          -- timeval, zeroed
	bytes[#bytes + 1] = string.char(ev_type % 256, math.floor(ev_type / 256))
	bytes[#bytes + 1] = string.char(code % 256, math.floor(code / 256))
	local v = value < 0 and (value + 0x100000000) or value
	bytes[#bytes + 1] = string.char(
		v % 256,
		math.floor(v / 256) % 256,
		math.floor(v / 65536) % 256,
		math.floor(v / 16777216) % 256)
	return table.concat(bytes)
end





-- =================================================================
-- =================================================================
-- ======= 1/ Little-endian primitives =============================
-- =================================================================
-- =================================================================

helpers.describe("input_event: little-endian primitives", function()

	helpers.it("decodes a u16 low byte first, not high byte first", function()
		local ie = helpers.load_module("infra.input_event")
		-- 0x1E00 vs 0x001E is the difference between KEY_A and a code no keyboard
		-- reports. Byte order is the one mistake that produces plausible output.
		helpers.assert_eq(ie.unpack_u16_le("\30\0", 1), 30, "0x1E 0x00 is 30, not 7680")
		helpers.assert_eq(ie.unpack_u16_le("\0\30", 1), 7680, "and 0x00 0x1E really is 7680")
	end)

	helpers.it("decodes a u16 from the given offset", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.unpack_u16_le("\255\255\30\0", 3), 30,
			"the offset must be honoured; every field but the first depends on it")
	end)

	helpers.it("decodes a positive i32", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.unpack_i32_le("\1\0\0\0", 1), 1, "a key press is value 1")
		helpers.assert_eq(ie.unpack_i32_le("\2\0\0\0", 1), 2, "an autorepeat is value 2")
	end)

	helpers.it("converts the high half of the range to a negative number", function()
		local ie = helpers.load_module("infra.input_event")
		-- EV_REL and EV_ABS carry signed deltas. Reading -1 as 4294967295 would
		-- not fail, it would move a pointer four billion units.
		helpers.assert_eq(ie.unpack_i32_le("\255\255\255\255", 1), -1,
			"0xFFFFFFFF is -1 in two's complement, not 4294967295")
	end)

	helpers.it("leaves the boundary value just below the sign bit positive", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.unpack_i32_le("\255\255\255\127", 1), 2147483647,
			"0x7FFFFFFF is the largest positive int32 and must not wrap")
	end)

	helpers.it("returns nil rather than arithmetic on a truncated field", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.unpack_u16_le("\30", 1), nil, "one byte is not a u16")
		helpers.assert_eq(ie.unpack_i32_le("\1\0\0", 1), nil, "three bytes are not an i32")
	end)

	helpers.it("packs a u16 low byte first", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.pack_uint_le(30, 2), "\30\0", "the wire is little-endian in both directions")
	end)

	helpers.it("packs a negative i32 in two's complement", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.pack_i32_le(-1), "\255\255\255\255", "-1 is 0xFFFFFFFF, not a truncation")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Decoding a real struct ===============================
-- =================================================================
-- =================================================================

helpers.describe("input_event: decode", function()

	helpers.it("reads type, code and value out of a 64-bit struct", function()
		local ie = helpers.load_module("infra.input_event")
		local ev = ie.decode(build(SIZE_64, 1, 30, 1), SIZE_64)
		helpers.assert_true(ev ~= nil, "a well-formed struct must decode")
		helpers.assert_eq(ev.type, 1, "EV_KEY")
		helpers.assert_eq(ev.code, 30, "KEY_A")
		helpers.assert_eq(ev.value, 1, "a press")
	end)

	helpers.it("reads the same fields out of a 32-bit struct", function()
		local ie = helpers.load_module("infra.input_event")
		-- THE regression. The old decoder hardcoded offset 17, so on a 32-bit
		-- userspace it read the last two timeval bytes as the type and the value
		-- as whatever followed the buffer. Offsets are derived from the size now,
		-- which is why this case needs no branch in the implementation.
		local ev = ie.decode(build(SIZE_32, 1, 30, 1), SIZE_32)
		helpers.assert_true(ev ~= nil, "an 8-byte timeval is not a malformed struct")
		helpers.assert_eq(ev.type, 1, "EV_KEY, at an offset eight bytes earlier")
		helpers.assert_eq(ev.code, 30, "KEY_A")
		helpers.assert_eq(ev.value, 1, "a press")
	end)

	helpers.it("distinguishes press, autorepeat and release", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.decode(build(SIZE_64, 1, 30, 1), SIZE_64).value, 1, "press")
		helpers.assert_eq(ie.decode(build(SIZE_64, 1, 30, 2), SIZE_64).value, 2, "autorepeat")
		helpers.assert_eq(ie.decode(build(SIZE_64, 1, 30, 0), SIZE_64).value, 0, "release")
	end)

	helpers.it("decodes a keycode above 255", function()
		local ie = helpers.load_module("infra.input_event")
		-- KEY_BRIGHTNESS_CYCLE. The high byte is exactly what a one-byte read
		-- would lose, and under a grab a lost key is one the user never sees.
		local ev = ie.decode(build(SIZE_64, 1, 243, 1), SIZE_64)
		helpers.assert_eq(ev.code, 243, "the second byte of the code must be read")
	end)

	helpers.it("does not filter by type — that is the dispatcher's job", function()
		local ie = helpers.load_module("infra.input_event")
		local ev = ie.decode(build(SIZE_64, 4, 4, 458756), SIZE_64)
		helpers.assert_eq(ev.type, 4, "EV_MSC decodes like anything else")
		helpers.assert_eq(ev.value, 458756, "including a value far outside key range")
	end)

	helpers.it("rejects a short buffer instead of decoding garbage", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.decode(string.rep("\0", SIZE_64 - 1), SIZE_64), nil,
			"a partial read is a truncated struct; decoding it invents a keystroke")
	end)

	helpers.it("rejects a non-string", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.decode(nil, SIZE_64), nil, "a failed read is nil, and must stay nil")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Encoding, and the round trip =========================
-- =================================================================
-- =================================================================

helpers.describe("input_event: encode", function()

	helpers.it("produces exactly the struct size asked for", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(#ie.encode(1, 30, 1, SIZE_64), SIZE_64, "64-bit struct")
		helpers.assert_eq(#ie.encode(1, 30, 1, SIZE_32), SIZE_32, "32-bit struct")
	end)

	helpers.it("matches a hand-built struct byte for byte", function()
		local ie = helpers.load_module("infra.input_event")
		helpers.assert_eq(ie.encode(1, 30, 1, SIZE_64), build(SIZE_64, 1, 30, 1),
			"the encoder must agree with the header, not merely with the decoder")
	end)

	helpers.it("zeroes the timestamp, which is what makes these tests possible", function()
		local ie = helpers.load_module("infra.input_event")
		local bytes = ie.encode(1, 30, 1, SIZE_64)
		helpers.assert_eq(bytes:sub(1, SIZE_64 - 8), string.rep("\0", SIZE_64 - 8),
			"the kernel stamps events arriving from uinput; sending a clock reading "
				.. "would be both redundant and non-deterministic")
	end)

	helpers.it("round-trips every field, on both struct sizes", function()
		local ie = helpers.load_module("infra.input_event")
		for _, size in ipairs({ SIZE_64, SIZE_32 }) do
			for _, case in ipairs({ { 1, 30, 1 }, { 1, 243, 2 }, { 1, 42, 0 }, { 3, 8, -1 } }) do
				local ev = ie.decode(ie.encode(case[1], case[2], case[3], size), size)
				helpers.assert_eq(ev.type, case[1], "type survives a round trip at size " .. size)
				helpers.assert_eq(ev.code, case[2], "code survives a round trip at size " .. size)
				helpers.assert_eq(ev.value, case[3], "value survives a round trip at size " .. size)
			end
		end
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The size is measured, not assumed ====================
-- =================================================================
-- =================================================================

helpers.describe("input_event: native_size", function()

	helpers.it("answers with a struct size big enough to hold the payload", function()
		local ie = helpers.load_module("infra.input_event")
		local size = ie.native_size()
		helpers.assert_type(size, "number", "the size must be a number to index with")
		helpers.assert_true(size >= 16,
			"an 8-byte payload after a timeval of at least 8 bytes; got " .. tostring(size))
		helpers.assert_true(size % 4 == 0,
			"the struct is int-aligned on every architecture the kernel supports; got " .. tostring(size))
	end)

	helpers.it("falls back to the 64-bit size on a runtime with no FFI to ask", function()
		local ie = helpers.load_module("infra.input_event")
		ie._reset_measurement()
		-- This interpreter has no ffi module, so the fallback IS the path taken
		-- here — and the fallback value is the one every fixture above is written
		-- against, which is why the two must not drift.
		local ok_ffi = pcall(require, "ffi")
		if not ok_ffi then
			helpers.assert_eq(ie.native_size(), ie.SIZE_64BIT,
				"with no FFI the codec must assume the 64-bit shape, the only one it can guess")
		else
			helpers.assert_true(ie.native_size() >= 16,
				"with FFI present the measurement replaces the guess")
		end
	end)

	helpers.it("caches the answer rather than probing per event", function()
		local ie = helpers.load_module("infra.input_event")
		ie._reset_measurement()
		local first = ie.native_size()
		helpers.assert_eq(ie.native_size(), first,
			"the size cannot change under a running process, and the read is on the "
				.. "keystroke path")
	end)

end)
