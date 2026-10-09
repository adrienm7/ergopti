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

-- Explicit lossless values stay distinguishable without changing legacy tables.
local ARRAY_VALUES = setmetatable({}, { __mode = "k" })
local LOSSLESS_NULL = setmetatable({}, {
	__newindex = function() error("JSON null is immutable", 2) end,
	__metatable = false,
})

local function array_length(value)
	if type(value) ~= "table" or value == LOSSLESS_NULL then return nil end
	local count = 0
	for index in pairs(value) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return nil end
		count = count + 1
	end
	for index = 1, count do if rawget(value, index) == nil then return nil end end
	return count
end

--- Reports whether a value retains an explicit JSON array identity.
--- @param value any
--- @return boolean
function M.is_array(value) return type(value) == "table" and ARRAY_VALUES[value] == true end

--- Reports whether a value is the explicit lossless JSON null token.
--- @param value any
--- @return boolean
function M.is_null(value) return value == LOSSLESS_NULL end

--- Copies dense values into an explicit JSON array, including an empty array.
--- @param values table Dense values to copy.
--- @return table array Detached outer array; child values retain their identities.
function M.array(values)
	local count = assert(array_length(values), "JSON arrays require dense numeric values")
	local array = {}
	for index = 1, count do array[index] = values[index] end
	ARRAY_VALUES[array] = true
	return array
end

-- What a lone UTF-16 surrogate decodes to: it names no character, and emitting
-- it as-is would produce bytes no UTF-8 reader accepts.
local REPLACEMENT_CHARACTER = 0xFFFD

-- The short escapes JSON defines; every other control character is \u00XX.
local CONTROL_ESCAPES = { ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- Quotes a string as JSON, escaping every character JSON forbids raw.
--- @param value string
--- @return string
function M.quote(value)
	local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[%z\1-\31\127]", function(ch)
		return CONTROL_ESCAPES[ch] or string.format("\\u%04x", ch:byte())
	end)
	return '"' .. escaped .. '"'
end

-- ============================================================================
-- 1. JSON decoder (recursive descent)
-- ============================================================================

