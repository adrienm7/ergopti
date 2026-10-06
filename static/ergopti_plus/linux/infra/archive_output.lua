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
local function new_factory(ports, private_adopter)
	assert(type(ports) == "table", "archive output ports required")
	local factory = {}
	local leases = retained_leases
	local retain_owner = rawget(ports, "retain_owner")
	assert(retain_owner == nil or type(retain_owner) == "function", "archive owner observer must be a function")

	function factory.reserve(directory, owner, current, deadline)
		if type(directory) ~= "string" or directory == "" or directory:find("\0", 1, true)
			or owner == nil or type(current) ~= "function" or not finite(deadline) then return nil end
		local lease, fd, descriptor = {}, nil, "absent"
		local retired, acquiring, probing, beginning = false, true, false, false
		local attempt, sequence, timer = nil, 0, nil
		local listeners, closing, revoking = {}, false, false
		local sealed, sealing, digest_work = false, false, nil
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

		local function cancel_digest()
			local work = digest_work
			if not work or not work.operation or type(work.cancel) ~= "function" or work.cancel_requested then return end
			work.cancel_requested = true -- Reserve this exact signal before reentry.
			pcall(work.cancel, work.operation)
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
			if sealing then return end
			local item, hash_work = attempt, digest_work
			closing = true -- Covers every foreign physical probe, including hash.
			if digest_work then
				local called, ack = pcall(digest_work.is_settled, digest_work.operation)
				if not called or ack ~= true then closing = false; return end
			end
			if attempt then
				if attempt.starting or attempt.pending then closing = false; return end
				local physically_ready = not attempt.producer or producer_settled(attempt, true)
				if not physically_ready then closing = false; return end
			end
			if not retired or acquiring or sealing or descriptor ~= "open"
				or attempt ~= item or digest_work ~= hash_work then closing = false; return end
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
			cancel_digest()
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
		local function begin_attempt(previous, previous_producer, disposition, final_native_admit)
			if acquiring or beginning or sealed then return nil end
			if disposition ~= nil and (disposition ~= "relay" and disposition ~= "redirect"
				or not attempt or not rawequal(previous_producer, attempt.producer)
				or type(final_native_admit) ~= "function") then return nil end
			local predecessor = attempt
			beginning = true
			if (attempt and (not rawequal(previous, attempt.public) or (disposition ~= "redirect" and attempt.bytes ~= 0)
				or attempt.failed or not producer_settled(attempt)))
				or (not attempt and previous ~= nil) or not admitted() then
				beginning = false
				return nil
			end
			if disposition ~= nil then
				local called, accepted = pcall(final_native_admit)
				local clocked, now = pcall(ports.now_ms)
				if not called or accepted ~= true or not clocked or not finite(now) or now >= deadline then
					beginning = false
					revoke()
					return nil
				end
			end
			if attempt ~= predecessor or retired or sealed or descriptor ~= "open" then beginning = false; return nil end
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

		function lease:begin(previous) return begin_attempt(previous) end

		--- Continues only the exact retired output producer. The target owner
		--- separately verifies actual HTTP transition/zero-body relay evidence.
		--- Redirect bodies are deliberately discarded; relay bodies must be zero.
		function lease:begin_continuation(previous, producer, disposition, final_native_admit)
			return begin_attempt(previous, producer, disposition, final_native_admit)
		end

		local function bind(ticket, producer, input)
			local item = attempt
			if sealed or not item or not rawequal(item.public, ticket) or item.producer or item.starting
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
			if sealed or beginning or not item or not rawequal(item.public, ticket) or not item.producer or item.pending or item.eof
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
			if not item or not rawequal(item.public, ticket) or not item.producer then return false end
			item.eof = true -- Actual native pipe EOF; not a logical cancellation.
			close_if_ready()
			return true
		end
		function lease:attempt_settled(ticket)
			return attempt and rawequal(attempt.public, ticket) and producer_settled(attempt) or false
		end
		--- Fresh native backpressure admission after the sink's external live probe.
		--- The original private owner/deadline and input state are never cached.
		function lease:resume_admit(ticket, final_native_admit)
			local item = attempt
			if not item or not rawequal(item.public, ticket) or not item.producer or item.pending then return false end
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
			if not attempt or not rawequal(attempt.public, ticket) then return nil end
			return attempt.pending ~= nil
		end
		function lease:bytes(ticket)
			return attempt and rawequal(attempt.public, ticket) and attempt.bytes or nil
		end
		function lease:failure(ticket)
			local item = attempt
			if not item or not rawequal(item.public, ticket) or not item.failure then return nil end
			return receipt(item.failure.stage, { errno = item.failure.native_errno })
		end

		--- Irreversibly seals the final ticket before any parent-only hash read.
		--- Hash cancellation retains the FD until exact read/context/timer ACKs.
		--- @param ticket table Final output ticket.
		--- @param expected_digest string Captured canonical release SHA-256.
		--- @param hash_deadline number Captured original hash phase deadline.
		--- @param callback function Private (digest, receipt, verified_token) result.
		--- @return table|nil operation Native hash physical debt owner.
		function lease:seal_sha256(ticket, expected_digest, hash_deadline, callback)
			local item = attempt
			if sealed or beginning or acquiring or not item or not rawequal(item.public, ticket) or item.failed
				or item.pending or not item.eof or not item.producer or item.bytes <= 0
				or type(expected_digest) ~= "string" or #expected_digest ~= 64 or expected_digest:find("[^0-9a-f]")
				or not finite(hash_deadline) or hash_deadline > deadline
				or type(callback) ~= "function" or type(ports.hash) ~= "function" then return nil end
			sealed, sealing = true, true -- No subsequent write, reset or producer bind.
			local producer = item.producer
			local function hash_current()
				if attempt ~= item or item.producer ~= producer or retired or descriptor ~= "open" then return false end
				if not producer_settled(item) or not admitted() then return false end
				local observed, now = pcall(ports.now_ms)
				return observed and finite(now) and now < hash_deadline and attempt == item
					and item.producer == producer and not retired and descriptor == "open"
					and not item.pending and item.eof and not item.failed
			end
			if not hash_current() then sealing = false; revoke(); return nil end
			local work = { delivered = false, received = false, token = {}, deadline = hash_deadline }
			digest_work = work
			local function publish()
				if sealing or digest_work ~= work or not work.operation or not work.received or work.delivered then return end
				local called, ack = pcall(work.is_settled, work.operation)
				if not called or ack ~= true then return end
				local digest = not work.had_error and work.digest or nil
				if digest and digest ~= expected_digest then digest = nil; work.reason = "checksum_mismatch" end
				if digest and not hash_current() then digest = nil; revoke() end
				if digest_work ~= work or work.delivered then return end
				work.delivered, work.verified = true, digest ~= nil
				pcall(callback, digest, work.receipt, digest and work.token or nil, work.reason)
				close_if_ready()
			end
			local called, operation = pcall(ports.hash, fd, item.bytes, hash_current, hash_deadline, function(digest, err)
				if digest_work ~= work or work.received then return end
				work.received, work.had_error = true, err ~= nil
				work.digest = type(digest) == "string" and #digest == 64 and not digest:find("[^0-9a-f]") and digest or nil
				work.receipt = type(err) == "table" and receipt("file_read", { errno = err.native_errno }) or nil
				publish()
			end)
			local is_settled = type(operation) == "table" and rawget(operation, "is_settled") or nil
			local cancel = type(operation) == "table" and rawget(operation, "cancel") or nil
			local on_settled = type(operation) == "table" and rawget(operation, "on_settled") or nil
			if called and type(is_settled) == "function" and type(cancel) == "function" and type(on_settled) == "function" then
				work.operation, work.is_settled, work.cancel, work.on_settled = operation, is_settled, cancel, on_settled
				local subscribed, ack = pcall(work.on_settled, operation, function() publish(); close_if_ready() end)
				if not subscribed or ack ~= true then revoke() end
			else
				-- An unknown hash allocation may own a read on this exact FD. Its
				-- integer value is never guessed closed or reused after refusal.
				work.is_settled, work.cancel = function() return false end, function() return false end
				work.operation = { is_settled = work.is_settled, cancel = work.cancel }
				revoke()
			end
			-- Hash construction/registration may reenter retirement before the
			-- exact child is attached. Signal that captured late owner before
			-- releasing the reservation; accepted cancellation is never an ACK.
			if not retired and not hash_current() then revoke() end
			if retired then cancel_digest() end
			sealing = false
			publish()
			close_if_ready()
			return work.operation
		end

		--- Admits only the private verification of the current sealed FD.
		--- @param token table Exact verification token returned by seal_sha256.
		--- @return boolean
		function lease:verified(token)
			local work, item = digest_work, attempt
			if not work or not work.verified or not rawequal(token, work.token) or not item or not sealed then return false end
			if not admitted() then return false end
			local observed, now = pcall(ports.now_ms)
			return observed and finite(now) and now < work.deadline and digest_work == work
				and attempt == item and not retired and descriptor == "open"
				and work.verified and rawequal(token, work.token)
		end

		-- Only the fixed native artifact constructor supplies this private port.
		-- No public constructor accepts an adopter or receives the descriptor.
		function lease:adopt_verified(token)
			local work, item = digest_work, attempt
			if not rawequal(self, lease) or type(private_adopter) ~= "function" or sealing or not work or not item
				or not work.verified or not rawequal(work.token, token) then return false end
			sealing = true -- Holds the original descriptor across every foreign probe.
			local ready = admitted() and producer_settled(item)
			local checked, hash_ack = pcall(work.is_settled, work.operation)
			local timed, now = pcall(ports.now_ms)
			if not ready or not checked or hash_ack ~= true or not timed or not finite(now)
				or now >= work.deadline or retired or descriptor ~= "open"
				or attempt ~= item or digest_work ~= work or not rawequal(work.token, token)
				or item.pending or not item.eof or item.failed then
				sealing = false
				revoke()
				return false
			end
			local called, staged = pcall(private_adopter, lease, fd, item.bytes, work.deadline)
			local accepted = called and staged == true and attempt == item
				and digest_work == work and descriptor == "open" and not retired
			sealing = false
			-- A staged name is not install authority. The registry waits for the
			-- original FD/timer ACK before its separate observational commit check.
			revoke()
			return accepted
		end

		-- The private factory must retain the exact lease before any allocation.
		-- An observer sees only methods, never the FD, pathname or native owner.
		if retain_owner then
			local retained, accepted = pcall(retain_owner, lease)
			if not retained or accepted ~= true or retired then
				acquiring = false
				revoke()
				return nil
			end
		end

		-- Native open returns the sole authority; there is no named fallback.
		local initial_ok, initial_current = pcall(current, owner)
		local clock_ok, now = pcall(ports.now_ms)
		if retired or not initial_ok or initial_current ~= true or not clock_ok or not finite(now) or now >= deadline then
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

