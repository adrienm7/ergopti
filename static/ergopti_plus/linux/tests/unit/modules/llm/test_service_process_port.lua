--- tests/unit/modules/llm/test_service_process_port.lua

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

test("explicit service runs indefinitely with referenced shared monitoring", function()
	local f = fixture(); local op = f.start()
	for _ = 1, 400 do f.tick() end
	expect(op.started and op:is_current() and not op:is_settled() and f.calls[1].cancel_count == 0, "no finite deadline")
	expect(f.calls[1].options.timeout_ms == nil and f.timers[1].repeat_ms == 25, "one logical repeating monitor and no duplicate native deadline")
	op:cancel(); f.calls[1].retire(); f.close()
end)
test("service API requires literal false and explicit source capability", function()
	for _, value in ipairs({ 0, -1, 1, 1.5, true, "false", {} }) do
		local f = fixture(); f.options.timeout_ms = value; local op = f.start()
		expect(op:is_settled() and op.result.error == "service_process_admission_invalid" and #f.calls == 0 and #f.timers == 0)
	end
	for _, key in ipairs({ "timeout_ms", "authorized" }) do
		local f = fixture(); f.options[key] = nil
		expect(f.start():is_settled() and #f.calls == 0, "nil service admission refuses")
	end
end)
test("finite and service APIs share one exact owner exclusion map", function()
	local f = fixture(); local service = f.start(); f.options.timeout_ms = 100
	local blocked = f.port.start("finite", {}, f.options, function() end)
	expect(blocked.result.error == "finite_process_owner_busy" and #f.calls == 1)
	service:cancel(); f.calls[1].retire(); f.close()
	local finite = f.port.start("finite", {}, f.options, function() end); f.options.timeout_ms = false
	expect(f.start().result.error == "service_process_owner_busy" and #f.calls == 2)
	finite:cancel(); f.calls[2].retire(); f.close(2)
end)
test("service fields remain immutable across source reentry", function()
	local f = fixture(); local args, env = { "serve" }, { "OLLAMA_HOST=127.0.0.1:11434" }
	f.options.env, f.options.capture_tail = env, true
	f.options.authorized = function() f.options.timeout_ms = 1; f.options.capture_tail = false; args[1] = "changed"; env[1] = "CHANGED=x"; return true end
	local op = f.start(nil, "ollama", args); local call = f.calls[1]
	expect(op.started and call.arguments[1] == "serve" and call.options.capture_tail == true and call.options.env[1] == "OLLAMA_HOST=127.0.0.1:11434")
	for _ = 1, 20 do f.tick() end
	expect(call.cancel_count == 0, "mutated timeout cannot shorten captured service lifetime")
	op:cancel(); call.retire(); f.close()
end)
test("service completion waits for physical owner and exact shared timer ACK", function()
	local f = fixture(); local op = f.start(); local retired = 0
	op:on_settled(function() retired = retired + 1 end)
	f.calls[1].deliver(); expect(#f.completed == 0 and not op:is_settled())
	f.calls[1].retire(); expect(#f.completed == 0 and not op:is_settled())
	f.close(); expect(op:is_settled() and retired == 1 and #f.completed == 1)
end)
test("service source refusal cancels and suppresses completion", function()
	local f = fixture(); local op = f.start(); f.current = false
	expect(not op:is_current() and not op:is_settled())
	f.tick(); expect(f.calls[1].cancel_count > 0)
	f.calls[1].retire(); f.close(); expect(op:is_settled() and #f.completed == 0)
end)
test("service source exception retains cancellation debt", function()
	local f = fixture(); local throwing = false
	f.options.authorized = function() if throwing then error("independent source error") end return true end
	local op = f.start(); throwing = true; f.tick()
	expect(not op:is_current() and not op:is_settled() and f.calls[1].cancel_count > 0)
	f.calls[1].retire(); f.close(); expect(op:is_settled() and #f.completed == 0)
end)
test("service current observer rechecks reentrant cancellation", function()
	local f = fixture(); local op, armed
	f.options.authorized = function() if armed then op:cancel() end return true end
	op = f.start(); armed = true
	expect(not op:is_current() and not op:is_settled(), "source callback cannot return stale current true")
	f.calls[1].retire(); f.close(); expect(op:is_settled() and #f.completed == 0)
end)
test("service cancellation reserves owner until all exact cleanup", function()
	local f = fixture(); local op = f.start(); expect(op:cancel() == false)
	expect(f.start().result.error == "service_process_owner_busy")
	f.calls[1].retire(); expect(f.start().result.error == "service_process_owner_busy")
	f.close(); local next_op = f.start(); expect(op:is_settled() and next_op.started)
	next_op:cancel(); f.calls[2].retire(); f.close(2)
end)
test("service timer admission refusal prevents native dispatch", function()
	local f = fixture(); f.refuse_timer = true; local op = f.start()
	expect(not op.started and not op:is_settled() and #f.calls == 0)
	f.close(); expect(op:is_settled())
end)
test("service physical acquisition exception remains unknown debt", function()
	local f = fixture(); f.throw_start = true; local op = f.start()
	expect(not op:is_settled() and op.cleanup_error == "service_process_unknown_acquisition_debt")
	expect(f.start().result.error == "service_process_owner_busy")
	op:cancel(); f.tick(); expect(not op:is_settled())
end)
test("service malformed physical capability remains unknown debt", function()
	local f = fixture(); f.malformed_start = true; local op = f.start()
	expect(not op:is_settled() and op.cleanup_error == "service_process_unknown_acquisition_debt")
	expect(f.start().result.error == "service_process_owner_busy")
end)
test("service synchronous physical completion still owns shared timer", function()
	local f = fixture(); f.on_dispatch = function(call) call.deliver(); call.retire() end
	local op = f.start(); expect(op.started and not op:is_settled() and #f.completed == 0)
	f.close(); expect(op:is_settled() and #f.completed == 1)
end)
test("service rejected close callback cannot borrow a fresh close", function()
	local f = fixture(); local op = f.start(); f.refuse_close = true
	f.calls[1].deliver(); f.calls[1].retire(); f.close()
	expect(not op:is_settled(), "refused callback retains debt")
	f.refuse_close = false; f.tick(); expect(not op:is_settled() and f.timers[1].close_requests == 2)
	f.close(); expect(op:is_settled() and #f.completed == 1)
end)
