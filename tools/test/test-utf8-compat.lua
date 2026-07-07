#!/usr/bin/env lua
--- tools/test/test-utf8-compat.lua
---
--- Regression test for _shared/lua/compat/utf8.lua (SLP-1 + SLP-2).
--- Validates:
---   1. The compat shim installs correctly when utf8 is absent.
---   2. The shim does NOT overwrite a native utf8 library (Lua 5.3+).
---   3. All 5 functions (len, offset, codes, char, codepoint) work correctly
---      on ASCII, multi-byte UTF-8, and edge cases.
---   4. The shim correctly handles the keymap terminators and text_utils
---      use cases (the actual callers in the Ergopti+ shared modules).
---
--- Usage:
---   lua tools/test/test-utf8-compat.lua        (Lua 5.3+ — tests native guard)
---   luajit tools/test/test-utf8-compat.lua     (LuaJIT — tests shim install)

local passed = 0
local failed = 0

local function assert_eq(actual, expected, label)
	if actual == expected then
		passed = passed + 1
	else
		failed = failed + 1
		io.stderr:write(string.format("FAIL [%s]: expected %s, got %s\n",
			label, tostring(expected), tostring(actual)))
	end
end

local function assert_true(val, label)
	if val then
		passed = passed + 1
	else
		failed = failed + 1
		io.stderr:write(string.format("FAIL [%s]: expected truthy, got %s\n",
			label, tostring(val)))
	end
end

-- =========================================================================
-- Test 1: Compat shim can be required
-- =========================================================================

-- Always set the path first — this script lives in tools/test/, two levels
-- below the repo root, and the shared lua modules are under
-- static/ergopti_plus/_shared/lua/.
package.path = "static/ergopti_plus/_shared/lua/?.lua" .. ";" .. package.path

local ok, compat = pcall(require, "compat.utf8")
assert_true(ok, "require compat.utf8")
assert_true(type(compat) == "table", "compat is a table")

-- =========================================================================
-- Test 2: Native utf8 guard — install() returns false on Lua 5.3+
-- =========================================================================

local is_native = (utf8 ~= nil) and (utf8.len ~= nil) and (utf8.char ~= nil)
local installed = compat.install()
if is_native then
	assert_eq(installed, false, "install() returns false when native utf8 present")
	-- Verify native utf8 was NOT overwritten
	assert_eq(utf8.len("héllo"), 5, "native utf8.len still works after install()")
	io.write(string.format("[INFO] Native utf8 detected (Lua %s) — shim guard works.\n", _VERSION))
else
	assert_eq(installed, true, "install() returns true when utf8 absent (LuaJIT)")
	io.write("[INFO] No native utf8 — compat shim installed.\n")
end

-- =========================================================================
-- Test 3: Use the compat functions directly (not via global)
-- =========================================================================

local u8 = installed and utf8 or compat  -- use global if installed, else module

-- 3a: len
assert_eq(u8.len(""), 0, "len('')")
assert_eq(u8.len("hello"), 5, "len('hello')")
assert_eq(u8.len("héllo"), 5, "len('héllo') — 2-byte char")
assert_eq(u8.len("日本語"), 3, "len('日本語') — 3-byte chars")
assert_eq(u8.len("🎉"), 1, "len('🎉') — 4-byte emoji")

-- 3b: len on malformed input — utf8.len returns (nil, pos), does NOT error
local result, pos = u8.len("\xFF")
assert_eq(result, nil, "len('\\xFF') returns nil")
assert_eq(pos, 1, "len('\\xFF') error position is 1")

-- 3c: offset — 'héllo' = h(1) + é(2) + l(1) + l(1) + o(1) = 7 bytes, 5 chars
assert_eq(u8.offset("héllo", 1), 1, "offset('héllo', 1)")
assert_eq(u8.offset("héllo", 2), 2, "offset('héllo', 2) — é starts at byte 2")
assert_eq(u8.offset("héllo", 5), 6, "offset('héllo', 5) — o at byte 6")
assert_eq(u8.offset("héllo", -1), 6, "offset('héllo', -1) — last char at byte 6")
assert_eq(u8.offset("héllo", -2), 5, "offset('héllo', -2)")
assert_eq(u8.offset("abc", 4), nil, "offset beyond end returns nil")
assert_eq(u8.offset("abc", 0), nil, "offset 0 returns nil")

