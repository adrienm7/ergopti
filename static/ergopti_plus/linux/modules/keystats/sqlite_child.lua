--- modules/keystats/sqlite_child.lua

--- ==============================================================================
--- MODULE: Persistent sqlite3 Child (Linux)
--- DESCRIPTION:
--- Keeps one `sqlite3` CLI process open on the metrics store for the
--- synchronous writer, so each statement is a round trip on its pipes instead
--- of a shell and a new process (about 4 ms each). The design and its measure
--- are docs/design/linux-sqlite-persistent-child.md.
---
--- FEATURES & RATIONALE:
--- 1. LuaJIT FFI only, never luv (tests/hardware/run_sqlite_private_no_luv.lua):
---    socketpair, pipe2, posix_spawnp with file actions, poll, read, send,
---    waitpid. M.available() is false on stock Lua, whose writer keeps one
---    process per call.
--- 2. Each success is acknowledged by a `.print` of a per-call random token,
---    drawn from /dev/urandom after the script is known and absent from it, so
---    neither the script nor a stored row can forge the acknowledgement.
--- 3. `-bail` still ends the child on the first refused statement, which
---    closes its connection and rolls an open batch back, exactly as one
---    process per call did. End of file before the token is that refusal: the
---    child is reaped and the next call starts a new one. A script that leaves
---    a transaction open is refused too (`BEGIN;` after it fails).
--- 4. Every read and write has a deadline (poll with a timeout): a hung child
---    is killed and reaped instead of hanging the daemon's loop.
--- 5. The script travels on the child's standard input, never on disk.
---    Standard input is a socket so that a write to a child that died raises
---    EPIPE (MSG_NOSIGNAL) instead of a SIGPIPE that would end the daemon.
--- 6. Diagnostics are returned raw to the caller, which logs only
---    sqlite_command.sanitise_error categories: stderr echoes SQL, and SQL
---    carries typed text. This module logs no SQL, output or stderr byte.
--- ==============================================================================

local M = {}
local Logger = require("core.logger.engine.shim")
local PrivacyPolicy = require("core.fs.engine.sqlite_privacy_policy")

local LOG = "modules.keystats.sqlite_child"




-- =====================================
-- =====================================
-- ======= 1/ Constants & State ========
-- =====================================
-- =====================================

-- Linux ABI values (x86_64 and aarch64 share them).
local AF_UNIX, SOCK_STREAM, SOCK_CLOEXEC, O_CLOEXEC = 1, 1, 524288, 524288
local MSG_DONTWAIT, MSG_NOSIGNAL = 64, 16384
local POLLIN, POLLOUT, POLLERR, POLLHUP, POLLNVAL = 1, 4, 8, 16, 32
local EINTR, EAGAIN = 4, 11
local SIGKILL, SIGPIPE = 9, 13
local POSIX_SPAWN_SETSIGDEF, POSIX_SPAWN_SETSIGMASK = 4, 8
local WNOHANG = 1

-- The FFI bindings, resolved once; false when this runtime has none.
local _native = nil

-- The live child: { pid, stdin, stdout, stderr, db_path }, or nil.
local _child = nil

-- /dev/urandom, opened on the first token.
local _random = nil




-- =====================================
-- =====================================
-- ======= 2/ Native bindings ==========
-- =====================================
-- =====================================

