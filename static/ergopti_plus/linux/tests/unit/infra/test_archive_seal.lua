--- tests/unit/infra/test_archive_seal.lua

--- ==============================================================================
--- MODULE: Retained FD Seal Ownership
--- DESCRIPTION:
--- Registers independent literal controls through the normal Linux test helpers.
--- Modeled ports do not establish native filesystem, transport or install proof.
--- ==============================================================================

--- Independent exact-FD seal/read-debt controls, separate from old 51 controls.
local Output = require("infra.archive_output")
local tests = {}
local ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(options)
	options = options or {}
	local h = { now = 0.25, current = true, closes = 0, hashes = 0, delivered = {}, hash_listeners = {} }
	local producer = { settled = false }
	function producer:is_settled() return self.settled end
	function producer:on_settled(fn) h.producer_ack = fn; return true end
	local timer = { started = true }
	function timer:is_settled() return h.timer_closed == true end
	function timer:cancel() h.timer_closed = true; return true end
	function timer:on_settled(fn) h.timer_ack = fn; return true end
	local hash = {}
	function hash:is_settled() return h.hash_closed == true end
	function hash:cancel() h.hash_cancelled = true; return true end
	function hash:on_settled(fn) h.hash_listeners[#h.hash_listeners + 1] = fn; return true end
	local factory = Output.new({ now_ms = function() return h.now end,
		deadline = function(_, expire) h.expire = expire; return timer end,
		open = function() return 7 end, truncate = function(fd) assert(fd == 7); return true end,
		write = function(fd, chunk, offset, callback)
			assert(fd == 7 and chunk == "abc" and offset == 0); h.write_ack = callback; return {}
		end,
		close = function(fd) assert(fd == 7); h.closes = h.closes + 1; return true end,
		hash = function(fd, length, current, deadline, callback)
			assert(fd == 7 and length == 3 and deadline == 80.5)
			h.hashes = h.hashes + 1
			h.hash_current, h.hash_done = current, callback
			if options.hash then return options.hash(h, hash) end
			return hash
		end,
	})
	h.lease = assert(factory.reserve("/owned", {}, function() return h.current end, 100.5))
	h.ticket = assert(h.lease:begin())
	assert(h.lease:bind(h.ticket, producer))
	assert(h.lease:write(h.ticket, "abc", function() end))
	function h:ready()
		self.write_ack(nil, 3)
		assert(self.lease:eof(self.ticket))
		producer.settled = true; self.producer_ack()
	end
	function h:seal()
		return self.lease:seal_sha256(self.ticket, ABC, 80.5, function(digest, receipt, token, reason)
			self.delivered[#self.delivered + 1] = { digest = digest, receipt = receipt, token = token, reason = reason }
		end)
	end
	function h:finish(digest, receipt)
		self.hash_closed = true; self.hash_done(digest, receipt)
		for _, listener in ipairs(self.hash_listeners) do listener() end
	end
	h.producer = producer
	return h
end
test("pending write cannot start seal or hash", function()
	local h = fixture(); assert(h:seal() == nil and h.hashes == 0)
	h:ready(); assert(h:seal() ~= nil)
end)
test("logical producer terminal cannot replace physical settlement", function()
	local h = fixture(); h.write_ack(nil, 3); h.lease:eof(h.ticket)
	assert(h:seal() == nil and h.hashes == 0)
end)
test("no EOF cannot start a hash read", function()
	local h = fixture(); h.write_ack(nil, 3); h.producer.settled = true
	assert(h:seal() == nil and h.hashes == 0)
end)
test("seal prevents all new reset write and producer bind", function()
	local h = fixture(); h:ready(); assert(h:seal())
	assert(h.lease:begin(h.ticket) == nil)
	assert(not h.lease:write(h.ticket, "abc", function() end))
	assert(not h.lease:bind(h.ticket, h.producer))
end)
test("hash read debt prevents FD closure after cancellation", function()
	local h = fixture(); h:ready(); h:seal(); h.lease:cancel()
	assert(h.hash_cancelled and h.closes == 0 and not h.lease:is_settled())
	h:finish(nil, { stage = "file_read" })
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("private verification is bound to final sealed FD", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC)
	assert(h.delivered[1].digest == ABC and h.lease:verified(h.delivered[1].token))
	assert(not h.lease:verified({}) and h.closes == 0)
end)
test("hash callback is not physical read context and timer ACK", function()
	local h = fixture(); h:ready(); h:seal(); h.hash_done(ABC)
	assert(#h.delivered == 0)
	h.hash_closed = true
	for _, listener in ipairs(h.hash_listeners) do listener() end
	assert(#h.delivered == 1)
end)
test("withdrawn transaction cannot publish completed digest", function()
	local h = fixture(); h:ready(); h:seal(); h.current = false; h:finish(ABC)
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil and h.closes == 1)
end)
test("expired original phase cannot publish completed digest", function()
	local h = fixture(); h:ready(); h:seal(); h.now = 80.5; h:finish(ABC)
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil)
end)
test("verification cannot survive its captured hash bound", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC); h.now = 80.5
	assert(not h.lease:verified(h.delivered[1].token))
end)
test("throwing hash allocation never authorizes guessed FD close", function()
	local h = fixture({ hash = function() error("submitted read then threw") end })
	h:ready(); h:seal(); h.lease:cancel()
	assert(h.closes == 0 and not h.lease:is_settled())
end)
test("duplicate result cannot borrow later outcome", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(nil, { native_errno = "EACCES" })
	h.hash_done(ABC)
	assert(#h.delivered == 1 and h.delivered[1].digest == nil)
	assert(h.delivered[1].receipt.native_errno == "EACCES")
end)
test("computed SHA256 must match exact captured release checksum", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(string.rep("0", 64))
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil)
	assert(h.delivered[1].reason == "checksum_mismatch" and h.delivered[1].receipt == nil)
end)
test("foreign equality metamethod cannot borrow verification token", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC)
	local calls = 0
	local fake = setmetatable({}, { __eq = function() calls = calls + 1; return true end })
	assert(not h.lease:verified(fake) and calls == 0)
	assert(h.lease:verified(h.delivered[1].token))
end)
test("foreign equality metamethod cannot borrow final seal ticket", function()
	local h = fixture(); h:ready()
	local calls = 0
	local fake = setmetatable({}, { __eq = function() calls = calls + 1; return true end })
	assert(h.lease:seal_sha256(fake, ABC, 80.5, function() end) == nil)
	assert(h.hashes == 0 and calls == 0)
end)
test("matching digest plus typed native failure cannot verify", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC, { stage = "file_read", native_errno = "EACCES" })
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil)
	assert(h.delivered[1].receipt.native_errno == "EACCES")