--- Decodes a JSON string into a Lua value.
--- Handles objects, arrays, strings, numbers, booleans, and null.
--- @param raw string JSON string.
--- @return any|nil Decoded Lua value, or nil on parse failure.
local function decode(raw, lossless, source_members)
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

	local NULL = lossless and LOSSLESS_NULL or {}

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
					if lossless and not hex:match("^%x%x%x%x$") then return nil end
					local code = tonumber(hex, 16)
					if not code then return nil end
					pos = pos + 4
					-- A character above the Basic Multilingual Plane arrives as a
					-- surrogate pair; each half alone is not a character.
					if code >= 0xD800 and code <= 0xDBFF then
						local low = raw:sub(pos, pos + 1) == "\\u" and tonumber(raw:sub(pos + 2, pos + 5), 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							pos = pos + 6
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
						else
							if lossless then return nil end
							code = REPLACEMENT_CHARACTER
						end
					elseif code >= 0xDC00 and code <= 0xDFFF then
						if lossless then return nil end
						code = REPLACEMENT_CHARACTER
					end
					res[#res + 1] = utf8_lib.char(code)
				else
					if lossless then return nil end
					res[#res + 1] = esc
				end
			else
				if lossless and ch:byte() < 32 then return nil end
				res[#res + 1] = ch
			end
		end
		return nil
	end

	parse_value = function(is_root)
		local c = skip_ws()
		if not c then return nil end

		if c == "{" then
			local recording = source_members and is_root
			if recording then source_members.open = pos end
			pos = pos + 1
			local obj = {}
			local member_first = pos
			if skip_ws() == "}" then
				if recording then source_members.close = pos end
				pos = pos + 1
				return obj
			end
			while true do
				if skip_ws() ~= '"' then return nil end
				local key = parse_string()
				if type(key) ~= "string" then return nil end
				if skip_ws() ~= ":" then return nil end
				pos = pos + 1
				if recording then skip_ws() end
				local value_first = recording and pos
				local val = parse_value()
				local value_last = recording and pos - 1
				if val == nil then return nil end
				if lossless and obj[key] ~= nil then return nil end
				obj[key] = (val == NULL) and nil or val
				local sep = skip_ws()
				if recording then
					source_members[#source_members + 1] = {
						key = key, first = member_first, last = pos - 1,
						value_first = value_first, value_last = value_last,
					}
				end
				if sep == "}" then
					if recording then source_members.close = pos end
					pos = pos + 1
					return obj
				end
				if sep ~= "," then return nil end
				pos = pos + 1
				member_first = pos
			end
		end

		if c == "[" then
			pos = pos + 1
			local arr = {}
			if lossless then ARRAY_VALUES[arr] = true end
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
			local token = raw:sub(s, e)
			local number = tonumber(token)
			if lossless then
				local mantissa, exponent = token:match("^(.-)[eE](.*)$")
				if exponent and not exponent:match("^[+-]?%d+$") then return nil end
				mantissa = mantissa or token
				if not (mantissa:match("^%-?0$") or mantissa:match("^%-?[1-9]%d*$")
					or mantissa:match("^%-?0%.%d+$") or mantissa:match("^%-?[1-9]%d*%.%d+$")) then return nil end
				if not number or number == math.huge or number == -math.huge then return nil end
			end
			return number
		end

		return nil
	end

	local ok, result = pcall(parse_value, true)
	if not ok then return nil end
	if result == nil or skip_ws() ~= nil then return nil end
	return result == NULL and nil or result
end

--- Decodes JSON with the established untagged-table behavior.
--- @param raw string
--- @return any|nil Decoded legacy value, or nil on failure.
function M.decode(raw) return decode(raw, false) end

--- Decodes explicit JSON identities without altering the default decoder.
--- Rejects malformed or ambiguous values instead of normalizing their content.
--- @param raw string
--- @return any|nil Tagged arrays/null and ordinary objects, or nil on failure.
function M.decode_lossless(raw) return decode(raw, true) end

-- ============================================================================
-- 2. JSON encoder
-- ============================================================================

--- Encodes a Lua value to a minimal JSON string.
--- Handles nil, boolean, number, string, and table.
--- @param val any Lua value.
--- @return string|nil JSON string, or nil on unsupported type.
function M.encode(val)
	if val == nil or val == LOSSLESS_NULL then return "null" end
	local t = type(val)
	if t == "boolean" then return val and "true" or "false" end
	if t == "number" then
		if val ~= val then return "null" end
		if val == math.huge or val == -math.huge then return "null" end
		return string.format("%.17g", val):gsub("%.%d+", function(frac)
			return (frac:gsub("0+$", ""))
		end):gsub("%.$", "")
	end
	if t == "string" then return M.quote(val) end
	if t == "table" then
		if ARRAY_VALUES[val] then
			local count = array_length(val)
			if not count then return nil end
			local parts = {}
			for index = 1, count do
				local encoded = M.encode(val[index])
				if encoded == nil then return nil end
				parts[index] = encoded
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
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

-- ============================================================================
-- 3. Source-bound root object edits
-- ============================================================================

-- Source authority stays private to this codec instance. Returned decoded values
-- never alias these spans; modifying a model cannot authorize a different source.
local ROOT_SOURCES = setmetatable({}, { __mode = "k" })
local SOURCE_RECEIPT_META = {
	__newindex = function() error("JSON source receipts are immutable", 2) end,
	__metatable = false,
}

--- Decodes a strict root object and retains its exact member spans privately.
--- Uses the same lossless parser, including decoded-key duplicate rejection.
--- The opaque receipt proves this source parsed; it is NOT a file-liveness,
--- ownership, generation, backup, or publication receipt. Callers must admit the
--- actual current file and native owner independently before publishing edits.
--- @param raw string Exact JSON source.
--- @return table|nil model Lossless decoded object; numbers keep legacy Lua types.
--- @return table|string receipt Opaque source receipt, or a bounded diagnostic.
local function decode_root_object_source(raw)
	local members = {}
	local model = decode(raw, true, members)
	if model == nil or not members.open or not members.close then
		return nil, "JSON source requires a strict root object"
	end
	local receipt = setmetatable({}, SOURCE_RECEIPT_META)
	ROOT_SOURCES[receipt] = { raw = raw, members = members }
	return model, receipt
end

function M.decode_root_object_source(raw) return decode_root_object_source(raw) end

-- Strict edit values use existing JSON identities without changing the legacy
-- encoder's permissive behavior. Reject values it otherwise drops/normalizes.
local function edit_kind(value)
	if rawequal(value, LOSSLESS_NULL) then return "null" end
	local kind = type(value)
	if kind ~= "table" then return kind end
	if getmetatable(value) ~= nil then return nil end
	local count = array_length(value)
	if ARRAY_VALUES[value] then return count and "array" or nil end
	if count and count > 0 then return "array" end
	for key in pairs(value) do if type(key) ~= "string" then return nil end end
	return "object"
end

local function valid_edit_value(value, visiting)
	local kind = edit_kind(value)
	if kind == "null" or kind == "string" or kind == "boolean" then return true end
	if kind == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
	if kind ~= "array" and kind ~= "object" then return false end
	if visiting[value] then return false end
	visiting[value] = true
	for _, child in pairs(value) do
		if not valid_edit_value(child, visiting) then visiting[value] = nil; return false end
	end
	visiting[value] = nil
	return true
end

local function same_edit_value(left, right)
	local kind = edit_kind(left)
	if kind ~= edit_kind(right) then return false end
	if kind ~= "array" and kind ~= "object" then
		if kind == "number" and left == 0 and right == 0 then return 1 / left == 1 / right end
		return left == right
	end
	for key, value in pairs(left) do
		local other = rawget(right, key)
		if other == nil or not same_edit_value(value, other) then return false end
	end
	for key in pairs(right) do if rawget(left, key) == nil then return false end end
	return true
end

local function prepare_edit_cells(updates)
	if type(updates) ~= "table" or getmetatable(updates) ~= nil or ARRAY_VALUES[updates] then return nil end
	local prepared = {}
	for key, cell in pairs(updates) do
		if type(key) ~= "string" or type(cell) ~= "table" or getmetatable(cell) ~= nil
			or ARRAY_VALUES[cell] or type(rawget(cell, "present")) ~= "boolean" then return nil end
		for field in pairs(cell) do if field ~= "present" and field ~= "value" then return nil end end
		local value = rawget(cell, "value")
		if not cell.present then
			if value ~= nil then return nil end
			prepared[key] = { present = false }
		else
			if not valid_edit_value(value, {}) then return nil end
			local ok, encoded = pcall(M.encode, value)
			if not ok or type(encoded) ~= "string" then return nil end
			local reparsed = decode(encoded, true)
			if reparsed == nil or not same_edit_value(value, reparsed) then return nil end
			-- Keep the independent reparsed copy, never caller-owned mutable values.
			prepared[key] = { present = true, value = reparsed, encoded = encoded }
		end
	end
	return prepared
end

--- Splices explicitly owned root members while retaining every unowned byte.
--- Updates are a string-keyed map of {present=true,value=...} or {present=false}.
--- Use the lossless null token for JSON null; nil is never an implicit deletion.
--- Existing member keys/trivia/order survive replacement; new keys append in
--- decoded-key order. Deletion removes that member's trivia and one delimiter.
--- The candidate is strictly reparsed and checked against all requested cells.
--- Receipts are codec-instance-local and reusable; no native IO occurs here.
--- @param receipt table Authentic receipt from decode_root_object_source.
--- @param updates table Explicit owned root-member edits.
--- @return string|nil source Candidate JSON source, or nil on refusal.
--- @return table|string model Reparsed model, or a bounded diagnostic.
--- @return table|nil receipt Fresh candidate source receipt on success.
function M.splice_root_object_source(receipt, updates)
	local source = type(receipt) == "table" and ROOT_SOURCES[receipt]
	if not source or next(receipt) ~= nil then return nil, "Invalid JSON source receipt" end
	local admitted, edits = pcall(prepare_edit_cells, updates)
	if not admitted or not edits then return nil, "Invalid JSON source update cells" end
	local raw, members = source.raw, source.members
	local parts, seen = {}, {}
	for _, member in ipairs(members) do
		local cell = edits[member.key]
		seen[member.key] = true
		if cell == nil then
			parts[#parts + 1] = raw:sub(member.first, member.last)
		elseif cell.present then
			parts[#parts + 1] = raw:sub(member.first, member.value_first - 1)
				.. cell.encoded .. raw:sub(member.value_last + 1, member.last)
		end
	end
	local appended = {}
	for key, cell in pairs(edits) do if not seen[key] and cell.present then appended[#appended + 1] = key end end
	table.sort(appended)
	for _, key in ipairs(appended) do
		local quoted, key_source = pcall(M.quote, key)
		if not quoted or type(key_source) ~= "string" then return nil, "JSON source key encoding failed" end
		parts[#parts + 1] = key_source .. ":" .. edits[key].encoded
	end
	local inner = table.concat(parts, ",")
	if #members == 0 then inner = raw:sub(members.open + 1, members.close - 1) .. inner end
	local candidate = raw:sub(1, members.open) .. inner .. raw:sub(members.close)
	local model, candidate_receipt = decode_root_object_source(candidate)
	if not model then return nil, "JSON source candidate failed strict reparse" end
	local original = decode(raw, true)
	for key, value in pairs(original) do
		local cell = edits[key]
		if cell == nil and not same_edit_value(value, rawget(model, key)) then
			return nil, "JSON source candidate changed an unowned member"
		end
	end
	for key, cell in pairs(edits) do
		local value = rawget(model, key)
		if (cell.present and (value == nil or not same_edit_value(cell.value, value)))
			or (not cell.present and value ~= nil) then return nil, "JSON source candidate disagrees with update cells" end
	end
	for key in pairs(model) do
		if rawget(original, key) == nil and not (edits[key] and edits[key].present) then
			return nil, "JSON source candidate introduced an unowned member"
		end
	end
	return candidate, model, candidate_receipt
end

return M