--- Public injected factories never acquire native artifact adoption authority.
function M.new(ports) return new_factory(ports, nil) end

--- Actual Linux backend: anonymous regular FD is parent-only and close-on-exec.
local function native_ports()
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
	return {
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
		hash = function(fd, length, current, hash_deadline, callback)
			return require("infra.fd_sha256").native().start(fd, length, current, hash_deadline, callback)
		end,
		close = function(fd)
			if ffi.C.close(fd) ~= 0 then return false, errno() end
			return true
		end,
	}
end

--- Actual Linux backend with its original anonymous directory allocation.
function M.native() return M.new(native_ports()) end

--- Private artifact factory seam: allocation remains inside the retained lease.
--- The capturing caller is the native artifact registry, never an update/UI port.
function M.native_with_owned_open(open_owned, retain_owner)
	assert(type(open_owned) == "function" and type(retain_owner) == "function",
		"private archive allocation and retention ports required")
	local ports = native_ports()
	ports.open, ports.retain_owner = open_owned, retain_owner
	return M.new(ports)
end

-- Native artifact registry is lexical with the original output descriptor.
-- Ordinary output factories cannot obtain this staging closure or its pointers.
local retained_artifacts = {}
local function unavailable(reason)
 return nil, { cause = "unknown", message_key = "network.failure.unknown", capability_reason = reason }