--- Resolves the FFI bindings once.
--- @return table|false
local function native()
	if _native ~= nil then return _native end
	_native = false
	if not rawget(_G, "jit") then return false end
	local loaded, ffi = pcall(require, "ffi")
	if not loaded or ffi.os ~= "Linux" then return false end
	-- Aliased names: another module's plain `read` or `pipe2` declaration
	-- must not make this one a redefinition.
	pcall(ffi.cdef, [[
		struct ergopti_sqlite_child_pollfd { int fd; short events; short revents; };
		int ergopti_sqlite_child_socketpair(int domain, int type, int protocol, int fds[2]) __asm__("socketpair");
		int ergopti_sqlite_child_pipe2(int fds[2], int flags) __asm__("pipe2");
		int ergopti_sqlite_child_spawnp(int *pid, const char *file, const void *actions, const void *attributes,
			char *const argv[], char *const envp[]) __asm__("posix_spawnp");
		int ergopti_sqlite_child_actions_init(void *actions) __asm__("posix_spawn_file_actions_init");
		int ergopti_sqlite_child_actions_dup2(void *actions, int fd, int target) __asm__("posix_spawn_file_actions_adddup2");
		int ergopti_sqlite_child_actions_destroy(void *actions) __asm__("posix_spawn_file_actions_destroy");
		int ergopti_sqlite_child_attr_init(void *attributes) __asm__("posix_spawnattr_init");
		int ergopti_sqlite_child_attr_flags(void *attributes, short flags) __asm__("posix_spawnattr_setflags");
		int ergopti_sqlite_child_attr_sigdefault(void *attributes, const void *set) __asm__("posix_spawnattr_setsigdefault");
		int ergopti_sqlite_child_attr_sigmask(void *attributes, const void *set) __asm__("posix_spawnattr_setsigmask");
		int ergopti_sqlite_child_attr_destroy(void *attributes) __asm__("posix_spawnattr_destroy");
		int ergopti_sqlite_child_sigemptyset(void *set) __asm__("sigemptyset");
		int ergopti_sqlite_child_sigaddset(void *set, int signal) __asm__("sigaddset");
		long ergopti_sqlite_child_read(int fd, void *buffer, size_t count) __asm__("read");
		long ergopti_sqlite_child_send(int fd, const void *buffer, size_t count, int flags) __asm__("send");
		int ergopti_sqlite_child_close(int fd) __asm__("close");
		int ergopti_sqlite_child_poll(struct ergopti_sqlite_child_pollfd *fds, unsigned long count, int timeout)
			__asm__("poll");
		int ergopti_sqlite_child_waitpid(int pid, int *status, int options) __asm__("waitpid");
		int ergopti_sqlite_child_kill(int pid, int signal) __asm__("kill");
		unsigned int ergopti_sqlite_child_umask(unsigned int mask) __asm__("umask");
		int ergopti_sqlite_child_clock_gettime(int clock, void *timespec) __asm__("clock_gettime");
		extern char **ergopti_sqlite_child_environ __asm__("environ");
	]])
	local resolved, C = pcall(function()
		local C = ffi.C
		local _ = C.ergopti_sqlite_child_socketpair, C.ergopti_sqlite_child_pipe2, C.ergopti_sqlite_child_spawnp,
			C.ergopti_sqlite_child_poll, C.ergopti_sqlite_child_waitpid, C.ergopti_sqlite_child_send, C.ergopti_sqlite_child_environ
		return C
	end)
	if not resolved then return false end
	-- One read's buffer; a dashboard row set is read in as many as it needs.
	local size = require("core.timing.engine.timings").count("limits", "sqlite_child_read_bytes")
	_native = { ffi = ffi, C = C, buffer = ffi.new("char[?]", size), buffer_size = size }
	return _native
end

--- A monotonic clock in milliseconds.
local function now_ms(n)
	local spec = n.ffi.new("int64_t[2]")
	n.C.ergopti_sqlite_child_clock_gettime(1, spec) -- CLOCK_MONOTONIC
	return tonumber(spec[0]) * 1000 + tonumber(spec[1]) / 1e6
end

--- Closes one descriptor, ignoring a descriptor already gone.
local function close_fd(n, fd)
	if fd and fd >= 0 then n.C.ergopti_sqlite_child_close(fd) end
end

--- Decodes a waitpid status: the exit code, or nil and the signal.
local function exit_code_of(status)
	if status % 128 == 0 then return math.floor(status / 256) % 256 end
	return nil, status % 128
end

