--- infra/archive_tar_feeder.lua

--- ==============================================================================
--- MODULE: Retained Archive Tar Feeder
--- DESCRIPTION:
--- Feeds a sealed native archive to one owned tar process through a private pipe.
--- Only infra/archive_output.lua's fixed native artifact registry calls it: the
--- registry passes its private record under an install reservation and joins this
--- operation before native artifact cleanup. No stage callback or descriptor comes
--- from anywhere else. The supervisor owns PIPE closure; this worker owns its
--- allocated original reader duplicate and pending I/O.
--- ==============================================================================

local M = {}

local retained_tar_operations = {} -- Module lifetime retains unresolved native debt.
function M.new(backend, listing_max_output_bytes, ollama_zstd)
	if ollama_zstd == true then
		if listing_max_output_bytes ~= nil then return nil end
	elseif type(listing_max_output_bytes) ~= "number" or listing_max_output_bytes <= 0
		or listing_max_output_bytes % 1 ~= 0 then return nil end
	local uv = require("luv")
	local Deadline = require("core.network.engine.managed_http_deadline")
	local Process = require("adapters.owned_process")
	local native = {}
	for _, name in ipairs({ "new_pipe", "fs_read", "fs_close", "write", "shutdown", "hrtime" }) do
		native[name] = uv[name]
		assert(type(native[name]) == "function", "retained tar native capability unavailable")
	end
	local start_process, start_deadline = rawget(Process, "start"), rawget(Deadline, "start")
	local allocate_reader, ffi = backend.symbols.allocate_reader, backend.ffi
	assert(type(start_process) == "function" and type(start_deadline) == "function" and allocate_reader ~= nil)
	local owners = retained_tar_operations -- Retain debt beyond dropped factories/callers.
	local CHUNK, MAX_LENGTH = 65536, 9007199254740991
	local function finite(value)
		return type(value) == "number" and value == value and value >= 0 and value <= MAX_LENGTH
	end
	local function failure(stage, err)
		local code = type(err) == "string" and (err:match("^(E[A-Z0-9_]+):") or err:match("^(E[A-Z0-9_]+)$")) or nil
		return { stage = stage, backend = "native_fs", native_errno_domain = "posix",
			failure_provenance = code and "verified" or "unknown", native_errno = code }
	end
	-- current is captured fresh install lineage/selection admission, NEVER the
	-- retired transfer budget. deadline is captured once at user install consent.
	return function(record, mode, work_dir, length, current, deadline, callback)
		if type(record) ~= "table" or record.pointer == nil or record.committed ~= true
			or not finite(length) or length % 1 ~= 0 or length == 0 or not finite(deadline)
			or type(current) ~= "function" or type(callback) ~= "function" then return nil end
		local args, max_output_bytes
		if ollama_zstd == true then
			if mode ~= "extract" or type(work_dir) ~= "string" or work_dir:sub(1, 1) ~= "/"
				or work_dir:find("\0", 1, true) then return nil end
			local zstd = require("infra.owned_programs").zstd_tar_option()
			if not zstd then return nil end
			args = { zstd, "--extract", "--file", "-", "--directory", work_dir,
				"--no-same-owner", "--no-same-permissions" }
		elseif mode == "names" then args = { "-tzf", "-" }
		elseif mode == "verbose" then args = { "-tvzf", "-" }
		elseif mode == "extract" and type(work_dir) == "string" and work_dir:sub(1, 1) == "/"
			and not work_dir:find("\0", 1, true) then
			args = { "-xzf", "-", "-C", work_dir, "--no-same-owner", "--no-same-permissions" }
		else return nil end
		if mode == "names" or mode == "verbose" then max_output_bytes = listing_max_output_bytes end
		local operation, input = {}, {}
		local state = { allocating = true, probing = false, terminal = false, worker_done = false,
			reader = nil, fd_state = "absent", pending = nil, offset = 0, listeners = {},
			worker_listeners = {}, supervisor = nil, dispatching = true, timer = nil, delivered = false, supervisor_state = "absent" }
		state.input = input -- Strongly retain exact acquired pipe on uncertain handoff.
		owners[operation] = state
		local drain, fail, issue, close_reader
		local function reader_settled()
			return not state.allocating and state.worker_done and state.pending == nil
				and (state.fd_state == "closed" or state.fd_state == "absent")
		end
		local function worker_notify()
			if not reader_settled() or state.worker_notified then return end
			state.worker_notified = true
			local listeners = state.worker_listeners; state.worker_listeners = {}
			for _, listener in ipairs(listeners) do pcall(listener) end
		end
		local function admitted()
			if state.terminal or state.probing then return false end
			state.probing = true
			local checked, active = pcall(current)
			local timed, now = pcall(native.hrtime)
			state.probing = false
			return checked and active == true and timed and type(now) == "number" and finite(now / 1e6) and now / 1e6 < deadline
				and not state.terminal
		end
		local function io_admitted(reader)
			if state.worker_done or state.pending or state.fd_state ~= "open" or state.reader ~= reader then return false end
			if not admitted() then return false end
			-- current/clock callbacks may cancel the captured supervisor, which
			-- closes/revokes this worker without changing state.terminal.
			return not state.worker_done and not state.pending and state.fd_state == "open"
				and state.reader == reader and not state.terminal
		end
		local function actor_settled(actor, methods)
			if not actor or not methods then return false end
			local called, ack = pcall(methods.is_settled, actor)
			return called and ack == true
		end
		local function drain_once()
			worker_notify()
			if state.dispatching or state.delivered or not reader_settled() then return end
			-- Only the actual supervisor ACK includes child exit, descendant group
			-- absence and every original native pipe/process close callback.
			if state.supervisor_state ~= "absent" and (state.supervisor_state ~= "owned" or not actor_settled(state.supervisor, state.supervisor_methods)) then return end
			if state.timer then
				pcall(state.timer_methods.cancel, state.timer)
				if not actor_settled(state.timer, state.timer_methods) then return end
			else return end -- Failed acquisition cannot invent timer closure.
			-- Only the captured native terminal callback may supply completion facts.
			local result = state.completion
			local ok = state.feed_ok == true and type(result) == "table" and result.ok == true
			if ok then
				local active = admitted() -- External lineage/clock may reenter completion.
				if not active or state.completion_seen ~= true or state.completion_refused
					or state.completion ~= result or state.feed_ok ~= true
					or state.terminal or state.delivered or state.dispatching or not reader_settled() then
					ok = false
					state.receipt = state.receipt or failure("file_read")
				end
				if state.completion_refused or state.completion ~= result then result = nil end
			end
			state.delivered = true
			owners[operation] = nil
			local error_message
			if not ok then error_message = "retained tar operation failed" end
			operation.result = { ok = ok, stdout = type(result) == "table" and result.stdout or nil,
				receipt = state.receipt, error = error_message }
			if ollama_zstd == true and type(result) == "table" then operation.result.exit_code = result.exit_code end
			pcall(callback, operation.result)
			local listeners = state.listeners; state.listeners = {}
			for _, listener in ipairs(listeners) do pcall(listener) end
		end
		drain = function()
			if state.draining or state.drain_unknown then return end
			state.draining = true -- Includes original settlement/clock probes.
			local called = pcall(drain_once)
			state.draining = false
			if not called then
				state.drain_unknown = true -- No inferred retirement from a throw.
				fail(failure("file_read"))
			end
		end
		close_reader = function()
			if state.allocating or not state.worker_done or state.pending or state.fd_state ~= "open" then drain(); return end
			state.fd_state = "closing"
			local work = { fired = false, admitted = false }; state.close_work = work
			local function acknowledge()
				if not work.admitted or not work.fired or state.close_work ~= work or state.fd_state ~= "closing" then return end
				state.fd_state = work.err == nil and "closed" or "uncertain-close"
				if work.err then fail(failure("file_read", work.err)) end
				drain()
			end
			local called, request = pcall(native.fs_close, state.reader, function(err)
				if work.fired or state.close_work ~= work or state.fd_state ~= "closing" then return end
				work.fired, work.err = true, err
				acknowledge()
			end)
			if called and request ~= nil and request ~= false then
				work.admitted = true
				acknowledge()
			else
				state.fd_state = "uncertain-close"
				fail(failure("file_read"))
			end
			drain()
		end
		fail = function(receipt)
			state.terminal, state.worker_done, state.feed_ok = true, true, false
			state.receipt = state.receipt or receipt or failure("file_read")
			if state.supervisor and not state.cancel_sent then
				state.cancel_sent = true
				pcall(state.supervisor_methods.cancel, state.supervisor)
			end
			close_reader()
		end
		function input:cancel()
			if not state.worker_done then state.worker_done = true; state.feed_ok = false end
			close_reader(); return true -- Logical stop; outstanding I/O still owns debt.
		end
		function input:can_close() return state.worker_done and state.pending == nil end
		function input:is_settled() return reader_settled() end
		function input:result() return { ok = state.feed_ok == true } end
		function input:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if reader_settled() then pcall(listener) else state.worker_listeners[#state.worker_listeners + 1] = listener end
			return true
		end
		function operation:cancel() fail(failure("file_read")); return true end
		function operation:is_settled() return state.delivered end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if state.delivered then pcall(listener) else state.listeners[#state.listeners + 1] = listener end
			return true
		end
		local function submit(kind, fn, callback)
			local work = { kind = kind, fired = false }; state.pending = work
			local called, request = pcall(fn, function(...)
				if work.fired or state.pending ~= work then return end
				work.fired = true; state.pending = nil
				if state.worker_done then close_reader(); return end
				callback(...)
			end)
			if not called then
				-- Throwing submit may already have acquired native work. Its exact
				-- callback remains the only pending-operation retirement authority.
				work.uncertain = true; fail(failure("file_read"))
			elseif not request and not work.fired then state.pending = nil; fail(failure("file_read")) end
		end
		issue = function()
			if state.pending or state.worker_done then return end
			local reader = state.reader
			if not io_admitted(reader) then fail(failure("file_read")); return end
			local capacity = math.min(CHUNK, length - state.offset + 1)
			local offset = state.offset
			submit("read", function(cb) return native.fs_read(reader, capacity, offset, cb) end, function(err, chunk)
				if err or type(chunk) ~= "string" or #chunk > capacity then fail(failure("file_read", err)); return end
				if not io_admitted(reader) then fail(failure("file_read")); return end
				if #chunk == 0 then
					if state.offset ~= length then fail(failure("file_read")); return end
					submit("shutdown", function(cb) return native.shutdown(input.handle, cb) end, function(shutdown_error)
						if shutdown_error or not io_admitted(reader) then fail(failure("file_write", shutdown_error)); return end
						state.worker_done, state.feed_ok = true, true
						close_reader()
					end)
					return
				end
				if state.offset > length - #chunk then fail(failure("file_read")); return end
				-- One complete libuv write callback retires this bounded chunk.
				-- Until it arrives, no new read can acquire unbounded backpressure.
				submit("write", function(cb) return native.write(input.handle, chunk, cb) end, function(write_error)
					if write_error then fail(failure("file_write", write_error)); return end
					if not io_admitted(reader) then fail(failure("file_read")); return end
					state.offset = offset + #chunk
					issue()
				end)
			end)
		end
		if not admitted() then owners[operation] = nil; return nil end
		local output = ffi.new("int[1]", -1)
		local allocated, status = pcall(allocate_reader, record.pointer, deadline, output)
		if allocated and status == 0 and tonumber(output[0]) >= 0 then
			state.reader, state.fd_state = tonumber(output[0]), "open"
		elseif not allocated then state.fd_state = "uncertain-allocation" end
		state.allocating = false
		local timer_call, timer = pcall(start_deadline, deadline, function() fail(failure("file_read")) end)
		if timer_call and type(timer) == "table" and type(rawget(timer, "is_settled")) == "function"
			and type(rawget(timer, "cancel")) == "function" and type(rawget(timer, "on_settled")) == "function" then
			state.timer = timer
			state.timer_methods = { cancel = rawget(timer, "cancel"), is_settled = rawget(timer, "is_settled"),
				on_settled = rawget(timer, "on_settled") }
			local registered, ack = pcall(state.timer_methods.on_settled, timer, drain)
			if not registered or ack ~= true or timer.started ~= true then fail() end
		else fail() end
		local piped, pipe = pcall(native.new_pipe, false)
		if piped and type(pipe) == "userdata" then input.handle = pipe else
			if not piped or pipe ~= nil then state.supervisor_state = "uncertain" end
			fail()
		end
		if state.fd_state ~= "open" then fail() end
		-- Even refusal transfers a valid pipe to the supervisor before any source
		-- callbacks; only that captured supervisor owns its physical close call.
		if input.handle then
			local started, supervisor = pcall(start_process, "tar", args, {
				owner = "retained-tar:" .. tostring(operation), stdin_owner = input,
				max_output_bytes = max_output_bytes,
				authorized = function() return admitted() end,
			}, function(result)
				-- Capture exactly one closed flat result before fallible callbacks.
				if state.completion_seen then state.completion = nil; state.completion_refused = true; drain(); return end
				state.completion_seen = true
				if type(result) == "table" and type(rawget(result, "ok")) == "boolean"
					and type(rawget(result, "stdout")) == "string"
					and (ollama_zstd ~= true or (type(rawget(result, "exit_code")) == "number"
						and rawget(result, "exit_code") % 1 == 0
						and (rawget(result, "ok") ~= true or rawget(result, "exit_code") == 0))) then
					state.completion = { ok = rawget(result, "ok"), stdout = rawget(result, "stdout") }
					if ollama_zstd == true then state.completion.exit_code = rawget(result, "exit_code") end
				else state.completion_refused = true end
				drain()
			end)
			if started and type(supervisor) == "table" and type(rawget(supervisor, "is_settled")) == "function"
				and type(rawget(supervisor, "on_settled")) == "function" and type(rawget(supervisor, "cancel")) == "function" then
				state.supervisor, state.supervisor_state = supervisor, "owned"
				state.supervisor_methods = { cancel = rawget(supervisor, "cancel"), is_settled = rawget(supervisor, "is_settled"),
					on_settled = rawget(supervisor, "on_settled") }
				local registered, ack = pcall(state.supervisor_methods.on_settled, supervisor, drain)
				if not registered or ack ~= true or supervisor.started ~= true then fail() end
			else state.supervisor_state = "uncertain"; fail() end
		end
		state.dispatching = false
		if not state.terminal and admitted() then issue() else fail() end
		drain()
		return operation
	end
end

return M