end
local function native_artifact_backend()
 local loaded, backend = pcall(function()
  local ffi, uv = require("ffi"), require("luv")
  local Paths, Clock = require("infra.paths"), require("infra.monotonic")
  local hrtime = rawget(uv, "hrtime")
  local has_hires, clock_backend = rawget(Clock, "has_hires"), rawget(Clock, "backend")
  if ffi.os ~= "Linux" or type(hrtime) ~= "function" or type(has_hires) ~= "function"
   or type(clock_backend) ~= "function" or has_hires() ~= true or clock_backend() ~= "luv.hrtime" then return nil end
  ffi.cdef([[
   struct ergopti_archive_publication;
   unsigned int ergopti_archive_publication_abi_version(void);
   double ergopti_archive_publication_clock_ms(void);
   int ergopti_archive_publication_create_directory(const char *, double, struct ergopti_archive_publication **);
   int ergopti_archive_publication_allocate_output(struct ergopti_archive_publication *, double, int *);
   int ergopti_archive_publication_allocate_reader(struct ergopti_archive_publication *, double, int *);
   int ergopti_archive_publication_stage(struct ergopti_archive_publication *, int, int64_t, const char *, double);
   int ergopti_archive_publication_commit(struct ergopti_archive_publication *);
   int ergopti_archive_publication_copy_display_path(const struct ergopti_archive_publication *, char *, size_t);
   int ergopti_archive_publication_cleanup(struct ergopti_archive_publication *);
   int ergopti_archive_publication_cleanup_with_disposition(struct ergopti_archive_publication *, int *);
   int ergopti_archive_publication_descriptors_closed(const struct ergopti_archive_publication *);
   int ergopti_archive_publication_named_remaining(const struct ergopti_archive_publication *);
   int ergopti_archive_publication_dispose_unpublished(struct ergopti_archive_publication *);
  ]])
  -- Exact installed native component only; no system/alternate binary fallback.
  local null_pointer = ffi.cast("void *", 0)
  local library = ffi.load(Paths.driver_root() .. "/bin/libergopti_archive_publication.so")
  local symbols = {}
  for _, name in ipairs({ "abi_version", "clock_ms", "create_directory", "allocate_output", "allocate_reader", "stage", "commit",
   "copy_display_path", "cleanup", "descriptors_closed", "named_remaining", "dispose_unpublished" }) do
   symbols[name] = library["ergopti_archive_publication_" .. name]
  end
  -- Old ABI1 backend remains usable with its original one-attempt cleanup law.
  local optional, cleanup_with_disposition = pcall(function()
   return library["ergopti_archive_publication_cleanup_with_disposition"]
  end)
  if optional and cleanup_with_disposition ~= nil then symbols.cleanup_with_disposition = cleanup_with_disposition end
  if symbols.abi_version() ~= 1 then return nil end
  local before = hrtime() / 1e6
  local native = symbols.clock_ms()
  local after = hrtime() / 1e6
  if not finite(before) or not finite(native) or not finite(after) or before < 0
   or native < before or native > after then return nil end
  local parent = os.getenv("TMPDIR") or "/tmp"
  if parent:sub(1, 1) ~= "/" or parent:find("\0", 1, true) then return nil end
  return { ffi = ffi, symbols = symbols, library = library, null_pointer = null_pointer,
   parent = parent, now_ms = function() return hrtime() / 1e6 end }
 end)
 if not loaded or not backend then return nil end
 return backend
