--- shared/lua/json.lua

--- ==============================================================================
--- MODULE: JSON Decoder (shared)
--- DESCRIPTION:
--- Minimal pure-Lua JSON decoder with no external dependencies. Supports all
--- standard JSON types: object, array, string (with escape sequences), number
--- (integer and float), boolean, and null.
---
--- FEATURES & RATIONALE:
--- 1. No dependencies: works under LuaJIT (5.1), Lua 5.4, and Hammerspoon's
---    embedded Lua runtime without any native extension.
--- 2. Null sentinel: JSON null decodes to the module-level JSON_NULL sentinel
---    object so callers can distinguish null from a missing key (which would
---    return nil in Lua).
--- 3. Error surfacing: malformed input raises a Lua error immediately so
---    callers using pcall() get a meaningful message rather than a silent nil.
--- ==============================================================================

local M = {}


--- Sentinel object returned for JSON null values.
--- Distinct from Lua nil so callers can tell "key exists but is null" apart from
--- "key does not exist". Check with `value == M.NULL`.
M.NULL = setmetatable({}, { __tostring = function() return "JSON_NULL" end })




-- =========================================
-- =========================================
-- ======= 1/ Internal Parser ==============
-- =========================================
-- =========================================

--- @class Parser
--- @field s string   Source JSON string.
--- @field i number   Current byte offset (1-based).
local Parser = {}
Parser.__index = Parser

--- Creates a new parser for the given string.
--- @param s string Raw JSON text.
--- @return Parser
local function new_parser(s)
	return setmetatable({ s = s, i = 1 }, Parser)
end

--- Returns the current character without advancing.
--- @return string|nil
function Parser:peek()
	return self.s:sub(self.i, self.i)
end

--- Returns the current character and advances the offset by one.
--- @return string|nil
function Parser:next()
	local ch = self.s:sub(self.i, self.i)
	self.i = self.i + 1
	return ch
end

--- Raises a parse error with the current position.
--- @param msg string Error description.
function Parser:err(msg)
	error(string.format("JSON parse error at byte %d: %s", self.i, msg), 2)
end

--- Skips ASCII whitespace (space, tab, newline, carriage return).
function Parser:skip_ws()
	while self.i <= #self.s do
		local b = self.s:byte(self.i)
		if b == 32 or b == 9 or b == 10 or b == 13 then
			self.i = self.i + 1
		else
			break
		end
	end
end

