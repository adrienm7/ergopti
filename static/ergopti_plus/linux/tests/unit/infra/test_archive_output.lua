--- tests/unit/infra/test_archive_output.lua

--- ==============================================================================
--- MODULE: Retained Archive Lease Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- controls/test_archive_output.lua
--- Independent fixed causal expectations for the actual archive-output module.
--- No expected result is generated from the implementation or shared policy.
local Output = require("infra.archive_output")
local helpers = require("tests.helpers")
local function check(name, fn)
	helpers.describe("Retained Archive Lease Controls", function()
		helpers.it(name, fn)
	end)
end
local function setup(options)
	options = options or {}
	local h = { now = 0, owner = {}, current = true, opens = 0, closes = 0, truncates = 0,
		writes = {}, resumes = 0, timer_closing = false, timer_settled = false, timer_listeners = {} }
	local producer = { settled = false, listeners = {} }
	function producer:is_settled()
		if options.settlement_probe then options.settlement_probe(h) end
		return self.settled
	end
	function producer:on_settled(listener) self.listeners[#self.listeners + 1] = listener; return true end
	function h:settle_producer()
		producer.settled = true
		for _, fn in ipairs(producer.listeners) do fn() end
	end
	local timer = { started = options.timer_started ~= false }
	function timer:is_settled() return h.timer_settled end
	function timer:cancel()
		h.timer_closing = true
		if options.timer_cancel then options.timer_cancel(h) end
		return true
	end
	function timer:on_settled(listener) h.timer_listeners[#h.timer_listeners + 1] = listener; return true end
	function h:timer_ack()
		h.timer_settled = true
		for _, fn in ipairs(h.timer_listeners) do fn() end
	end
	local ports = {
		now_ms = function() return h.now end,
		deadline = function(deadline, expire)
			assert(deadline == 100)
			h.expire = expire
			if options.arm then options.arm(h) end
			return timer
		end,
		open = function(directory)
			assert(directory == "/owned")
			h.opens = h.opens + 1
			if options.open then return options.open(h) end
			return 7
		end,
		truncate = function(fd)
			assert(fd == 7)
			h.truncates = h.truncates + 1
			if options.truncate then return options.truncate(h) end
			return true
		end,
		write = function(fd, chunk, offset, callback)
			assert(fd == 7)
			h.writes[#h.writes + 1] = { chunk = chunk, offset = offset, ack = callback }
			if options.write then return options.write(h) end
			return {}
		end,
		close = function(fd)
			assert(fd == 7)
			h.closes = h.closes + 1
			if options.close then return options.close(h) end
			return true
		end,
	}
	h.factory = Output.new(ports)
	h.lease, h.refusal = h.factory.reserve("/owned", h.owner, function(owner)
		assert(owner == h.owner)
		if options.current_probe then options.current_probe(h) end
		return h.current
	end, 100)
	function h:begin()
		self.ticket = assert(self.lease:begin())
		assert(self.lease:bind(self.ticket, producer))
		return self.ticket
	end
	function h:write(value)
		return self.lease:write(self.ticket, value, function(ok, receipt)
			self.resumes = self.resumes + 1
			self.last_ok, self.receipt = ok, receipt
		end)
	end
	function h:ack(index, err, count) self.writes[index].ack(err, count) end
	return h
end

check("unsupported allocation launches no named fallback", function()
	local h = setup({open = function() return nil, {errno = "EOPNOTSUPP"} end})
	assert(not h.lease and h.opens == 1 and h.closes == 0)
	assert(h.refusal.stage == "file_create" and h.refusal.native_errno == "EOPNOTSUPP")
end)
check("literal current true is required before native open", function()
	local h = setup({current_probe = function(h) h.current = "true" end})
	assert(not h.lease and h.opens == 0)
end)
check("post-open retired owner closes only its admitted FD", function()
	local h = setup({open = function(h) h.current = false; return 7 end})
	assert(not h.lease and h.closes == 1)
end)
check("one chunk holds backpressure until its actual write ACK", function()
	local h = setup(); h:begin(); assert(h:write("abc"))
	assert(h.resumes == 0 and #h.writes == 1 and not h:write("def"))
	h:ack(1, nil, 3)
	assert(h.resumes == 1 and h.last_ok and h.lease:bytes(h.ticket) == 3)
end)
check("short writes preserve exact bytes and positioned offsets", function()
	local h = setup(); h:begin(); assert(h:write("abc"))
	h:ack(1, nil, 1)
	assert(#h.writes == 2 and h.writes[2].chunk == "bc" and h.writes[2].offset == 1)
	h:ack(2, nil, 2)
	assert(h.resumes == 1 and h.last_ok and h.lease:bytes(h.ticket) == 3)
end)
check("duplicate native ACK cannot resume twice or write again", function()
	local h = setup(); h:begin(); h:write("abc"); h:ack(1, nil, 3); h:ack(1, nil, 3)
	assert(h.resumes == 1 and #h.writes == 1)
end)
check("cancel waits independently for write EOF producer and timer ACKs", function()
	local h = setup(); h:begin(); h:write("abc"); h.lease:cancel()
	assert(h.closes == 0 and not h.lease:is_settled())
	h.lease:eof(h.ticket); h:settle_producer()
	assert(h.closes == 0)
	h:ack(1, nil, 3)
	assert(h.closes == 1 and not h.last_ok and not h.lease:is_settled())
	h:timer_ack(); assert(h.lease:is_settled())
end)
check("producer settlement cannot stand in for stdout EOF", function()
	local h = setup(); h:begin(); h.lease:cancel(); h:settle_producer(); h:timer_ack()
	assert(h.closes == 0 and not h.lease:is_settled())
	h.lease:eof(h.ticket); assert(h.closes == 1 and h.lease:is_settled())
end)
check("EOF cannot stand in for producer physical settlement", function()
	local h = setup(); h:begin(); h.lease:cancel(); h.lease:eof(h.ticket); h:timer_ack()
	assert(h.closes == 0)
	h:settle_producer(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("empty relay reset requires exact preceding ticket and native retirement", function()
	local h = setup(); h:begin()
	assert(not h.lease:begin(h.ticket) and h.truncates == 1)
	h.lease:eof(h.ticket); h:settle_producer()
	assert(not h.lease:begin({}) and h.truncates == 1)
	local next_ticket = assert(h.lease:begin(h.ticket))
	assert(next_ticket ~= h.ticket and h.truncates == 2)
	assert(not h.lease:eof(h.ticket))
end)
check("any successfully written body bytes prevent relay reset", function()
	local h = setup(); h:begin(); h:write("abc"); h:ack(1, nil, 3)
	h.lease:eof(h.ticket); h:settle_producer()
	assert(not h.lease:begin(h.ticket) and h.truncates == 1)
end)
check("original deadline expiry before reset cannot receive a fresh budget", function()
	local h = setup(); h:begin(); h.lease:eof(h.ticket); h:settle_producer(); h.now = 100
	assert(not h.lease:begin(h.ticket) and h.truncates == 1 and h.closes == 1)
end)
check("native ENOSPC write is typed and aborts exact sink", function()
	local h = setup(); h:begin(); h:write("abc"); h:ack(1, {errno = "ENOSPC"})
	assert(h.resumes == 1 and not h.last_ok)
	assert(h.receipt.stage == "file_write" and h.receipt.native_errno_domain == "posix"
		and h.receipt.native_errno == "ENOSPC")
	h.receipt.native_errno = "EACCES"
	assert(h.lease:failure(h.ticket).native_errno == "ENOSPC")
	assert(not h.lease:begin(h.ticket))
end)
check("invalid native write size is unknown rather than manufactured ENOSPC", function()
	local h = setup(); h:begin(); h:write("abc"); h:ack(1, nil, 4)
	assert(not h.last_ok and h.receipt.native_errno == nil)
end)
check("current owner revocation during pending write forbids success resume", function()
	local h = setup(); h:begin(); h:write("abc"); h.current = false; h:ack(1, nil, 3)
	assert(h.resumes == 1 and not h.last_ok and not h:write("def"))
end)
check("deadline fires while writer pending and retains physical debt", function()
	local h = setup(); h:begin(); h:write("abc"); h.now = 101; h.expire()
	assert(h.closes == 0 and not h.lease:is_settled())
	h:ack(1, nil, 3); assert(not h.last_ok and h.closes == 0)
	h.lease:eof(h.ticket); h:settle_producer(); h:timer_ack()
	assert(h.lease:is_settled() and h.closes == 1)
end)
check("write submission throw never guesses a physical write ACK", function()
	local h = setup({write = function() error("after submission") end})
	h:begin(); assert(not h:write("abc")); h.lease:eof(h.ticket); h:settle_producer(); h:timer_ack()
	assert(not h.lease:is_settled() and h.closes == 0)
	h:ack(1, nil, 3); assert(h.lease:is_settled() and not h.last_ok)
end)
check("ambiguous close is attempted once even if descriptor number is reused", function()
	local h = setup({close = function() error("close may already have happened") end})
	h.lease:cancel(); h:timer_ack(); h.lease:cancel(); h.lease:cancel()
	assert(h.closes == 1 and not h.lease:is_settled())
end)
check("cancel before producer bind closes parent descriptor without fictitious EOF", function()
	local h = setup(); h.ticket = assert(h.lease:begin()); h.lease:cancel(); h:timer_ack()
	assert(h.closes == 1 and h.lease:is_settled())
end)
check("reentrant close cancellation cannot consume descriptor twice", function()
	local h = setup({close = function(h) h.lease:cancel(); return true end})
	h.lease:cancel(); h:timer_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("reentrant timer cancellation cannot recurse or consume a successor", function()
	local h = setup({timer_cancel = function(h) h.lease:cancel() end})
	h.lease:cancel(); h:timer_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("post-current absolute clock check closes slow probe admission", function()
	local h = setup(); h:begin()
	h.current = true
	-- A current probe is a reentrant native boundary, not elapsed-time proof.
	h.now = 100
	assert(not h:write("abc") and #h.writes == 0)
end)
check("oversized chunk launches zero native writes", function()
	local h = setup(); h:begin(); assert(not h:write(string.rep("x", 65537)))
	assert(#h.writes == 0)
end)
check("foreign attempt cannot EOF or write current output", function()
	local h = setup(); h:begin()
	assert(not h.lease:eof({}) and not h.lease:write({}, "abc", function() end))
	assert(#h.writes == 0)
end)
check("actual EOF during current probe forbids a new writer after settlement", function()
	local h = setup({current_probe = function(h)
		if h.probe_eof then
			h.probe_eof = false
			assert(h.lease:eof(h.ticket))
			h:settle_producer()
		end
	end})
	h:begin(); h.probe_eof = true
	assert(not h:write("abc") and #h.writes == 0 and h.resumes == 0)
end)
check("actual EOF during short-write probe forbids another native submission", function()
	local h = setup({current_probe = function(h)
		if h.probe_eof then
			h.probe_eof = false
			assert(h.lease:eof(h.ticket))
			h:settle_producer()
		end
	end})
	h:begin(); h:write("abc"); h.probe_eof = true; h:ack(1, nil, 1)
	assert(#h.writes == 1 and h.resumes == 1 and not h.last_ok)
	assert(h.lease:bytes(h.ticket) == 1 and not h.lease:begin(h.ticket))
end)
