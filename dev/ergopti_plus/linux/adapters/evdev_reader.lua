--- adapters/evdev_reader.lua

--- ==============================================================================
--- MODULE: evdev Reader (Linux)
--- DESCRIPTION:
--- The input side of the keystroke path: opens /dev/input/eventN directly, takes
--- EVIOCGRAB when the daemon needs to own the stream, and hands decoded events
--- back one at a time without ever blocking.
---
--- WHY THIS REPLACES A SUBPROCESS:
--- Capture used to scrape the TEXT output of `evtest --grab` (or `libinput
--- debug-events`) through io.popen. That had four defects at once, and they were
--- not independent:
---   1. A blocking `pipe:read("*l")`. The tray, the periodic tick, the file
---      watchers and the window cache advanced only when a key arrived — the
---      exact opposite of what the daemon's own header promised.
---   2. A binary dependency. `evtest` had to exist, and the daemon refused to
---      start without it. `libinput debug-events` additionally masks keycodes
---      unless it is given --show-keycodes, which it was not.
---   3. Lossy parsing. Re-emission under a grab has to be exact, and a regex
---      over prose loses whatever the prose does not spell out.
---   4. No control. EVIOCGRAB belonged to a child process, so the daemon could
---      not release it, could not re-take it after the device came back, and
---      could not know whether it had ever been taken.
--- Reading the fd ourselves removes all four, and it is what keyd, kanata, kmonad
--- and xremap do for the same reasons.
---
--- FEATURES & RATIONALE:
--- 1. O_NONBLOCK, always. read() returning "nothing right now" is what makes the
---    event loop an event loop instead of a keystroke-driven one. poll() is
---    offered for a caller that wants to sleep until input rather than spin.
--- 2. Swappable syscall backend, same seam as the uinput writer. Production binds
---    LuaJIT FFI; tests bind a recorder. Without it, "the grab is taken before
---    the first read" could only ever be verified on hardware, and "the keyboard
---    still works" is not an assertion.
--- 3. The grab needs no unwind handler. EVIOCGRAB is bound to the open file
---    descriptor, and the kernel drops it when that descriptor closes — including
---    when the process dies, however it dies. So a crashed daemon cannot leave a
---    dead keyboard behind, and this module deliberately does not carry a
---    signal-handler or __gc mechanism that would only pretend to add safety.
--- 4. Decoding is not here. infra/input_event.lua owns the struct in both
---    directions, so the size comes from ffi.sizeof rather than from a comment
---    asserting 24 bytes.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local InputEvent = require("infra.input_event")

local LOG = "adapters.evdev_reader"




-- ===========================================
-- ===========================================
-- ======= 1/ Kernel constants ===============
-- ===========================================
-- ===========================================

-- open(2) flags. O_RDONLY is 0, so the value is the non-blocking bit alone.
local O_NONBLOCK = 0x0800

-- EVIOCGRAB = _IOW('E', 0x90, int)
--   (1 << 30) | (sizeof(int) << 16) | ('E' << 8) | 0x90
--   0x40000000 |     0x00040000     |   0x4500   |  0x90  = 0x40044590
-- Argument: 1 takes the grab, 0 releases it.
local EVIOCGRAB = 0x40044590
local GRAB_ON   = 1
local GRAB_OFF  = 0

-- poll(2) event mask for "there is something to read".
local POLLIN = 0x001

-- How many struct reads one drain may perform before yielding to the caller.
-- A bound rather than a limit: under autorepeat the kernel can hand back events
-- faster than the loop consumes them, and an unbounded drain would starve the
-- tray and the periodic tick — the very defect this module exists to remove.
local MAX_EVENTS_PER_DRAIN = 256

--- The device this daemon grabs: the keyboard, or the remap daemon's output.
M.KEYBOARD = "keyboard"

--- The device it only watches: a pointer, for the click that moves the caret.
M.POINTER = "pointer"

--- The touchpad, read for gestures and NEVER grabbed.
---
--- The grab is right for the keyboard, where every keystroke has to be swallowed
--- and re-emitted. It would be wrong here: taking the touchpad from the
--- compositor leaves the user with a dead cursor, and evdev is broadcast, so
--- reading in parallel costs nothing. libinput never calls EVIOCGRAB for the same
--- reason — the caller owns the fd.
M.TOUCHPAD = "touchpad"




-- ===========================================
-- ===========================================
-- ======= 2/ Backend seam ===================
-- ===========================================
-- ===========================================

-- The syscall surface, as a table so tests can replace it wholesale. nil until
-- someone binds one.
local _backend = nil

-- Open descriptors, by slot. The daemon reads two devices: the keyboard it
-- grabs, and — when one is found — the pointer it only watches, because a click
-- moves the caret and every character buffered before it belongs to a different
-- position in a different line. One module rather than two because the syscall
-- surface, the struct and the drain are identical; separate state because the
-- keyboard is grabbed and the pointer must never be.
local _slots = {}

