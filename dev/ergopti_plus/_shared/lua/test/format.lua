--- _shared/lua/test/format.lua

--- ==============================================================================
--- MODULE: Test Format Helpers (Shared)
--- DESCRIPTION:
--- Pure-Lua value formatting and stack-trace helpers shared by the Linux and
--- macOS test suites. Every driver that ships a `describe`/`it` harness should
--- require this module instead of copy-pasting `inspect()` or `_caller_site`.
---
--- FEATURES & RATIONALE:
--- 1. inspect(v): pretty-prints any Lua value into a single-line representation
---    suitable for assertion error messages. Tables are expanded 3 levels deep
---    with cycle detection. No more `table: 0x1a2b3c` in CI failure logs.
--- 2. caller_site(skip_pattern, level): walks the debug stack, finds the first
---    frame whose source path DOES NOT match `skip_pattern`, and returns
---    `"file:line"`. Each driver passes its own helpers-file pattern so the
---    returned site points at the TEST file, not the assertion helper.
--- 3. fail_msg(msg, skip_pattern): convenience wrapper — calls caller_site()
---    at level 3 (one extra frame for the fail_msg call itself) and prepends
---    the file:line to `msg`.
--- 4. Zero dependencies: no hs.*, no file I/O — works under LuaJIT 2.x and
---    plain Lua 5.4 equally.
--- ==============================================================================





-- ============================
-- ============================
-- ======= 1/ inspect() =======
-- ============================
-- ============================

--- Pretty-prints any Lua value (string, number, boolean, nil, table, function,
--- thread, userdata) into a single-line representation. Tables are expanded up
--- to 3 levels deep; beyond that `{…}` is shown. Cycles are detected and
--- rendered as `[cyclic]`. Strings longer than 120 chars are truncated.
---
--- @param v     any   Value to format.
--- @param depth number Internal recursion counter (omit on first call).
--- @param seen  table  Cycle-detection weak set (omit on first call).
--- @return string Single-line representation.
local function _inspect(v, depth, seen)
	depth = depth or 0
	if depth > 2 then return "{…}" end
	if type(v) == "string" then
		if #v > 120 then return string.format("%q", v:sub(1, 117) .. "...") end
		return string.format("%q", v)
	end
	if type(v) == "number" then return tostring(v) end
	if type(v) == "boolean" then return v and "true" or "false" end
	if v == nil then return "nil" end
	if type(v) == "function" then return "<function>" end
	if type(v) == "thread" then return "<thread>" end
	if type(v) == "userdata" then return "<userdata>" end
	if type(v) ~= "table" then return tostring(v) end

	seen = seen or {}
	if seen[v] then return "[cyclic]" end
	seen[v] = true

	local parts = {}
	local count = 0
	for k, val in pairs(v) do
		count = count + 1
		if count > 20 then parts[#parts + 1] = "…"; break end
		local key_fmt
		if type(k) == "string" and k:match("^[%a_][%w_]*$") then
			key_fmt = k
		else
			key_fmt = "[" .. _inspect(k, depth + 1, seen) .. "]"
		end
		parts[#parts + 1] = key_fmt .. "=" .. _inspect(val, depth + 1, seen)
	end
	seen[v] = nil
	return "{" .. table.concat(parts, " ") .. "}"
end





-- ================================
-- ================================
-- ======= 2/ caller_site() =======
-- ================================
-- ================================

--- Walks the debug stack looking for the first frame whose source path does
--- NOT match `skip_pattern`. Returns `"file:line"` pointing at the caller's
--- own test file, not the assertion helper.
---
--- @param skip_pattern string Lua pattern matching the helpers-file source path
---                      (e.g. `"helpers%.lua$"` for Linux, `"helpers[/\\\\]init%.lua$"`
---                      for macOS).
--- @param level         number Starting stack level (default 2 = immediate caller).
--- @return string file:line pair, or "" if unresolvable.
--- Finds the first stack frame that is not part of the test harness itself.
---
--- `skip_pattern` may be one Lua pattern or a LIST of them. The list form exists
--- because the assertion bodies moved into their own shared file: with a single
--- pattern only the harness frame was skipped, so every failure reported
--- `assertions.lua:57` instead of the line of the test that actually failed —
--- diagnostics pointing at the assertion library rather than the assertion.
local function _caller_site(skip_pattern, level)
	level = level or 2
	local patterns = type(skip_pattern) == "table" and skip_pattern or { skip_pattern }
	local function skipped(src)
		for _, pat in ipairs(patterns) do
			if src:match(pat) then return true end
		end
		return false
	end
	for lvl = level, level + 10 do
		local info = debug.getinfo(lvl, "Sl")
		if info and info.source then
			local src = info.source:gsub("^@", "")
			if not skipped(src) then
				local fname = src:match("([^/\\]+)$") or src
				return fname .. ":" .. (info.currentline or "?")
			end
		end
	end
	return ""
end





-- =============================
-- =============================
-- ======= 3/ fail_msg() =======
-- =============================
-- =============================

--- Formats a failure message with the test's file:line prefix.
--- Calls _caller_site at level 3 (one extra for this function itself).
---
--- @param msg          string Assertion message.
--- @param skip_pattern string Lua pattern passed to _caller_site.
--- @return string Formatted message like `"test.lua:42: assertion reason"`.
local function _fail_msg(msg, skip_pattern)
	local site = _caller_site(skip_pattern, 3)
	if site ~= "" then
		return site .. ": " .. msg
	end
	return msg
end





-- ===============================
-- ===============================
-- ======= 4/ deep_equal() =======
-- ===============================
-- ===============================

--- Deep structural equality. Tables are compared key-by-key recursively;
--- non-table values use `==`. Handles different key sets (checks both
--- directions). Does NOT handle `__eq` metamethods (not needed for tests).
--- @param a any First value.
--- @param b any Second value.
--- @return boolean true if structurally equal.
local function _deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not _deep_equal(v, b[k]) then return false end
	end
	for k, v in pairs(b) do
		if not _deep_equal(v, a[k]) then return false end
	end
	return true
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

local M = {}

--- Pretty-print a value. Public alias for _inspect.
--- Usage: helpers.inspect(some_table)
M.inspect = _inspect

--- Deep structural equality.
--- Usage: if helpers.deep_equal(a, b) then ... end
M.deep_equal = _deep_equal

--- Returns a fail_msg() closure bound to a specific skip_pattern.
--- Usage in driver helpers:
---   local fmt = require("test.format")
---   local _fail = fmt.fail_msg_for("helpers%.lua$")   -- Linux
---   local _fail = fmt.fail_msg_for("helpers[/\\\\]init%.lua$")  -- macOS
---   -- then: error(_fail("expected X, got Y"), 0)
--- @param skip_pattern string Lua pattern matching the helpers file.
--- @return function(msg) -> string
function M.fail_msg_for(skip_pattern)
	return function(msg)
		return _fail_msg(msg, skip_pattern)
	end
end

return M