end

-- SOURCE ONLY lexical part of archive_output's fixed native artifact registry.
-- This is NOT a require-able module or a public descriptor/pointer constructor.
-- Registry passes only its private record under an install reservation and joins
-- this operation before native artifact cleanup. Supervisor owns PIPE closure;
-- this worker owns its allocated original reader duplicate and pending I/O.
local retained_tar_operations = {} -- Module lifetime retains unresolved native debt.
local function new_private_tar_feeder(backend, listing_max_output_bytes)
 if type(listing_max_output_bytes) ~= "number" or listing_max_output_bytes <= 0
  or listing_max_output_bytes % 1 ~= 0 then return nil end
	local uv = require("luv")
	local Deadline = require("infra.managed_http_deadline")
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
		if mode == "names" then args = { "-tzf", "-" }
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
					and type(rawget(result, "stdout")) == "string" then
					state.completion = { ok = rawget(result, "ok"), stdout = rawget(result, "stdout") }
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

--- Constructs only the fixed native registry; no stage callback/FD is accepted.
--- basename is the captured canonical release asset selected by shared defaults.
--- Missing native capability refuses; a displayed pathname is never a fallback.
function M.native_artifact(basename)
 if type(basename) ~= "string" or basename == "" or basename:find("\0", 1, true)
  or basename:find("/", 1, true) or basename == "." or basename == ".." then return unavailable("invalid_native_archive_name") end
 local backend = native_artifact_backend()
 if not backend then return unavailable("native_archive_component_unavailable") end
 local ffi, native, now_ms = backend.ffi, backend.symbols, backend.now_ms
 local Target = require("infra.http_output_target")
 local create_target, seal_owned = rawget(Target, "create"), rawget(Target, "seal_owned")
 if type(create_target) ~= "function" or type(seal_owned) ~= "function" then return unavailable("owned_archive_sealing_unavailable") end
 local factory, records = {}, {}
 local install_readers_settled = function() return true end
 local function current(record, phase, limit)
  if records[record.brand] ~= record or record.cancelled or record.constructing then return false end
  local checked, consent = pcall(phase and record.phase_current or record.lineage)
  local timed, now = pcall(now_ms)
  return checked and consent == true and timed and finite(now) and now >= 0 and now < (limit or record.deadline)
   and records[record.brand] == record and not record.cancelled and not record.constructing
 end
 local function lease_settled(record)
  if record.constructing or record.unknown then return false end
  if not record.lease then return true end
  local called, ack = pcall(record.lease_methods.is_settled, record.lease)
  return called and ack == true and not record.constructing and not record.unknown
 end
 local function notify(record)
  if not record.transfer_ack then return end
  local listeners = record.listeners
  record.listeners = {}
  for _, listener in ipairs(listeners) do pcall(listener) end
 end
 local function cleanup(record, explicit_retry)
  if record.cleaning or record.constructing or record.unknown or not record.cancelled then return false end
  record.cleaning = true -- Reserve before every original lease/reader/native physical probe.
  local pointer, transaction, lease, install = record.pointer, record.transaction, record.lease, record.install
  local retry = record.cleanup_retry
  local checked, ready = pcall(function()
   if not lease_settled(record) or not install_readers_settled(record) or record.constructing or record.unknown then return false end
   if record.disposed then return true end
   if records[record.brand] ~= record or not record.cancelled then return false end
   if record.cleanup_attempted and (explicit_retry ~= true or not retry
    or retry.record ~= record or retry.brand ~= record.brand or retry.pointer ~= pointer
    or retry.transaction ~= transaction or retry.lease ~= lease or retry.install ~= install
    or retry.attempt ~= record.cleanup_attempt) then return false end
   -- Physical gates above reserve but do not spend the prior receipt. Repeat
   -- identities after every foreign probe before a new native call is admitted.
   if not lease_settled(record) or not install_readers_settled(record)
    or records[record.brand] ~= record or record.pointer ~= pointer or record.transaction ~= transaction
    or record.lease ~= lease or record.install ~= install or record.constructing or record.unknown
    or not record.cancelled or record.cleanup_retry ~= retry then return false end
   if pointer ~= nil then
    local disposition
    if native.cleanup_with_disposition ~= nil then disposition = ffi.new("int[1]", 0) end
    if records[record.brand] ~= record or record.pointer ~= pointer or record.transaction ~= transaction
     or record.lease ~= lease or record.install ~= install or record.constructing or record.unknown
     or not record.cancelled or record.cleanup_retry ~= retry then return false end
    local attempt = {}
    record.cleanup_attempted, record.cleanup_retry, record.cleanup_attempt = true, nil, attempt
    -- Spend ONLY immediately before the exact native attempt. Unknown native
    -- errors permanently retain the original owner; no bare descriptor retry.
    local called, status
    if disposition then called, status = pcall(native.cleanup_with_disposition, pointer, disposition)
    else called, status = pcall(native.cleanup, pointer) end
    if records[record.brand] ~= record or record.pointer ~= pointer or record.transaction ~= transaction
     or record.lease ~= lease or record.install ~= install or record.cleanup_attempt ~= attempt
     or record.constructing or record.unknown or not record.cancelled then return false end
    if called and status == -1 and disposition and disposition[0] == 1 then
     record.cleanup_retry = { record = record, brand = record.brand, pointer = pointer, transaction = transaction,
      lease = lease, install = install, attempt = attempt }
     return false
    end
    if not called or status ~= 0 or (disposition and disposition[0] ~= 0) then return false end
    local closed, descriptors = pcall(native.descriptors_closed, pointer)
    local counted, names = pcall(native.named_remaining, pointer)
    if not closed or descriptors ~= 1 or not counted or names ~= 0 or record.pointer ~= pointer then return false end
    local disposed, result = pcall(native.dispose_unpublished, pointer)
    if not disposed or result ~= 0 or record.pointer ~= pointer then return false end
    record.pointer = nil
   end
   record.disposed, record.transfer_ack = true, true
   retained_artifacts[record] = nil
   return true
  end)
  record.cleaning = false
  if checked and ready == true then
   notify(record)
   local listeners = record.artifact_listeners or {}; record.artifact_listeners = {}
   for _, listener in ipairs(listeners) do pcall(listener) end
   return true
  end
  return false
 end
 local function cancel(record)
  record.cancelled = true
  if record.lease and not record.lease_cancelled then
   record.lease_cancelled = true
   pcall(record.lease_methods.cancel, record.lease)
  end
  cleanup(record)
 end
 local function adopt_finished(record)
  local operation = record.adoption
  if not operation or operation.constructing or operation.finishing or operation.done or not operation.hash_received then return end
  operation.finishing = true -- Includes all physical, lineage, native and clock probes.
  local function intact()
   return records[record.brand] == record and record.adoption == operation and not operation.done
  end
  local function deliver(path, error_message, receipt)
   if not intact() then return end
   operation.done = true -- Reserve terminal delivery before callback reentry.
   pcall(operation.callback, path, error_message, receipt)
   local listeners = operation.listeners
   operation.listeners = {}
   for _, listener in ipairs(listeners) do pcall(listener) end
  end
  local called = pcall(function()
   if not lease_settled(record) or not intact() then return end
   if operation.staged ~= true or not current(record, false, operation.deadline) then
    cancel(record)
    if intact() and record.transfer_ack then deliver(nil, "verified archive adoption refused", operation.receipt) end
    return
   end
   if not intact() or record.cancelled then return end
   -- Original FD and timer ACK precede this observational original hash check.
   -- No Budget.admit, retired network consent, relative restart or new timer.
   local committed_call, committed = pcall(native.commit, record.pointer)
   if not intact() then return end
   if not committed_call or committed ~= 0 or not current(record, false, operation.deadline) then
    cancel(record)
    if intact() and record.transfer_ack then deliver(nil, "verified archive commit refused", nil) end
    return
   end
   if not intact() or record.cancelled then return end
   local display = ffi.new("char[4352]")
   local copied, status = pcall(native.copy_display_path, record.pointer, display, 4352)
   -- Actual C ABI returns status0. Observe at most the owned buffer, never an
   -- unbounded C-string read or an inferred byte count from that status.
   local observed, bounded = pcall(ffi.string, display, 4352)
   local terminator = observed and type(bounded) == "string" and bounded:find("\0", 1, true) or nil
   local path = terminator and terminator > 1 and bounded:sub(1, terminator - 1) or nil
   if not intact() then return end
   if not copied or status ~= 0 or not path or not current(record, false, operation.deadline) then
    cancel(record)
    if intact() and record.transfer_ack then deliver(nil, "verified archive display unavailable", nil) end
    return
   end
   if not intact() or record.cancelled then return end
   record.committed, record.transfer_ack = true, true
   deliver(path, nil, nil) -- Information only; the brand is install authority.
   notify(record)
  end)
  operation.finishing = false
  if not called then
   record.unknown = true -- No guessed publication or physical retirement.
   cancel(record)
  end
 end
 function factory.reserve_transfer(meta, transaction, lineage, phase_current, deadline)
  if type(meta) ~= "table" or transaction == nil or type(lineage) ~= "function"
   or type(phase_current) ~= "function" or not finite(deadline) then return nil end
  local selected = {}
  for _, key in ipairs({ "tag", "download_url", "checksum_url" }) do
   local value = rawget(meta, key)
   if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then return nil end
   selected[key] = value
  end
  local record = { brand = {}, transaction = transaction, meta = selected, lineage = lineage,
   phase_current = phase_current, deadline = deadline, listeners = {}, cancelled = false, constructing = false }
  records[record.brand], retained_artifacts[record] = record, true
  if not current(record, true) then cancel(record); return record.brand, nil end
  record.constructing = true
  local owner = ffi.new("struct ergopti_archive_publication *[1]")
  local called, status = pcall(native.create_directory, backend.parent, deadline, owner)
  local pointer = owner[0]
  -- Native NULL stays cdata on reference Lua FFI providers; Lua receipts use nil.
  record.pointer = pointer ~= nil and pointer ~= backend.null_pointer and pointer or nil
  record.constructing = false
  if not called then record.unknown = true end
  if not called or status ~= 0 or not record.pointer or not current(record, true) then
   cancel(record); return record.brand, nil
  end
  local ports = native_ports()
  ports.open = function()
   if not current(record, true) or not record.pointer then return nil end
   local output = ffi.new("int[1]", -1)
   local allocated, result = pcall(native.allocate_output, record.pointer, deadline, output)
   if not allocated then record.unknown = true; error("ambiguous native output allocation") end
   -- C policy errno is private diagnostics, never a verified disk/permission cause.
   if result ~= 0 then return nil end
   return tonumber(output[0])
  end
  ports.retain_owner = function(lease)
   if record.lease or record.cancelled then return false end
   local methods = {}
   for _, name in ipairs({ "cancel", "is_settled", "on_settled", "begin", "adopt_verified" }) do
    methods[name] = rawget(lease, name)
    if type(methods[name]) ~= "function" then return false end
   end
   record.lease, record.lease_methods = lease, methods
   local observed, ack = pcall(methods.on_settled, lease, function()
    if rawequal(record.lease, lease) then cleanup(record); adopt_finished(record) end
   end)
   return observed and ack == true and not record.cancelled
  end
  local output = new_factory(ports, function(lease, descriptor, bytes, hash_deadline)
   if not rawequal(record.lease, lease) or not record.adoption or record.adoption.deadline ~= hash_deadline
    or record.staged or not current(record, true, hash_deadline) then return false end
   record.stage_attempted = true
   local staged, result = pcall(native.stage, record.pointer, descriptor, ffi.cast("int64_t", bytes), basename, hash_deadline)
   record.staged = staged and result == 0
   if record.staged then record.sealed_length = bytes end
   return record.staged and current(record, true, hash_deadline) and rawequal(record.lease, lease)
  end)
  local reserved, lease = pcall(output.reserve, backend.parent, transaction, phase_current, deadline)
  if not reserved or not lease or not current(record, true) then cancel(record); return record.brand, nil end
  local begun, ticket = pcall(record.lease_methods.begin, lease)
  local made, target = pcall(create_target, lease, ticket)
  if not begun or not ticket or not made or type(target) ~= "table" or not current(record, true) then
   cancel(record); return record.brand, nil
  end
  return record.brand, target
 end
 function factory.bind_checksum(brand, expected)
  local record = records[brand]
  if not record or record.expected or record.binding or type(expected) ~= "string" or #expected ~= 64
   or expected:find("[^0-9a-f]") then return false end
  record.binding = true -- Reserve immutable commitment before foreign admission.
  local admitted = current(record, true)
  local accepted = admitted and records[brand] == record and not record.cancelled and record.expected == nil
  if accepted then record.expected = expected end
  record.binding = false
  return accepted
 end
 function factory.seal_and_adopt(brand, completion, expected, hash_deadline, callback)
  local record = records[brand]
  if not record or record.adoption or record.expected ~= expected or type(callback) ~= "function"
   or not finite(hash_deadline) or hash_deadline > record.deadline then return nil end
  local operation = { started = false }
  local work = { done = false, constructing = true, listeners = {}, callback = callback, deadline = hash_deadline }
  record.adoption = work
  function operation:is_settled() return work.done == true end
  function operation:on_settled(listener)
   if type(listener) ~= "function" then return false end
   if work.done then pcall(listener) else work.listeners[#work.listeners + 1] = listener end
   return true
  end
  function operation:request_cancel()
   if work.done then return true end
   cancel(record); adopt_finished(record); return true
  end
  function operation:cancel()
   if not work.done then cancel(record); adopt_finished(record) end
   return work.done == true
  end
  -- Reserve exact adoption work before the first foreign source/clock probe.
  if not current(record, true, hash_deadline) or records[brand] ~= record or record.adoption ~= work then
   work.constructing, work.hash_received = false, true
   cancel(record); adopt_finished(record)
   return operation
  end
  local called, hash = pcall(seal_owned, completion, expected, hash_deadline, record.lease, function(digest, receipt, proof)
   work.hash_received, work.receipt = true, receipt
   if digest == expected and proof ~= nil and receipt == nil and not record.cancelled then
    local adopted, ack = pcall(record.lease_methods.adopt_verified, record.lease, proof)
    work.staged = adopted and ack == true and record.staged == true
   else cancel(record) end
   adopt_finished(record)
  end)
  work.constructing = false
  operation.started = called and type(hash) == "table"
  if not operation.started then
   work.hash_received = true
   cancel(record)
  end
  adopt_finished(record)
  return operation
 end
 function factory.retry_transfer_cleanup(brand)
  local record = records[brand]
  if not record or not record.cancelled or not record.cleanup_retry or record.install ~= nil then return false end
  local retired = cleanup(record, true)
  adopt_finished(record)
  return retired == true and records[brand] == record and record.transfer_ack == true
 end
 function factory.cancel_transfer(brand)
  local record = records[brand]
  if not record then return false end
  cancel(record); adopt_finished(record); return true
 end
 function factory.transfer_settled(brand)
  local record = records[brand]
  if not record then return false end
  if record.cancelled then cleanup(record) end
  return record.transfer_ack == true
 end
 function factory.on_transfer_settled(brand, listener)
  local record = records[brand]
  if not record or type(listener) ~= "function" then return false end
  if record.transfer_ack then pcall(listener) else record.listeners[#record.listeners + 1] = listener end
  return true
 end
 function factory.retire_artifact(brand)
  local record = records[brand]
  if not record or record.install ~= nil then return false end
  local prior_retry = record.cleanup_retry
  cancel(record)
  -- One explicit call cannot consume the conflict it just observed. Only its
  -- entry receipt can authorize this later retirement attempt.
  if not record.disposed and prior_retry ~= nil and record.cleanup_retry == prior_retry
   and records[brand] == record then cleanup(record, true) end
  return record.disposed == true
 end
 function factory.artifact_settled(brand)
  local record = records[brand]
  return record ~= nil and record.disposed == true
 end
 function factory.on_artifact_settled(brand, listener)
  local record = records[brand]
  if not record or type(listener) ~= "function" then return false end
  if record.disposed then pcall(listener) else
   record.artifact_listeners = record.artifact_listeners or {}
   record.artifact_listeners[#record.artifact_listeners + 1] = listener
  end
  return true
 end

 -- Local installation uses a new canonical deadline and the original artifact
 -- lineage. No retired transfer deadline/presentation consent is consulted.
 local installs = {}
 local capture_install, admit_install_budget, install_deadline, retire_install, capture_listing
 local function install_identity(work)
  return installs[work.token] == work and work.record.install == work and not work.done
   and records[work.record.brand] == work.record and not work.record.cancelled and work.record.pointer ~= nil
 end
 local function install_active(work)
  if not install_identity(work) or not work.accepted or work.finishing or work.probing then return false end
  work.probing = true
  local checked, active = pcall(work.execution)
  local clocked, now = pcall(now_ms)
  local timed, valid = pcall(admit_install_budget, work.budget, now)
  work.probing = false
  return checked and active == true and clocked and timed and valid == true and install_identity(work)
   and work.accepted and not work.finishing
 end
 local function readers_settled(record)
  if record.reader_unknown then return false end
  for _, child in ipairs(record.install_readers or {}) do
   if child.constructing or child.unknown then return false end
   local checked, physical = pcall(child.methods.is_settled, child.operation)
   if not checked or physical ~= true then return false end
  end
  return not record.reader_unknown
 end
 install_readers_settled = readers_settled
 function factory.begin_install(brand, transaction, defaults, admission, execution)
  local record = records[brand]
  if not record or not rawequal(transaction, record.transaction) or record.install ~= nil or not record.committed
   or not record.transfer_ack or record.cancelled or record.pointer == nil or not record.sealed_length
   or type(admission) ~= "function" or type(execution) ~= "function" then return nil end
  local work = { token = {}, record = record, constructing = true, accepted = false, done = false,
   execution = execution, listeners = {} }
  record.install, installs[work.token] = work, work -- Reserve before any native/source capability probe.
  local prepared, ready = pcall(function()
   if not capture_install then
    local policy = require("updater.install_budget")
    capture_install, admit_install_budget = rawget(policy, "capture"), rawget(policy, "admit")
    install_deadline, retire_install = rawget(policy, "deadline"), rawget(policy, "retire")
    capture_listing = rawget(policy, "capture_listing")
    if type(capture_install) ~= "function" or type(admit_install_budget) ~= "function"
     or type(install_deadline) ~= "function" or type(retire_install) ~= "function"
     or type(capture_listing) ~= "function" then return false end
   end
   local inspected, current_native = pcall(admission)
   local clocked, now = pcall(now_ms)
   if not inspected or current_native ~= true or not clocked or not install_identity(work) then return false end
   local captured, budget = pcall(capture_install, defaults, now)
   if not captured or budget == nil or not install_identity(work) then return false end
   work.budget, work.deadline = budget, install_deadline(budget)
   local listed, listing_cap = pcall(capture_listing, defaults)
   if not listed or listing_cap == nil or not install_identity(work) then return false end
   work.feeder = new_private_tar_feeder(backend, listing_cap)
   if type(work.feeder) ~= "function" or not install_identity(work) then return false end
   local final, still_current = pcall(admission)
   local observed, final_now = pcall(now_ms)
   return final and still_current == true and observed and admit_install_budget(budget, final_now) == true
    and install_identity(work) and type(work.deadline) == "number"
  end)
  work.constructing = false
  if not prepared or ready ~= true or not install_identity(work) then
   if work.budget and retire_install then pcall(retire_install, work.budget) end
   installs[work.token] = nil
   if record.install == work then record.install = nil end
   return nil -- All constructor probes above precede native reader acquisition.
  end
  work.accepted = true
  return work.token
 end
 function factory.install_current(token)
  local work = installs[token]
  return work ~= nil and install_active(work)
 end
 local finish_readers
 local function flat_result(result)
  local copy = { ok = type(result) == "table" and rawget(result, "ok") == true }
  if type(result) == "table" then
   local stdout = rawget(result, "stdout")
   if type(stdout) == "string" then copy.stdout = stdout end
   local receipt = rawget(result, "receipt")
   if type(receipt) == "table" then
    copy.receipt = {}
    for key, value in next, receipt do
     if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
      copy.receipt[key] = value
     end
    end
   end
  end
  return copy
 end
 function factory.install_feed(token, mode, directory, callback)
  local work = installs[token]
  if not work or type(callback) ~= "function" or not install_active(work) or work.child ~= nil then return nil end
  local record = work.record
  local child = { constructing = true, received = false, done = false }
  work.child = child
  record.install_readers = record.install_readers or {}
  record.install_readers[#record.install_readers + 1] = child
  local function deliver()
   if child.constructing or child.unknown or child.done or not child.received or not child.operation then return end
   local checked, physical = pcall(child.methods.is_settled, child.operation)
   if not checked or physical ~= true or child.done or work.child ~= child then return end
   child.done, work.child = true, nil
   pcall(callback, flat_result(child.result))
   if finish_readers then finish_readers(work) end
  end
  local started, operation = pcall(work.feeder, record, mode, directory, record.sealed_length,
   function() return install_active(work) end, work.deadline, function(result)
    if child.received then return end
    child.received, child.result = true, flat_result(result)
    deliver()
   end)
  if started and type(operation) == "table" then
   local methods = { is_settled = rawget(operation, "is_settled"), cancel = rawget(operation, "cancel"),
    on_settled = rawget(operation, "on_settled") }
   if type(methods.is_settled) == "function" and type(methods.cancel) == "function" and type(methods.on_settled) == "function" then
    child.operation, child.methods = operation, methods
    local observed, ack = pcall(methods.on_settled, operation, deliver)
    if not observed or ack ~= true then child.unknown = true end
   else child.unknown = true end
  elseif started and operation == nil then
   -- The fixed lexical helper returns nil only before native acquisition.
   local absent = {}
   function absent:is_settled() return true end
   function absent:cancel() return true end
   function absent:on_settled(listener) pcall(listener); return true end
   child.operation, child.methods = absent, { is_settled = absent.is_settled, cancel = absent.cancel, on_settled = absent.on_settled }
   child.received, child.result = true, { ok = false }
  else child.unknown = true end -- Thrown/unknown helper acquisition never proves physical retirement.
  child.constructing = false
  if child.unknown then record.reader_unknown = true end
  if child.operation and (child.unknown or not install_identity(work) or work.finishing) then
   child.signalled = true; pcall(child.methods.cancel, child.operation)
  end
  deliver()
  return child.operation -- Only opaque feeder operation; never its native duplicate/pointer/pipe.
 end
 finish_readers = function(work)
  if not work.finish or work.finish.done or work.finish.probing or work.constructing then return end
  local finish, record = work.finish, work.record
  finish.probing = true
  local checked = pcall(function()
   local observed, ready = pcall(readers_settled, record)
   if not observed or ready ~= true or work.finish ~= finish or finish.done then return end
   local retired, ack = pcall(retire_install, work.budget)
   if not retired or ack ~= true or work.finish ~= finish or finish.done then return end
   local settled = finish.keep == true
   if not settled then record.cancelled = true; settled = cleanup(record) == true end
   if not settled or work.finish ~= finish or finish.done then return end
   finish.done, work.done = true, true
   if record.install == work then record.install = nil end
   installs[work.token] = nil
   pcall(finish.callback, { ok = true })
   local listeners = finish.listeners; finish.listeners = {}
   for _, listener in ipairs(listeners) do pcall(listener) end
  end)
  finish.probing = false
  if not checked then record.reader_unknown = true end -- Preserve, never infer physical retirement from throws.
 end
 function factory.finish_install(token, keep, callback)
  local work = installs[token]
  if not work or work.done or work.finish or type(keep) ~= "boolean" or type(callback) ~= "function" then return nil end
  local finish, operation = { done = false, probing = false, keep = keep, callback = callback, listeners = {} }, {}
  work.finish, work.finishing = finish, true
  function operation:is_settled() return finish.done end
  function operation:on_settled(listener)
   if type(listener) ~= "function" then return false end
   if finish.done then pcall(listener) else finish.listeners[#finish.listeners + 1] = listener end
   return true
  end
  function operation:cancel()
   finish.keep = false
   for _, child in ipairs(work.record.install_readers or {}) do
    if child.operation and child.methods and not child.signalled then
     child.signalled = true; pcall(child.methods.cancel, child.operation)
    end
   end
   finish_readers(work)
   return true -- Physical retirement remains is_settled's captured acknowledgement.
  end
  finish_readers(work)
  return operation
 end


 return factory
end

return M
