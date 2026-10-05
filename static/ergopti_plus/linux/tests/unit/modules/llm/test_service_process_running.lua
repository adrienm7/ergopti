--- tests/unit/modules/llm/test_service_process_running.lua

local helpers = require("tests.helpers")
local Worker = require("native_worker_owner")
local Port = require("llm.finite_process_port")
local function expect(value, reason) assert(value, reason) end
local function test(name, body) helpers.it(name, body) end

local serial = 0
local function fixture()
	serial = serial + 1
	local f = { timers = {}, calls = {}, completed = {}, current = true }
	local native = {}
	function native.new_timer()
		local timer = { closed = false, closing = false }; f.timers[#f.timers + 1] = timer
		if f.on_allocate then f.on_allocate() end
		return timer
	end
	function native.timer_start(timer, delay, repeat_ms, callback)
		timer.delay, timer.repeat_ms, timer.callback = delay, repeat_ms, callback
		if f.refuse_timer then return false end
		return 0
	end
	function native.timer_stop(timer) timer.stopped = true if f.refuse_stop then return false end return 0 end
	function native.close(timer, callback)
		timer.close_requests = (timer.close_requests or 0) + 1
		timer.closing = true; timer.close_callback = callback
		if f.refuse_close then return false end
		return 0
	end
	local Process = {}
	function Process.start(executable, arguments, options, callback)
		if f.throw_start then error("independent acquisition exception") end
		if f.malformed_start then return {} end
		local call = { executable = executable, arguments = arguments, options = options,
			callback = callback, retired = false, cancel_count = 0, listeners = {} }
		local op = { started = f.refused_start ~= true }; call.operation = op
		f.calls[#f.calls + 1] = call
		function op:is_settled() return call.retired end
		function op:is_running()
			if f.running_hook then return f.running_hook(call) end
			return not call.retired and call.cancel_count == 0 and call.exited ~= true
		end
		function op:on_settled(listener)
			if f.refuse_listener then return false end
			call.listeners[#call.listeners + 1] = listener
			if call.retired then listener() end
			return true
		end
		function op:cancel()
			call.cancel_count = call.cancel_count + 1
			op.result = { ok = false, exit_code = -1, stdout = "", stderr = "", error = "cancelled" }
			return false -- Signal acceptance is never physical settlement.
		end
		function call.deliver(result)
			op.result = result or { ok = true, exit_code = 0, stdout = "GNU coreutils --zero", stderr = "diagnostic" }
			callback(op.result)
		end
		function call.retire()
			call.retired = true
			for _, listener in ipairs(call.listeners) do listener() end
		end
		if f.on_dispatch then f.on_dispatch(call) end
		return op
	end
	f.port = Port.new(Worker, Process, native, 25)
	f.options = { owner = "finite-test-" .. serial, authorized = function() return f.current end,
		timeout_ms = false, max_output_bytes = 65536 }
	function f.start(options, program, arguments)
		return f.port.start_service(program or "sha256sum", arguments or { "--help" }, options or f.options,
			function(result) f.completed[#f.completed + 1] = result end)
	end
	function f.tick(index) f.timers[index or 1].callback() end
	function f.close(index)
		local timer = f.timers[index or 1]
		expect(timer.closing and timer.close_callback, "shared timer must own requested close")
		timer.closed = true; timer.close_callback()
	end
	return f
end

test("service running proof uses physical lifecycle rather than logical current", function()
	local f = fixture(); local op = f.start(); expect(op:is_current() and op:is_running())
	f.calls[1].exited = true
	expect(op:is_current() and not op:is_settled() and not op:is_running(), "known exit debt must not become ready service")
	op:cancel(); f.calls[1].retire(); f.close()
end)
test("service running proof refuses absent malformed throwing or false native predicates", function()
	for _, mode in ipairs({ "missing", "malformed", "throw", "false" }) do
		local f = fixture(); local op = f.start(); local cap = f.calls[1].operation
		if mode == "missing" then cap.is_running = nil
		elseif mode == "malformed" then cap.is_running = true
		elseif mode == "throw" then cap.is_running = function() error("native running refusal") end
		else cap.is_running = function() return false end end
		expect(not op:is_running() and not op:is_settled(), "unknown running observation is not affirmative readiness")
		op:cancel(); f.calls[1].retire(); f.close()
	end
end)
test("service running proof rechecks logical cancellation from native predicate", function()
	local f = fixture(); local op = f.start()
	f.running_hook = function() op:cancel(); return true end
	expect(not op:is_running() and not op:is_settled(), "reentrant native predicate cannot outlive logical owner")
	f.calls[1].retire(); f.close()
end)
test("service running proof rechecks native exit at final logical source boundary", function()
	local f = fixture(); local armed, checks = false, 0
	f.options.authorized = function()
		if armed then checks = checks + 1; if checks == 2 then f.calls[1].exited = true end end
		return true
	end
	local op = f.start(); armed = true
	expect(not op:is_running() and checks >= 2 and op:is_current(), "last source call cannot borrow earlier native running state")
	op:cancel(); f.calls[1].retire(); f.close()
end)
test("service running proof excludes settled or superseded exact operations", function()
	local f = fixture(); local old = f.start(); f.calls[1].deliver(); f.calls[1].retire(); f.close()
	local successor = f.start()
	expect(old:is_settled() and not old:is_running() and successor:is_running(), "successor never lends lifecycle to old operation")
	successor:cancel(); f.calls[2].retire(); f.close(2)
end)
