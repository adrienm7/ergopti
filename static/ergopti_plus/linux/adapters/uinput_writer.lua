--- adapters/uinput_writer.lua

--- ==============================================================================
--- MODULE: uinput Writer (Linux)
--- DESCRIPTION:
--- A non-forking channel for re-emitting evdev key events, backed by
--- /dev/uinput directly instead of one `ydotool key` subprocess per event.
---
--- WHY THIS EXISTS:
--- The daemon cannot take EVIOCGRAB until re-emitting an event is cheap. Under a
--- grab the daemon is the ONLY remaining path to the application, so every
--- physical key it consumes has to be put back — and `injector.emit_key` shells
--- out once per event. That is a fork per physical keystroke, on the input path.
---
--- Batching is NOT the fix, and the reason is worth stating because the batched
--- version looks obviously correct: `ydotool key` does accept several
--- `code:value` pairs per call, but `_pump_one` re-emits an event and THEN
--- dispatches it, so an injection triggered by event N would run before the
--- re-emit of N itself. That is exactly the interleaving the grab exists to
--- remove. The channel has to be non-forking, not batched.
---
--- FEATURES & RATIONALE:
--- 1. Pure encoder. `encode_event()` builds the 24-byte `struct input_event`
---    with hand-rolled little-endian packing rather than `string.pack`, which
---    LuaJIT (5.1) does not have. One code path on every interpreter beats a
---    version branch that only one side of CI ever executes.
--- 2. Swappable backend. All syscalls go through a small table (open / ioctl /
---    write / close). Production binds it to LuaJIT FFI; tests bind a recorder.
---    Without that seam the encoding could only be verified on hardware, and
---    "the keyboard still works" is not an assertion.
--- 3. Degrades honestly. With no FFI, no /dev/uinput, or no permission,
---    `is_available()` returns false and the caller keeps its existing path.
---    It never half-opens a device and reports success.
--- 4. Autorepeat is preserved. The ydotool wire format has no repeat value, so
---    that path collapses 2 into a fresh press. uinput carries 2 natively, and
---    re-emitting exactly what the kernel reported is the whole point of a
---    pass-through — so this channel does not collapse it. The difference
---    between the two channels is deliberate and pinned by tests.
---
--- PORTABILITY:
--- The ioctl request numbers below are the asm-generic encodings, correct on
--- x86_64 and arm64. Architectures with a different _IOC layout (mips, powerpc,
--- sparc, alpha) would need their own values; `is_available()` failing closed
--- means those simply keep the subprocess path rather than corrupting a device.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "adapters.uinput_writer"




-- ===========================================
-- ===========================================
-- ======= 1/ Kernel constants ===============
-- ===========================================
-- ===========================================

-- linux/input-event-codes.h
local EV_SYN     = 0x00
local EV_KEY     = 0x01
local SYN_REPORT = 0x00

-- linux/uinput.h ioctl requests, asm-generic _IOC encoding.
--   UI_SET_EVBIT   = _IOW('U', 100, int)                → 0x40045564
--   UI_SET_KEYBIT  = _IOW('U', 101, int)                → 0x40045565
--   UI_DEV_SETUP   = _IOW('U',   3, struct uinput_setup) → 0x405C5503 (92-byte struct)
--   UI_DEV_CREATE  = _IO ('U',   1)                     → 0x5501
--   UI_DEV_DESTROY = _IO ('U',   2)                     → 0x5502
local UI_SET_EVBIT   = 0x40045564
local UI_SET_KEYBIT  = 0x40045565
local UI_DEV_SETUP   = 0x405C5503
local UI_DEV_CREATE  = 0x5501
local UI_DEV_DESTROY = 0x5502

-- Highest keycode registered on the virtual device. KEY_MAX is 0x2FF, but the
-- daemon only ever re-emits keyboard keys, and registering the full range costs
-- 768 ioctls at startup for codes no keyboard reports.
local KEY_CODE_MAX = 255

