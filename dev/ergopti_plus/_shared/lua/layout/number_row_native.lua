-- _shared/lua/layout/number_row_native.lua
-- Native level selection never turns an action or a dead state into text.

local Policy = require("layout.number_row_policy")
local utf8_lib = (type(utf8) == "table" and type(utf8.len) == "function") and utf8 or require("compat.utf8")
local M = {}
M.POSITIONS = 10
M.LEVELS = 40
M.MAX_TEXT_BYTES = 1024

local function integer(value, maximum)
	return type(value) == "number" and value >= 0 and value <= maximum and value % 1 == 0
end

local function dense(values, count)
	if type(values) ~= "table" or #values ~= count then return false end
	local found = 0
	for key in pairs(values) do
		if not integer(key, count) or key == 0 then return false end
		found = found + 1
	end
	return found == count
end

local function text(value)
	if type(value) ~= "string" or #value > M.MAX_TEXT_BYTES or value:find("\0", 1, true) then return false end
	local ok, length = pcall(utf8_lib.len, value)
	return ok and length ~= nil
end

--- Validates native typed action parameters, including empty-output dead keys.
--- The source adapter must separately attest its actual issuer and generation.
function M.levels(platform, rows, codes)
	if (platform ~= "hs" and platform ~= "linux") or not dense(rows, M.LEVELS)
		or not dense(codes, M.POSITIONS) then return nil end
	local seen, result = {}, { [false] = {}, [true] = {} }
	for _, code in ipairs(codes) do
		if not integer(code, platform == "hs" and 127 or 767) or (platform == "linux" and code == 0) or seen[code] then return nil end
		seen[code] = true
	end
	for index, row in ipairs(rows) do
		local caps, shifted, position = index > 20, math.floor((index - 1) / 10) % 2 == 1, (index - 1) % 10 + 1
		if type(row) ~= "table" or row.code ~= codes[position] or row.caps ~= caps or row.shift ~= shifted
			or not text(row.text) then return nil end
		local dead, action
		if platform == "hs" then
			if not integer(row.dead_state, 4294967295) then return nil end
			dead, action = row.dead_state ~= 0, { dead_state = row.dead_state }
		else
			if not integer(row.keysym, 4294967295) or type(row.dead) ~= "boolean" then return nil end
			if row.dead and row.keysym == 0 then return nil end
			dead, action = row.dead, { keysym = row.keysym, dead = row.dead }
		end
		local pair = result[caps][position] or { code = row.code, digit = tostring(position % 10) }
		result[caps][position] = pair
		pair[shifted and "shift" or "plain"] = { code = row.code, caps = caps,
			shift = shifted, text = row.text, dead = dead, native_action = action }
	end
	return result
end

--- Requires a genuine direct digit on exactly one native level at all positions.
--- Caps variants are independent: no uppercasing or conventional level guesses.
function M.capable(levels, mode)
	if not Policy.mode(mode) or mode == "native" or type(levels) ~= "table" then return false end
	for _, caps in ipairs({ false, true }) do
		if not dense(levels[caps], M.POSITIONS) then return false end
		for position, pair in ipairs(levels[caps]) do
			if type(pair) ~= "table" or pair.digit ~= tostring(position % 10) or not integer(pair.code, 767)
				or type(pair.digit) ~= "string"
				or type(pair.plain) ~= "table" or type(pair.shift) ~= "table"
				or type(pair.plain.dead) ~= "boolean" or type(pair.shift.dead) ~= "boolean"
				or not text(pair.plain.text) or not text(pair.shift.text)
				or pair.plain.code ~= pair.code or pair.shift.code ~= pair.code
				or pair.plain.caps ~= caps or pair.shift.caps ~= caps
				or pair.plain.shift ~= false or pair.shift.shift ~= true
				or type(pair.plain.native_action) ~= "table" or type(pair.shift.native_action) ~= "table" then return false end
			local plain_digit = pair.plain.dead == false and pair.plain.text == pair.digit
			local shift_digit = pair.shift.dead == false and pair.shift.text == pair.digit
			if plain_digit == shift_digit then return false end
			local symbol = plain_digit and pair.shift or pair.plain
			if mode == "symbols" and not symbol.dead and symbol.text == "" then return false end
		end
	end
	return true
end

--- Selects the exact native action descriptor; emission retains native parameters.
function M.select(levels, mode, position, caps, physical_shift)
	if not Policy.mode(mode) or mode == "native" or not integer(position, M.POSITIONS) or position == 0
		or type(caps) ~= "boolean" or type(physical_shift) ~= "boolean" or not M.capable(levels, mode) then return nil end
	local pair = levels[caps][position]
	local digit_shift = pair.shift.dead == false and pair.shift.text == pair.digit
	local shifted = digit_shift
	if mode == "symbols" then shifted = not shifted end
	if physical_shift then shifted = not shifted end
	return pair[shifted and "shift" or "plain"]
end

return M