--- The state for a slot, created on first use.
--- @param slot string|nil Defaults to the keyboard.
--- @return table { fd, grabbed, path }
local function state(slot)
	local key = slot or M.KEYBOARD
	local entry = _slots[key]
	if not entry then
		entry = { fd = nil, grabbed = false, path = nil }
		_slots[key] = entry
	end
	return entry
end

--- Replaces the syscall backend. Test seam.
---
--- A backend implements:
---   open(path, flags)        → handle|nil, err
---   ioctl(handle, req, arg)  → boolean
---   read(handle, count)      → string|nil   (nil when nothing is available)
---   poll(handle, timeout_ms) → boolean      (true when readable)
---   close(handle)
--- @param backend table|nil
function M._set_backend(backend)
	_backend = backend
	_slots = {}
	Logger.debug(LOG, "Backend replaced: %s.", backend and "custom" or "none")
end

--- Drops the backend and any open descriptor. Test seam.
function M._reset_backend()
	for _, entry in pairs(_slots) do
		if entry.fd and _backend and _backend.close then pcall(_backend.close, entry.fd) end
	end
	_backend = nil
	_slots = {}
	Logger.debug(LOG, "Backend reset.")
end

--- Builds the LuaJIT FFI backend, or nil when FFI is unavailable.
---
--- Isolated so requiring this module never depends on the interpreter: plain Lua
--- (what developers run) has no ffi, LuaJIT (what CI and the daemon run) does,
--- and neither should fail to LOAD the module.
--- @return table|nil backend, string|nil err
local function build_ffi_backend()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then
		return nil, "LuaJIT FFI unavailable"
	end

	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		int open(const char *pathname, int flags);
		int close(int fd);
		int ioctl(int fd, unsigned long request, ...);
		long read(int fd, void *buf, unsigned long count);
		struct pollfd { int fd; short events; short revents; };
		int poll(struct pollfd *fds, unsigned long nfds, int timeout);
	]])
	-- A second require would redefine the same symbols; that raises rather than
	-- being a no-op, and it is not an error.
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		return nil, "ffi.cdef failed: " .. tostring(cdef_err)
	end

	-- One buffer for the lifetime of the backend. Allocating per read would put
	-- a GC allocation on the keystroke path for no benefit; the bytes are copied
	-- into a Lua string before the next read can overwrite them.
	local size = InputEvent.native_size()
	local buf  = ffi.new("char[?]", size)
	local pfd  = ffi.new("struct pollfd[1]")

	return {
		open = function(path, flags)
			local fd = ffi.C.open(path, flags)
			if fd < 0 then return nil, "open failed" end
			return fd
		end,
		ioctl = function(fd, request, arg)
			return ffi.C.ioctl(fd, request, ffi.cast("int", arg or 0)) >= 0
		end,
		read = function(fd, count)
			local got = tonumber(ffi.C.read(fd, buf, count))
			-- Negative is EAGAIN under O_NONBLOCK far more often than it is a real
			-- error, and a short read is a truncated struct we must not decode.
			if not got or got < count then return nil end
			return ffi.string(buf, got)
		end,
		poll = function(fd, timeout_ms)
			pfd[0].fd = fd
			pfd[0].events = POLLIN
			pfd[0].revents = 0
			local rc = tonumber(ffi.C.poll(pfd, 1, timeout_ms))
			return rc ~= nil and rc > 0
		end,
		close = function(fd)
			ffi.C.close(fd)
		end,
	}
end

--- Binds the production FFI backend.
--- @return boolean True when a backend is available.
function M.use_ffi_backend()
	local backend, err = build_ffi_backend()
	if not backend then
		Logger.debug(LOG, "FFI backend unavailable: %s.", tostring(err))
		return false
	end
	_backend = backend
	Logger.debug(LOG, "FFI backend bound.")
	return true
end




-- ===========================================
-- ===========================================
-- ======= 3/ Device lifecycle ===============
-- ===========================================
-- ===========================================

--- True when this reader could plausibly open a device: a backend exists and the
--- node is readable. Deliberately opens nothing — a probe with side effects on
--- an input device is a grab nobody asked for.
--- @param path string Device path, e.g. "/dev/input/event3".
--- @return boolean available, string|nil reason
function M.is_available(path)
	if not _backend and not M.use_ffi_backend() then
		return false, "no LuaJIT FFI on this runtime"
	end
	if type(path) ~= "string" or path == "" then
		return false, "no device path"
	end
	local fh = io.open(path, "rb")
	if not fh then
		return false, path .. " is not readable (is this user in the input group?)"
	end
	fh:close()
	return true
end

--- Opens the device for reading, non-blocking.
--- @param path string Device path.
--- @return boolean True when the descriptor is live.
function M.open(path, slot)
	local st = state(slot)
	if st.fd then
		Logger.debug(LOG, "open(): already open on %s.", tostring(st.path))
		return true
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "open(): a device path is required.")
		return false
	end
	if not _backend and not M.use_ffi_backend() then
		Logger.error(LOG, "open(): no syscall backend — cannot read %s.", path)
		return false
	end

	local fd, err = _backend.open(path, O_NONBLOCK)
	if not fd then
		Logger.error(LOG, "open(): cannot open %s — %s.", path, tostring(err))
		return false
	end

	st.fd = fd
	st.path = path
	st.grabbed = false
	Logger.success(LOG, "Reading %s (non-blocking).", path)
	return true
