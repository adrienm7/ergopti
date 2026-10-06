--- infra/archive_output.lua

--- Parent-only archive output. Children never receive the retained descriptor.
--- A producer must provide actual stdout EOF and its physical settlement owner.
--- This module does not authorize pathname reopening, publication or relay policy.
local M = {}
local retained_leases = {} -- Physical debt outlives dropped factories/callers.
local MAX_CHUNK, MAX_SIZE = 65536, 9007199254740991

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function receipt(stage, err)
	return { stage = stage, backend = "native_fs", native_errno_domain = "posix",
		failure_provenance = type(err) == "table" and type(err.errno) == "string" and "verified" or "unknown",
		native_errno = type(err) == "table" and err.errno or nil }
end

--- Constructs an output factory from exact native allocation/write/close ports.
--- Injected ports support independent causal controls; production uses native().
function M.new(ports)
	assert(type(ports) == "table", "archive output ports required")
	local factory = {}
	local leases = retained_leases

	function factory.reserve(directory, owner, current, deadline)
		if type(directory) ~= "string" or directory == "" or directory:find("\0", 1, true)
			or owner == nil or type(current) ~= "function" or not finite(deadline) then return nil end
		local lease, fd, descriptor = {}, nil, "absent"
		local retired, acquiring, probing, beginning = false, true, false, false
		local attempt, sequence, timer = nil, 0, nil
		local listeners, closing, revoking = {}, false, false
		leases[lease] = true

		local function notify()
			if descriptor ~= "closed" and descriptor ~= "absent" then return end
			if acquiring then return end
			if timer then
				local ok, settled = pcall(timer.is_settled, timer)
				if not ok or settled ~= true then return end
			end
			leases[lease] = nil
			local pending = listeners
			listeners = {}
			for _, listener in ipairs(pending) do pcall(listener) end
		end

		local function input_closed(item)
			local input, producer = item.input, item.producer
			if not input or not producer then return false end
			local ok, closed = pcall(input.reader_closed, input.source, item.public, producer)
			return ok and closed == true and attempt == item and item.input == input
				and item.producer == producer
		end

		local admitted

		local function writable(item, work, producer)
			local ended = item.input and input_closed(item)
			if ended then item.input_ended = true end
			-- The native reader getter may be slow or reenter ownership/clock
			-- changes. Re-admit the original owner and deadline after it.
			if not admitted() then return false end
			return attempt == item and not retired and not item.eof and not item.input_ended
				and item.producer == producer and item.pending == work
		end

		local function producer_settled(item, allow_closed)
			if not item or item.pending or not item.producer then return false end
			local ended = item.eof or (allow_closed and input_closed(item))
			if not ended then return false end
			local producer = item.producer
			local ok, settled = pcall(item.producer_is_settled, producer)
			return ok and settled == true and attempt == item and not item.pending
				and item.producer == producer and (item.eof or (allow_closed and input_closed(item)))
		end

		local function abort_attempt()
			local item = attempt
			if not item or not item.input or not item.producer or item.abort_attempted then return end
			local input, producer = item.input, item.producer
			-- Reserve this exact abort before probes or native calls can reenter.
			item.abort_attempted = true
			local ok, settled = pcall(item.producer_is_settled, producer)
			if attempt ~= item or item.input ~= input or item.producer ~= producer then return end
			if ok and settled == true then return end
			-- Accepted abort is only logical/native signal admission. It is not
			-- a reader close ACK, child exit, EOF or writer retirement receipt.
			pcall(input.abort, input.source, item.public, producer)
		end

		local function close_if_ready()
			if not retired or acquiring or closing or descriptor ~= "open" then notify(); return end
			if attempt then
				if attempt.starting or attempt.pending then return end
				closing = true -- Native settlement probes can reenter cancellation.
				local physically_ready = not attempt.producer or producer_settled(attempt, true)
				closing = false
				if not physically_ready then return end
			end
			-- Reserve destructive authority before a native call that may reenter.
			closing, descriptor = true, "closing"
			local called, ack = pcall(ports.close, fd)
			descriptor = called and ack == true and "closed" or "uncertain-close"
			closing = false
			notify()
		end

		local function revoke()
			retired = true
			if revoking then return end
			revoking = true
			abort_attempt()
			if timer then pcall(timer.cancel, timer) end
			close_if_ready()
			revoking = false
		end

		admitted = function()
			if retired or descriptor ~= "open" or probing then return false end
			probing = true
			local current_ok, active = pcall(current, owner)
			local clock_ok, now = pcall(ports.now_ms)
			probing = false
			if retired or descriptor ~= "open" then return false end
			if not clock_ok or not finite(now) or now >= deadline or not current_ok or active ~= true then
				revoke()
				return false
			end
			return true
		end

		function lease:cancel() revoke(); return true end
		function lease:is_settled()
			if acquiring or (descriptor ~= "closed" and descriptor ~= "absent") then return false end
			if not timer then return true end
			local ok, settled = pcall(timer.is_settled, timer)
			return ok and settled == true
		end
		function lease:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if self:is_settled() then pcall(listener) else listeners[#listeners + 1] = listener end
			return true
		end

		-- Initial and relay attempts share one original deadline. A caller must
		-- separately admit policy; reset never grants retry after delivered bytes.
		function lease:begin(previous)
			if acquiring or beginning then return nil end
			beginning = true
			if (attempt and (previous ~= attempt.public or attempt.bytes ~= 0
				or attempt.failed or not producer_settled(attempt)))
				or (not attempt and previous ~= nil) or not admitted() then
				beginning = false
				return nil
			end
			sequence = sequence + 1
			local item = { public = {}, sequence = sequence, bytes = 0, pending = nil,
				eof = false, starting = true, failed = false, producer = nil }
			attempt = item -- Block reentrant successor before truncate/probes.
			local called, ack, err = pcall(ports.truncate, fd)
			item.starting = false
			beginning = false
			if not called or ack ~= true then
				item.failed = true
				item.failure = receipt("file_write", err)
				-- No producer was dispatched; no pipe can remain open.
				item.eof = true
				item.producer = { is_settled = function() return true end }
				item.producer_is_settled = item.producer.is_settled
				revoke()
				return nil
			end
			if retired or attempt ~= item or not admitted() then
				if attempt == item and not item.producer then
					item.eof = true
					item.producer = { is_settled = function() return true end }
					item.producer_is_settled = item.producer.is_settled
				end
				revoke()
				return nil
			end
			return item.public
		end

		local function bind(ticket, producer, input)
			local item = attempt
			if not item or item.public ~= ticket or item.producer or item.starting
				or beginning or type(producer) ~= "table" or type(producer.is_settled) ~= "function"
				or type(producer.on_settled) ~= "function" then return false end
			local is_settled, on_settled = producer.is_settled, producer.on_settled
			if not admitted() then return false end
			if attempt ~= item or retired or item.producer or item.eof or item.starting then return false end
			item.producer, item.input, item.producer_is_settled = producer, input, is_settled
			local called, ack = pcall(on_settled, producer, function() close_if_ready() end)
			if not called or ack ~= true then item.failed = true; revoke(); return false end
			if input then
				local registered, accepted = pcall(input.on_reader_closed, input.source, ticket, producer, function()
					if attempt == item and item.input == input and item.producer == producer then
						if input_closed(item) then item.input_ended = true end
						close_if_ready()
					end
				end)
				if not registered or accepted ~= true then item.failed = true; revoke(); return false end
			end
			return not retired and attempt == item and item.producer == producer and item.input == input
		end

		--- Legacy private EOF-only seam retained for predecessor controls.
		--- Production cancellation requires bind_input's exact native close owner.
		function lease:bind(ticket, producer) return bind(ticket, producer, nil) end

		--- Binds the sole native reader/abort capability to this exact attempt.
		--- Input methods must capture one private native request/controller and
		--- refence it after native reads; a logical terminal flag is insufficient.
		function lease:bind_input(ticket, producer, input)
			if type(input) ~= "table" or type(input.abort) ~= "function"
				or type(input.reader_closed) ~= "function" or type(input.on_reader_closed) ~= "function" then return false end
			return bind(ticket, producer, { source = input, abort = input.abort,
				reader_closed = input.reader_closed, on_reader_closed = input.on_reader_closed })
		end

		-- Every admitted chunk has exactly one retained physical write receipt.
		-- Return false while a write is pending; the curl sink must stop reading.
		function lease:write(ticket, chunk, callback)
			local item = attempt
			if beginning or not item or item.public ~= ticket or not item.producer or item.pending or item.eof
				or type(chunk) ~= "string" or #chunk == 0 or #chunk > MAX_CHUNK
				or item.bytes > MAX_SIZE - #chunk or type(callback) ~= "function" or not admitted() then
				return false
			end
			-- A native current/clock probe can deliver EOF or retire this owner.
			-- Repeat exact private state admission after that reentrant boundary.
			local producer = item.producer
			if not producer or not writable(item, nil, producer) then return false end
			local work = { chunk = chunk, written = 0, callback = callback, uncertain = false }
			item.pending = work
			local function complete(err)
				if item.pending ~= work then return end
				item.pending = nil
				if err then item.failed = true; item.failure = receipt("file_write", err); revoke() end
				local consent = not err and attempt == item and admitted()
				consent = consent == true and writable(item, nil, producer)
				-- The exact native sink callback retires backpressure even on
				-- failure/revocation; it is not permission to publish page state.
				pcall(callback, consent == true, item.failure and receipt("file_write", { errno = item.failure.native_errno }) or nil)
				close_if_ready()
			end
			local issue
			issue = function()
				local remaining = work.chunk:sub(work.written + 1)
				local fired = false
				local called, request = pcall(ports.write, fd, remaining, item.bytes, function(err, count)
					if fired or item.pending ~= work then return end
					fired = true
					if err then complete(err); return end
					if not finite(count) or count % 1 ~= 0 or count <= 0 or count > #remaining then
						complete({}); return
					end
					item.bytes, work.written = item.bytes + count, work.written + count
					if work.written == #work.chunk then complete(); return end
					-- An ACK proves this partial write retired. Revocation stops
					-- new writes; already submitted writes remain retained.
					local active = admitted()
					if not active or not writable(item, work, producer) then
						if item.pending == work then
							item.pending = nil
							item.failed = true
							pcall(callback, false, item.failure and receipt("file_write", { errno = item.failure.native_errno }) or nil)
						end
						close_if_ready()
						return
					end
					issue()
				end)
				if not called then
					-- A throwing port may already have submitted native work.
					work.uncertain = true
					revoke()
				elseif not request and not fired then
					-- libuv's explicit nil request means no write was submitted.
					complete({})
				end
			end
			issue()
			return not retired
		end

		function lease:eof(ticket)
			local item = attempt
			if not item or item.public ~= ticket or not item.producer then return false end
			item.eof = true -- Actual native pipe EOF; not a logical cancellation.
			close_if_ready()
			return true
		end
		function lease:attempt_settled(ticket)
			return attempt and attempt.public == ticket and producer_settled(attempt) or false
		end
		--- Fresh native backpressure admission after the sink's external live probe.
		--- The original private owner/deadline and input state are never cached.
		function lease:resume_admit(ticket, final_native_admit)
			local item = attempt
			if not item or item.public ~= ticket or not item.producer or item.pending then return false end
			local producer = item.producer
			if not admitted() or not writable(item, nil, producer) then return false end
			if final_native_admit ~= nil then
				if type(final_native_admit) ~= "function" then return false end
				-- The native source guard follows every lease current/reader probe.
				-- The original observational clock then bounds that guard's work.
				local called, accepted = pcall(final_native_admit)
				local clock_ok, now = pcall(ports.now_ms)
				if not clock_ok or not finite(now) or now >= deadline then revoke(); return false end
				if not called or accepted ~= true then return false end
			end
			return attempt == item and not retired and descriptor == "open" and not item.eof
				and not item.input_ended and item.producer == producer and item.pending == nil
		end
		--- Read-only exact-ticket ledger for the sole native stdout sink.
		--- False means no write is retained; nil means no ticket authority.
		function lease:write_pending(ticket)
			if not attempt or attempt.public ~= ticket then return nil end
			return attempt.pending ~= nil
		end
		function lease:bytes(ticket)
			return attempt and attempt.public == ticket and attempt.bytes or nil
		end
		function lease:failure(ticket)
			local item = attempt
			if not item or item.public ~= ticket or not item.failure then return nil end
			return receipt(item.failure.stage, { errno = item.failure.native_errno })
		end

		-- Native open returns the sole authority; there is no named fallback.
		local initial_ok, initial_current = pcall(current, owner)
		local clock_ok, now = pcall(ports.now_ms)
		if not initial_ok or initial_current ~= true or not clock_ok or not finite(now) or now >= deadline then
			acquiring = false
			revoke()
			return nil
		end
		local called, value, err = pcall(ports.open, directory)
		if called and type(value) == "number" and value >= 0 and value % 1 == 0 then
			fd, descriptor = value, "open"
		elseif not called then
			-- Unknown allocation after a throwing port stays retained, never guessed closed.
			descriptor = "uncertain-open"
		end
		if descriptor ~= "open" then
			acquiring = false
			revoke()
			return nil, receipt("file_create", err)
		end
		if not admitted() then acquiring = false; revoke(); return nil end
		local armed, timer_owner = pcall(ports.deadline, deadline, revoke)
		if armed and type(timer_owner) == "table" and type(timer_owner.is_settled) == "function"
			and type(timer_owner.cancel) == "function" and type(timer_owner.on_settled) == "function" then
			timer = timer_owner
			local subscribed, ack = pcall(timer.on_settled, timer, notify)
			if not subscribed or ack ~= true or timer.started ~= true then
				acquiring = false
				revoke()
				return nil
			end
		else
			-- An ambiguous timer allocation cannot be asserted physically absent.
			timer = { is_settled = function() return false end, cancel = function() return false end }
			acquiring = false
			revoke()
			return nil
		end
		acquiring = false
		if not admitted() then revoke(); return nil end
		return lease
	end
	return factory
end

--- Actual Linux backend: anonymous regular FD is parent-only and close-on-exec.
function M.native()
	local ffi, uv = require("ffi"), require("luv")
	assert(ffi.os == "Linux", "archive output requires Linux")
	ffi.cdef([[int open(const char *path, int flags, ...); int close(int fd);
		int ftruncate(int fd, long length);]])
	local Clock = require("infra.monotonic")
	local Deadline = require("infra.managed_http_deadline")
	local function errno()
		local code = ffi.errno()
		-- Canonical names from actual POSIX syscall errno; other errors stay
		-- unknown instead of being inferred from generic write/read failures.
		local names = { [1] = "EPERM", [13] = "EACCES", [28] = "ENOSPC", [30] = "EROFS", [122] = "EDQUOT" }
		return { errno = names[code] }
	end
	return M.new({
		now_ms = Clock.now_ms,
		deadline = Deadline.start,
		open = function(directory)
			-- O_TMPFILE includes O_DIRECTORY. Never add O_EXCL: future owned
			-- publication must retain this inode, not copy/reopen a pathname.
			local fd = ffi.C.open(directory, 4259840 + 2 + 524288 + 131072, ffi.cast("unsigned int", 384))
			if fd < 0 then return nil, errno() end
			return tonumber(fd)
		end,
		truncate = function(fd)
			if ffi.C.ftruncate(fd, 0) ~= 0 then return false, errno() end
			return true
		end,
		write = function(fd, chunk, offset, callback)
			return uv.fs_write(fd, chunk, offset, function(err, count)
				local failure
				if err then
					-- Typed libuv filesystem error, never curl/stderr inference.
					failure = { errno = type(err) == "string" and
						(err:match("^(E[A-Z0-9_]+):") or err:match("^(E[A-Z0-9_]+)$")) or nil }
				end
				callback(failure, count)
			end)
		end,
		close = function(fd)
			if ffi.C.close(fd) ~= 0 then return false, errno() end
			return true
		end,
	})
end

return M
