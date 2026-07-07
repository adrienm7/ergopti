--- _shared/lua/keylogger/utils.lua
---
--- Pure, driver-agnostic keylogger utility functions extracted from the macOS
--- aggregator (modules/keylogger/aggregator/core.lua) so they can be shared
--- by macOS, AHK (hand-port), and Linux without duplicating the logic.
---
--- This module has ZERO driver dependencies — no hs, no Logger, no Paths,
--- no Timings, no io. It can be require()d by any Lua runtime (LuaJIT, etc.).

local M = {}

-- ============================================================================
-- 1. Table helpers
-- ============================================================================

--- Get-or-create a sub-table at `tbl[k]`. Returns the existing or freshly
--- inserted sub-table. The optional `default` table is shallow-copied as the
--- initial value when the key is absent.
---
--- This is the most-used helper in the aggregator — every walk function calls
--- it to lazily initialise per-key accumulator rows in the batch.
---
--- @param tbl     table   Parent table.
--- @param k       any     Key to look up.
--- @param default table|nil  Default value if absent (reference, not deep-copied).
--- @return table  The existing or freshly-inserted sub-table.
function M.gc(tbl, k, default)
	local v = tbl[k]
	if not v then
		v = default or {}
		tbl[k] = v
	end
	return v
end

-- ============================================================================
-- 2. UTF-8 character utilities
-- ============================================================================

--- UTF-8-aware character classifier. Categorises a single (possibly multi-byte)
--- character into one of five buckets used by the typing-metrics pipeline.
---
--- @param c string  A single character (may be 1-4 bytes in UTF-8).
--- @return string   One of "space", "digit", "letter", "punct", "other".
function M.char_class(c)
	if not c or #c == 0 then return "other" end
	if c == " " or c == "\t" or c == "\n" or c == "\194\160" or c == "\226\128\175" then
		return "space"
	end
	local b = c:byte(1)
	if b >= 48 and b <= 57 then return "digit" end
	if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return "letter" end
	if b >= 0xC2 and b <= 0xCF then return "letter" end
	if b >= 0xD0 and b <= 0xD7 then return "letter" end
	if c:sub(1, 1) == "[" and c:sub(-1) == "]" then return "other" end
	if c:match("^[%p<>=+*/\\\\|%-]$") then return "punct" end
	return "other"
end

--- Pop the last UTF-8 codepoint off a string. Used by the backspace handler to
--- truncate the in-progress word buffer one logical character at a time.
---
--- Relies on `utf8.offset` (Lua 5.3+ built-in, or the compat shim on LuaJIT).
--- Falls back to raw byte truncation (`s:sub(1, -2)`) on malformed input so a
--- corrupt string never crashes the aggregator.
---
--- @param s string  Input string.
--- @return string   String with the last codepoint removed.
function M.pop_utf8(s)
	if not s or #s == 0 then return s or "" end
	local ok, off = pcall(utf8.offset, s, -1)
	if not ok or not off then return s:sub(1, -2) end
	return s:sub(1, off - 1)
end

return M