end

--- Takes EVIOCGRAB, so the desktop stops receiving this device entirely.
---
--- The caller must already be able to put every consumed event back. This module
--- cannot check that, so the guard lives at the keyboard hook, which owns both
--- ends; taking the grab here without one leaves the user with a dead keyboard.
--- @return boolean True when the grab is held.
function M.grab(slot)
	local st = state(slot)
	if not st.fd then
		Logger.error(LOG, "grab(): no device open.")
		return false
	end
	if st.grabbed then return true end
	if not _backend.ioctl(st.fd, EVIOCGRAB, GRAB_ON) then
		Logger.error(LOG, "grab(): EVIOCGRAB failed on %s — another process may already hold it.",
			tostring(st.path))
		return false
	end
	st.grabbed = true
	Logger.success(LOG, "Grabbed %s — the desktop no longer sees this device.", tostring(st.path))
	return true
end

--- Releases EVIOCGRAB, returning the device to the desktop.
--- @return boolean True when the device is no longer grabbed.
function M.ungrab(slot)
	local st = state(slot)
	if not st.fd or not st.grabbed then return true end
	if not _backend.ioctl(st.fd, EVIOCGRAB, GRAB_OFF) then
		Logger.warn(LOG, "ungrab(): EVIOCGRAB(0) failed — closing the descriptor will release it.")
		return false
	end
	st.grabbed = false
	Logger.done(LOG, "Released %s.", tostring(st.path))
	return true
end

--- Closes the device, releasing the grab on the way out.
function M.close(slot)
	local st = state(slot)
	if not st.fd then return end
	M.ungrab(slot)
	pcall(_backend.close, st.fd)
	Logger.info(LOG, "Closed %s.", tostring(st.path))
	st.fd = nil
	st.path = nil
	st.grabbed = false
end

--- @return boolean True when a device is open.
function M.is_open(slot)
	return state(slot).fd ~= nil
end

--- @return boolean True when EVIOCGRAB is currently held.
function M.is_grabbed(slot)
	return state(slot).grabbed
end

--- @return string|nil The open device path.
function M.device_path(slot)
	return state(slot).path
end




-- ===========================================
-- ===========================================
-- ======= 4/ Reading ========================
-- ===========================================
-- ===========================================

--- Blocks until the device has something to read, or the timeout expires.
---
--- Optional: a caller polling on its own schedule never needs it. It exists so an
--- event loop can sleep on input instead of waking to find nothing, which is the
--- difference between an idle daemon costing nothing and one costing a wakeup per
--- tick.
--- @param timeout_ms integer Milliseconds; 0 returns immediately, -1 waits forever.
--- @return boolean True when a read would return data.
function M.wait_readable(timeout_ms, slot)
	local st = state(slot)
	if not st.fd then return false end
	if type(_backend.poll) ~= "function" then return true end
	local ok, readable = pcall(_backend.poll, st.fd, timeout_ms or 0)
	return ok and readable == true
end

--- Reads one event, or nil when none is available right now.
--- @return table|nil { type = integer, code = integer, value = integer }.
function M.read_event(slot)
	local st = state(slot)
	if not st.fd then return nil end
	local size = InputEvent.native_size()
	local ok, data = pcall(_backend.read, st.fd, size)
	if not ok or type(data) ~= "string" then return nil end
	return InputEvent.decode(data, size)
end

--- Drains every event currently available, calling `handler` for each.
---
--- Bounded so one burst cannot monopolise the loop. The handler is called
--- through pcall: an error in the domain callbacks must not abort the drain,
--- because under a grab an aborted drain is input the user typed and never sees.
--- @param handler function Called with (event_table).
--- @return integer Number of events dispatched.
function M.drain(handler, slot)
	local st = state(slot)
	if not st.fd or type(handler) ~= "function" then return 0 end
	local count = 0
	for _ = 1, MAX_EVENTS_PER_DRAIN do
		local ev = M.read_event(slot)
		if not ev then break end
		count = count + 1
		local ok, err = pcall(handler, ev)
		if not ok then
			Logger.error(LOG, "drain(): handler failed on type=%d code=%d value=%d — %s.",
				ev.type, ev.code, ev.value, tostring(err))
		end
	end
	return count
end

-- Exposed for the tests that pin the ioctl request and the open flags.
M.EVIOCGRAB  = EVIOCGRAB
M.GRAB_ON    = GRAB_ON
M.GRAB_OFF   = GRAB_OFF
M.O_NONBLOCK = O_NONBLOCK
M.MAX_EVENTS_PER_DRAIN = MAX_EVENTS_PER_DRAIN

return M
