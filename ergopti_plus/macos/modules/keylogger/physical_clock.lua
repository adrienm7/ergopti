--- modules/keylogger/physical_clock.lua

--- Converts native HID ticks to the absolute nanosecond domain used by the host.
local M = {}
local UINT64_MAX = "18446744073709551615"

--- Captures a verified native timebase without consulting a delivery-time clock.
---@param information table Native clock domain, version and rational scale.
---@return function convert Exact original ticks to nonnegative Lua integer nanoseconds.
function M.new(information)
	assert(type(information) == "table" and information.version == 1
		and information.domain == "mach_absolute_time", "Invalid physical clock domain")
	local numer, denom = information.numer, information.denom
	for _, value in ipairs({ numer, denom }) do
		assert(type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 4294967295,
			"Invalid physical clock timebase")
	end
	assert(numer and denom, "Missing physical clock timebase")
	numer, denom = math.tointeger(numer), math.tointeger(denom)
	return function(ticks)
		assert(type(ticks) == "string" and ticks:match("^%d+$")
			and (ticks == "0" or ticks:sub(1, 1) ~= "0")
			and (#ticks < #UINT64_MAX or (#ticks == #UINT64_MAX and ticks <= UINT64_MAX)),
			"Invalid physical clock timestamp")
		-- Decimal arithmetic preserves unsigned ticks and avoids the intermediate
		-- overflow in ticks * numer. Each operation fits below 10 * UINT32_MAX.
		local digits, carry = {}, 0
		for index = #ticks, 1, -1 do
			local product = tonumber(ticks:sub(index, index)) * numer + carry
			digits[#digits + 1], carry = product % 10, product // 10
		end
		while carry > 0 do digits[#digits + 1], carry = carry % 10, carry // 10 end
		local quotient, remainder = {}, 0
		for index = #digits, 1, -1 do
			local dividend = remainder * 10 + digits[index]
			local digit = dividend // denom
			remainder = dividend % denom
			if digit ~= 0 or #quotient > 0 then quotient[#quotient + 1] = tostring(digit) end
		end
		local decimal = #quotient == 0 and "0" or table.concat(quotient)
		local maximum = tostring(math.maxinteger)
		assert(#decimal < #maximum or (#decimal == #maximum and decimal <= maximum),
			"Physical clock timestamp exceeds host integer range")
		return assert(math.tointeger(tonumber(decimal)), "Physical clock timestamp is not exact")
	end
end

return M
