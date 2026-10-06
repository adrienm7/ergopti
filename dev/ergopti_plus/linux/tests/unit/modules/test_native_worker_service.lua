--- tests/unit/modules/test_native_worker_service.lua

local helpers = require("tests.helpers")
local Worker = require("native_worker_owner")
local function expect(value, reason) assert(value, reason) end
local function test(name, body) helpers.it(name, body) end

local function fixture(timeout, retry)
	local f = { entries = {}, timers = {}, completed = {}, source = true, unrefs = 0 }
	local ports = { timeout_ms = timeout, retry_ms = retry == nil and 25 or retry, parse = function(value) return value end,
		complete = function(code) f.completed[#f.completed + 1] = code end }
	f.ports = ports
	ports.runner = { spawn = function(_, _, callback)
		local entry = { callback = callback, starts = 0, terminations = {}, settled = false }
		f.entries[#f.entries + 1] = entry
		local handle = {
			start = function() entry.starts = entry.starts + 1; return true end,
			isSettled = function() return entry.settled end,
			terminate = function(force) entry.terminations[#entry.terminations + 1] = force; return false end,
			onSettled = function(fn) entry.retired = fn; return not f.refuse_listener end,
		}
		return handle
	end }
	ports.native = {
		new_timer = function()
			local timer = { closes = {}, stops = 0, referenced = true }
			timer.unref = function() f.unrefs = f.unrefs + 1; timer.referenced = false end
			f.timers[#f.timers + 1] = timer
			return timer
		end,
		timer_start = function(timer, delay, interval, fn)
			timer.delay, timer.interval, timer.tick = delay, interval, fn
			if f.refuse_start then return false end
			return 0
		end,
		timer_stop = function(timer)
			timer.stops = timer.stops + 1
			if f.refuse_stop then return false end
			return 0
		end,
		close = function(timer, fn)
			timer.closes[#timer.closes + 1] = fn
			if f.refuse_close then return false end
			return 0
		end,
		unref = function(timer) timer.unref() end,
	}
	f.owner = Worker.new(function()
		return { executable = "service-fixture", arguments = {} }, function()
			if f.source_hook then f.source_hook() end
			return f.source
		end
	end, ports)
	function f.tick() f.timers[#f.timers].tick() end
	function f.finish(index)
		local entry = f.entries[index or #f.entries]
		entry.callback(37); entry.settled = true; entry.retired()
	end
	function f.close(index, attempt)
		local timer = f.timers[index or #f.timers]
		assert(timer.closes[attempt or #timer.closes], "exact native close callback missing")()
	end
	return f
end

test("literal false service survives hundreds of ticks with referenced monitor", function()
	local f = fixture(false)
	expect(f.owner.run("service"), "explicit service must start")
	for _ = 1, 400 do f.tick() end
	expect(#f.entries[1].terminations == 0 and f.owner.has_pending(), "service has no elapsed deadline")
	expect(f.unrefs == 0 and f.timers[1].referenced, "service monitor remains referenced")
	f.finish(); expect(f.owner.has_pending() and #f.completed == 0, "native timer close remains debt")
	f.close(); expect(not f.owner.has_pending() and f.completed[1] == 37, "exact completion after retirement")
end)
test("service policy scalar snapshot survives external ports mutation", function()
	local f = fixture(false)
	f.source_hook = function() f.ports.timeout_ms = 1; f.ports.retry_ms = 1 end
	expect(f.owner.run("service"), "snapshot service starts")
	for _ = 1, 20 do f.tick() end
	expect(#f.entries[1].terminations == 0, "mutated finite timeout cannot replace captured service policy")
	expect(f.timers[1].delay == 25 and f.timers[1].interval == 25, "retry snapshot remains unchanged")
	f.finish(); f.close()
end)
test("positive finite policy retains its original fourth-tick deadline", function()
	local f = fixture(100)
	expect(f.owner.run("finite"), "finite starts")
	for _ = 1, 3 do f.tick() end
	expect(#f.entries[1].terminations == 0, "finite deadline not reached early")
	f.tick(); expect(#f.entries[1].terminations == 1 and f.owner.has_pending(), "finite kill is not retirement")
	f.finish(); f.close(); expect(not f.owner.has_pending() and #f.completed == 0, "cancel suppresses shared completion")
end)
test("zero nil malformed and nonfinite policy cannot become service", function()
	for _, value in ipairs({ 0, -1, true, "100", "false", {}, math.huge, -math.huge, 0 / 0 }) do
		local ok = pcall(fixture, value)
		expect(not ok, "malformed timeout must refuse construction")
	end
	expect(not pcall(fixture, nil), "missing timeout is not service")
end)
test("source refusal cancels service without fabricating physical settlement", function()
	local f = fixture(false); expect(f.owner.run("service"))
	f.source = false; f.tick()
	expect(#f.entries[1].terminations == 1 and f.owner.has_pending(), "source revocation retains native debt")
	f.finish(); expect(f.owner.has_pending(), "process receipt still owes own timer close")
	f.close(); expect(not f.owner.has_pending() and #f.completed == 0, "stale service cannot publish")
end)
test("source exception has the same retained cancellation semantics", function()
	local f = fixture(false); expect(f.owner.run("service"))
	f.source_hook = function() error("independent source refusal") end
	f.tick(); expect(#f.entries[1].terminations == 1 and f.owner.has_pending(), "throw retains cancellation debt")
	f.finish(); f.close(); expect(not f.owner.has_pending() and #f.completed == 0)
end)
test("pause and resume retain debt and defer the next service until own ACK", function()
	local f = fixture(false); expect(f.owner.run("service"))
	expect(f.owner.set_paused(true) == false and f.owner.has_pending(), "pause signal is not cleanup")
	expect(f.owner.set_paused(false) == false and f.owner.run("successor") == false, "resume cannot borrow pending retirement")
	f.finish(); expect(f.owner.has_pending(), "native timer retirement still pending")
	f.close(); expect(f.owner.run("successor"), "deferred resume admits after exact settlement")
	f.finish(); f.close(); expect(#f.completed == 1 and f.completed[1] == 37)
end)
test("service timer-stop refusal retains its exact retirement requirement", function()
	local f = fixture(false); expect(f.owner.run("service")); f.refuse_stop = true
	f.finish(); expect(f.owner.has_pending() and #f.timers[1].closes == 0, "stop refused, no invented close")
	f.refuse_stop = false; f.tick(); expect(f.owner.has_pending(), "new stop still needs close callback")
	f.close(); expect(not f.owner.has_pending() and #f.completed == 1)
end)
test("rejected service close callbacks cannot borrow a fresh attempt", function()
	local f = fixture(false); expect(f.owner.run("service")); f.refuse_close = true; f.finish()
	f.close(1, 1); expect(f.owner.has_pending() and #f.completed == 0, "rejected callback has no authority")
	f.refuse_close = false; f.tick(); expect(#f.timers[1].closes == 2)
	f.close(1, 1); expect(f.owner.has_pending(), "old callback cannot borrow newer admission")
	f.close(1, 2); expect(not f.owner.has_pending() and #f.completed == 1)
	expect(f.owner.run("successor")); f.close(1, 2)
	expect(f.owner.has_pending() and #f.completed == 1, "old exact callback cannot release a successor")
	f.finish(2); f.close(2); expect(#f.completed == 2)
end)
for _, mode in ipairs({ "refusal", "exception" }) do
	test("service pulse " .. mode .. " preserves physical retirement", function()
		local f = fixture(false); expect(f.owner.run("service"))
		f.ports.pulse = function() if mode == "exception" then error("pulse exception") end return false end
		f.tick(); expect(#f.entries[1].terminations == 1 and f.owner.has_pending(), "failed pulse cancels without release")
		f.finish(); expect(f.owner.has_pending(), "failed pulse retains timer debt")
		f.ports.pulse = nil; f.close(); expect(not f.owner.has_pending() and #f.completed == 0)
	end)
end
test("refused service timer prevents physical start and owns close debt", function()
	local f = fixture(false); f.refuse_start = true
	expect(f.owner.run("service") == false and f.entries[1].starts == 0, "unarmed monitor cannot start service")
	expect(f.owner.has_pending() and #f.entries[1].terminations == 1, "deferred handle remains owned")
	f.entries[1].settled = true; f.tick(); expect(f.owner.has_pending(), "exact timer close remains due")
	f.close(); expect(not f.owner.has_pending() and #f.completed == 0)
end)
test("service rejects malformed repeating monitor policy", function()
	for _, retry in ipairs({ 0, -1, false, true, "25", {}, math.huge, -math.huge, 0 / 0 }) do
		expect(not pcall(fixture, false, retry), "invalid retry must not create an unmonitored service")
	end
end)
test("refused service settlement observer cancels and independently polls debt", function()
	local f = fixture(false); f.refuse_listener = true
	expect(f.owner.run("service") == false and f.owner.has_pending(), "refused observer cancels exact service")
	expect(#f.entries[1].terminations == 1, "observer refusal triggers cancellation")
	f.entries[1].settled = true; f.tick(); expect(f.owner.has_pending(), "poll proof still owes timer ACK")
	f.close(); expect(not f.owner.has_pending() and #f.completed == 0)
end)
