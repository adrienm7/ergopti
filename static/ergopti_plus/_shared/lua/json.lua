--- _shared/lua/json.lua
---
--- Minimal pure-Lua JSON encoder/decoder shared across all Lua drivers.
--- No external dependencies — runs on Lua 5.1+, LuaJIT 2.x, and Lua 5.4.
---
--- Used by: Linux E2E harness (corpus vectors), Linux locale module
--- (fallback decoder), macOS locale module (fallback decoder), and any
--- future driver that needs to read _shared JSON data without an OS JSON lib.

-- Resolved here rather than assumed to be a global. LuaJIT has no utf8 table, and
-- a shared module cannot depend on its caller having installed the compat shim —
-- it does not know its callers. The decoder used to guard with `utf8 and … or
-- string.char(code)`, which looks safe and is not: string.char refuses anything
-- above 255 and truncates 128-255 to one byte, so every \uXXXX escape outside
-- ASCII decoded to the wrong character on the one interpreter this driver runs.
local utf8_lib = (type(utf8) == "table" and utf8.char) and utf8 or require("compat.utf8")

local M = {}

-- ============================================================================
-- 1. JSON decoder (recursive descent)
-- ============================================================================

--- Decodes a JSON string into a Lua value.
--- Handles objects, arrays, strings, numbers, booleans, and null.
--- @param raw string JSON string.
--- @return any|nil Decoded Lua value, or nil on parse failure.
function M.decode(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local pos = 1

	local function skip_ws()
		while pos <= #raw do
			local c = raw:sub(pos, pos)
			if c == " " or c == "\t" or c == "\r" or c == "\n" then
				pos = pos + 1
			else
				return c
			end
		end
		return nil
	end

	local NULL = {}

	local parse_value  -- forward decl

	local function parse_string()
		if raw:sub(pos, pos) ~= '"' then return nil end
		pos = pos + 1
		local res = {}
		while pos <= #raw do
			local ch = raw:sub(pos, pos)
			pos = pos + 1
			if ch == '"' then return table.concat(res) end
			if ch == "\\" then
				local esc = raw:sub(pos, pos)
				pos = pos + 1
				if     esc == '"'  then res[#res + 1] = '"'
				elseif esc == "\\" then res[#res + 1] = "\\"
				elseif esc == "/"  then res[#res + 1] = "/"
				elseif esc == "b"  then res[#res + 1] = "\b"
				elseif esc == "f"  then res[#res + 1] = "\f"
				elseif esc == "n"  then res[#res + 1] = "\n"
				elseif esc == "r"  then res[#res + 1] = "\r"
				elseif esc == "t"  then res[#res + 1] = "\t"
				elseif esc == "u" then
					local hex = raw:sub(pos, pos + 3)
					pos = pos + 4
					local code = tonumber(hex, 16)
					if code and code >= 32 then
						res[#res + 1] = utf8_lib.char(code)
					end
				else
					res[#res + 1] = esc
				end
			else
				res[#res + 1] = ch
			end
		end
		return nil
	end

	parse_value = function()
		local c = skip_ws()
		if not c then return nil end

		if c == "{" then
			pos = pos + 1
			local obj = {}
			if skip_ws() == "}" then pos = pos + 1; return obj end
			while true do
				if skip_ws() ~= '"' then return nil end
				local key = parse_string()
				if type(key) ~= "string" then return nil end
				if skip_ws() ~= ":" then return nil end
				pos = pos + 1
				local val = parse_value()
				if val == nil then return nil end
				obj[key] = (val == NULL) and nil or val
				local sep = skip_ws()
				if sep == "}" then pos = pos + 1; return obj end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		if c == "[" then
			pos = pos + 1
			local arr = {}
			if skip_ws() == "]" then pos = pos + 1; return arr end
			while true do
				local val = parse_value()
				if val == nil then return nil end
				table.insert(arr, val == NULL and nil or val)
				local sep = skip_ws()
				if sep == "]" then pos = pos + 1; return arr end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		if c == '"' then return parse_string() end

		if c == "t" and raw:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true end
		if c == "f" and raw:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
		if c == "n" and raw:sub(pos, pos + 3) == "null"  then pos = pos + 4; return NULL end

		local s, e = raw:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if s == pos then
			pos = e + 1
			return tonumber(raw:sub(s, e))
		end

		return nil
	end

	local ok, result = pcall(parse_value)
	if not ok then return nil end
	if result == nil or skip_ws() ~= nil then return nil end
	return result == NULL and nil or result
end

-- ============================================================================
-- 2. JSON encoder
-- ============================================================================

--- Encodes a Lua value to a minimal JSON string.
--- Handles nil, boolean, number, string, and table.
--- @param val any Lua value.
--- @return string|nil JSON string, or nil on unsupported type.
function M.encode(val)
	if val == nil then return "null" end
	local t = type(val)
	if t == "boolean" then return val and "true" or "false" end
	if t == "number" then
		if val ~= val then return "null" end
		if val == math.huge or val == -math.huge then return "null" end
		return string.format("%.17g", val):gsub("%.%d+", function(frac)
			return (frac:gsub("0+$", ""))
		end):gsub("%.$", "")
	end
	if t == "string" then
		local escaped = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
		return '"' .. escaped .. '"'
	end
	if t == "table" then
		local is_array = true
		local max_idx = 0
		for k in pairs(val) do
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then is_array = false; break end
			if k > max_idx then max_idx = k end
		end
		if is_array and max_idx > 0 then
			local parts = {}
			for i = 1, max_idx do
				parts[i] = M.encode(val[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, v in pairs(val) do
			if type(k) == "string" then
				parts[#parts + 1] = M.encode(k) .. ":" .. M.encode(v)
			end
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return nil
end

return M