--- Ends the child: kill it when asked, then reap it and close its descriptors.
--- @return number|nil exit_code
local function reap(n, child, kill)
	close_fd(n, child.stdin)
	close_fd(n, child.stdout)
	close_fd(n, child.stderr)
	child.stdin, child.stdout, child.stderr = -1, -1, -1
	if _child == child and child.pid <= 0 then _child = nil end
	-- Already reaped: waitpid(-1) would reap another of the daemon's children.
	if child.pid <= 0 then return nil end
	if kill then n.C.ergopti_sqlite_child_kill(child.pid, SIGKILL) end
	local status = n.ffi.new("int[1]")
	local waited
	repeat
		waited = n.C.ergopti_sqlite_child_waitpid(child.pid, status, 0)
	until waited ~= -1 or n.ffi.errno() ~= EINTR
	if _child == child then _child = nil end
	if waited ~= child.pid then return nil end
	return exit_code_of(tonumber(status[0]))
end




-- =====================================
-- =====================================
-- ======= 3/ Spawn ====================
-- =====================================
-- =====================================

--- Starts `program -init /dev/null -bail -noheader <db>` on three fresh pipes.
--- @return table|nil child
--- @return string|nil detail A category, never a path or SQL.
local function spawn(n, program, db_path)
	local ffi, C = n.ffi, n.C
	local input, output, errors = ffi.new("int[2]"), ffi.new("int[2]"), ffi.new("int[2]")
	if C.ergopti_sqlite_child_socketpair(AF_UNIX, SOCK_STREAM + SOCK_CLOEXEC, 0, input) ~= 0 then
		return nil, "socketpair failed"
	end
	if C.ergopti_sqlite_child_pipe2(output, O_CLOEXEC) ~= 0 then
		close_fd(n, input[0]); close_fd(n, input[1])
		return nil, "pipe2 failed"
	end
	if C.ergopti_sqlite_child_pipe2(errors, O_CLOEXEC) ~= 0 then
		close_fd(n, input[0]); close_fd(n, input[1]); close_fd(n, output[0]); close_fd(n, output[1])
		return nil, "pipe2 failed"
	end
	-- glibc's file actions are 80 bytes, its attributes 336 and a sigset 128:
	-- generous opaque storage keeps them correct on any Linux libc.
	local actions, attributes = ffi.new("uint64_t[128]"), ffi.new("uint64_t[128]")
	local defaults, mask = ffi.new("uint64_t[32]"), ffi.new("uint64_t[32]")
	C.ergopti_sqlite_child_actions_init(actions)
	C.ergopti_sqlite_child_actions_dup2(actions, input[1], 0)
	C.ergopti_sqlite_child_actions_dup2(actions, output[1], 1)
	C.ergopti_sqlite_child_actions_dup2(actions, errors[1], 2)
	C.ergopti_sqlite_child_attr_init(attributes)
	-- The daemon may ignore SIGPIPE or block signals for its own loop: the
	-- child starts with neither, as a shell-started sqlite3 did.
	C.ergopti_sqlite_child_sigemptyset(defaults)
	C.ergopti_sqlite_child_sigaddset(defaults, SIGPIPE)
	C.ergopti_sqlite_child_sigemptyset(mask)
	C.ergopti_sqlite_child_attr_sigdefault(attributes, defaults)
	C.ergopti_sqlite_child_attr_sigmask(attributes, mask)
	C.ergopti_sqlite_child_attr_flags(attributes, POSIX_SPAWN_SETSIGDEF + POSIX_SPAWN_SETSIGMASK)
	-- sqlite3 treats a bare relative name as a URI or an option: keep the
	-- filesystem identity, as sqlite_command.build does.
	local filename = db_path:sub(1, 1) == "/" and db_path or ("./" .. db_path)
	local words = { program, "-init", "/dev/null", "-bail", "-noheader", filename }
	local argv = ffi.new("char *[?]", #words + 1)
	local anchors = {}
	for index, word in ipairs(words) do
		anchors[index] = ffi.new("char[?]", #word + 1, word)
		argv[index - 1] = anchors[index]
	end
	argv[#words] = nil
	local pid = ffi.new("int[1]")
	-- The umask the shell set before each sqlite3: its journal is private.
	local previous = C.ergopti_sqlite_child_umask(PrivacyPolicy.creation_mask)
	local spawned = C.ergopti_sqlite_child_spawnp(pid, program, actions, attributes, argv, C.ergopti_sqlite_child_environ)
	C.ergopti_sqlite_child_umask(previous)
	C.ergopti_sqlite_child_actions_destroy(actions)
	C.ergopti_sqlite_child_attr_destroy(attributes)
	close_fd(n, input[1]); close_fd(n, output[1]); close_fd(n, errors[1])
	if spawned ~= 0 then
		close_fd(n, input[0]); close_fd(n, output[0]); close_fd(n, errors[0])
		return nil, "posix_spawnp failed"
	end
	return { pid = tonumber(pid[0]), stdin = tonumber(input[0]), stdout = tonumber(output[0]),
		stderr = tonumber(errors[0]), db_path = db_path }
end




-- =====================================
-- =====================================
-- ======= 4/ Exchange =================
-- =====================================
-- =====================================

--- Draws one token absent from the script.
local function draw_token(script)
	if not _random then
		_random = io.open("/dev/urandom", "rb")
		if not _random then error("sqlite child: /dev/urandom could not be opened", 0) end
	end
	while true do
		local bytes = _random:read(16)
		if type(bytes) ~= "string" or #bytes ~= 16 then error("sqlite child: /dev/urandom read failed", 0) end
		local token = "ERGOPTI_SQL_ACK_" .. (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
		if not script:find(token, 1, true) then return token end
	end
end

--- Reads what one descriptor holds now; "" at end of file, nil when nothing is ready.
local function read_ready(n, fd)
	local count = n.C.ergopti_sqlite_child_read(fd, n.buffer, n.buffer_size)
	if count > 0 then return n.ffi.string(n.buffer, count) end
	if count == 0 then return "" end
	local errno = n.ffi.errno()
	if errno == EINTR or errno == EAGAIN then return nil end
	return ""
end

--- Feeds one script and collects its output until the token or end of file.
--- @return string outcome "ack", "eof" or "deadline".
--- @return string stdout
--- @return string stderr
local function exchange(n, child, payload, token, deadline_ms)
	local ffi, C = n.ffi, n.C
	local fds = ffi.new("struct ergopti_sqlite_child_pollfd[3]")
	local sent, out, err = 0, {}, {}
	-- The last bytes read, enough to see "\n" .. token .. "\n" across chunks.
	local tail, total = "", 0
	local ack = token .. "\n"
	local stdout_open, stderr_open = true, true
	local started = now_ms(n)
	while true do
		local remaining = deadline_ms - (now_ms(n) - started)
		if remaining <= 0 then return "deadline", table.concat(out), table.concat(err) end
		local count = 0
		local stdin_slot, stdout_slot, stderr_slot
		if sent < #payload and child.stdin >= 0 then
			fds[count].fd, fds[count].events, fds[count].revents = child.stdin, POLLOUT, 0
			stdin_slot, count = count, count + 1
		end
		if stdout_open then
			fds[count].fd, fds[count].events, fds[count].revents = child.stdout, POLLIN, 0
			stdout_slot, count = count, count + 1
		end
		if stderr_open then
			fds[count].fd, fds[count].events, fds[count].revents = child.stderr, POLLIN, 0
			stderr_slot, count = count, count + 1
		end
		if count == 0 then return "eof", table.concat(out), table.concat(err) end
		local ready = C.ergopti_sqlite_child_poll(fds, count, math.max(1, math.ceil(remaining)))
		if ready < 0 and ffi.errno() ~= EINTR then return "deadline", table.concat(out), table.concat(err) end
		if ready > 0 then
			if stdin_slot and fds[stdin_slot].revents ~= 0 then
				if bit.band(fds[stdin_slot].revents, POLLERR + POLLHUP + POLLNVAL) ~= 0 then
					sent = #payload -- The child is gone; its stdout's end of file says how.
				else
					local wrote = C.ergopti_sqlite_child_send(child.stdin, ffi.cast("const char *", payload) + sent,
						#payload - sent, MSG_DONTWAIT + MSG_NOSIGNAL)
					if wrote > 0 then
						sent = sent + tonumber(wrote)
					elseif ffi.errno() ~= EAGAIN and ffi.errno() ~= EINTR then
						sent = #payload
					end
				end
			end
			if stderr_slot and fds[stderr_slot].revents ~= 0 then
				local chunk = read_ready(n, child.stderr)
				if chunk == "" then stderr_open = false elseif chunk then err[#err + 1] = chunk end
			end
			if stdout_slot and fds[stdout_slot].revents ~= 0 then
				local chunk = read_ready(n, child.stdout)
				if chunk == "" then
					stdout_open = false
				elseif chunk then
					out[#out + 1] = chunk
					total = total + #chunk
					tail = (tail .. chunk):sub(-#ack - 1)
					if sent == #payload and tail:sub(-#ack) == ack
						and (total == #ack or tail:sub(1, 1) == "\n") then
						return "ack", table.concat(out), table.concat(err)
					end
				end
			end
			-- stdout closed means the child is exiting: what it printed on stderr
			-- before that is already in the pipe, so drain it without waiting.
			if not stdout_open then
				while stderr_open do
					fds[0].fd, fds[0].events, fds[0].revents = child.stderr, POLLIN, 0
					if C.ergopti_sqlite_child_poll(fds, 1, 0) <= 0 then break end
					local chunk = read_ready(n, child.stderr)
					if chunk == "" then stderr_open = false elseif chunk then err[#err + 1] = chunk else break end
				end
				return "eof", table.concat(out), table.concat(err)
			end
		end
	end
end

--- Reads whatever a descriptor already holds, without waiting.
local function drain_now(n, fd)
	local fds = n.ffi.new("struct ergopti_sqlite_child_pollfd[1]")
	local parts = {}
	while true do
		fds[0].fd, fds[0].events, fds[0].revents = fd, POLLIN, 0
		if n.C.ergopti_sqlite_child_poll(fds, 1, 0) <= 0 then break end
		local chunk = read_ready(n, fd)
		if not chunk or chunk == "" then
			if chunk == "" then parts.eof = true end
			break
		end
		parts[#parts + 1] = chunk
	end
	return table.concat(parts), parts.eof == true
end




-- =====================================
-- =====================================
-- ======= 5/ Public API ===============
-- =====================================
-- =====================================

--- Whether this runtime can host the persistent child (LuaJIT FFI on Linux).
--- @return boolean
function M.available()
	return native() ~= false
end

--- The live child's process id, or nil.
--- @return number|nil
function M.pid()
	return _child and _child.pid or nil
end

--- Runs one script on the persistent child, starting it when none is live.
--- @param program string The sqlite3 program (owned_programs.path).
--- @param db_path string The store; a different store ends the live child first.
--- @param script string Complete SQL script; may contain typed text.
--- @param deadline_ms number The longest wait for the acknowledgement.
--- @return table result `{ status, output?, stderr?, exit_code?, detail? }`:
---   "ok" (acknowledged; output is stdout before the token), "refused" (the
---   child ended before the token, rolled back; reaped), "lost" (deadline or
---   a framing defect: the child was killed and reaped, the outcome of the
---   script is unknown) or "unavailable" (nothing was sent).
function M.run(program, db_path, script, deadline_ms)
	local n = native()
	if not n then return { status = "unavailable", detail = "no FFI runtime" } end
	if type(program) ~= "string" or program == "" or type(db_path) ~= "string" or db_path == ""
		or type(script) ~= "string" or type(deadline_ms) ~= "number" or deadline_ms <= 0 then
		error("sqlite child: invalid run arguments", 2)
	end
	if _child and _child.db_path ~= db_path then M.close(deadline_ms) end
	if _child then
		-- A child that died between calls (killed, out of memory) is reaped and
		-- replaced before this script is sent, so it is not refused for nothing.
		local status = n.ffi.new("int[1]")
		if n.C.ergopti_sqlite_child_waitpid(_child.pid, status, WNOHANG) == _child.pid then
			_child.pid = -1
			reap(n, _child, false)
			Logger.warn(LOG, "The persistent sqlite3 child had ended (status %d); a new one starts.", tonumber(status[0]))
		else
			-- Bytes waiting before anything was sent belong to no call.
			local stale, eof = drain_now(n, _child.stdout)
			if stale ~= "" or eof then
				reap(n, _child, true)
				Logger.error(LOG, "The persistent sqlite3 child wrote out of frame; it was ended.")
			end
		end
	end
	if not _child then
		local child, detail = spawn(n, program, db_path)
		if not child then
			Logger.error(LOG, "The persistent sqlite3 child could not start (%s).", detail)
			return { status = "unavailable", detail = detail }
		end
		_child = child
		Logger.debug(LOG, "Persistent sqlite3 child started (pid %d).", child.pid)
	end
	local child = _child
	local token = draw_token(script)
	-- The `;` completes a final statement without one, which the end of a
	-- heredoc used to complete. BEGIN fails, and so refuses the script, when
	-- the script left a transaction open: a fresh process rolled it back.
	local payload = script .. "\n;\n.output stdout\nBEGIN;\nROLLBACK;\n.print " .. token .. "\n"
	local outcome, output, stderr = exchange(n, child, payload, token, deadline_ms)
	if outcome == "ack" then
		local trailing, eof = drain_now(n, child.stdout)
		local late_errors = drain_now(n, child.stderr)
		if trailing ~= "" or eof then
			-- Bytes after the acknowledgement: the frame is not this call's.
			reap(n, child, true)
			Logger.error(LOG, "The persistent sqlite3 child answered out of frame; it was ended.")
			return { status = "lost", detail = "out of frame" }
		end
		return { status = "ok", output = output:sub(1, #output - #token - 1), stderr = stderr .. late_errors }
	end
	if outcome == "deadline" then
		reap(n, child, true)
		Logger.error(LOG, "The persistent sqlite3 child missed its %d ms deadline; it was ended.", deadline_ms)
		return { status = "lost", detail = "deadline" }
	end
	local code = reap(n, child, false)
	return { status = "refused", stderr = stderr, exit_code = code }
end

--- Ends the live child: end of input, then a reap within the deadline.
--- @param deadline_ms number|nil Longest wait before the child is killed.
--- @return boolean ended True when no child is left.
function M.close(deadline_ms)
	local n = native()
	if not n or not _child then return true end
	local child = _child
	close_fd(n, child.stdin)
	child.stdin = -1
	local started, status = now_ms(n), n.ffi.new("int[1]")
	local budget = deadline_ms or 1000
	while now_ms(n) - started < budget do
		local waited = n.C.ergopti_sqlite_child_waitpid(child.pid, status, WNOHANG)
		if waited == child.pid then
			close_fd(n, child.stdout); close_fd(n, child.stderr)
			_child = nil
			Logger.debug(LOG, "Persistent sqlite3 child ended.")
			return true
		end
		if waited == -1 and n.ffi.errno() ~= EINTR then break end
		drain_now(n, child.stdout)
		drain_now(n, child.stderr)
		local fds = n.ffi.new("struct ergopti_sqlite_child_pollfd[1]")
		fds[0].fd, fds[0].events = child.stdout, POLLIN
		n.C.ergopti_sqlite_child_poll(fds, 1, 5)
	end
	reap(n, child, true)
	Logger.warn(LOG, "The persistent sqlite3 child did not end at end of input; it was killed.")
	return true
end

return M
