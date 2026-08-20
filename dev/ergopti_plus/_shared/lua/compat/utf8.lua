--- _shared/lua/compat/utf8.lua


--- ==============================================================================

-- LuaJIT is 5.1-based: `unpack` is a global there and `table.unpack` is absent
-- unless the build enabled 5.2 compatibility, which the one CI and the Linux
-- daemon run does not. Resolved once here rather than at each call site, and
-- table-first so a 5.4 interpreter keeps using the modern spelling.
local table_unpack = table.unpack or unpack
--- MODULE: UTF-8 Compatibility Shim (for LuaJIT)
--- DESCRIPTION:
--- Pure-Lua reimplementation of Lua 5.3's built-in `utf8` library for runtimes
--- that do not bundle it (notably LuaJIT 2.x). Exposes the same surface:
--- len, offset, codes, char, codepoint — matching the Lua 5.3 semantics.
---
--- Install once from the daemon entry point BEFORE any shared module require:
---   require("compat.utf8").install()
---   -- now utf8.len / utf8.offset / utf8.codes / utf8.char work everywhere
---
--- FEATURES & RATIONALE:
--- 1. Pure Lua: no C extensions, no FFI — works on any Lua 5.1+ runtime.
--- 2. Correctness over speed: every function validates UTF-8 boundaries and
---    returns nil+error-pos on malformed sequences (matching Lua 5.3).
--- 3. Global install: `install()` sets `utf8` as a global so existing pcall-
---    guarded shared code (terminators, text_utils, toml_codec) needs zero changes.
--- ==============================================================================

local M = {}

-- UTF-8 codepoint byte pattern: leading byte followed by 0–3 continuation bytes.
local UTF8_CHAR = "[%z\\1-\\127\\194-\\244][\\128-\\191]*"

--- Returns the number of UTF-8 codepoints in s.
--- Returns nil, byte_position on malformed input (Lua 5.3 contract).
--- @param s string
--- @return number|nil
local function utf8_len(s)
	if type(s) ~= "string" then return nil, 0 end
	local n = 0
	local i = 1
	while i <= #s do
		local byte = s:byte(i)
		if not byte then return nil, i end
		local clen
		if     byte < 0x80 then clen = 1
		elseif byte < 0xC0 then return nil, i   -- continuation byte at start
		elseif byte < 0xE0 then clen = 2
		elseif byte < 0xF0 then clen = 3
		elseif byte < 0xF8 then clen = 4
		else return nil, i                       -- invalid leading byte
		end
		-- Validate continuation bytes
		for j = 1, clen - 1 do
			local cb = s:byte(i + j)
			if not cb or cb < 0x80 or cb >= 0xC0 then return nil, i + j end
		end
		i = i + clen
		n = n + 1
	end
	return n
end

--- Returns the byte position of the n-th codepoint in s (1-indexed).
--- Negative n counts from the end. Returns nil on out-of-range or malformed input.
--- @param s string
--- @param n number 1-based codepoint index (negative = from end).
--- @return number|nil
local function utf8_offset(s, n)
	if type(s) ~= "string" then return nil end
	if type(n) ~= "number" then return nil end
	if n == 0 then return nil end

	if n > 0 then
		local count = 0
		local i = 1
		while i <= #s do
			local byte = s:byte(i)
			if not byte then return nil end
			local clen
			if     byte < 0x80 then clen = 1
			elseif byte < 0xC0 then return nil
			elseif byte < 0xE0 then clen = 2
			elseif byte < 0xF0 then clen = 3
			elseif byte < 0xF8 then clen = 4
			else return nil
			end
			count = count + 1
			if count == n then return i end
			i = i + clen
		end
		return nil  -- n beyond end
	else
		-- Negative offset: count from the end
		local total = utf8_len(s)
		if not total then return nil end
		local target = total + n + 1
		if target <= 0 then return nil end
		return utf8_offset(s, target)
	end
end

--- Iterator: for p, c in utf8_codes(s) do … end
--- Yields (byte_position, codepoint_value) for each codepoint in s.
--- @param s string
--- @return function iterator
local function utf8_codes(s)
	if type(s) ~= "string" then return function() end end
	local i = 1
	return function()
		if i > #s then return nil end
		local byte = s:byte(i)
		if not byte then return nil end
		local clen, cp
		if     byte < 0x80 then clen, cp = 1, byte
		elseif byte < 0xC0 then return nil
		elseif byte < 0xE0 then
			clen = 2
			cp = (byte - 0xC0) * 0x40 + (s:byte(i+1) or 0) - 0x80
		elseif byte < 0xF0 then
			clen = 3
			cp = (byte - 0xE0) * 0x1000 + ((s:byte(i+1) or 0) - 0x80) * 0x40 + (s:byte(i+2) or 0) - 0x80
		elseif byte < 0xF8 then
			clen = 4
			cp = (byte - 0xF0) * 0x40000 + ((s:byte(i+1) or 0) - 0x80) * 0x1000
				+ ((s:byte(i+2) or 0) - 0x80) * 0x40 + (s:byte(i+3) or 0) - 0x80
		else
			return nil
		end
		local pos = i
		i = i + clen
		return pos, cp
	end
end

--- Encodes one or more codepoint integers into a UTF-8 string.
--- @param ... number Codepoint values.
--- @return string
local function utf8_char(...)
	local args = {...}
	local buf = {}
	for _, cp in ipairs(args) do
		if type(cp) ~= "number" or cp < 0 then
			error("bad argument #1 to 'char' (number expected, got " .. type(cp) .. ")")
		end
		-- LuaJIT has no native `//` floor-division operator (that's Lua 5.3+),
		-- so integer division is spelled out via math.floor() for portability.
		if cp < 0x80 then
			buf[#buf + 1] = string.char(cp)
		elseif cp < 0x800 then
			buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
		elseif cp < 0x10000 then
			buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
		elseif cp < 0x110000 then
			buf[#buf + 1] = string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
				0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
		else
			error("bad argument #1 to 'char' (value out of range)")
		end
	end
	return table.concat(buf)
end

--- Returns the codepoint values of the characters at positions i..j in s.
--- @param s string
--- @param i number Start position (default 1).
--- @param j number End position (default i).
--- @return ... number Codepoint values.
local function utf8_codepoint(s, i, j)
	if type(s) ~= "string" then return end
	i = i or 1
	j = j or i
	local results = {}
	local pos = 1
	local cp_idx = 0
	local iter = utf8_codes(s)
	while true do
		local p, cp = iter()
		if not p then break end
		cp_idx = cp_idx + 1
		if cp_idx >= i and cp_idx <= j then
			results[#results + 1] = cp
		end
		if cp_idx >= j then break end
	end
	return table_unpack(results)
end

--- Installs the shim as the global `utf8` table. Safe to call multiple times
--- (subsequent calls are no-ops). Must be called BEFORE any shared module that
--- uses utf8 is required.
function M.install()
	if utf8 and utf8.codes and utf8.char and utf8.offset and utf8.len then
		-- Native utf8 already present (Lua 5.3+) — don't overwrite.
		return false
	end
	_G.utf8 = {
		len       = utf8_len,
		offset    = utf8_offset,
		codes     = utf8_codes,
		char      = utf8_char,
		codepoint = utf8_codepoint,
	}
	return true
end

-- Export the functions so they can be used without installing globally
-- (useful in test contexts).
M.len       = utf8_len
M.offset    = utf8_offset
M.codes     = utf8_codes
M.char      = utf8_char
M.codepoint = utf8_codepoint

return M
