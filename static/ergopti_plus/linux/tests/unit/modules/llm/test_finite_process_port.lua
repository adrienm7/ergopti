--- tests/unit/modules/llm/test_finite_process_port.lua

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
		timeout_ms = 100, max_output_bytes = 65536 }
	function f.start(options, program, arguments)
		return f.port.start(program or "sha256sum", arguments or { "--help" }, options or f.options,
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

test("finite timeout is mandatory and refuses before any native acquisition", function()
	for _, timeout in ipairs({ false, 0, -1, 1.5 }) do
		local f = fixture(); f.options.timeout_ms = timeout
		local op = f.start(); expect(op:is_settled() and not op.started, "invalid deadline is empty refusal")
		expect(#f.calls == 0 and #f.timers == 0 and f.completed[1].error == "finite_process_admission_invalid", "no acquisition")
	end
	local f = fixture(); f.options.timeout_ms = nil
	expect(f.start():is_settled() and #f.calls == 0, "nil is forbidden for finite helper")
end)
test("shared timer admission precedes deferred process dispatch", function()
	local f = fixture(); f.refuse_timer = true
	local op = f.start()
	expect(#f.calls == 0 and #f.timers == 1 and not op:is_settled(), "refused timer prevents spawn but owns close debt")
	f.close(); expect(op:is_settled() and not op.started, "empty deferred facade plus timer ACK settles")
end)
test("immutable helper fields map to actual shared worker and native capture", function()
	local f = fixture(); local args = { "--zero", "--", "/private/archive" }; local env = { "OLLAMA_HOST=127.0.0.1:11434" }
	f.options.env, f.options.cwd, f.options.capture_tail = env, "/private", false
	f.options.authorized = function() args[1] = "MUTATED"; env[1] = "MUTATED=x"; f.options.owner = "MUTATED"; return true end
	local op = f.start(nil, "sha256sum", args); local call = f.calls[1]
	expect(op.started and call.executable == "sha256sum" and call.arguments[1] == "--zero", "argv snapshot")
	expect(call.options.owner:match("^finite%-test%-%d+$") and call.options.timeout_ms == nil, "shared sole finite deadline")
	expect(call.options.env[1] == "OLLAMA_HOST=127.0.0.1:11434" and call.options.cwd == "/private", "env/cwd snapshot")
	expect(f.timers[1].delay == 25 and f.timers[1].repeat_ms == 25 and call.options.max_output_bytes == 65536, "actual timer policy")
	call.deliver(); call.retire(); f.close(); expect(op:is_settled(), "cleanup fixture")
end)
test("completion waits for exact process settlement and shared timer close ACK", function()
	local f = fixture(); local op = f.start(); local call = f.calls[1]; local retired = 0
	op:on_settled(function() retired = retired + 1 end)
	call.deliver(); expect(#f.completed == 0 and not op:is_settled(), "result callback alone does not retire native")
	call.retire(); expect(#f.completed == 0 and not op:is_settled() and f.timers[1].closing, "native retirement still owes timer ACK")
	f.close(); expect(op:is_settled() and retired == 1 and #f.completed == 1, "all physical debts retired")
	expect(f.completed[1].stdout == "GNU coreutils --zero" and f.completed[1].stderr == "diagnostic", "full result retained")
end)
test("same owner cannot succeed before either process or timer physical retirement", function()
	local f = fixture(); local op = f.start(); local busy = f.start()
	expect(busy:is_settled() and busy.result.error == "finite_process_owner_busy" and #f.calls == 1, "process debt blocks successor")
	f.calls[1].deliver(); f.calls[1].retire(); busy = f.start()
	expect(busy.result.error == "finite_process_owner_busy" and #f.calls == 1, "timer debt blocks successor")
	f.close(); local next_op = f.start(); expect(next_op.started and #f.calls == 2 and op:is_settled(), "only actual retirement releases exact slot")
	next_op:cancel(); f.calls[2].retire(); f.close(2)
end)
test("source admission reentry observes reserved exact owner", function()
	local f = fixture(); local nested, entered = nil, false
	f.options.authorized = function() if not entered then entered = true; nested = f.start() end return true end
	local op = f.start(); expect(nested.result.error == "finite_process_owner_busy" and #f.calls == 1, "outer reservation cannot be overwritten")
	op:cancel(); f.calls[1].retire(); f.close()
end)
test("cancellation suppresses delivery and retains physical process and timer debt", function()
	local f = fixture(); local op = f.start(); local call = f.calls[1]
	expect(op:cancel() == false and call.cancel_count > 0 and not op:is_settled(), "termination is not settlement")
	call.retire(); expect(not op:is_settled() and #f.completed == 0, "timer close debt retained")
	f.close(); expect(op:is_settled() and #f.completed == 0 and op.result.error == "cancelled", "cancel settles without delivery")
end)
test("shared finite deadline cancels exact child then reports after physical retirement", function()
	local f = fixture(); local op = f.start(); local call = f.calls[1]
	for _ = 1, 3 do f.tick() end
	expect(call.cancel_count == 0, "deadline not reached before fourth 25ms tick")
	f.tick(); expect(call.cancel_count > 0 and not op:is_settled() and #f.completed == 0, "deadline kill does not settle")
	call.retire(); f.close(); expect(op:is_settled() and #f.completed == 1 and f.completed[1].error == "cancelled", "honest finite failure receipt")
end)
test("stale source retires without callbacks or owner release before ACKs", function()
	local f = fixture(); local op = f.start(); f.current = false; f.tick()
	expect(f.calls[1].cancel_count > 0 and not op:is_settled(), "stale source cancels physically owned child")
	f.calls[1].retire(); f.close(); expect(op:is_settled() and #f.completed == 0, "stale completion cannot publish")
end)
test("reentrant cancellation during acquisition retains returned exact capability", function()
	local f = fixture(); local operation
	f.on_dispatch = function(call) f.current = false end
	operation = f.start(); expect(#f.calls == 1 and f.calls[1].cancel_count > 0 and not operation:is_settled(), "revoked acquisition retains exact capability")
	f.calls[1].retire(); f.close(); expect(operation:is_settled() and #f.completed == 0, "revoked exact cleanup ACKs")
end)
test("throwing native acquisition retains honest unknown debt", function()
	local f = fixture(); f.throw_start = true; local op = f.start()
	expect(not op:is_settled() and op.cleanup_error == "finite_process_unknown_acquisition_debt", "throw carries no physical empty receipt")
	expect(f.start().result.error == "finite_process_owner_busy", "unknown exact acquisition blocks successor")
	op:cancel(); f.tick(); expect(not op:is_settled(), "retry/kill cannot manufacture missing capability")
end)
test("malformed native acquisition retains honest unknown debt", function()
	local f = fixture(); f.malformed_start = true; local op = f.start()
	expect(not op:is_settled() and op.cleanup_error == "finite_process_unknown_acquisition_debt", "malformed capability cannot retire")
	expect(f.start().result.error == "finite_process_owner_busy", "malformed debt blocks successor")
end)
test("refused native settlement listener still requires independent physical polling", function()
	local f = fixture(); f.refuse_listener = true; local op = f.start(); local call = f.calls[1]
	call.deliver(); call.retire(); expect(not op:is_settled() and not f.timers[1].closing, "no fabricated callback receipt")
	f.tick(); expect(f.timers[1].closing and not op:is_settled(), "shared polling proves native settlement only")
	f.close(); expect(op:is_settled() and #f.completed == 1 and op.cleanup_error == nil, "proved physical retirement resolves monitor refusal")
end)
test("refused shared timer stop cannot borrow process retirement", function()
	local f = fixture(); local op = f.start(); f.refuse_stop = true
	f.calls[1].deliver(); f.calls[1].retire(); expect(not op:is_settled() and not f.timers[1].closing, "stop receipt required")
	f.refuse_stop = false; f.tick(); f.close(); expect(op:is_settled(), "own timer stop plus ACK permits successor")
end)
test("refused shared timer close cannot borrow an attempted close callback", function()
	local f = fixture(); local op = f.start(); f.refuse_close = true
	f.calls[1].deliver(); f.calls[1].retire(); expect(not op:is_settled(), "close admission refused")
	f.close(); expect(not op:is_settled(), "callback from refused close does not qualify ownership")
	f.refuse_close = false; f.tick()
	expect(not op:is_settled() and f.timers[1].close_requests == 2, "refused close callback cannot substitute fresh close admission")
	f.close(); expect(op:is_settled(), "fresh admitted close ACK required")
end)
test("empty native refusal retains diagnostic result after shared timer ACK", function()
	local f = fixture(); f.refused_start = true
	f.on_dispatch = function(call) call.deliver({ ok = false, exit_code = -1, stdout = "", stderr = "", error = "binary unavailable" }); call.retire() end
	local op = f.start(); expect(not op.started and not op:is_settled(), "no native process started; shared timer still owned")
	f.close(); expect(op:is_settled() and f.completed[1].error == "binary unavailable", "exact native refusal diagnostic delivered")
end)
test("synchronous native completion retains actual shared close debt", function()
	local f = fixture(); f.on_dispatch = function(call) call.deliver(); call.retire() end
	local op = f.start(); expect(op.started and not op:is_settled() and #f.completed == 0, "sync completion not sync timer close")
	f.close(); expect(op:is_settled() and #f.completed == 1, "sync native settlement qualifies only after timer ACK")
end)
test("output callback and capture policy are preserved without port dispatch", function()
	local f = fixture(); local seen = {}; f.options.on_output = function(chunk, stream) seen[#seen + 1] = { chunk, stream } end
	f.options.capture_tail = true; local op = f.start(); local call = f.calls[1]
	expect(call.options.capture_tail == true and #seen == 0, "port fabricates no native output")
	call.options.on_output("latest", "stderr"); expect(seen[1][1] == "latest" and seen[1][2] == "stderr", "native ABI order preserved")
	op:cancel(); call.retire(); f.close()
end)
test("invalid sparse argv and environment refuse without native calls", function()
	local f = fixture(); expect(f.start(nil, nil, { [1] = "a", [3] = "b" }):is_settled(), "sparse argv refused")
	f.options.env = { "not-a-binding" }; local op = f.start()
	expect(op:is_settled() and op.result.error == "finite_process_admission_invalid" and #f.calls == 0 and #f.timers == 0, "invalid env no native acquisition")
end)
