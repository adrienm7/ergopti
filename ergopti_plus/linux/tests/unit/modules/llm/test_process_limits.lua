--- tests/unit/modules/llm/test_process_limits.lua

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
	f.port = Port.new(Worker, Process, native)
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

test("canonical process defaults preserve independent literal policy", function()
	local Limits = require("llm.process_limits")
	local first, second = Limits.defaults(), Limits.defaults()
	expect(first.worker_retry_ms == 25 and first.group_recheck_ms == 25 and first.max_output_bytes == 65536, "independent existing defaults")
	first.worker_retry_ms, first.group_recheck_ms, first.max_output_bytes = 1, 1, 1
	expect(second.worker_retry_ms == 25 and second.group_recheck_ms == 25 and second.max_output_bytes == 65536, "default snapshots remain detached")
	local third = Limits.defaults(); expect(third.worker_retry_ms == 25 and third.max_output_bytes == 65536, "caller cannot alter canonical defaults")
end)
test("omitted bridge defaults map unchanged into native capture and shared timer", function()
	local f = fixture(); f.options.max_output_bytes = nil; local op = f.start()
	expect(op.started and f.timers[1].delay == 25 and f.timers[1].repeat_ms == 25, "finite compatibility cadence is unchanged")
	expect(f.calls[1].options.max_output_bytes == 65536, "both owners consume canonical capture default")
	op:cancel(); f.calls[1].retire(); f.close()
end)
test("explicit caller retry and output bounds override canonical compatibility defaults", function()
	local f = fixture(); local Process = { start = function(program, args, opts, cb)
		f.explicit_bound = opts.max_output_bytes
		return { started = false, result = { ok = false }, cancel = function() return true end,
			is_settled = function() return true end, on_settled = function(_, fn) fn(); return true end }
	end }
	local timer = { new_timer = function() return {} end, timer_start = function(handle, delay, interval, fn)
		f.explicit_delay, f.explicit_interval = delay, interval; return 0
	end, timer_stop = function() return 0 end, close = function(_, fn) fn(); return 0 end }
	local port = Port.new(Worker, Process, timer, 50)
	local op = port.start_service("fixture", {}, { owner = "explicit-defaults", timeout_ms = false,
		authorized = function() return true end, max_output_bytes = 4096 }, function() end)
	expect(op:is_settled() and f.explicit_delay == 50 and f.explicit_interval == 50 and f.explicit_bound == 4096, "canonical production cadence remains caller-owned")
end)
