--- tests/support/prepared_native_ports.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

local helpers = require("tests.helpers")

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

--- Restores every backend captured while loading a fixture, including cold imports.
--- The entry objects retain nil, false and table values without truthiness coercion.
--- @param module_name string
--- @param fake table
--- @return table
local function load_against_fake(module_name, fake)
	local saved = {}
	for _, name in ipairs({ "luv", module_name, "adapters.shell_runner", "infra.monotonic" }) do
		saved[#saved + 1] = { name = name, value = package.loaded[name] }
	end
	package.loaded["luv"] = fake
	package.loaded[module_name] = nil
	local loaded, result = pcall(require, module_name)
	for _, entry in ipairs(saved) do package.loaded[entry.name] = entry.value end
	if not loaded then error(result, 0) end
	return result
end

--- Loads a fresh client against one fake libuv instance.
--- @param config table|nil
--- @return table client, table state
local function fresh_client(config)
	local fake, state = fake_luv(config)
	return load_against_fake("adapters.curl_http_client", fake), state
end

--- Loads a fresh file digest adapter against one fake libuv instance.
--- @param config table|nil
--- @return table digest, table state
local function fresh_digest(config)
	local fake, state = fake_luv(config)
	return load_against_fake("adapters.file_digest", fake), state
end


return { fresh_client = fresh_client }
