--- tests/unit/infra/test_output_continuations.lua

--- Normal discovery adapter for frozen independent controlled-native cases.
--- This adapter does not establish physical curl, filesystem or enterprise coverage.

local helpers = require("tests.helpers")

--- Literal output continuation controls against actual lease/target modules.
--- Native transport acknowledgements are explicit controlled ports, not proof
--- of physical curl/PAC/kernel behavior. Expected final bytes are handwritten.
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(body, received)
	local h = { now = 0.25, current = true, bytes = "", truncates = 0, writes = {}, results = {} }
	local timer = { started = true }
	function timer:is_settled() return true end
	function timer:cancel() return true end
	function timer:on_settled() return true end
	local lease = assert(Output.new({ now_ms = function() return h.now end,
		deadline = function() return timer end, open = function() return 7 end,
		truncate = function() h.truncates = h.truncates + 1; h.bytes = ""; return true end,
		write = function(_, chunk, _, callback)
			h.writes[#h.writes + 1] = { chunk = chunk, callback = callback }; return {}
		end,
		close = function() h.closed = true; return true end,
		hash = function() error("this control never hashes") end,
	}).reserve("/owned", {}, function() return h.current end, 100.5))
	local ticket = assert(lease:begin())
	local target = assert(Target.create(lease, ticket))
	local producer = { settled = false }
	function producer:is_settled() return self.settled end
	function producer:on_settled(fn) h.producer_ack = fn; return true end
	local input = { closed = false }
	function input:abort() return true end
	function input:reader_closed() return self.closed end
	function input:on_reader_closed(_, _, fn) h.reader_ack = fn; return true end
	function input:pause() return true end
	function input:resume() return true end
	function input:live() return h.current end
	function input:write_ack() end
	function input:continuation_receipt(_, owner, result)
		if not rawequal(owner, producer) or not rawequal(result, h.result) then return nil end
		return { result = h.result, reader_eof = h.eof == true, physical_settled = producer.settled,
			cancelled = h.cancelled == true, received_bytes = h.received or received or #body }
	end
	h.lease, h.ticket, h.target, h.producer, h.input = lease, ticket, target, producer, input
	h.sink = assert(Target.attach(target, producer, input))
	if #body > 0 then assert(h.sink:consume(body)) end
	function h:writer_ack()
		for _, work in ipairs(self.writes) do
			if not work.done then
				work.done = true; self.bytes = self.bytes .. work.chunk; work.callback(nil, #work.chunk)
			end
		end
	end
	function h:retire()
		self.eof = true; assert(self.sink:eof()); input.closed = true; self.reader_ack()
		producer.settled = true; self.producer_ack()
	end
	function h:next(kind, guard)
		return Target.next(target, producer, self.result, kind, guard or function() return self.current end)
	end
	return h
end
local function redirect()
	return { ok = false, status = 302, redirect_receipt = { format = "curl-single-hop-v1" } }
end
test("nonzero redirect body resets only after writer EOF and physical ACK", function()
	local h = fixture("intermediate"); h.result = redirect(); h:writer_ack(); h:retire()
	local next_target = assert(h:next("redirect"))
	assert(Target.valid(next_target) and h.truncates == 2 and h.bytes == "")
end)
test("pending parent write refuses redirect reset", function()
	local h = fixture("intermediate"); h.result = redirect(); h:retire()
	assert(h:next("redirect") == nil and h.truncates == 1)
end)
test("physical child ACK without actual EOF refuses continuation", function()
	local h = fixture(""); h.result = redirect(); h.producer.settled = true
	assert(h:next("redirect") == nil and h.truncates == 1)
end)
test("actual EOF without physical child retirement refuses continuation", function()
	local h = fixture(""); h.result = redirect(); h.eof = true; h.sink:eof()
	assert(h:next("redirect") == nil and h.truncates == 1)
end)
test("zero received and committed body permits admitted relay", function()
	local h = fixture(""); h.result = { ok = false }; h:retire()
	assert(h:next("relay") ~= nil and h.truncates == 2)
end)
test("nonzero received but zero committed bytes cannot authorize relay", function()
	local h = fixture("", 3); h.result = { ok = false }; h:retire()
	assert(h:next("relay") == nil and h.truncates == 1)
end)
test("nonzero committed body cannot authorize relay", function()
	local h = fixture("abc"); h.result = { ok = false }; h:writer_ack(); h:retire()
	assert(h:next("relay") == nil and h.truncates == 1 and h.bytes == "abc")
end)
test("original current source refuses before destructive reset", function()
	local h = fixture("intermediate"); h.result = redirect(); h:writer_ack(); h:retire(); h.current = false
	assert(h:next("redirect") == nil and h.truncates == 1)
end)
test("slow final continuation guard consumes original deadline", function()
	local h = fixture("intermediate"); h.result = redirect(); h:writer_ack(); h:retire()
	assert(h:next("redirect", function() h.now = 100.5; return true end) == nil)
	assert(h.truncates == 1)
end)
test("a consumed predecessor cannot reset twice", function()
	local h = fixture(""); h.result = { ok = false }; h:retire(); assert(h:next("relay"))
	assert(h:next("relay") == nil and h.truncates == 2)
end)
test("foreign result equality cannot borrow native receipt", function()
	local h = fixture(""); h.result = redirect(); h:retire()
	local calls = 0; local meta = { __eq = function() calls = calls + 1; return true end }
	local original = h.result; setmetatable(original, meta)
	local foreign = setmetatable({}, meta)
	local ok, err = xpcall(function()
		assert(Target.next(h.target, h.producer, foreign, "redirect", function() return true end) == nil)
		assert(calls == 0 and h.truncates == 1)
	end, debug.traceback)
	setmetatable(original, nil)
	if not ok then error(err, 0) end
end)
test("cancelled native producer cannot continue even after ACK", function()
	local h = fixture(""); h.result = redirect(); h:retire(); h.cancelled = true
	assert(h:next("redirect") == nil and h.truncates == 1)
end)
test("final positive body returns a private completion capability", function()
	local h = fixture("abc"); h.result = { ok = true }; h:writer_ack(); h:retire()
	assert(type(Target.complete(h.target, h.producer, h.result)) == "table")
	assert(Target.complete(h.target, h.producer, h.result) == nil)
end)
test("fractional native received count refuses final proof", function()
	local h = fixture("abc"); h.result = { ok = true }; h:writer_ack(); h:retire(); h.received = 3.5
	assert(Target.complete(h.target, h.producer, h.result) == nil)
end)
test("nonfinite native received count refuses final proof", function()
	local h = fixture("abc"); h.result = { ok = true }; h:writer_ack(); h:retire(); h.received = 0/0
	assert(Target.complete(h.target, h.producer, h.result) == nil)
end)
test("empty final archive cannot obtain a sealing capability", function()
	local h = fixture(""); h.result = { ok = true }; h:retire()
	assert(Target.complete(h.target, h.producer, h.result) == nil)
end)
test("final completion requires actual EOF and physical producer ACK", function()
	local h = fixture("abc"); h.result = { ok = true }; h:writer_ack(); h.producer.settled = true
	assert(Target.complete(h.target, h.producer, h.result) == nil)
end)
test("forged final result cannot borrow a completed producer", function()
	local h = fixture("abc"); h.result = { ok = true }; h:writer_ack(); h:retire()
	local calls = 0; local meta = { __eq = function() calls = calls + 1; return true end }
	local original = h.result; setmetatable(original, meta)
	local foreign = setmetatable({ ok = true }, meta)
	local ok, err = xpcall(function()
		assert(Target.complete(h.target, h.producer, foreign) == nil and calls == 0)
	end, debug.traceback)
	setmetatable(original, nil)
	if not ok then error(err, 0) end
end)
assert(#tests == 18, "Independent frozen output case floor must remain 18")
helpers.describe("test_output_continuations", function()
	for _, case in ipairs(tests) do
		helpers.it(case[1], case[2])
	end
end)
