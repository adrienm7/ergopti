--- tests/unit/infra/test_http_output_target.lua

--- ==============================================================================
--- MODULE: Native Parent Output Target Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- controls/test_http_output_target.lua
--- Independent sink-controls against actual output lease and target modules.
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local helpers = require("tests.helpers")
local function check(name, fn)
	helpers.describe("Native Parent Output Target Controls", function()
		helpers.it(name, fn)
	end)
end
local function setup(options)
	options = options or {}
	local h = { owner = {}, current = true, now = 0, active = true, eof = false, closed = false,
		settled = false, pauses = 0, resumes = 0, aborts = 0, write_acks = 0, closes = 0,
		writes = {}, reader_listeners = {}, producer_listeners = {}, timer_listeners = {}, timer_closed = false }
	local producer = {}
	function producer:is_settled() return h.settled end
	function producer:on_settled(listener) h.producer_listeners[#h.producer_listeners + 1] = listener; return true end
	local timer = { started = true }
	function timer:is_settled() return h.timer_closed end
	function timer:cancel() return true end
	function timer:on_settled(listener) h.timer_listeners[#h.timer_listeners + 1] = listener; return true end
	h.lease = assert(Output.new({
		now_ms = function() return h.now end,
		deadline = function(_, expire) h.expire = expire; return timer end,
		open = function() return 7 end,
		truncate = function(fd) assert(fd == 7); return true end,
		write = function(fd, chunk, offset, callback)
			assert(fd == 7)
			h.writes[#h.writes + 1] = {chunk = chunk, offset = offset, ack = callback}
			if options.write then return options.write(h) end
			return {}
		end,
		close = function(fd) assert(fd == 7); h.closes = h.closes + 1; return true end,
	}).reserve("/owned", h.owner, function(owner) assert(owner == h.owner); return h.current end, 100))
	h.ticket = assert(h.lease:begin())
	h.target = assert(Target.create(h.lease, h.ticket))
	local input = {}
	function input:live()
		if options.live then options.live(h) end
		return h.active and not h.closed and not h.eof
	end
	function input:pause()
		h.pauses = h.pauses + 1
		if options.pause then return options.pause(h) end
		return true
	end
	function input:resume() h.resumes = h.resumes + 1; return true end
	function input:write_ack(failure)
		h.write_acks = h.write_acks + 1
		h.ack_failure = failure
	end
	function input:abort(ticket, exact)
		assert(ticket == h.ticket and exact == producer)
		h.aborts = h.aborts + 1; h.active = false
		h.abort_failure = Target.failure(h.target)
		return true
	end
	function input:reader_closed(ticket, exact)
		assert(ticket == h.ticket and exact == producer)
		return h.closed
	end
	function input:on_reader_closed(ticket, exact, listener)
		assert(ticket == h.ticket and exact == producer)
		h.reader_listeners[#h.reader_listeners + 1] = listener; return true
	end
	h.input, h.producer = input, producer
	h.sink = assert(Target.attach(h.target, producer, input))
	function h:retire()
		self.sink:stop(true)
		self.closed, self.settled, self.timer_closed = true, true, true
		for _, fn in ipairs(self.reader_listeners) do fn() end
		for _, fn in ipairs(self.producer_listeners) do fn() end
		for _, fn in ipairs(self.timer_listeners) do fn() end
	end
	return h
end
check("forged output object is refused by private target registry", function()
	assert(not Target.valid({}) and Target.attach({}, {}, {}) == nil)
end)
check("one registered target can bind only one producer", function()
	local h = setup()
	assert(not Target.valid(h.target) and Target.attach(h.target, {}, h.input) == nil)
	h:retire(); assert(h.lease:is_settled())
end)
check("native reads pause before one exact parent filesystem write", function()
	local h = setup(); assert(h.sink:consume("abc"))
	assert(h.pauses == 1 and h.resumes == 0 and #h.writes == 1 and h.writes[1].chunk == "abc")
	h.writes[1].ack(nil, 3)
	assert(h.resumes == 1 and h.write_acks == 1 and not h.sink:has_pending_write())
	h:retire()
end)
check("a second incoming chunk cannot overtake pending filesystem ACK", function()
	local h = setup(); h.sink:consume("abc")
	assert(not h.sink:consume("def") and h.pauses == 1 and #h.writes == 1)
	h.writes[1].ack(nil, 3); h:retire()
end)
check("explicit native pause refusal launches zero filesystem writes", function()
	local h = setup({pause = function() return false end})
	assert(not h.sink:consume("abc") and #h.writes == 0 and not h.sink:has_pending_write())
	assert(h.aborts == 1); h:retire()
end)
check("owner revocation after pause refuses without ghost pending IO", function()
	local h = setup({pause = function(h) h.current = false; return true end})
	assert(not h.sink:consume("abc") and #h.writes == 0 and not h.sink:has_pending_write())
	assert(h.aborts == 1); h:retire(); assert(h.lease:is_settled())
end)
check("ambiguous submitted native write remains pending until its actual ACK", function()
	local h = setup({write = function() error("after physical submission") end})
	assert(not h.sink:consume("abc") and h.sink:has_pending_write())
	h:retire(); assert(not h.lease:is_settled())
	h.writes[1].ack(nil, 3)
	assert(not h.sink:has_pending_write() and h.lease:is_settled() and h.resumes == 0)
end)
check("actual ENOSPC reaches native abort as typed filesystem evidence", function()
	local h = setup(); h.sink:consume("abc"); h.writes[1].ack({errno = "ENOSPC"})
	assert(h.aborts == 1 and h.resumes == 0 and h.write_acks == 1)
	assert(h.abort_failure.backend == "native_fs" and h.abort_failure.native_errno == "ENOSPC")
	h:retire()
end)
check("native EOF stops future input and preserves bytes after pending ACK", function()
	local h = setup(); h.sink:consume("abc"); h.eof = true; assert(h.sink:eof())
	h.writes[1].ack(nil, 3)
	assert(h.resumes == 0 and h.write_acks == 1 and h.lease:bytes(h.ticket) == 3)
	assert(not h.sink:consume("def") and #h.writes == 1)
	h:retire()
end)
check("live source refusal after write ACK cannot resume retired native input", function()
	local h = setup(); h.sink:consume("abc"); h.active = false; h.writes[1].ack(nil, 3)
	assert(h.resumes == 0 and h.write_acks == 1); h:retire()
end)
check("captured lease write method cannot borrow a later replacement", function()
	local h = setup()
	h.lease.write = function() error("foreign method") end
	assert(h.sink:consume("abc") and #h.writes == 1)
	h.writes[1].ack(nil, 3); h:retire()
end)
check("captured native resume method cannot borrow a later source method", function()
	local h = setup(); h.sink:consume("abc")
	h.input.resume = function() error("foreign input") end
	h.writes[1].ack(nil, 3); assert(h.resumes == 1); h:retire()
end)
check("duplicate native write callback cannot resume or settle another attempt", function()
	local h = setup(); h.sink:consume("abc"); h.writes[1].ack(nil, 3); h.writes[1].ack(nil, 3)
	assert(h.resumes == 1 and h.write_acks == 1); h:retire()
end)
check("oversized input refuses before native pause and descriptor mutation", function()
	local h = setup(); assert(not h.sink:consume(string.rep("x", 65537)))
	assert(h.pauses == 0 and #h.writes == 0); h:retire()
end)
check("closed retained lease cannot create a new registered output target", function()
	local h = setup(); h:retire(); assert(h.lease:is_settled())
	assert(Target.create(h.lease, h.ticket) == nil)
end)
check("zero-IO refusal reconsiders native cleanup without ghost write debt", function()
	local h = setup({pause = function(h) h.current = false; return true end})
	assert(not h.sink:consume("abc") and #h.writes == 0)
	assert(h.write_acks == 1 and not h.sink:has_pending_write())
	h:retire(); assert(h.lease:is_settled())
end)
check("slow native live getter after filesystem ACK cannot resume past deadline", function()
	local h = setup({live = function(h)
		if h.slow_live then h.slow_live = false; h.now = 100 end
	end})
	h.sink:consume("abc"); h.slow_live = true; h.writes[1].ack(nil, 3)
	assert(h.resumes == 0 and h.aborts == 1 and h.lease:bytes(h.ticket) == 3)
	h:retire()
end)
check("native resume admission refuses another producer operation", function()
	local h = setup()
	assert(not Target.resume_admit(h.target, {}) and Target.resume_admit(h.target, h.producer))
	h:retire()
end)
check("last ENOSPC ACK survives EOF and exact physical producer retirement", function()
	local h = setup(); assert(h.sink:consume("abc"))
	h.eof = true; assert(h.sink:eof())
	h.closed, h.settled, h.timer_closed = true, true, true
	for _, fn in ipairs(h.reader_listeners) do fn() end
	for _, fn in ipairs(h.producer_listeners) do fn() end
	for _, fn in ipairs(h.timer_listeners) do fn() end
	assert(not h.lease:is_settled() and h.sink:has_pending_write())
	h.writes[1].ack({errno = "ENOSPC"})
	assert(h.lease:is_settled() and not h.sink:has_pending_write() and h.aborts == 0)
	assert(h.write_acks == 1 and h.resumes == 0)
	assert(h.ack_failure.stage == "file_write" and h.ack_failure.backend == "native_fs")
	assert(h.ack_failure.native_errno == "ENOSPC" and h.ack_failure.failure_provenance == "verified")
	assert(h.sink:failure().native_errno == "ENOSPC")
end)
check("native receipt mutation cannot replace private last-write evidence", function()
	local h = setup(); assert(h.sink:consume("abc"))
	h.writes[1].ack({errno = "ENOSPC"})
	h.ack_failure.native_errno = "EACCES"
	local receipt = h.sink:failure(); assert(receipt.native_errno == "ENOSPC")
	receipt.native_errno = "EDQUOT"
	assert(h.sink:failure().native_errno == "ENOSPC")
	h:retire()
end)
check("duplicate last-write callback cannot overwrite retained failure or reconsider twice", function()
	local h = setup(); assert(h.sink:consume("abc"))
	h.writes[1].ack({errno = "ENOSPC"}); h.writes[1].ack(nil, 3)
	assert(h.write_acks == 1 and h.resumes == 0 and h.sink:failure().native_errno == "ENOSPC")
	h:retire()
end)
