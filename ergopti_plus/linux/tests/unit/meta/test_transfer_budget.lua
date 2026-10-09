--- tests/unit/meta/test_transfer_budget.lua

--- ==============================================================================
--- MODULE: Captured Archive Phase Budget
--- DESCRIPTION:
--- Registers independent literal controls through the normal Linux test helpers.
--- Modeled ports do not establish native filesystem, transport or install proof.
--- ==============================================================================

--- Independent literal transfer budget controls. No native or transport ports.
local Budget = require("updater.transfer_budget")
local tests = {}
local function policy()
	return { archive_transfer = { schema_version = 1,
		phase_timeout_ms = { checksum = 15000, archive = 300000, hash = 15000 } } }
end
local function test(name, body) tests[#tests + 1] = { name, body } end
test("total is derived from all captured caps", function()
	assert(Budget.deadline(Budget.capture(policy(), 100)) == 330100)
end)
test("noncanonical caps derive their own total", function()
	local p = policy()
	p.archive_transfer.phase_timeout_ms = { checksum = 2, archive = 3, hash = 4 }
	assert(Budget.deadline(Budget.capture(p, 10)) == 19)
end)
test("mutating defaults cannot extend captured caps", function()
	local p = policy()
	local token = Budget.capture(p, 100)
	p.archive_transfer.phase_timeout_ms.checksum = 990000
	assert(Budget.enter(token, "checksum", 100) == 15100)
	assert(Budget.deadline(token) == 330100)
end)
test("token fields cannot extend private deadline", function()
	local token = Budget.capture(policy(), 100)
	token.deadline = 99999999
	assert(Budget.deadline(token) == 330100)
end)
test("checksum begins once within cap", function()
	local token = Budget.capture(policy(), 100)
	assert(Budget.enter(token, "checksum", 101) == 15101)
	assert(Budget.enter(token, "checksum", 1000) == 15101)
end)
test("archive continuation does not restart on relay or redirect", function()
	local token = Budget.capture(policy(), 0)
	assert(Budget.enter(token, "checksum", 0) == 15000)
	assert(Budget.enter(token, "archive", 12000) == 312000)
	assert(Budget.enter(token, "archive", 25000) == 312000)
	assert(Budget.enter(token, "archive", 311999) == 312000)
	assert(Budget.enter(token, "archive", 312000) == nil)
end)
test("final hash is capped by original total", function()
	local token = Budget.capture(policy(), 0)
	assert(Budget.enter(token, "checksum", 14000) == 29000)
	assert(Budget.enter(token, "archive", 28000) == 328000)
	assert(Budget.enter(token, "hash", 327000) == 330000)
	assert(Budget.admit(token, "hash", 329999))
	assert(not Budget.admit(token, "hash", 330000))
end)
test("hash receives its own smaller cap when total permits", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	Budget.enter(token, "archive", 1)
	assert(Budget.enter(token, "hash", 2) == 15002)
end)
test("phase cannot be skipped", function()
	assert(Budget.enter(Budget.capture(policy(), 0), "archive", 0) == nil)
end)
test("old phase cannot regain dispatch consent", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	Budget.enter(token, "archive", 1)
	assert(not Budget.admit(token, "checksum", 2))
	assert(Budget.enter(token, "checksum", 2) == nil)
end)
test("expired checksum cannot proceed", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	assert(Budget.enter(token, "archive", 15000) == nil)
end)
test("expired archive cannot proceed", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	Budget.enter(token, "archive", 1)
	assert(Budget.enter(token, "hash", 300001) == nil)
end)
test("regressing monotonic clock is refused", function()
	local token = Budget.capture(policy(), 100)
	Budget.enter(token, "checksum", 110)
	assert(not Budget.admit(token, "checksum", 109))
end)
test("retirement cannot restore consent", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	assert(Budget.retire(token))
	assert(Budget.deadline(token) == nil)
	assert(Budget.enter(token, "checksum", 1) == nil)
	assert(not Budget.admit(token, "checksum", 1))
end)
test("forged token is refused", function()
	assert(Budget.deadline({}) == nil)
	assert(not Budget.admit({}, "checksum", 0))
end)
test("missing cap has no fallback", function()
	local p = policy()
	p.archive_transfer.phase_timeout_ms.hash = nil
	assert(Budget.capture(p, 0) == nil)
end)
test("fractional and nonpositive caps refused", function()
	for _, value in ipairs({ 0, -1, 0.5, math.huge }) do
		local p = policy()
		p.archive_transfer.phase_timeout_ms.archive = value
		assert(Budget.capture(p, 0) == nil)
	end
end)
test("overflowed original total refused", function()
	assert(Budget.capture(policy(), 9007199254740990) == nil)
end)
test("metatable cannot supply absent policy", function()
	assert(Budget.capture(setmetatable({}, { __index = policy() }), 0) == nil)
end)
test("nonfinite observation cannot dispatch", function()
	local token = Budget.capture(policy(), 0)
	Budget.enter(token, "checksum", 0)
	assert(not Budget.admit(token, "checksum", math.huge))
	assert(not Budget.admit(token, "checksum", 0 / 0))
end)
test("actual high-resolution monotonic shape preserves fractional time", function()
	local token = Budget.capture(policy(), 12.375)
	assert(Budget.deadline(token) == 330012.375)
	assert(Budget.enter(token, "checksum", 12.625) == 15012.625)
	assert(Budget.admit(token, "checksum", 13.125))
end)
test("nil phase before admission refuses without throwing", function()
	assert(not Budget.admit(Budget.capture(policy(), 0), nil, 0))
end)

-- Registration preserves every original case body and its literal expectation.
local helpers = require("tests.helpers")
helpers.describe("Captured Archive Phase Budget", function()
	assert(#tests == 22, "Independent Captured Archive Phase Budget case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function",
			"Independent case registration refused")
		helpers.it(case[1], case[2])
	end
end)

return tests
