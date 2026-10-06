--- tests/unit/infra/test_archive_output_input.lua

--- ==============================================================================
--- MODULE: Retained Archive Input Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- controls/test_archive_output_input.lua
--- Literal close/abort/EOF expectations for actual revision-2 output source.
local Output = require("infra.archive_output")
local helpers = require("tests.helpers")
local function check(name, fn)
	helpers.describe("Retained Archive Input Controls", function()
		helpers.it(name, fn)
	end)
end
local function setup(options)
	options = options or {}
	local h = { owner = {}, now = 0, current = true, closes = 0, truncates = 0,
		writes = {}, aborts = 0, closed = false, settled = false, callbacks = 0,
		reader_listeners = {}, producer_listeners = {}, timer_listeners = {}, timer_closed = false }
	local producer = {}
	function producer:is_settled()
		if options.producer_probe then options.producer_probe(h) end
		return h.settled
	end
	function producer:on_settled(listener) h.producer_listeners[#h.producer_listeners + 1] = listener; return true end
	local timer = { started = true }
	function timer:is_settled() return h.timer_closed end
	function timer:cancel() return true end
	function timer:on_settled(listener) h.timer_listeners[#h.timer_listeners + 1] = listener; return true end
	local input = {}
	function input:reader_closed(ticket, exact)
		assert(ticket == h.ticket and exact == producer and self == input)
		if options.reader_probe then options.reader_probe(h) end
		return h.closed
	end
	function input:on_reader_closed(ticket, exact, listener)
		assert(ticket == h.ticket and exact == producer and self == input)
		h.reader_listeners[#h.reader_listeners + 1] = listener
		if options.subscribe then return options.subscribe(h) end
		return true
	end
	function input:abort(ticket, exact)
		assert(ticket == h.ticket and exact == producer and self == input)
		h.aborts = h.aborts + 1
		if options.abort then return options.abort(h) end
		return true -- Accepted signal only; all physical fields remain false.
	end
	h.producer, h.input = producer, input
	h.factory = Output.new({
		now_ms = function() return h.now end,
		deadline = function(deadline, expire) assert(deadline == 100); h.expire = expire; return timer end,
		open = function(directory) assert(directory == "/owned"); return 7 end,
		truncate = function(fd) assert(fd == 7); h.truncates = h.truncates + 1; return true end,
		write = function(fd, chunk, offset, ack)
			assert(fd == 7)
			h.writes[#h.writes + 1] = { chunk = chunk, offset = offset, ack = ack }
			return {}
		end,
		close = function(fd) assert(fd == 7); h.closes = h.closes + 1; return true end,
	})
	h.lease = assert(h.factory.reserve("/owned", h.owner, function(owner)
		assert(owner == h.owner)
		if options.current_probe then options.current_probe(h) end
		return h.current
	end, 100))
	h.ticket = assert(h.lease:begin())
	function h:bind() return self.lease:bind_input(self.ticket, producer, input) end
	function h:reader_ack()
		self.closed = true
		for _, fn in ipairs(self.reader_listeners) do fn() end
	end
	function h:producer_ack()
		self.settled = true
		for _, fn in ipairs(self.producer_listeners) do fn() end
	end
	function h:timer_ack()
		self.timer_closed = true
		for _, fn in ipairs(self.timer_listeners) do fn() end
	end
	function h:write()
		return self.lease:write(self.ticket, "abc", function(ok, receipt)
			self.callbacks = self.callbacks + 1; self.last_ok, self.receipt = ok, receipt
		end)
	end
	return h
end
check("cancel before EOF retires only after exact reader child and timer ACKs", function()
	local h = setup(); assert(h:bind()); assert(h.lease:cancel())
	assert(h.aborts == 1 and h.closes == 0 and not h.lease:is_settled())
	h:reader_ack(); assert(h.closes == 0)
	h:producer_ack(); assert(h.closes == 1 and not h.lease:is_settled())
	h:timer_ack(); assert(h.lease:is_settled())
	assert(not h.lease:attempt_settled(h.ticket) and not h.lease:begin(h.ticket))
end)
check("accepted abort never becomes reader EOF or child exit", function()
	local h = setup(); h:bind(); h.lease:cancel(); h:timer_ack()
	assert(h.aborts == 1 and not h.closed and not h.settled and h.closes == 0)
end)
check("reader close ACK alone never becomes physical producer settlement", function()
	local h = setup(); h:bind(); h.lease:cancel(); h:reader_ack(); h:timer_ack()
	assert(h.closes == 0 and not h.lease:is_settled())
end)
check("child exit ACK alone never becomes actual read handle close", function()
	local h = setup(); h:bind(); h.lease:cancel(); h:producer_ack(); h:timer_ack()
	assert(h.closes == 0 and not h.lease:is_settled())
end)
check("abort refusal revokes writes but retains debt until independent ACKs", function()
	local h = setup({abort = function() return false end}); h:bind(); h.lease:cancel(); h:timer_ack()
	assert(h.aborts == 1 and h.closes == 0 and not h:write())
	h:reader_ack(); h:producer_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("throwing abort cannot cause retry or manufacture physical closure", function()
	local h = setup({abort = function() error("signal unknown") end}); h:bind(); h.lease:cancel()
	h.lease:cancel(); h:timer_ack(); assert(h.aborts == 1 and h.closes == 0)
	h:reader_ack(); h:producer_ack(); assert(h.lease:is_settled())
end)
check("reentrant abort cancels exact input once without recursive native signal", function()
	local h = setup({abort = function(h) h.lease:cancel(); return true end})
	h:bind(); h.lease:cancel(); h:reader_ack(); h:producer_ack(); h:timer_ack()
	assert(h.aborts == 1 and h.closes == 1 and h.lease:is_settled())
end)
check("foreign attempt cannot bind a reader or revoke current child", function()
	local h = setup(); assert(not h.lease:bind_input({}, h.producer, h.input))
	assert(h.aborts == 0 and h:bind())
end)
check("queued close notification without actual native close state retires nothing", function()
	local h = setup(); h:bind(); h.lease:cancel(); h:producer_ack(); h:timer_ack()
	for _, fn in ipairs(h.reader_listeners) do fn() end
	assert(h.closes == 0 and not h.lease:is_settled())
	h:reader_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("pending filesystem ACK remains necessary after reader and child close", function()
	local h = setup(); h:bind(); h:write(); h.lease:cancel()
	h:reader_ack(); h:producer_ack(); h:timer_ack()
	assert(h.closes == 0 and not h.lease:is_settled())
	h.writes[1].ack(nil, 3)
	assert(h.closes == 1 and h.lease:is_settled() and h.callbacks == 1 and not h.last_ok)
end)
check("physical read closure without EOF cannot publish or admit another attempt", function()
	local h = setup(); h:bind(); h:reader_ack(); h:producer_ack()
	assert(not h.lease:attempt_settled(h.ticket) and not h.lease:begin(h.ticket))
	assert(h.truncates == 1 and h.closes == 0)
	h.lease:cancel(); h:timer_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("owner change during write ACK aborts captured child and never resumes", function()
	local h = setup(); h:bind(); h:write(); h.current = false; h.writes[1].ack(nil, 3)
	assert(h.aborts == 1 and h.callbacks == 1 and not h.last_ok and h.closes == 0)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("subscription reentry retires exact attempt before bind success", function()
	local h = setup({subscribe = function(h) h.lease:cancel(); return true end})
	assert(not h:bind() and h.aborts == 1 and h.closes == 0)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("native close-state probe reentry cannot close retained integer twice", function()
	local h = setup({reader_probe = function(h) h.lease:cancel() end})
	h:bind(); h.lease:cancel(); h:reader_ack(); h:producer_ack(); h:timer_ack()
	assert(h.aborts == 1 and h.closes == 1 and h.lease:is_settled())
end)
check("full write ACK after reentrant EOF preserves bytes but refuses resume", function()
	local h = setup({current_probe = function(h)
		if h.probe_eof then
			h.probe_eof = false
			h.lease:eof(h.ticket)
			h:producer_ack()
		end
	end})
	h:bind(); h:write(); h.probe_eof = true; h.writes[1].ack(nil, 3)
	assert(h.callbacks == 1 and not h.last_ok and h.receipt == nil)
	assert(h.lease:bytes(h.ticket) == 3 and #h.writes == 1)
	h.lease:cancel(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("original monotonic deadline aborts exact producer without replacing budget", function()
	local h = setup(); h:bind(); h.now = 100; h.expire()
	assert(h.aborts == 1 and not h:write() and not h.lease:begin(h.ticket))
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("captured input abort cannot be replaced by a foreign public method", function()
	local h = setup(); h:bind()
	h.input.abort = function() error("foreign method must not be called") end
	h.lease:cancel(); assert(h.aborts == 1)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("malformed input owner refuses without binding or calling abort", function()
	local h = setup()
	assert(not h.lease:bind_input(h.ticket, h.producer, {abort = function() end}))
	assert(h.aborts == 0 and h:bind())
end)
check("native close-state must be literal true even after child exit", function()
	local h = setup(); h:bind(); h.lease:cancel(); h:producer_ack(); h:timer_ack()
	h.closed = "true"
	for _, fn in ipairs(h.reader_listeners) do fn() end
	assert(h.closes == 0)
	h:reader_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("captured producer settlement method survives unrelated public mutation", function()
	local h = setup(); h:bind()
	h.producer.is_settled = function() return true end
	h.lease:cancel(); h:reader_ack(); h:timer_ack()
	assert(h.aborts == 1 and h.closes == 0)
	h:producer_ack(); assert(h.closes == 1 and h.lease:is_settled())
end)
check("exact reader closure without EOF forbids every future parent write", function()
	local h = setup(); h:bind(); h:reader_ack(); h:producer_ack()
	assert(not h:write() and #h.writes == 0 and h.callbacks == 0)
	h.lease:cancel(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("read-close ACK during full write probe preserves bytes and denies resume", function()
	local h = setup({current_probe = function(h)
		if h.probe_closed then
			h.probe_closed = false
			h:reader_ack()
			h:producer_ack()
		end
	end})
	h:bind(); h:write(); h.probe_closed = true; h.writes[1].ack(nil, 3)
	assert(h.callbacks == 1 and not h.last_ok and h.receipt == nil)
	assert(h.lease:bytes(h.ticket) == 3 and #h.writes == 1)
	assert(not h.lease:attempt_settled(h.ticket))
	h.lease:cancel(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("slow native reader probe cannot launch initial write after deadline", function()
	local h = setup({reader_probe = function(h)
		if h.slow_probe then h.slow_probe = false; h.now = 100 end
	end})
	h:bind(); h.slow_probe = true
	assert(not h:write() and #h.writes == 0 and h.callbacks == 0 and h.aborts == 1)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("slow native reader probe cannot launch next partial write after deadline", function()
	local h = setup({reader_probe = function(h)
		if h.slow_probe then h.slow_probe = false; h.now = 100 end
	end})
	h:bind(); assert(h:write()); h.slow_probe = true; h.writes[1].ack(nil, 1)
	assert(#h.writes == 1 and h.callbacks == 1 and not h.last_ok and h.aborts == 1)
	assert(h.lease:bytes(h.ticket) == 1)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
check("slow native reader probe cannot resume full ACK beyond original deadline", function()
	local h = setup({reader_probe = function(h)
		if h.slow_probe then h.slow_probe = false; h.now = 100 end
	end})
	h:bind(); assert(h:write()); h.slow_probe = true; h.writes[1].ack(nil, 3)
	assert(#h.writes == 1 and h.callbacks == 1 and not h.last_ok and h.receipt == nil and h.aborts == 1)
	assert(h.lease:bytes(h.ticket) == 3)
	h:reader_ack(); h:producer_ack(); h:timer_ack(); assert(h.lease:is_settled())
end)