--- Expects and consumes a specific literal string.
--- @param lit string Expected text.
function Parser:expect(lit)
	local got = self.s:sub(self.i, self.i + #lit - 1)
	if got ~= lit then
		self:err(string.format("expected %q got %q", lit, got))
	end
	self.i = self.i + #lit
end

--- Decodes and returns the next JSON value.
--- @return any Decoded Lua value.
function Parser:value()
	self:skip_ws()
	local ch = self:peek()
	if ch == nil or ch == "" then self:err("unexpected end of input") end

	if ch == "{" then return self:object()
	elseif ch == "[" then return self:array()
	elseif ch == '"' then return self:string()
	elseif ch == "t" then self:expect("true");  return true
	elseif ch == "f" then self:expect("false"); return false
	elseif ch == "n" then self:expect("null");  return M.NULL
	elseif ch == "-" or (ch >= "0" and ch <= "9") then return self:number()
	else self:err(string.format("unexpected character %q", ch))
	end
end

--- Decodes a JSON object `{...}` into a Lua table (used as a Map).
--- @return table
function Parser:object()
	self:expect("{")
	local t = {}
	self:skip_ws()
	if self:peek() == "}" then self.i = self.i + 1; return t end
	while true do
		self:skip_ws()
		if self:peek() ~= '"' then self:err("expected string key") end
		local key = self:string()
		self:skip_ws()
		self:expect(":")
		local val = self:value()
		t[key] = val
		self:skip_ws()
		local sep = self:peek()
		if sep == "}" then self.i = self.i + 1; break
		elseif sep == "," then self.i = self.i + 1
		else self:err("expected ',' or '}'") end
	end
	return t
end

--- Decodes a JSON array `[...]` into a Lua sequence table.
--- @return table
function Parser:array()
	self:expect("[")
	local t = {}
	self:skip_ws()
	if self:peek() == "]" then self.i = self.i + 1; return t end
	while true do
		t[#t + 1] = self:value()
		self:skip_ws()
		local sep = self:peek()
		if sep == "]" then self.i = self.i + 1; break
		elseif sep == "," then self.i = self.i + 1
		else self:err("expected ',' or ']'") end
	end
	return t
end

--- Decodes a JSON string `"..."` with standard escape sequences.
--- @return string
function Parser:string()
	self:expect('"')
	local parts = {}
	while true do
		local ch = self:next()
		if ch == nil or ch == "" then self:err("unterminated string") end
		if ch == '"' then break
		elseif ch == "\\" then
			local esc = self:next()
			if     esc == '"'  then parts[#parts + 1] = '"'
			elseif esc == "\\" then parts[#parts + 1] = "\\"
			elseif esc == "/"  then parts[#parts + 1] = "/"
			elseif esc == "b"  then parts[#parts + 1] = "\b"
			elseif esc == "f"  then parts[#parts + 1] = "\f"
			elseif esc == "n"  then parts[#parts + 1] = "\n"
			elseif esc == "r"  then parts[#parts + 1] = "\r"
			elseif esc == "t"  then parts[#parts + 1] = "\t"
			elseif esc == "u"  then
				-- 4-hex-digit Unicode escape — decode to UTF-8.
				local hex = self.s:sub(self.i, self.i + 3)
				if #hex < 4 then self:err("incomplete \\u escape") end
				self.i = self.i + 4
				local cp = tonumber(hex, 16)
				if not cp then self:err("invalid \\u escape: " .. hex) end
				-- Encode codepoint as UTF-8.
				if cp < 0x80 then
					parts[#parts + 1] = string.char(cp)
				elseif cp < 0x800 then
					parts[#parts + 1] = string.char(
						0xC0 + math.floor(cp / 64),
						0x80 + (cp % 64))
				else
					parts[#parts + 1] = string.char(
						0xE0 + math.floor(cp / 4096),
						0x80 + math.floor((cp % 4096) / 64),
						0x80 + (cp % 64))
				end
			else
				self:err(string.format("unknown escape \\%s", esc))
			end
		else
			parts[#parts + 1] = ch
		end
	end
	return table.concat(parts)
end

--- Decodes a JSON number (integer or float).
--- @return number
function Parser:number()
	local start = self.i
	-- Optional leading minus.
	if self:peek() == "-" then self.i = self.i + 1 end
	-- Integer part.
	while self.i <= #self.s do
		local b = self.s:byte(self.i)
		if b >= 48 and b <= 57 then self.i = self.i + 1
		else break end
	end
	-- Optional fractional part.
	if self:peek() == "." then
		self.i = self.i + 1
		while self.i <= #self.s do
			local b = self.s:byte(self.i)
			if b >= 48 and b <= 57 then self.i = self.i + 1
			else break end
		end
	end
	-- Optional exponent.
	local ep = self:peek()
	if ep == "e" or ep == "E" then
		self.i = self.i + 1
		local sp = self:peek()
		if sp == "+" or sp == "-" then self.i = self.i + 1 end
		while self.i <= #self.s do
			local b = self.s:byte(self.i)
			if b >= 48 and b <= 57 then self.i = self.i + 1
			else break end
		end
	end
	local raw = self.s:sub(start, self.i - 1)
	local n = tonumber(raw)
	if n == nil then self:err("invalid number: " .. raw) end
	return n
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Decodes a JSON string and returns the corresponding Lua value.
--- JSON null becomes M.NULL; objects become tables keyed by string; arrays
--- become sequence tables. Raises a Lua error on malformed input.
--- @param s string Raw JSON text.
--- @return any Decoded Lua value.
function M.decode(s)
	if type(s) ~= "string" then
		error("json.decode: expected string, got " .. type(s), 2)
	end
	local p = new_parser(s)
	local v = p:value()
	p:skip_ws()
	if p.i <= #s then
		p:err("trailing garbage after JSON value")
	end
	return v
end

return M
