--- tests/unit/meta/test_input_reader_decode.lua
---
--- Integration tests for input_reader's evdev binary decode.
--- helpers and layout tables. The evdev struct parser (parse_event, decode_u16_le,
--- decode_s32_le) and keycode lookup tables are pure functions testable on any OS.
---
--- Real /dev/input/eventN reading requires Linux; those paths are guarded
--- behind io.open("rb") which fails on Windows — the test verifies the logic
--- layer only, leaving the blocking read loop for native Linux testing.

local helpers     = require("tests.helpers")
local inputReader = helpers.load_module("modules.hotstrings.input_reader")

helpers.describe("input_reader (evdev decode)", function()

  -- ==========================================================================
  -- 1. Binary decode helpers (decode_u16_le, decode_s32_le)
  -- ==========================================================================

  -- The decode layer is reached through an explicit test seam. Its previous
  -- "coverage" built a 24-byte buffer and then never fed it to anything: the
  -- `data` local was dead, and every assertion in the block was assert_true(true)
  -- or a type check on the constructor. Struct offsets, byte order, the signed
  -- conversion and the short-buffer guard were all unverified — and each of them,
  -- when wrong, silently mistypes or drops keystrokes rather than failing.
  local decode = inputReader.__decode_for_test

  --- Builds a 24-byte input_event exactly as the kernel lays it out.
  --- @param ev_type number
  --- @param ev_code number
  --- @param ev_value number Signed 32-bit.
  --- @return string
  local function make_event(ev_type, ev_code, ev_value)
    local bytes = {}
    for _ = 1, 16 do bytes[#bytes + 1] = string.char(0x00) end   -- timeval
    bytes[#bytes + 1] = string.char(ev_type % 256)
    bytes[#bytes + 1] = string.char(math.floor(ev_type / 256) % 256)
    bytes[#bytes + 1] = string.char(ev_code % 256)
    bytes[#bytes + 1] = string.char(math.floor(ev_code / 256) % 256)
    local v = ev_value < 0 and (ev_value + 0x100000000) or ev_value
    bytes[#bytes + 1] = string.char(v % 256)
    bytes[#bytes + 1] = string.char(math.floor(v / 256) % 256)
    bytes[#bytes + 1] = string.char(math.floor(v / 65536) % 256)
    bytes[#bytes + 1] = string.char(math.floor(v / 16777216) % 256)
    return table.concat(bytes)
  end

  helpers.describe("decode_u16_le()", function()
    helpers.it("is exposed through the test seam", function()
      helpers.assert_eq(type(decode), "table",
        "the decode layer must be reachable from tests — file-locals with no seam are why this whole path went unverified")
      helpers.assert_eq(type(decode.u16_le), "function", "u16_le must be reachable")
      helpers.assert_eq(type(decode.s32_le), "function", "s32_le must be reachable")
      helpers.assert_eq(type(decode.parse_event), "function", "parse_event must be reachable")
    end)

    helpers.it("decodes little-endian, not big-endian", function()
      -- 0x10 0x27 is 10000 little-endian and 4135 big-endian. A byte-order
      -- regression turns every keycode into a different key.
      helpers.assert_eq(decode.u16_le(string.char(0x10, 0x27), 1), 10000,
        "the low byte comes first — reading it big-endian maps each keycode to an unrelated key")
    end)

    helpers.it("reads from the given offset", function()
      local data = string.char(0xFF, 0xFF) .. string.char(0x1E, 0x00)
      helpers.assert_eq(decode.u16_le(data, 3), 30,
        "the offset must be honoured, or every field is read from the wrong place in the struct")
    end)
  end)

  helpers.describe("decode_s32_le()", function()
    helpers.it("decodes a positive value", function()
      helpers.assert_eq(decode.s32_le(string.char(0x01, 0x00, 0x00, 0x00), 1), 1,
        "KEY_DOWN is value 1 — the most common event in the stream")
    end)

    helpers.it("converts the high half of the range to negative", function()
      -- 0xFFFFFFFF is -1 signed. Without the conversion it reads as 4294967295,
      -- which equals nothing the dispatcher tests for, so such an event would
      -- fall through every branch silently.
      helpers.assert_eq(decode.s32_le(string.char(0xFF, 0xFF, 0xFF, 0xFF), 1), -1,
        "values at or above 0x80000000 must convert to negative")
    end)

    helpers.it("leaves the boundary value just below the sign bit positive", function()
      helpers.assert_eq(decode.s32_le(string.char(0xFF, 0xFF, 0xFF, 0x7F), 1), 2147483647,
        "0x7FFFFFFF is the largest positive int32 — converting it too would be an off-by-one on the sign boundary")
    end)
  end)

  helpers.describe("parse_event()", function()
    helpers.it("decodes a well-formed KEY_A keydown", function()
      local ev = decode.parse_event(make_event(1, 30, 1))
      helpers.assert_true(ev ~= nil, "a full 24-byte event must decode")
      helpers.assert_eq(ev.ev_type, 1, "EV_KEY is type 1 — the filter the whole dispatcher depends on")
      helpers.assert_eq(ev.ev_code, 30, "KEY_A is code 30")
      helpers.assert_eq(ev.ev_value, 1, "KEY_DOWN is value 1")
    end)

    helpers.it("distinguishes keydown, repeat and keyup", function()
      -- The dispatcher forwards ONLY value == 1. If repeat (2) or keyup (0)
      -- decoded as 1, a held key would fire its hotstring on every repeat.
      helpers.assert_eq(decode.parse_event(make_event(1, 30, 2)).ev_value, 2,
        "auto-repeat must decode as 2, or a held key fires its hotstring repeatedly")
      helpers.assert_eq(decode.parse_event(make_event(1, 30, 0)).ev_value, 0,
        "key release must decode as 0, or every keystroke is counted twice")
    end)

    helpers.it("decodes a two-byte keycode above 255", function()
      -- Codes above 255 exercise the high byte; a decoder that only read the low
      -- byte would handle KEY_F13 (183) fine but alias anything past 0xFF.
      local ev = decode.parse_event(make_event(1, 300, 1))
      helpers.assert_eq(ev.ev_code, 300, "the high byte of the keycode must be read")
    end)

    helpers.it("rejects a short buffer instead of decoding garbage", function()
      helpers.assert_eq(decode.parse_event(string.rep(string.char(0), 23)), nil,
        "a partial read must return nil — decoding it would emit a keystroke assembled from whatever followed in memory")
      helpers.assert_eq(decode.parse_event(""), nil, "an empty buffer must return nil")
    end)

    helpers.it("does not filter by type — that is the dispatcher's job", function()
      -- EV_SYN (type 0) arrives after every key event. parse_event must decode
      -- it faithfully and leave the filtering to the caller, which is where the
      -- EV_KEY test lives.
      local ev = decode.parse_event(make_event(0, 0, 0))
      helpers.assert_true(ev ~= nil, "a synchronisation event must still decode")
      helpers.assert_eq(ev.ev_type, 0, "and report its real type")
    end)
  end)

  -- ==========================================================================
  -- 2. Reader instantiation
  -- ==========================================================================

  helpers.describe("new() constructor", function()
    helpers.it("creates a reader with qwerty layout", function()
      local called = false
      local reader = inputReader.new("/dev/null", "qwerty",
        function(ch) called = true end)
      helpers.assert_true(type(reader) == "table", "returns table")
      helpers.assert_true(type(reader.start) == "function", "has start method")
      helpers.assert_true(type(reader.stop) == "function", "has stop method")
    end)

    helpers.it("creates a reader with azerty layout", function()
      local reader = inputReader.new("/dev/null", "azerty",
        function() end)
      helpers.assert_true(type(reader) == "table", "azerty reader created")
    end)

    helpers.it("defaults to qwerty for unknown layout", function()
      local reader = inputReader.new("/dev/null", "bepo",
        function() end)
      helpers.assert_true(type(reader) == "table", "unknown layout → qwerty fallback")
    end)

    helpers.it("accepts optional on_control callback", function()
      local char_called = false
      local ctrl_called = false
      local reader = inputReader.new("/dev/null", "qwerty",
        function(ch) char_called = true end,
        function(key) ctrl_called = true end)
      helpers.assert_true(type(reader) == "table", "reader with control callback")
    end)

    helpers.it("stop() is idempotent", function()
      local reader = inputReader.new("/dev/nonexistent", "qwerty",
        function() end)
      -- stop() on a reader that never started should not crash
      local ok = pcall(function() reader:stop() end)
      helpers.assert_true(ok, "stop() on idle reader does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. start() with nonexistent device (degrades gracefully)
  -- ==========================================================================

  helpers.describe("start() error handling", function()
    helpers.it("logs error on nonexistent device", function()
      local reader = inputReader.new("/dev/nonexistent_xyz", "qwerty",
        function() end)
      -- start() should return immediately after logging error (no crash)
      local ok = pcall(function() reader:start() end)
      helpers.assert_true(ok, "start() on nonexistent device does not crash")
    end)

    helpers.it("start() on /dev/null returns immediately (no keyboard events)", function()
      local reader = inputReader.new("/dev/null", "qwerty",
        function() end)
      -- /dev/null is readable but produces EOF immediately
      local ok = pcall(function() reader:start() end)
      helpers.assert_true(ok, "start() on /dev/null completes without crash")
    end)
  end)

end)
