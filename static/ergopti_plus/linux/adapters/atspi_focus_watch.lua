--- adapters/atspi_focus_watch.lua

--- ==============================================================================
--- MODULE: Native Accessibility Focus Watch Owner (Linux)
--- DESCRIPTION:
--- Owns one isolated AT-SPI listener and private nonblocking FIFO transport.
--- Input callbacks drain native receipts without dispatching a nested libuv loop.
--- Missing, stale, malformed and physically retired authority stays fail-closed.
--- ==============================================================================

local M = {}
local Json = require("json")
local Monotonic = require("infra.monotonic")
local Timings = require("infra.timings")
local OwnedProcess = require("adapters.owned_process")
local Paths = require("infra.paths")
local AtspiFocus = require("adapters.atspi_focus")
local Logger = require("logger.shim")
local LOG = "adapters.atspi_focus_watch"
local MAX_BYTES = 65536
local MAX_FRAMES = 128

--- Allocates only daemon-owned FIFO endpoints with close-on-exec descriptors.
--- @return table transport
local function native_transport()
	local ffi = require("ffi")
	local uv = require("luv")
	ffi.cdef([[
		int mkfifo(const char *path, unsigned int mode);
		int open(const char *path, int flags, ...);
		long read(int fd, void *buffer, unsigned long count);
		long write(int fd, const void *buffer, unsigned long count);
		int close(int fd);
	]])
	local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-focus-XXXXXX"))
	local transport = { directory = directory, events_path = directory .. "/events", control_path = directory .. "/control" }
	local events_fd, control_fd = nil, nil
	local files = {}
	local buffer = ffi.new("char[4096]")
	function transport.close()
		local accepted = true
		for _, descriptor in ipairs({ events_fd or -1, control_fd or -1 }) do
			if descriptor >= 0 and ffi.C.close(descriptor) ~= 0 then accepted = false end
		end
		events_fd, control_fd = nil, nil
		return accepted
	end
	function transport.cleanup()
		local accepted = true
		for path in pairs(files) do
			local ok, _, code = uv.fs_unlink(path)
			if ok or code == "ENOENT" then files[path] = nil else accepted = false end
		end
		if next(files) == nil and directory then
			local ok, _, code = uv.fs_rmdir(directory)
			if ok or code == "ENOENT" then directory = nil else accepted = false end
		end
		return accepted and directory == nil
	end
	local ok = pcall(function()
		assert(uv.fs_chmod(directory, 448)) -- 0700, independently of the caller's umask.
		for _, path in ipairs({ transport.events_path, transport.control_path }) do
			assert(ffi.C.mkfifo(path, 384) == 0, "private focus FIFO creation failed") -- 0600.
			files[path] = true
		end
		events_fd = ffi.C.open(transport.events_path, 2048 + 524288) -- O_RDONLY | O_NONBLOCK | O_CLOEXEC.
		assert(events_fd >= 0, "private focus output could not be opened")
		control_fd = ffi.C.open(transport.control_path, 2 + 2048 + 524288) -- O_RDWR | O_NONBLOCK | O_CLOEXEC.
		assert(control_fd >= 0, "private focus control could not be opened")
	end)
	if not ok then
		transport.error = "native endpoint allocation failed"
		transport.close()
		transport.cleanup()
		return transport
	end
	function transport.read()
		if events_fd == nil then return nil, "closed" end
		local count = tonumber(ffi.C.read(events_fd, buffer, 4096))
		if count > 0 then return ffi.string(buffer, count) end
		if count == 0 then return nil, "eof" end
		local code = ffi.errno()
		if code == 11 then return nil, "again" end -- EAGAIN.
		if code == 4 then return "" end -- EINTR retries within the pump's work bound.
		return nil, "read failed"
	end
	function transport.request(request)
		if control_fd == nil then return false end
		local encoded = "R" .. tostring(request) .. "\n"
		return ffi.C.write(control_fd, encoded, #encoded) == #encoded
	end
	function transport.command()
		local executable = assert(uv.exepath(), "native interpreter identity unavailable")
		return executable, { Paths.driver_root() .. "/adapters/atspi_focus_watch_worker.lua",
			transport.events_path, tostring(uv.os_getpid()),
			tostring(Timings.ms("privacy", "focus_settle_ms")), transport.control_path }
	end
	return transport
end

--- Creates one independently owned native focus watcher.
--- Test transports model native ownership without requiring LuaJIT or libatspi.
--- @param options table|nil { now_ms?, create_transport?, start_process? }
--- @return table watcher
function M.new(options)
	options = options or {}
	local now_ms = options.now_ms or Monotonic.now_ms
	local create_transport = options.create_transport or native_transport
	local start_process = options.start_process or OwnedProcess.start
	local lease_ms = Timings.ms("privacy", "atspi_probe_timeout_ms")
	local barrier_ms = Timings.ms("privacy", "focus_barrier_timeout_ms")
	local pause = options.pause or function()
		require("luv").sleep(1)
	end
	local watcher = {}
	local transport, operation, callback = nil, nil, nil
	local active, ready, failed = false, false, false
	local receipt, last_at, sequence, request = nil, nil, 0, 0
	local pending, received = "", false
	local answered_request = -1
	local cleanup_ok = true

	local function publish(snapshot)
		local before = receipt and receipt.bus .. receipt.path .. tostring(receipt.role) or nil
		local after = snapshot and snapshot.bus .. snapshot.path .. tostring(snapshot.role) or nil
		receipt = snapshot
		AtspiFocus._publish_resident_snapshot(snapshot)
		if callback and before ~= after then callback(snapshot) end
	end
	local function cleanup()
		if operation and not operation:is_settled() then return false end
		if transport then
			local closed = transport.close() == true
			local removed = transport.cleanup() == true
			cleanup_ok = closed and removed
			if cleanup_ok then transport = nil end
		end
		return cleanup_ok and transport == nil
	end
	local function fail(reason)
		if not failed then Logger.warn(LOG, "Native focus authority withheld (%s).", reason) end
		failed, ready = true, false
		publish(nil)
		if operation then operation:cancel() end
		cleanup()
	end

	--- Registers the single privacy owner before starting the native listener.
	--- @param listener function Receives a detached native receipt or nil.
	function watcher.on_change(listener)
		assert(callback == nil and not active and type(listener) == "function", "focus watcher listener already initialized")
		callback = listener
	end

	--- Starts one exact helper, refusing a new generation until old debt settles.
	--- @return boolean started
	function watcher.start()
		if active or not cleanup() then return false end
		active, ready, failed = true, false, false
		operation = nil
		receipt, last_at, sequence, request, pending, received = nil, nil, 0, 0, "", false
		answered_request = -1
		watcher.started_at = now_ms()
		local ok, owned = pcall(create_transport)
		if not ok or type(owned) ~= "table" then fail("transport unavailable"); return false end
		transport = owned
		if transport.error then fail(transport.error); return false end
		local commanded, executable, arguments = pcall(transport.command)
		if not commanded then fail("interpreter unavailable"); return false end
		local ended = false
		local spawned, child = pcall(start_process, executable, arguments, {
			owner = "accessibility-focus-watch", capture_tail = true,
			max_output_bytes = MAX_BYTES, cwd = Paths.driver_root(),
		}, function()
			ended = true
			if operation then fail("worker exited") end
		end)
		operation = spawned and child or nil
		if operation then operation:on_settled(cleanup) end
		if not operation or operation.started ~= true or ended then fail("worker dispatch refused"); return false end
		return true
	end

	local function consume(message)
		local now = now_ms()
		if type(message) ~= "table" or type(message.sequence) ~= "number" or message.sequence % 1 ~= 0
			or message.sequence ~= sequence + 1 or type(message.at_ms) ~= "number"
			or message.at_ms ~= message.at_ms or message.at_ms < 0 or message.at_ms > now
			or type(message.request) ~= "number" or message.request % 1 ~= 0 or message.request < 0
			or message.request > request then return false end
		if last_at and message.at_ms < last_at then return false end
		local kind, candidate = message.kind, nil
		if kind == "snapshot" then
			if not ready or type(message.role) ~= "number" or message.role < 0 or message.role % 1 ~= 0
				or type(message.active_scope) ~= "boolean" then return false end
			if message.active_scope == true and type(message.bus) == "string" and message.bus:match("^:%d+%.%d+$")
				and type(message.path) == "string" and message.path:match("^/[%w_/]+$") then
				candidate = { role = message.role, bus = message.bus, path = message.path }
			end
		elseif kind ~= "ready" and kind ~= "heartbeat" and kind ~= "unknown" then return false end
		sequence, last_at = message.sequence, message.at_ms
		if kind == "ready" then
			-- Both ends are open now. Unlink the private names before admitting
			-- input, so an unclean daemon death leaves no FIFO or directory.
			if transport.cleanup() ~= true then return false end
			ready = true
		end
		if now - message.at_ms > lease_ms then
			-- A busy daemon can accumulate honest old frames while its resident
			-- remains healthy. Retire their authority, retaining the exact owner
			-- so only a new matching admission request can restore the verdict.
			publish(nil)
			return true
		end
		if kind == "ready" or message.request ~= request or kind == "heartbeat" then return true end
		answered_request = request
		publish(kind == "snapshot" and candidate or nil)
		return true
	end

	--- Drains only a bounded number of already-available native messages.
	--- @return boolean available
	function watcher.pump()
		if not active or failed or not transport then return false end
		if operation and not operation:is_running() then fail("worker unavailable"); return false end
		local bytes, frames = 0, 0
		for _ = 1, MAX_FRAMES do
			local chunk, status = transport.read()
			if chunk == nil then
				if status ~= "again" and not (status == "eof" and not received) then fail("output ended") end
				break
			end
			received = true
			bytes = bytes + #chunk
			pending = pending .. chunk
			if bytes > MAX_BYTES or #pending > MAX_BYTES then fail("output exceeded bound"); break end
			while true do
				local newline = pending:find("\n", 1, true)
				if not newline then break end
				local line = pending:sub(1, newline - 1)
				pending = pending:sub(newline + 1)
				frames = frames + 1
				local ok, message = pcall(Json.decode, line)
				if frames > MAX_FRAMES or not ok or not consume(message) then fail("invalid native receipt"); break end
			end
			if failed then break end
		end
		local fresh = last_at ~= nil and now_ms() - last_at <= lease_ms
		if not fresh then publish(nil) end
		return ready and not failed and fresh
	end

	--- Invalidates locally before requesting a fresh resident traversal.
	--- @return boolean requested
	function watcher.invalidate()
		publish(nil)
		if not active or failed or not transport then return false end
		request = request + 1
		if not transport.request(request) then fail("refresh request refused"); return false end
		return true
	end

	--- Obtains a causally fresh resident answer before logical input collection.
	--- Timeout withholds logical collection and never starts a second process.
	--- @return table|nil receipt
	function watcher.barrier()
		watcher.pump()
		if not ready or failed or not transport then return nil end
		request = request + 1
		if not transport.request(request) then fail("admission request refused"); return nil end
		local deadline = now_ms() + barrier_ms
		while now_ms() <= deadline do
			watcher.pump()
			if failed then return nil end
			if answered_request == request then return watcher.snapshot() end
			pause()
		end
		publish(nil)
		return nil
	end

	--- Returns the last live, exact focused-control receipt without native work.
	--- @return table|nil receipt
	function watcher.snapshot()
		if not ready or failed or not receipt or last_at == nil or now_ms() - last_at > lease_ms then return nil end
		return { role = receipt.role, bus = receipt.bus, path = receipt.path }
	end

	--- Waits only during daemon startup, before entering the native event loop.
	--- @return boolean ready
	function watcher.wait_ready()
		local ok, uv = pcall(require, "luv")
		if not ok or not active then return false end
		watcher.started_at = now_ms()
		while now_ms() - watcher.started_at <= lease_ms do
			uv.run("nowait")
			if watcher.pump() then return true end
			if failed then return false end
			uv.sleep(1)
		end
		publish(nil)
		return false
	end

	--- Fences publications and retains physical cleanup debt until acknowledged.
	--- @return boolean settled
	function watcher.stop()
		active, ready = false, false
		publish(nil)
		if operation then operation:cancel() end
		return cleanup()
	end

	--- Returns physical process, descriptor and private-directory settlement.
	--- @return boolean settled
	function watcher.is_settled() return cleanup() end

	return watcher
end

return M
