--- tests/unit/infra/test_fd_sha256.lua

--- ==============================================================================
--- MODULE: Retained FD Digest Lifecycle
--- DESCRIPTION:
--- Registers independent literal controls through the normal Linux test helpers.
--- Modeled ports do not establish native filesystem, transport or install proof.
--- ==============================================================================

--- Independent parent read/context/phase-deadline ownership controls.
local Digest = require("infra.fd_sha256")
local tests = {}
local ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(options)
	options = options or {}
	local h = { now = 0.25, reads = {}, frees = 0, updates = {}, delivered = {}, listeners = {} }
	local timer = { started = true, closed = false }
	function timer:is_settled() return self.closed end
	function timer:on_settled(fn) h.listeners[#h.listeners + 1] = fn; return true end
	function timer:cancel()
		if not options.delay_timer then self.closed = true end
		return true
	end
	h.timer = timer
	h.ports = {
		now_ms = function() return h.now end,
		deadline = function(_, fn) h.expire = fn; return timer end,
		read = function(fd, cap, offset, callback)
			h.reads[#h.reads + 1] = { fd = fd, cap = cap, offset = offset, callback = callback }
			if options.throw_read then error("submitted then threw") end
			if options.refuse_read then return nil end
			return {}
		end,
		digest_create = function() h.context = {}; return h.context end,
		digest_update = function(context, chunk)
			assert(context == h.context)
			h.updates[#h.updates + 1] = chunk
			if options.update then return options.update(h) end
			return true
		end,
		digest_final = function()
			if options.final then return options.final(h) end
			return ABC
		end,
		digest_free = function(context)
			assert(context == h.context)
			h.frees = h.frees + 1
			if options.throw_free then error("unknown free outcome") end
			return true
		end,
	}
	h.current = function()
		if options.current then return options.current(h) end
		return true
	end
	function h:start(length)
		self.operation = Digest.new(self.ports).start(7, length or 3, self.current, 100.75,
			function(digest, receipt) self.delivered[#self.delivered + 1] = { digest = digest, receipt = receipt } end)
		return self.operation
	end
	function h:ack(chunk, err, index)
		self.reads[index or #self.reads].callback(err, chunk)
	end
	return h
end
test("exact bytes and separate EOF precede private completion", function()
	local h = fixture(); h:start(); h:ack("abc")
	assert(#h.delivered == 0 and h.reads[2].offset == 3 and h.reads[2].cap == 1)
	h:ack("")
	assert(h.delivered[1].digest == ABC and h.frees == 1 and h.operation:is_settled())
end)
test("bounded reads retain exact offsets", function()
	local h = fixture(); h:start(65537)
	assert(h.reads[1].cap == 65536 and h.reads[1].fd == 7)
	h:ack(string.rep("a", 65536))
	assert(h.reads[2].cap == 2 and h.reads[2].offset == 65536)
	h.operation:cancel(); h:ack("")
end)
test("early EOF refuses digest", function()
	local h = fixture(); h:start(); h:ack("ab"); h:ack("")
	assert(h.delivered[1].digest == nil and h.delivered[1].receipt.stage == "file_read")
end)
test("extra byte refuses digest", function()
	local h = fixture(); h:start(); h:ack("abcd")
	assert(h.delivered[1].digest == nil and #h.updates == 0)
end)
test("actual native filesystem errno stays typed", function()
	local h = fixture(); h:start(); h:ack(nil, { errno = "EACCES" })
	assert(h.delivered[1].receipt.native_errno == "EACCES")
	assert(h.delivered[1].receipt.failure_provenance == "verified")
end)
test("pending read survives cancellation until exact callback", function()
	local h = fixture(); h:start(); h.operation:cancel()
	assert(not h.operation:is_settled() and h.frees == 0 and #h.delivered == 0)
	h:ack("abc")
	assert(h.operation:is_settled() and h.frees == 1 and #h.updates == 0)
end)
test("deadline notification is not physical read retirement", function()
	local h = fixture(); h:start(); h.expire()
	assert(not h.operation:is_settled() and h.frees == 0)
	h:ack("abc")
	assert(h.delivered[1].digest == nil and h.frees == 1)
end)
test("slow owner probe consumes original phase deadline", function()
	local h = fixture({ current = function(self) self.now = 100.75; return true end }); h:start()
	assert(#h.reads == 0 and h.frees == 0 and h.operation:is_settled())
end)
test("withdrawn source refuses before allocation", function()
	local h = fixture({ current = function() return false end }); h:start()
	assert(h.context == nil and #h.reads == 0 and h.delivered[1].digest == nil)
end)
test("duplicate prior read callback cannot advance offset", function()
	local h = fixture(); h:start(); h:ack("abc", nil, 1); h:ack("abc", nil, 1)
	assert(#h.reads == 2 and #h.updates == 1)
	h:ack(""); assert(#h.delivered == 1)
end)
test("throwing submitted read retains exact ambiguous debt", function()
	local h = fixture({ throw_read = true }); h:start()
	assert(not h.operation:is_settled() and h.frees == 0)
	h:ack("abc")
	assert(h.operation:is_settled() and h.delivered[1].digest == nil)
end)
test("explicit nil submission can retire absent read", function()
	local h = fixture({ refuse_read = true }); h:start()
	assert(h.operation:is_settled() and h.frees == 1 and h.delivered[1].digest == nil)
end)
test("unknown context free remains debt and is never retried", function()
	local h = fixture({ throw_free = true }); h:start(); h:ack("abc"); h:ack("")
	assert(not h.operation:is_settled() and #h.delivered == 0 and h.frees == 1)
	h.operation:cancel(); assert(h.frees == 1)
end)
test("scheduled timer close cannot publish success", function()
	local h = fixture({ delay_timer = true }); h:start(); h:ack("abc"); h:ack("")
	assert(not h.operation:is_settled() and #h.delivered == 0 and h.frees == 1)
	h.timer.closed = true
	for _, listener in ipairs(h.listeners) do listener() end
	assert(h.operation:is_settled() and h.delivered[1].digest == ABC)
end)
test("reentrant update cancellation cannot free active context", function()
	local h = fixture({ update = function(self)
		self.operation:cancel(); assert(self.frees == 0); return true
	end }); h:start(); h:ack("abc")
	assert(h.frees == 1 and h.delivered[1].digest == nil)
end)
test("reentrant final cancellation cannot free active context", function()
	local h = fixture({ final = function(self)
		self.operation:cancel(); assert(self.frees == 0); return ABC
	end }); h:start(); h:ack("abc"); h:ack("")
	assert(h.frees == 1 and h.delivered[1].digest == nil)
end)
test("slow final hash cannot renew original deadline", function()
	local h = fixture({ final = function(self) self.now = 100.75; return ABC end })
	h:start(); h:ack("abc"); h:ack("")
	assert(h.delivered[1].digest == nil)
end)
test("malformed final hash has no success fallback", function()
	local h = fixture({ final = function() return string.rep("g", 64) end })
	h:start(); h:ack("abc"); h:ack("")
	assert(h.delivered[1].digest == nil and h.frees == 1)
end)
test("empty or fractional committed lengths refuse before IO", function()
	local h = fixture(); assert(h:start(0) == nil); assert(h:start(0.5) == nil)
	assert(#h.reads == 0 and h.context == nil)
end)
test("cancel after EOF before timer ACK revokes digest", function()
	local h = fixture({ delay_timer = true }); h:start(); h:ack("abc"); h:ack("")
	h.operation:cancel(); h.timer.closed = true
	for _, listener in ipairs(h.listeners) do listener() end
	assert(h.delivered[1].digest == nil and h.operation:is_settled())
end)
test("late physical timer ACK cannot publish expired digest", function()
	local h = fixture({ delay_timer = true }); h:start(); h:ack("abc"); h:ack("")
	h.now = 100.75; h.timer.closed = true
	for _, listener in ipairs(h.listeners) do listener() end
	assert(h.delivered[1].digest == nil and h.operation:is_settled())
end)

-- Registration preserves every original case body and its literal expectation.
local helpers = require("tests.helpers")
helpers.describe("Retained FD Digest Lifecycle", function()
	assert(#tests == 21, "Independent Retained FD Digest Lifecycle case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function",
			"Independent case registration refused")
		helpers.it(case[1], case[2])
	end
end)

return tests