-- struct input_event is 24 bytes on 64-bit: timeval (2 × 8) + type/code (2 × 2)
-- + value (4).
local INPUT_EVENT_SIZE = 24

-- Bus type and identifiers reported by the virtual device (linux/input.h).
-- BUS_VIRTUAL is what a software-synthesised keyboard should claim; a real bus
-- id would make the device indistinguishable from hardware in `libinput list`.
local BUS_VIRTUAL   = 0x06
-- Read, never redeclared: the remap daemon excludes this exact name and the
-- device finder classifies by it, so a second copy here is a silent way for the
-- three to disagree. See infra/device_names.lua for what that costs.
local DEVICE_NAME   = require("infra.device_names").VIRTUAL_KEYBOARD
local DEVICE_VENDOR = 0x0001
local DEVICE_PROD   = 0x0001
local DEVICE_VER    = 0x0001

local UINPUT_PATH = "/dev/uinput"




-- ===========================================
-- ===========================================
-- ======= 2/ Little-endian packing ==========
-- ===========================================
-- ===========================================

--- Packs an unsigned integer into `width` little-endian bytes.
---
--- Hand-rolled rather than string.pack: LuaJIT is Lua 5.1 and has no string.pack,
--- and a version branch here would mean the branch CI does not run is the one
--- that ships. Values are masked rather than validated because every caller
--- below passes a kernel constant or an evdev code, and a silent truncation is
--- visible in the byte-level tests.
--- @param value integer
--- @param width integer Number of bytes.
--- @return string
local function pack_uint_le(value, width)
	local bytes = {}
	local v = value
	for i = 1, width do
		bytes[i] = string.char(v % 256)
		v = math.floor(v / 256)
	end
	return table.concat(bytes)
end

