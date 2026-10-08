--- tests/unit/infra/test_archive_capability_identity.lua

--- ==============================================================================
--- MODULE: Retained FD Raw Capability
--- DESCRIPTION:
--- Registers independent literal controls through the normal Linux test helpers.
--- Modeled ports do not establish native filesystem, transport or install proof.
--- ==============================================================================

--- Fixed raw-capability controls causal under LuaJIT and Lua5.4 equality rules.
local Output = require("infra.archive_output")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function with_forged(original, body)
	local calls, previous = 0, getmetatable(original)
	local equality = { __eq = function() calls = calls + 1; return true end }
	local fake = setmetatable({}, equality)
	setmetatable(original, equality)
	local ok, err = xpcall(function() body(fake, function() return calls end) end, debug.traceback)
	setmetatable(original, previous)
	if not ok then error(err, 0) end
end
local function fixture()
	local h = { writes = 0, truncates = 0, binds = 0 }
	local producer = { settled = false }
	function producer:is_settled() return self.settled end
	function producer:on_settled(fn) h.binds = h.binds + 1; h.ack = fn; return true end
	local timer = { started = true }
	function timer:is_settled() return true end
	function timer:cancel() return true end
	function timer:on_settled() return true end
	local factory = Output.new({ now_ms = function() return 0.25 end,
		deadline = function() return timer end, open = function() return 7 end,
		truncate = function() h.truncates = h.truncates + 1; return true end,
		write = function(_, _, _, callback) h.writes = h.writes + 1; h.write_ack = callback; return {} end,
		close = function() return true end,
	})
	h.lease = assert(factory.reserve("/owned", {}, function() return true end, 100.5))
	h.ticket = assert(h.lease:begin())
	h.producer = producer
	function h:bind() assert(self.lease:bind(self.ticket, producer)) end
	function h:retire()
		assert(self.lease:eof(self.ticket)); producer.settled = true; self.ack()
	end
	return h
end
test("forged bind never captures producer or equality callback", function()
	local h = fixture()
	with_forged(h.ticket, function(fake, calls)
		assert(not h.lease:bind(fake, h.producer) and h.binds == 0 and calls() == 0)
	end)
	h:bind(); assert(h.binds == 1)
end)
test("forged write never submits filesystem IO", function()
	local h = fixture(); h:bind()
	with_forged(h.ticket, function(fake, calls)
		assert(not h.lease:write(fake, "abc", function() end) and h.writes == 0 and calls() == 0)
	end)
	assert(h.lease:write(h.ticket, "abc", function() end) and h.writes == 1)
end)
test("forged EOF cannot retire an actual input", function()
	local h = fixture(); h:bind(); h.producer.settled = true
	with_forged(h.ticket, function(fake, calls)
		assert(not h.lease:eof(fake) and not h.lease:attempt_settled(h.ticket) and calls() == 0)
	end)
	assert(h.lease:eof(h.ticket) and h.lease:attempt_settled(h.ticket))
end)
test("forged predecessor cannot truncate a retired exact ticket", function()
	local h = fixture(); h:bind(); h:retire()
	with_forged(h.ticket, function(fake, calls)
		assert(h.lease:begin(fake) == nil and h.truncates == 1 and calls() == 0)
	end)
	assert(h.lease:begin(h.ticket) ~= nil and h.truncates == 2)
end)
test("forged ledger ticket cannot borrow bytes pending or settlement", function()
	local h = fixture(); h:bind(); assert(h.lease:write(h.ticket, "abc", function() end))
	h.write_ack(nil, 3); h:retire()
	with_forged(h.ticket, function(fake, calls)
		assert(h.lease:bytes(fake) == nil and h.lease:write_pending(fake) == nil)
		assert(not h.lease:attempt_settled(fake) and not h.lease:resume_admit(fake))
		assert(h.lease:failure(fake) == nil and calls() == 0)
	end)
	assert(h.lease:bytes(h.ticket) == 3 and h.lease:attempt_settled(h.ticket))
end)
test("forged ticket cannot receive another ticket typed filesystem error", function()
	local h = fixture(); h:bind(); assert(h.lease:write(h.ticket, "abc", function() end))
	h.write_ack({ errno = "ENOSPC" })
	with_forged(h.ticket, function(fake, calls)
		assert(h.lease:failure(fake) == nil and calls() == 0)
	end)
	assert(h.lease:failure(h.ticket).native_errno == "ENOSPC")
end)

-- Registration preserves every original case body and its literal expectation.
local helpers = require("tests.helpers")
helpers.describe("Retained FD Raw Capability", function()
	assert(#tests == 6, "Independent Retained FD Raw Capability case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function",
			"Independent case registration refused")
		helpers.it(case[1], case[2])
	end
end)

return tests
