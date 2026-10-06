--- infra/fd_sha256.lua

--- Bounded parent-only SHA-256 over an already retained sealed descriptor.
--- The caller owns that FD and must join this operation's physical read/context/
--- timer retirement before closing it. This module never reopens a pathname.
local M = {}
local retained = {}
local CHUNK_BYTES, MAX_INTEGER = 65536, 9007199254740991

local function time(value)
	return type(value) == "number" and value == value and value >= 0
		and value <= MAX_INTEGER
end

local function integer(value)
	return time(value) and value % 1 == 0
end

local function failure(stage, err)
	local native_errno = type(err) == "table" and type(err.errno) == "string" and err.errno or nil
	return { stage = stage, backend = "native_fs", native_errno_domain = "posix",
		native_errno = native_errno, failure_provenance = native_errno and "verified" or "unknown" }
end

--- Constructs the private read/hash worker from explicit native ports.
--- @param ports table read, digest_create/update/final/free, deadline, now_ms.
--- @return table factory
function M.new(ports)
	assert(type(ports) == "table", "FD digest ports required")
	local factory = {}

	--- Captures an exact sealed FD and original phase deadline.
	--- @param fd number Native parent-owned descriptor, never a display pathname.
	--- @param length number Exact committed length of the sealed output ticket.
	--- @param current function Fresh literal-true sealed transaction admission.
	--- @param deadline number Original absolute hash phase bound.
	--- @param callback function Private completion after physical retirement.
	--- @return table|nil operation
	function factory.start(fd, length, current, deadline, callback)
		if not integer(fd) or not integer(length) or length == 0 or type(current) ~= "function"
			or not time(deadline) or type(callback) ~= "function" then return nil end
		for _, name in ipairs({ "read", "digest_create", "digest_update", "digest_final",
			"digest_free", "deadline", "now_ms" }) do
			if type(ports[name]) ~= "function" then return nil end
		end
		local operation = {}
		local state = { terminal = false, pending = nil, offset = 0, context = nil,
			context_state = "absent", timer = nil, acquiring = true, probing = false,
			finishing = false, native_work = false, delivered = false, digest = nil, receipt = nil, listeners = {} }
		retained[operation] = state
		local settle, terminate, issue

		local function physically_settled()
			if not state.terminal or state.acquiring or state.pending or state.native_work
				or state.context_state ~= "absent" and state.context_state ~= "freed" then return false end
			if not state.timer then return true end
			local called, ack = pcall(state.timer.is_settled, state.timer)
			return called and ack == true
		end

		settle = function()
			if state.finishing or not state.terminal or state.acquiring or state.pending or state.native_work then return end
			state.finishing = true
			if state.context_state == "open" then
				local context = state.context
				state.context_state = "freeing" -- Reserve exactly one destructive native call.
				local called, ack = pcall(ports.digest_free, context)
				state.context_state = called and ack == true and "freed" or "uncertain-free"
				if state.context_state == "freed" then state.context = nil end
			end
			if state.timer then pcall(state.timer.cancel, state.timer) end
			state.finishing = false
			if not physically_settled() or state.delivered then return end
			if state.digest then
				-- Physical timer retirement may arrive after source withdrawal or
				-- the original hash bound. It cannot revive publication consent.
				state.finishing = true
				local admitted, accepted = pcall(current)
				local observed, now = pcall(ports.now_ms)
				state.finishing = false
				if not admitted or accepted ~= true or not observed or not time(now) or now >= deadline then
					state.digest, state.receipt = nil, failure("file_read")
				end
			end
			state.delivered = true
			retained[operation] = nil
			local listeners = state.listeners
			state.listeners = {}
			-- Publication belongs to the original caller's owner fence. The worker
			-- reports only its private terminal outcome and actual physical debt.
			pcall(callback, state.digest, state.receipt and failure(state.receipt.stage,
				{ errno = state.receipt.native_errno }) or nil)
			for _, listener in ipairs(listeners) do pcall(listener) end
		end

		terminate = function(receipt)
			if receipt and state.digest and not state.delivered then
				state.digest, state.receipt = nil, receipt
			end
			if not state.terminal then
				state.terminal = true
				state.receipt = receipt
				if receipt then state.digest = nil end
			end
			settle()
		end

		local function admit()
			if state.terminal or state.probing then return false end
			state.probing = true
			local called, accepted = pcall(current)
			local clock_ok, now = pcall(ports.now_ms)
			state.probing = false
			if state.terminal then return false end
			if not called or accepted ~= true or not clock_ok or not time(now) or now >= deadline then
				terminate(failure("file_read"))
				return false
			end
			return true
		end

		function operation:cancel()
			terminate(failure("file_read"))
			return true -- Logical revoke; pending read/native close ACKs still own debt.
		end
		function operation:is_settled() return physically_settled() end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if physically_settled() then pcall(listener)
			else state.listeners[#state.listeners + 1] = listener end
			return true
		end

		issue = function()
			if state.pending or state.context_state ~= "open" or not admit() then return end
			local work = { offset = state.offset, fired = false }
			-- Read one bounded chunk plus a separate final EOF observation. A file
			-- larger than its original committed byte count cannot pass the digest.
			local capacity = math.min(CHUNK_BYTES, length - state.offset + 1)
			state.pending = work
			local called, request = pcall(ports.read, fd, capacity, work.offset, function(err, chunk)
				if work.fired or state.pending ~= work then return end
				work.fired = true
				state.pending = nil -- Actual callback retires only this read request.
				if state.terminal then settle(); return end
				if err or type(chunk) ~= "string" or #chunk > capacity then
					terminate(failure("file_read", err)); return
				end
				if not admit() then return end
				if #chunk == 0 then
					if state.offset ~= length then terminate(failure("file_read")); return end
					state.native_work = true
					local finalized, digest = pcall(ports.digest_final, state.context)
					state.native_work = false
					if state.terminal then settle(); return end
					if not finalized or type(digest) ~= "string" or #digest ~= 64
						or digest:find("[^0-9a-f]") or not admit() then
						terminate(failure("file_read")); return
					end
					state.digest = digest
					terminate()
					return
				end
				if state.offset > length - #chunk then terminate(failure("file_read")); return end
				state.native_work = true
				local updated, ack = pcall(ports.digest_update, state.context, chunk)
				state.native_work = false
				if state.terminal then settle(); return end
				if not updated or ack ~= true or not admit() then terminate(failure("file_read")); return end
				state.offset = state.offset + #chunk
				issue()
			end)
			if not called then
				-- The port may already own a native read: only its actual callback
				-- can clear this request, even after logical cancellation.
				if state.pending == work then work.uncertain = true end
				terminate(failure("file_read"))
			elseif not request and not work.fired then
				state.pending = nil -- Explicit libuv refusal means no submitted work.
				terminate(failure("file_read"))
			end
		end

		if not admit() then state.acquiring = false; settle(); return operation end
		local armed, timer = pcall(ports.deadline, deadline, function() terminate(failure("file_read")) end)
		if armed and type(timer) == "table" and type(timer.cancel) == "function"
			and type(timer.is_settled) == "function" and type(timer.on_settled) == "function" then
			state.timer = timer
			local subscribed, ack = pcall(timer.on_settled, timer, settle)
			if not subscribed or ack ~= true or timer.started ~= true then terminate(failure("file_read")) end
		else
			state.timer = { cancel = function() return false end, is_settled = function() return false end }
			terminate(failure("file_read"))
		end
		if not state.terminal and admit() then
			state.context_state = "allocating"
			local created, context = pcall(ports.digest_create)
			if created and context ~= nil then
				state.context, state.context_state = context, "open"
			else
				state.context_state = created and "absent" or "uncertain-allocation"
				terminate(failure("file_read"))
			end
		end
		state.acquiring = false
		if state.terminal then settle() else issue() end
		return operation
	end
	return factory
end

--- Builds the actual libuv/opaque OpenSSL EVP backend from native APIs.
--- @return table factory
function M.native()
	local projected = require("_generated.native_runtime")
	local runtime = type(projected) == "table" and rawget(projected, "archive_digest_runtime")
	local soname = type(runtime) == "table" and rawget(runtime, "soname")
	assert(type(runtime) == "table" and rawget(runtime, "schema_version") == 1
		and soname == "libcrypto.so.3",
		"Generated FD digest runtime descriptor unavailable")
	local ffi, uv = require("ffi"), require("luv")
	assert(ffi.os == "Linux", "FD digest requires Linux")
	-- Exact opaque typedefs/prototypes from installed OpenSSL types.h/evp.h.
	-- No ABI layout, EVP context fields or version-dependent sizes are guessed.
	ffi.cdef([[
		typedef struct evp_md_st EVP_MD;
		typedef struct evp_md_ctx_st EVP_MD_CTX;
		typedef struct engine_st ENGINE;
		EVP_MD_CTX *EVP_MD_CTX_new(void);
		void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
		const EVP_MD *EVP_sha256(void);
		int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, ENGINE *impl);
		int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *data, size_t count);
		int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);
	]])
	local crypto = ffi.load(soname)
	local Clock, Deadline = require("infra.monotonic"), require("infra.managed_http_deadline")
	return M.new({
		now_ms = Clock.now_ms, deadline = Deadline.start,
		read = function(fd, capacity, offset, callback)
			return uv.fs_read(fd, capacity, offset, function(err, chunk)
				local typed
				if err then typed = { errno = type(err) == "string" and
					(err:match("^(E[A-Z0-9_]+):") or err:match("^(E[A-Z0-9_]+)$")) or nil } end
				callback(typed, chunk)
			end)
		end,
		digest_create = function()
			local context = crypto.EVP_MD_CTX_new()
			if context == nil then return nil end
			if crypto.EVP_DigestInit_ex(context, crypto.EVP_sha256(), nil) ~= 1 then
				crypto.EVP_MD_CTX_free(context)
				return nil
			end
			return context
		end,
		digest_update = function(context, chunk)
			return crypto.EVP_DigestUpdate(context, chunk, #chunk) == 1
		end,
		digest_final = function(context)
			local output, length = ffi.new("unsigned char[32]"), ffi.new("unsigned int[1]")
			if crypto.EVP_DigestFinal_ex(context, output, length) ~= 1 or tonumber(length[0]) ~= 32 then return nil end
			local hex = {}
			for i = 0, 31 do hex[#hex + 1] = string.format("%02x", tonumber(output[i])) end
			return table.concat(hex)
		end,
		digest_free = function(context)
			crypto.EVP_MD_CTX_free(context) -- Header-defined void native return.
			return true
		end,
	})
end

return M
