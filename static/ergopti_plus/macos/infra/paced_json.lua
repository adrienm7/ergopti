--- infra/paced_json.lua

--- ==============================================================================
--- MODULE: Paced JSON Encoder
--- DESCRIPTION:
--- Encodes a Lua value to JSON in pure Lua so a large dashboard payload can be
--- serialized between the pauses of an `infra.paced_job` instead of inside one
--- native `hs.json.encode` call that cannot yield.
---
--- FEATURES & RATIONALE:
--- 1. LuaSkin-compatible shapes: an empty table and a 1..n sequence encode as
---    arrays, every other table as an object with string keys, exactly as
---    `hs.json.encode` did for the same payloads.
--- 2. Fail fast: non-finite numbers, invalid UTF-8, and unsupported key or
---    value types raise instead of producing JSON the page cannot parse.
--- 3. Bounded memory: pieces are folded into chunks as they accumulate, so a
---    multi-megabyte payload never needs one table slot per token.
--- ==============================================================================

local M = {}

local utf8 = utf8





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Values encoded between two pause checks.
local VALUES_PER_PAUSE = 512

--- Pieces folded into one chunk string.
local PIECES_PER_CHUNK = 4096

--- Largest integer a double represents exactly; integral floats below it are
--- written without a fractional part, as NSJSONSerialization writes them.
local EXACT_INTEGER_LIMIT = 2 ^ 53

local ESCAPES = {
	["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}





-- ==========================
-- ==========================
-- ======= 2/ Scalars =======
-- ==========================
-- ==========================

local function escape_char(c)
	return ESCAPES[c] or string.format("\\u%04x", c:byte())
end

--- Encodes one string, refusing bytes the page could not decode.
--- @param s string Value.
--- @return string json
local function encode_string(s)
	if not utf8.len(s) then error("paced_json: string is not valid UTF-8", 0) end
	return '"' .. (s:gsub('[%c"\\]', escape_char)) .. '"'
end

--- Encodes one number with NSJSONSerialization's integral formatting.
--- @param n number Value.
--- @return string json
local function encode_number(n)
	if math.type(n) == "integer" then return string.format("%d", n) end
	if n ~= n or n == math.huge or n == -math.huge then
		error("paced_json: non-finite number", 0)
	end
	if n == math.floor(n) and math.abs(n) < EXACT_INTEGER_LIMIT then
		return string.format("%d", math.tointeger(n))
	end
	return string.format("%.17g", n)
end

--- Encodes one object key.
--- @param k any Key.
--- @return string json
local function encode_key(k)
	local kind = type(k)
	if kind == "string" then return encode_string(k) end
	if kind == "number" then return '"' .. encode_number(k) .. '"' end
	error("paced_json: unsupported key type " .. kind, 0)
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Encodes `value` to JSON, pausing through `pacer` while it works.
--- @param value any Table, string, number or boolean.
--- @param pacer table|nil Pacer from `infra.paced_job`; nil encodes in one go.
--- @return string json
function M.encode(value, pacer)
	local chunks, pieces, count, encoded = {}, {}, 0, 0

	local function emit(piece)
		count = count + 1
		pieces[count] = piece
		if count == PIECES_PER_CHUNK then
			chunks[#chunks + 1] = table.concat(pieces, "", 1, count)
			count = 0
		end
	end

	local encode_value
	encode_value = function(v)
		encoded = encoded + 1
		if pacer and encoded % VALUES_PER_PAUSE == 0 then pacer.pause() end
		local kind = type(v)
		if kind == "string" then emit(encode_string(v))
		elseif kind == "number" then emit(encode_number(v))
		elseif kind == "boolean" then emit(v and "true" or "false")
		elseif kind == "table" then
			local n = #v
			local keys = 0
			for _ in pairs(v) do keys = keys + 1 end
			if keys == 0 then
				emit("[]")
			elseif n == keys then
				emit("[")
				for i = 1, n do
					if i > 1 then emit(",") end
					encode_value(v[i])
				end
				emit("]")
			else
				emit("{")
				local first = true
				for k, item in pairs(v) do
					emit(first and "" or ",")
					first = false
					emit(encode_key(k))
					emit(":")
					encode_value(item)
				end
				emit("}")
			end
		else
			error("paced_json: unsupported value type " .. kind, 0)
		end
	end

	encode_value(value)
	chunks[#chunks + 1] = table.concat(pieces, "", 1, count)
	return table.concat(chunks)
end

return M