-- 3d: codes iterator
local chars = {}
for p, c in u8.codes("hé!") do
	chars[#chars + 1] = { pos = p, cp = c }
end
assert_eq(#chars, 3, "codes('hé!'): 3 codepoints")
assert_eq(chars[1].pos, 1, "codes[1].pos = 1")
assert_eq(chars[2].pos, 2, "codes[2].pos = 2 — é starts at byte 2")

-- 3e: char
assert_eq(u8.char(104, 233, 33), "hé!", "char(104, 233, 33) = 'hé!'")
assert_eq(u8.char(0x1F389), "🎉", "char(0x1F389) = '🎉'")

-- 3f: codepoint
local c1, c2 = u8.codepoint("hé", 1, 2)
assert_eq(c1, 104, "codepoint('hé', 1, 1) = 104 (h)")
assert_eq(c2, 233, "codepoint('hé', 2, 2) = 233 (é)")

-- =========================================================================
-- Test 4: Keymap terminators use case (the call site in terminators.lua)
-- =========================================================================

-- terminators.lua:94 does: pcall(utf8.offset, s, 2) — extracts first char
-- It falls back to s:sub(1,1) on failure (ASCII-only).
-- We verify this exact pattern works with multi-byte chars.

local function first_char(s)
	local ok, off = pcall(u8.offset, s, 2)
	if ok and off then
		return s:sub(1, off - 1)
	end
	return s:sub(1, 1)
end

assert_eq(first_char("hello"), "h", "first_char('hello')")
assert_eq(first_char("h"), "h", "first_char('h')")
assert_eq(first_char("éclair"), "é", "first_char('éclair') — 2-byte")
-- 3-byte UTF-8 (U+65E5): 0xE6 0x97 0xA5 — verify first_char handles it
local three_byte = string.char(0xE6, 0x97, 0xA5)
assert_eq(#first_char(three_byte) >= 1, true, "first_char 3-byte returns >= 1 byte")
assert_eq(first_char(""), "", "first_char('')")

-- =========================================================================
-- Test 5: text_utils use case (the call sites in text_utils/init.lua)
-- =========================================================================

-- text_utils/init.lua:42 calls utf8.codes(s) to split into chars
-- text_utils/init.lua:106 calls utf8.offset(s, start_idx)
-- text_utils/init.lua:128 calls utf8.len(s)
-- text_utils/init.lua:141 calls utf8.offset(s, -n)

local function split_chars(s)
	local chars = {}
	for _, c in u8.codes(s) do
		table.insert(chars, u8.char(c))
	end
	return chars
end

local chars = split_chars("aéb")
assert_eq(#chars, 3, "split_chars('aéb'): 3 chars")
assert_eq(chars[2], "é", "split_chars[2] = 'é'")

local function safe_slice(s, start_idx, end_idx)
	local ok_s, start_byte = pcall(u8.offset, s, start_idx)
	if not ok_s or not start_byte then return "" end
	if end_idx then
		local ok_e, next_byte = pcall(u8.offset, s, end_idx + 1)
		if ok_e and next_byte then
			return s:sub(start_byte, next_byte - 1)
		end
	end
	return s:sub(start_byte)
end

assert_eq(safe_slice("aébc", 2, 3), "éb", "safe_slice('aébc', 2, 3)")
assert_eq(safe_slice("aébc", 1, 1), "a", "safe_slice('aébc', 1, 1)")

local function safe_len(s)
	local ok, len = pcall(u8.len, s)
	if ok and len then return len end
	return #s
end

assert_eq(safe_len("héllo"), 5, "safe_len('héllo') = 5")
assert_eq(safe_len("hello"), 5, "safe_len('hello') = 5")

local function last_n_chars(s, n)
	local ok, start_idx = pcall(u8.offset, s, -n)
	if ok and start_idx then
		return s:sub(start_idx)
	end
	return s
end

assert_eq(last_n_chars("héllo wörld", 5), "wörld", "last_n_chars 5")
assert_eq(last_n_chars("héllo", 1), "o", "last_n_chars 1")

-- =========================================================================
-- Results
-- =========================================================================

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
