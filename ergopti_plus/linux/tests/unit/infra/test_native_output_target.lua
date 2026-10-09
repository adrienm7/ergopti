--- tests/unit/infra/test_native_output_target.lua

--- ==============================================================================
--- MODULE: Native Output Sink Composition Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

--- controls/test_native_output_target.lua
--- Independent actual-core caller controls; original fake fixture prefix retained.
--- Creates the minimum libuv process/pipe surface used by HttpClient.
--- @param config table|nil
--- @return table fake, table state
local function fake_luv(config)
	local options = config or {}
	local state = { groups = {}, probes = {}, timer_starts = {}, kills = {}, handles = {}, requests = {}, closes = {}, refused_closes = {},
		descriptors = {}, descriptor_closes = {}, identities = {} }
	local fake = {}
	local function refused(receipt)
		if receipt == "throw" then error("SIMULATED close refusal") end
		if receipt == "false" then return false end
		return nil
	end

	local function handle(kind)
		if options.allocation_nil_at == #state.handles + 1 then return nil end
		if options.allocation_failure_at == #state.handles + 1 then error("allocation refused") end
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.new_pipe() return handle("pipe") end
	function fake.update_time() end -- native void-style clock refresh
	function fake.pipe()
		if options.body_pipe_failure then return nil, "pipe refused" end
		local read, write = 100 + #state.descriptors, 101 + #state.descriptors
		state.descriptors[#state.descriptors + 1] = read
		state.descriptors[#state.descriptors + 1] = write
		state.identities[read] = { dev = 1, ino = read, type = "fifo" }
		state.identities[write] = { dev = 1, ino = read, type = "fifo" }
		return { read = read, write = write }
	end
	function fake.pipe_open(pipe, descriptor)
		state.first_body_handle = state.first_body_handle or pipe
		if options.body_attach_failure then return nil, "attachment refused" end
		pipe.descriptor = descriptor
		state.body_pipe = pipe
		return 0
	end
	function fake.fs_close(descriptor)
		state.descriptor_closes[#state.descriptor_closes + 1] = descriptor
		if options.raw_close_receipt and not state.allow_closes then
			if options.close_after_retirement then
				state.identities[descriptor] = options.reuse_descriptor and { dev = 9, ino = 99, type = "file" } or nil
			end
			return refused(options.raw_close_receipt)
		end
		state.identities[descriptor] = nil
		return true
	end
	function fake.fs_fstat(descriptor)
		if options.body_metadata_failure and not state.allow_metadata then return nil, "SIMULATED metadata failure", "EIO" end
		if state.identities[descriptor] then return state.identities[descriptor] end
		return nil, "descriptor absent", "EBADF"
	end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		state.timer_starts[#state.timer_starts + 1] = { timer = timer, timeout = timeout_ms, repeat_ms = repeat_ms, callback = callback }
		if options.timer_failure or (repeat_ms > 0 and state.monitor_refused) then return nil, "timer refused" end
		timer.stopped = false
		timer.timeout_ms = timeout_ms
		timer.repeat_ms = repeat_ms
		timer.callback = callback
		return true
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback) pipe.read_callback = callback; return true end
	function fake.write(pipe, data, callback)
		if pipe == state.body_pipe and options.body_write_failure then return nil, "write refused" end
		pipe.written = (pipe.written or "") .. data
		if pipe == state.body_pipe then state.body = pipe.written else state.config = pipe.written end
		if pipe == state.body_pipe and options.defer_body_write then state.body_written = callback; return true end
		if callback then callback(nil) end
		return true
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value, callback)
		if options.refused_close_callback and not state.allow_closes then
			state.refused_closes[#state.refused_closes + 1] = callback
			if options.refused_close_sync then callback() end
			if options.refused_close_callback == "throw" then error("close refused") end
			if options.refused_close_callback == "false" then return false end
			return nil, "close refused"
		end
		if value == state.first_body_handle and options.body_handle_close_receipt and not state.allow_closes then
			return refused(options.body_handle_close_receipt)
		end
		if options.close_failure and not state.allow_closes then return nil, "close refused" end
		if value.kind == "timer" and state.monitor_close_refused then return nil, "monitor close refused" end
		value.closing = true
		if value.descriptor then
			state.descriptor_closes[#state.descriptor_closes + 1] = value.descriptor
			state.identities[value.descriptor] = nil
			value.descriptor = nil
		end
		if callback then
			state.closes[#state.closes + 1] = { handle = value, callback = callback }
			if not options.defer_close then callback() end
		end
	end
	function state.ack_closes()
		for _, receipt in ipairs(state.closes) do
			if not receipt.acknowledged then
				receipt.acknowledged = true
				receipt.callback()
			end
		end
	end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		if signal == 0 then
			state.probes[#state.probes + 1] = { pid = pid, signal = signal }
			if state.probe_mode == "throw" then error("probe refused") end
			if state.probe_mode == "false" then return false end
			if state.probe_mode == "nil" then return nil end
			if state.probe_mode == "text-only" then return nil, "ESRCH: no such process" end
			if state.probe_mode == "unknown-code" then return nil, "probe refused", "EPERM" end
			if state.groups[-pid] == false then return nil, "ESRCH: no such process", "ESRCH" end
			return true
		end
		if options.kill_missing then return nil, "ESRCH: no such process", "ESRCH" end
		if options.kill_failure and not state.allow_kills then return nil, "EPERM: operation not permitted", "EPERM" end
		return true
	end
	function fake.spawn(command, options, callback)
		if config and config.spawn_failure then return nil, "EACCES", "permission denied" end
		local pid = 4320 + #state.requests + 1
		state.groups[pid] = true
		state.command = command
		state.options = options
		state.exit_callback = callback
		state.process = handle("process")
		state.requests[#state.requests + 1] = {
			options = options,
			exit_callback = callback,
			process = state.process,
			pid = pid,
		}
		return state.process, pid
	end

	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.stderr(chunk) state.options.stdio[3].read_callback(nil, chunk) end
	function state.exit(code, signal)
		if not options.descendants_alive then state.groups[state.requests[#state.requests].pid] = false end
		state.exit_callback(code or 0, signal or 0)
	end
	function state.complete(code)
		state.stdout(nil)
		state.stderr(nil)
		state.exit(code or 0)
	end
	function state.complete_request(index, stdout_text, code)
		local request = assert(state.requests[index], "unknown fake request")
		if stdout_text ~= nil then request.options.stdio[2].read_callback(nil, stdout_text) end
		request.options.stdio[2].read_callback(nil, nil)
		request.options.stdio[3].read_callback(nil, nil)
		if not options.descendants_alive then state.groups[request.pid] = false end
		request.exit_callback(code or 0, 0)
	end
	return fake, state
end

local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local helpers = require("tests.helpers")
local function check(name, fn)
	helpers.describe("Native Output Sink Composition Controls", function()
		helpers.it(name, fn)
	end)
end
local function setup(options)
	options = options or {}
	local uv, state = fake_luv(options)
	local saved_luv, saved_core = package.loaded.luv, package.loaded["adapters.curl_http_client"]
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = uv, nil
	local loaded, core = pcall(require, "adapters.curl_http_client")
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = saved_luv, saved_core
	assert(loaded, core)
	local h = { core = core, state = state, uv = uv, owner = {}, current = true, native_source_current = true, source_checks = 0, now = 0,
		writes = {}, closes = 0, timer_closed = false, timer_listeners = {}, results = {}, notices = {}, events = {} }
	local timer = { started = true }
	function timer:is_settled() return h.timer_closed end
	function timer:cancel()
		h.timer_closed = true
		local callbacks = h.timer_listeners; h.timer_listeners = {}
		for _, callback in ipairs(callbacks) do callback() end
		return true
	end
	function timer:on_settled(callback) h.timer_listeners[#h.timer_listeners + 1] = callback; return true end
	h.lease = assert(Output.new({
		now_ms = function() return h.now end,
		deadline = function(_, expire) h.expire = expire; return timer end,
		open = function() return 70 end,
		truncate = function(fd) assert(fd == 70); return true end,
		close = function(fd) assert(fd == 70); h.closes = h.closes + 1; return true end,
		write = function(fd, chunk, offset, callback)
			assert(fd == 70)
			h.writes[#h.writes + 1] = {chunk = chunk, offset = offset, ack = callback}
			if options.write_throw then error("after submitted native write") end
			return {}
		end,
	}).reserve("/owned", h.owner, function(owner)
		assert(owner == h.owner)
		if options.lease_current then options.lease_current(h) end
		return h.current
	end, 100))
	h.ticket = assert(h.lease:begin()); h.target = assert(Target.create(h.lease, h.ticket))
	h.options = {method = "GET", buffered = false, owner = "exact-output", timeout_ms = 100,
		max_download_bytes = 1000, output_target = h.target, authorized = function()
			h.source_checks = h.source_checks + 1
			if options.source_check then options.source_check(h) end
			return h.current and h.native_source_current
		end,
		on_native_terminal = function(result) h.notices[#h.notices + 1] = result; h.events[#h.events + 1] = "terminal" end}
	function h:start()
		self.operation = self.core.dispatch_owned("https://example.invalid/archive", {}, nil, self.options, nil,
			function(result) self.results[#self.results + 1] = result; self.events[#self.events + 1] = "done" end)
		return self.operation
	end
	function h:finish_input(code)
		self.state.stdout(nil)
		self.state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
		self.state.stderr(nil)
		self.state.exit(code or 0)
	end
	function h:retire()
		self.lease:cancel()
		if self.operation and not self.operation:is_settled() then
			self.operation:request_cancel()
			if #self.state.requests > 0 then self.state.exit(0) end
		end
		self.state.ack_closes()
	end
	return h
end
check("private ticket capability refuses forged ticket or unrelated producer", function()
	local h = setup(); assert(h:start().started)
	assert(Target.owns(h.target, h.ticket, h.operation))
	assert(not Target.owns(h.target, {}, h.operation) and not Target.owns(h.target, h.ticket, {}))
	h:retire()
end)
check("forged target native preflight refuses before allocating child resources", function()
	local h = setup(); h.options.output_target = {}
	local admitted = h.core.preflight("https://example.invalid/archive", {}, nil, h.options)
	assert(admitted == false and #h.state.handles == 0 and #h.state.requests == 0)
	h:retire()
end)
check("owned stdout pauses before byte-exact parent write and resumes on its ACK", function()
	local h = setup(); assert(h:start().started); h.state.stdout("a\0b")
	assert(h.state.options.stdio[2].read_stopped and #h.writes == 1 and h.writes[1].chunk == "a\0b")
	assert(#h.results == 0 and not h.operation:is_settled())
	h.writes[1].ack(nil, 3); h:finish_input()
	assert(#h.results == 1 and h.results[1].ok and h.operation:is_settled())
	assert(h.lease:bytes(h.ticket) == 3); h:retire(); assert(h.lease:is_settled())
end)
check("native child success cannot publish before the exact pending file-write ACK", function()
	local h = setup(); assert(h:start().started); h.state.stdout("abc"); h:finish_input()
	assert(#h.results == 0 and #h.notices == 0 and not h.operation:is_settled())
	h.writes[1].ack(nil, 3)
	assert(#h.results == 1 and h.results[1].ok and #h.notices == 1 and h.operation:is_settled())
	h:retire()
end)
check("last ENOSPC after actual input completion cannot become successful HTTP completion", function()
	local h = setup(); assert(h:start().started); h.state.stdout("abc"); h:finish_input()
	h.writes[1].ack({errno = "ENOSPC"})
	assert(#h.results == 1 and h.results[1].ok == false and h.operation:is_settled())
	assert(h.results[1].failure_receipt.backend == "native_fs" and h.results[1].failure_receipt.native_errno == "ENOSPC")
	assert(h.lease:is_settled() and h.closes == 1)
end)
check("unexpected second stdout delivery while a write is pending aborts without dropped success", function()
	local h = setup(); assert(h:start().started); h.state.stdout("abc"); h.state.stdout("def")
	assert(#h.writes == 1 and #h.notices == 1 and h.notices[1].ok == false)
	h:finish_input(); assert(not h.operation:is_settled())
	h.writes[1].ack(nil, 3)
	assert(#h.results == 1 and h.results[1].ok == false); h:retire()
end)
check("cancel without input EOF retains both native owner and pending writer until actual ACK", function()
	local h = setup(); assert(h:start().started); h.state.stdout("abc"); h.operation:request_cancel(); h.state.exit(0)
	assert(not h.operation:is_settled() and not h.lease:is_settled() and h.closes == 0)
	h.writes[1].ack(nil, 3)
	assert(h.operation:is_settled() and h.lease:is_settled() and h.closes == 1 and #h.results == 0)
end)
check("ambiguous native file-write throw retains exact debt through child and reader close", function()
	local h = setup({write_throw = true}); assert(h:start().started); h.state.stdout("abc"); h.state.exit(0)
	assert(not h.operation:is_settled() and not h.lease:is_settled() and h.closes == 0)
	h.writes[1].ack(nil, 3)
	assert(h.operation:is_settled() and h.lease:is_settled() and h.closes == 1)
end)
check("scheduled native reader close cannot retire the captured output descriptor", function()
	local h = setup({defer_close = true}); assert(h:start().started); h.state.stdout("abc")
	h.operation:request_cancel(); h.state.exit(0); h.writes[1].ack(nil, 3)
	assert(not h.operation:is_settled() and not h.lease:is_settled() and h.closes == 0)
	h.state.ack_closes()
	assert(h.operation:is_settled() and h.lease:is_settled() and h.closes == 1)
end)
check("a slow native reader capability after file ACK cannot restart past original deadline", function()
	local h = setup(); assert(h:start().started); h.state.stdout("abc")
	local reader, original = h.state.options.stdio[2], h.uv.is_closing
	local initial_callback = reader.read_callback
	h.uv.is_closing = function(handle)
		if handle == reader then h.now = 100 end
		return original(handle)
	end
	h.writes[1].ack(nil, 3)
	assert(#h.notices == 1 and h.notices[1].ok == false)
	assert(reader.read_callback == initial_callback and reader.read_stopped)
	h.state.exit(0); h:retire()
end)
check("native archive size refusal cannot write another byte beyond captured limit", function()
	local h = setup(); h.options.max_download_bytes = 2; assert(h:start().started); h.state.stdout("abc")
	assert(#h.writes == 0 and #h.notices == 1 and h.notices[1].ok == false)
	h.state.exit(0); h:retire()
end)
check("buffered redirect/body/path/etag combinations cannot admit an archive target", function()
	for _, field in ipairs({"buffered", "follow_redirects", "output_path", "etag_compare", "etag_save"}) do
		local h = setup(); h.options[field] = field == "buffered" or field == "follow_redirects" and true or "/foreign"
		assert(h.core.preflight("https://example.invalid/archive", {}, nil, h.options) == false)
		assert(#h.state.requests == 0); h:retire()
	end
	local h = setup(); assert(h.core.preflight("https://example.invalid/archive", {}, "body", h.options) == false); h:retire()
end)
check("lease admission cannot spawn after withdrawing captured native source", function()
	local h = setup({lease_current = function(h)
		if h.source_checks >= 2 then h.native_source_current = false end
	end})
	local operation = h:start()
	assert(operation.started == false and #h.state.requests == 0 and #h.results == 0)
	h:retire()
end)
check("lease admission cannot resume reader after native source withdrawal", function()
	local h = setup({lease_current = function(h)
		if h.withdraw_source then h.native_source_current = false end
	end})
	assert(h:start().started); h.state.stdout("abc")
	local reader, original = h.state.options.stdio[2], h.uv.is_closing
	local restarts, native_read = 0, h.uv.read_start
	h.uv.is_closing = function(handle)
		if handle == reader then h.withdraw_source = true end
		return original(handle)
	end
	h.uv.read_start = function(handle, callback)
		if handle == reader then restarts = restarts + 1 end
		return native_read(handle, callback)
	end
	h.writes[1].ack(nil, 3)
	assert(restarts == 0 and reader.read_stopped and h.native_source_current == false)
	h.state.exit(0); h:retire()
end)
check("slow final native source guard cannot receive a new archive deadline", function()
	local h = setup({lease_current = function(h)
		if h.source_checks >= 2 then h.delay_source = true end
	end, source_check = function(h)
		if h.delay_source then h.now = 100 end
	end})
	local operation = h:start()
	assert(operation.started == false and #h.state.requests == 0 and h.now == 100)
	h:retire()
end)
check("reentrant output cancellation preserves terminal observation before physical done", function()
	local h = setup(); h.options.max_download_bytes = 2; assert(h:start().started)
	h.state.exit(0) -- A real child can exit before captured stdout buffers drain.
	h.state.stdout("abc") -- Size refusal submits no filesystem write.
	assert(#h.writes == 0 and #h.results == 1 and h.results[1].ok == false)
	assert(#h.events == 2 and h.events[1] == "terminal" and h.events[2] == "done")
	h:retire()
end)