--- Packs a signed 32-bit integer little-endian (two's complement).
--- @param value integer
--- @return string
local function pack_i32_le(value)
	if value < 0 then value = value + 0x100000000 end
	return pack_uint_le(value, 4)
end

--- Encodes one `struct input_event`.
---
--- The timestamp is zero by default: the kernel stamps events arriving from
--- uinput itself, so sending zeros is both correct and deterministic — which is
--- what makes the byte-level tests possible at all.
--- @param ev_type integer EV_KEY / EV_SYN.
--- @param code integer Event code.
--- @param value integer Event value (0 release, 1 press, 2 autorepeat).
--- @param sec integer|nil tv_sec, default 0.
--- @param usec integer|nil tv_usec, default 0.
--- @return string A 24-byte struct.
function M.encode_event(ev_type, code, value, sec, usec)
	return pack_uint_le(sec or 0, 8)
		.. pack_uint_le(usec or 0, 8)
		.. pack_uint_le(ev_type, 2)
		.. pack_uint_le(code, 2)
		.. pack_i32_le(value)
end

--- Encodes the `struct uinput_setup` handed to UI_DEV_SETUP.
--- Layout: struct input_id { u16 bustype, vendor, product, version } then
--- char name[80] then u32 ff_effects_max — 92 bytes.
--- @return string A 92-byte struct.
function M.encode_setup()
	local name = DEVICE_NAME
	if #name > 79 then name = name:sub(1, 79) end
	return pack_uint_le(BUS_VIRTUAL, 2)
		.. pack_uint_le(DEVICE_VENDOR, 2)
		.. pack_uint_le(DEVICE_PROD, 2)
		.. pack_uint_le(DEVICE_VER, 2)
		.. name
		.. string.rep("\0", 80 - #name)
		.. pack_uint_le(0, 4)
end




-- ===========================================
-- ===========================================
-- ======= 3/ Backend seam ===================
-- ===========================================
-- ===========================================

-- The syscall surface, as a table so tests can replace it wholesale. nil until
-- someone binds one: production calls M.use_ffi_backend(), the harness calls
-- M._set_backend(recorder).
local _backend = nil

-- Open device handle, or nil when closed. Kept separate from _backend so a
-- backend swap mid-session cannot leave a stale fd behind.
local _fd = nil

--- Replaces the syscall backend. Test seam.
---
--- A backend implements:
---   open(path)          → handle|nil, err
---   ioctl(handle, req, arg) → boolean          (arg: integer or string)
---   write(handle, bytes)    → boolean
---   close(handle)
--- @param backend table|nil
function M._set_backend(backend)
	_backend = backend
	_fd = nil
	Logger.debug(LOG, "Backend replaced: %s.", backend and "custom" or "none")
end

--- Drops the backend and any open handle. Test seam.
function M._reset_backend()
	if _fd and _backend and _backend.close then pcall(_backend.close, _fd) end
	_backend = nil
	_fd = nil
	Logger.debug(LOG, "Backend reset.")
end

--- Builds the LuaJIT FFI backend, or nil when FFI is unavailable.
---
--- Isolated in its own function so requiring this module never depends on the
--- interpreter: plain Lua 5.4 (what developers run) has no ffi, LuaJIT (what CI
--- and the daemon run) does, and neither should fail to LOAD the module.
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
		long write(int fd, const void *buf, unsigned long count);
	]])
	-- A second require of this module would redefine the same symbols; that
	-- raises rather than being a no-op, and it is not an error.
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		return nil, "ffi.cdef failed: " .. tostring(cdef_err)
	end

	local O_WRONLY   = 0x0001
	local O_NONBLOCK = 0x0800

	return {
		open = function(path)
			local fd = ffi.C.open(path, O_WRONLY + O_NONBLOCK)
			if fd < 0 then return nil, "open failed" end
			return fd
		end,
		ioctl = function(fd, request, arg)
			local rc
			if type(arg) == "string" then
				rc = ffi.C.ioctl(fd, request, ffi.cast("const char *", arg))
			else
				rc = ffi.C.ioctl(fd, request, ffi.cast("int", arg or 0))
			end
			return rc >= 0
		end,
		write = function(fd, bytes)
			local n = ffi.C.write(fd, bytes, #bytes)
			return tonumber(n) == #bytes
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
-- ======= 4/ Device lifecycle ===============
-- ===========================================
-- ===========================================

--- True when this channel can plausibly be opened: a backend exists and
--- /dev/uinput is present.
---
--- Deliberately does NOT open the device. Callers use this to choose a channel
--- during startup, and a probe with side effects would leave a half-created
--- virtual keyboard behind on every check.
--- @return boolean
function M.is_available()
	if not _backend and not M.use_ffi_backend() then return false end
	local fh = io.open(UINPUT_PATH, "r")
	if fh then
		fh:close()
		return true
	end
	-- Unreadable but present is normal: /dev/uinput is commonly write-only for
	-- the owning group, so a write probe is the honest test. It is deferred to
	-- open() rather than done here, because opening IS the side effect.
	local fh_w = io.open(UINPUT_PATH, "a")
	if fh_w then
		fh_w:close()
		return true
	end
	Logger.debug(LOG, "%s is not accessible — the caller keeps its existing channel.", UINPUT_PATH)
	return false
end

--- Creates the virtual keyboard device.
---
--- The ioctl order is fixed by the kernel: capabilities must be registered
--- BEFORE UI_DEV_CREATE, because the device's capability bits are frozen the
--- moment it is created. Registering a key afterwards succeeds and does nothing,
--- which is the kind of failure that only shows up as one key silently not
--- working.
--- @return boolean True when the device is ready to accept events.
function M.open()
	if _fd then
		Logger.debug(LOG, "open(): already open.")
		return true
	end
	if not _backend and not M.use_ffi_backend() then
		Logger.warn(LOG, "open(): no backend available.")
		return false
	end

	local fd, err = _backend.open(UINPUT_PATH)
	if not fd then
		Logger.warn(LOG, "open(): cannot open %s (%s).", UINPUT_PATH, tostring(err))
		return false
	end

	if not _backend.ioctl(fd, UI_SET_EVBIT, EV_KEY) then
		Logger.error(LOG, "open(): UI_SET_EVBIT(EV_KEY) failed.")
		_backend.close(fd)
		return false
	end
	for code = 1, KEY_CODE_MAX do
		if not _backend.ioctl(fd, UI_SET_KEYBIT, code) then
			Logger.error(LOG, "open(): UI_SET_KEYBIT(%d) failed.", code)
			_backend.close(fd)
			return false
		end
	end
	-- EV_SYN last among the capability bits, but still before UI_DEV_CREATE.
	if not _backend.ioctl(fd, UI_SET_EVBIT, EV_SYN) then
		Logger.error(LOG, "open(): UI_SET_EVBIT(EV_SYN) failed.")
		_backend.close(fd)
		return false
	end

	if not _backend.ioctl(fd, UI_DEV_SETUP, M.encode_setup()) then
		Logger.error(LOG, "open(): UI_DEV_SETUP failed.")
		_backend.close(fd)
		return false
	end
	if not _backend.ioctl(fd, UI_DEV_CREATE, 0) then
		Logger.error(LOG, "open(): UI_DEV_CREATE failed.")
		_backend.close(fd)
		return false
	end

	_fd = fd
	Logger.success(LOG, "Virtual keyboard created on %s.", UINPUT_PATH)
	return true
end

--- Destroys the virtual keyboard and closes the descriptor.
function M.close()
	if not _fd then return end
	Logger.start(LOG, "Destroying the virtual keyboard…")
	pcall(_backend.ioctl, _fd, UI_DEV_DESTROY, 0)
	pcall(_backend.close, _fd)
	_fd = nil
	Logger.success(LOG, "Virtual keyboard destroyed.")
end

--- @return boolean True when the device is open and emit() will work.
function M.is_open()
	return _fd ~= nil
end




-- ===========================================
-- ===========================================
-- ======= 5/ Emission =======================
-- ===========================================
-- ===========================================

--- Emits one key event, followed by the SYN_REPORT that makes it visible.
---
--- Without the SYN_REPORT the kernel buffers the event and the application sees
--- nothing — a failure that looks exactly like "the key did not work" while
--- every write returned success.
---
--- The autorepeat value (2) is passed through unchanged, unlike the ydotool
--- path, which has no wire representation for it and re-sends a press. Under a
--- grab this code is a pass-through, and a pass-through that rewrites what it
--- passes is not one.
--- @param code integer evdev keycode.
--- @param value integer 0 release, 1 press, 2 autorepeat.
--- @return boolean
function M.emit(code, value)
	if type(code) ~= "number" or type(value) ~= "number" then
		Logger.error(LOG, "emit(): invalid arguments — code=%s value=%s.",
			tostring(code), tostring(value))
		return false
	end
	if not _fd then
		Logger.error(LOG, "emit(): device is not open.")
		return false
	end

	if not _backend.write(_fd, M.encode_event(EV_KEY, code, value)) then
		Logger.warn(LOG, "emit(%d:%d): key write failed.", code, value)
		return false
	end
	if not _backend.write(_fd, M.encode_event(EV_SYN, SYN_REPORT, 0)) then
		Logger.warn(LOG, "emit(%d:%d): SYN_REPORT write failed — the key stays buffered.", code, value)
		return false
	end
	return true
end

-- Exposed for the tests that pin the wire format and the ioctl order.
M.EV_SYN     = EV_SYN
M.EV_KEY     = EV_KEY
M.SYN_REPORT = SYN_REPORT
M.INPUT_EVENT_SIZE = INPUT_EVENT_SIZE
M.KEY_CODE_MAX = KEY_CODE_MAX
M.UI_SET_EVBIT   = UI_SET_EVBIT
M.UI_SET_KEYBIT  = UI_SET_KEYBIT
M.UI_DEV_SETUP   = UI_DEV_SETUP
M.UI_DEV_CREATE  = UI_DEV_CREATE
M.UI_DEV_DESTROY = UI_DEV_DESTROY
M.UINPUT_PATH = UINPUT_PATH

return M