end)
test("matching digest plus malformed nonnil error cannot verify", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC, "invalid native error")
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil)
end)
local function with_forged(original, body)
	local calls, previous = 0, getmetatable(original)
	local equality = { __eq = function() calls = calls + 1; return true end }
	local fake = setmetatable({}, equality)
	setmetatable(original, equality)
	local ok, err = xpcall(function() body(fake, function() return calls end) end, debug.traceback)
	setmetatable(original, previous)
	if not ok then error(err, 0) end
end
test("matching metatables cannot borrow sealed verification on either ABI", function()
	local h = fixture(); h:ready(); h:seal(); h:finish(ABC)
	with_forged(h.delivered[1].token, function(fake, calls)
		assert(not h.lease:verified(fake) and calls() == 0)
	end)
	assert(h.lease:verified(h.delivered[1].token))
end)
test("matching metatables cannot borrow final seal ticket on either ABI", function()
	local h = fixture(); h:ready()
	with_forged(h.ticket, function(fake, calls)
		assert(h.lease:seal_sha256(fake, ABC, 80.5, function() end) == nil)
		assert(h.hashes == 0 and calls() == 0)
	end)
end)
test("mutated public hash settlement cannot close an FD with pending read", function()
	local h = fixture(); h:ready(); local operation = assert(h:seal())
	operation.is_settled = function() return true end
	h.lease:cancel()
	assert(h.hash_cancelled and h.closes == 0 and not h.lease:is_settled())
	h:finish(nil, { stage = "file_read" })
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("mutated public hash cancel cannot suppress exact native cancellation", function()
	local h = fixture(); h:ready(); local operation = assert(h:seal())
	operation.cancel = function() return true end
	h.lease:cancel()
	assert(h.hash_cancelled and h.closes == 0)
	h:finish(nil, { stage = "file_read" })
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("cancel during hash construction signals the exact late child", function()
	local h = fixture({ hash = function(self, operation)
		self.lease:cancel(); return operation
	end }); h:ready(); assert(h:seal())
	assert(h.hash_cancelled and h.closes == 0 and not h.lease:is_settled())
	h:finish(nil, { stage = "file_read" })
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("cancel during hash listener registration retains pending read", function()
	local h = fixture({ hash = function(self, operation)
		local original = operation.on_settled
		operation.on_settled = function(receiver, fn)
			assert(receiver == operation)
			self.lease:cancel()
			return original(receiver, fn)
		end
		return operation
	end }); h:ready(); assert(h:seal())
	assert(h.hash_cancelled and h.closes == 0)
	h:finish(nil, { stage = "file_read" })
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("source withdrawal during child return revokes late hash owner", function()
	local h = fixture({ hash = function(self, operation)
		self.current = false; return operation
	end }); h:ready(); assert(h:seal())
	assert(h.hash_cancelled and h.closes == 0)
	h:finish(ABC)
	assert(h.delivered[1].digest == nil and h.delivered[1].token == nil)
	assert(h.closes == 1 and h.lease:is_settled())
end)
test("settled hash probe reentry cannot close exact FD twice", function()
	local armed, probes = false, 0
	local h = fixture({ hash = function(self, operation)
		local original = operation.is_settled
		operation.is_settled = function(receiver)
			if armed then
				probes = probes + 1
				-- First is publish's non-destructive readiness observation;
				-- second is close_if_ready's actual descriptor-close admission.
				if probes == 2 then armed = false; self.lease:cancel() end
			end
			return original(receiver)
		end
		return operation
	end }); h:ready(); h:seal(); h.lease:cancel()
	h.hash_done(nil, { stage = "file_read" })
	h.hash_closed = true; armed = true
	-- The retained exact physical-ACK listener runs outside revoke.
	for _, listener in ipairs(h.hash_listeners) do listener() end
	assert(probes == 2 and h.closes == 1 and h.lease:is_settled())
end)

-- Registration preserves every original case body and its literal expectation.
local helpers = require("tests.helpers")
helpers.describe("Retained FD Seal Ownership", function()
	assert(#tests == 25, "Independent Retained FD Seal Ownership case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function",
			"Independent case registration refused")
		helpers.it(case[1], case[2])
	end
end)

return tests
