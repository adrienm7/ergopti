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
local original_output_observer_factory, original_capture_output = nil, nil
local kernel_backends = setmetatable({}, { __mode = "k" })
local kernel_declared = setmetatable({}, { __mode = "k" })
local original_kernel_capture, original_kernel_ports = nil, nil
local kernel_sources = setmetatable({}, { __mode = "k" })

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

-- Highest keycode registered on the virtual device: the kernel's KEY_MAX
-- (0x2FF) from linux/input-event-codes.h, the same bound the keyboard hook
-- forwards. Registering fewer bits saves a few hundred one-time ioctls and
-- costs every higher key: UI_DEV_CREATE freezes the capability bits, so a
-- grabbed high key is swallowed and then "re-emitted" to a device that
-- cannot emit it — the write succeeds while the application sees nothing.
local KEY_CODE_MAX = 0x2FF

-- File descriptors are non-negative signed native int values.
local MAX_DESCRIPTOR = 0x7FFFFFFF

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

-- errno for "present but this user may not read it". A write-only group grant on
-- /dev/uinput answers exactly this to a read probe.
local EACCES = 13

-- The node every probe and open() targets. Only the tests move it: probing the
-- real node from a root test run is how a stray regular file came to sit there.
local _uinput_path = UINPUT_PATH

-- open(2) flags, asm-generic values (x86_64 and arm64): write-only, non-blocking
-- and close-on-exec. The device lives as long as the last descriptor on its
-- file, so a child that inherited one (`xdg-open … &`, the update relay) would
-- keep it alive after the daemon died, with any key it had forwarded still held
-- down: the kernel releases held keys only when the device is destroyed.
local O_WRONLY   = 0x0001
local O_NONBLOCK = 0x0800
local O_CLOEXEC  = 0x80000
local OPEN_FLAGS = O_WRONLY + O_NONBLOCK + O_CLOEXEC




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

-- A constructor or wire operation owns the channel before calling any provider.
-- The capability never exposes a descriptor: a recycled numeric fd is not an owner.
local _busy = false
local _output = nil
local _transaction = nil
local _dispatch = nil
local _debt = false
local _constructor_debt = nil
local _generation = 0
local _strict_constructor = false
local _constructor_ports = nil
local _legacy_wire = false
local encode_event = M.encode_event
local encode_setup = M.encode_setup

--- Checks only private observed currency; this is not a kernel state lease.
--- @param output table Issued private record.
--- @return boolean current
local function output_identity(output)
	return output ~= nil and rawequal(output, _output) and not output.retired
		and rawequal(output.backend, _backend) and output.fd == _fd
		and rawequal(output.write, rawget(output.backend, "write"))
		and rawequal(output.ioctl, rawget(output.backend, "ioctl"))
		and rawequal(output.close, rawget(output.backend, "close"))
end

--- Checks exact capability identity without invoking a replaceable export.
--- @param capability table Opaque capability.
--- @return boolean current
local function output_current(capability)
	return not _busy and not _debt and _transaction == nil and output_identity(_output)
		and rawequal(capability, _output.capability)
end

--- Writes a complete KEY/SYN attempt through one captured native owner.
--- @param capability table Opaque capability.
--- @param code integer evdev keycode.
--- @param value integer Native up/down/repeat value.
--- @return boolean acknowledged
local function emit_owned(capability, code, value, transaction)
	local output = _output
	if _busy or _debt or not output_identity(output)
		or not rawequal(capability, output.capability)
		or (_transaction ~= nil and not rawequal(transaction, _transaction)) then return false end
	if type(code) ~= "number" or code ~= math.floor(code) or code < 1 or code > KEY_CODE_MAX
		or (value ~= 0 and value ~= 1 and value ~= 2) then return false end
	_busy = true
	output.write_epoch = output.write_epoch + 1
	local called, acknowledged = pcall(function()
		if output.write(output.fd, encode_event(EV_KEY, code, value)) ~= true then return false end
		if not output_identity(output) then return false end
		if output.write(output.fd, encode_event(EV_SYN, SYN_REPORT, 0)) ~= true then return false end
		return output_identity(output)
	end)
	if not called or acknowledged ~= true then
		_debt = true
		output.write_debt = true
		pcall(Logger.error, LOG, "An owned native KEY/SYN attempt was not acknowledged.")
	end
	if called and acknowledged == true then
		if value == 1 then output.down[code] = true
		elseif value == 0 then output.down[code] = nil
		elseif output.down[code] ~= true then output.roster_known = false end
		if transaction ~= nil then transaction.write_epoch = output.write_epoch end
	end
	_busy = false
	return called and acknowledged == true
end

--- Retires only the captured native descriptor, never a successor's descriptor.
--- @param capability table Opaque capability.
--- @return boolean retired
local function close_owned(capability, transaction)
	local output = _output
	if _busy or not output_identity(output) or output.close_attempted
		or not rawequal(capability, output.capability)
		or (_transaction ~= nil and not rawequal(transaction, _transaction)) then return false end
	_busy = true
	output.close_attempted = true
	pcall(Logger.start, LOG, "Retiring the exact owned virtual keyboard…")
	local destroyed, destroy_ack = pcall(output.ioctl, output.fd, UI_DEV_DESTROY, 0)
	local closed, close_ack = pcall(output.close, output.fd)
	local same = output_identity(output)
	if closed and close_ack == true and same then
		_fd = nil
		output.retired = true
	end
	local acknowledged = destroyed and destroy_ack == true and closed and close_ack == true and same
	if acknowledged then
		output.retirement_ack = true
		_output = nil
		if _transaction ~= nil then _transaction.retired = true end
		_transaction = nil
		_debt = false
		_strict_constructor = false
		_legacy_wire = false
	else
		-- A failed close may already have recycled its fd. It must never be retried.
		_debt = true
	end
	pcall(acknowledged and Logger.success or Logger.error, LOG,
		acknowledged and "Owned virtual keyboard retired." or "Native retirement remains unacknowledged; the descriptor will not be retried.")
	_busy = false
	return acknowledged
end

--- Replaces the syscall backend. Test seam.
---
--- A backend implements:
---   open(path, flags)       → handle|nil, err
---   ioctl(handle, req, arg) → boolean          (arg: integer or string)
---   write(handle, bytes)    → boolean
---   close(handle)
--- @param backend table|nil
function M._set_backend(backend)
	if backend ~= nil and type(backend) ~= "table" then return false end
	if _busy or _output ~= nil or _debt or _fd ~= nil then return false end
	_backend = backend
	_fd = nil
	Logger.debug(LOG, "Backend replaced: %s.", backend and "custom" or "none")
end

--- Drops the backend and any open handle. Test seam.
function M._reset_backend()
	if _busy or _debt then return false end
	if _output ~= nil and not close_owned(_output.capability) then return false end
	_busy = true
	if _fd and _backend and _backend.close then pcall(_backend.close, _fd) end
	_backend = nil
	_fd = nil
	_strict_constructor = false
	_legacy_wire = false
	pcall(Logger.debug, LOG, "Backend reset.")
	_busy = false
end

--- Builds the LuaJIT FFI backend, or nil when FFI is unavailable.
---
--- Isolated in its own function so requiring this module never depends on the
--- interpreter: plain Lua 5.4 (what developers run) has no ffi, LuaJIT (what CI
--- and the daemon run) does, and neither should fail to LOAD the module.
--- @return table|nil backend, string|nil err
--- Internal implementation fragment for adapters/uinput_writer.lua.
--- SOURCE DRAFT: not installed, imported, compiled or exercised.
--- The factory is called only inside build_ffi_backend, before native open.
--- Its owner_current argument is the Writer's private original-fd/generation join.
--- It observes metadata only: no input read, grab, event injection or output grant.

local function build_kernel_node_ports(ffi)
	if not ffi.abi("64bit") or (ffi.arch ~= "x64" and ffi.arch ~= "arm64") then return nil end
	if not kernel_declared[ffi] then
	ffi.cdef([[
		typedef struct { int64_t tv_sec; uint32_t tv_nsec; int32_t reserved; } ErgoptiStatxTime107;
		typedef struct {
			uint32_t mask, blksize; uint64_t attributes;
			uint32_t nlink, uid, gid; uint16_t mode, spare0;
			uint64_t ino, size, blocks, attributes_mask;
			ErgoptiStatxTime107 atime, btime, ctime, mtime;
			uint32_t rdev_major, rdev_minor, dev_major, dev_minor;
			uint64_t mnt_id; uint32_t dio_mem_align, dio_offset_align;
			uint64_t subvol; uint32_t atomic_write_unit_min, atomic_write_unit_max;
			uint32_t atomic_write_segments_max, spare1; uint64_t spare3[9];
		} ErgoptiStatx107;
		int statx(int dirfd, const char *pathname, int flags, unsigned int mask, ErgoptiStatx107 *buf);
		int openat(int dirfd, const char *pathname, int flags, ...);
		long pread(int fd, void *buf, unsigned long count, long offset);
	]])
	kernel_declared[ffi] = true
	end
	if ffi.sizeof("ErgoptiStatx107") ~= 256 or ffi.offsetof("ErgoptiStatx107", "mode") ~= 28
		or ffi.offsetof("ErgoptiStatx107", "ino") ~= 32
		or ffi.offsetof("ErgoptiStatx107", "rdev_major") ~= 128
		or ffi.offsetof("ErgoptiStatx107", "rdev_minor") ~= 132 then return nil end
	-- These are additional optional ports; existing ordinary Writer ports stay intact.
	local ports = { openat = ffi.C.openat, statx = ffi.C.statx, pread = ffi.C.pread,
		close = ffi.C.close, ioctl = ffi.C.ioctl, new = ffi.new, string = ffi.string, errno = ffi.errno }
	local function ports_current()
		return ffi.C.openat == ports.openat and ffi.C.statx == ports.statx and ffi.C.pread == ports.pread
			and ffi.C.close == ports.close and ffi.C.ioctl == ports.ioctl
			and ffi.new == ports.new and ffi.string == ports.string and ffi.errno == ports.errno
	end
	local O_PATH, O_NOFOLLOW, O_CLOEXEC, O_DIRECTORY = 2097152, 131072, 524288, 65536
	local DIR_FLAGS = O_PATH + O_NOFOLLOW + O_CLOEXEC + O_DIRECTORY
	local AT_FDCWD, NOFOLLOW, EMPTY_PATH = -100, 256, 4096
	local TYPE_MASK, INO_MASK = 1, 256
	local UI_GET_SYSNAME_64 = 0x8040552c -- _IOC(_IOC_READ, 'U', 44, 64), asm-generic.
	local metadata_debt, busy = false, false
	local function current(owner_current)
		local ok, value = pcall(function()
			if owner_current() ~= true then return false end
			local matched = ports_current()
			return matched and owner_current() == true
		end)
		return ok and value == true and not metadata_debt
	end
	local function stat(dirfd, name, flags)
		local buffer = ports.new("ErgoptiStatx107[1]")
		if ports.statx(dirfd, name, flags, TYPE_MASK + INO_MASK, buffer) ~= 0 then return nil end
		local value = buffer[0]
		local mask = tonumber(value.mask)
		if mask % 2 ~= 1 or math.floor(mask / INO_MASK) % 2 ~= 1 then return nil end
		return { ino = ports.new("uint64_t", value.ino), dev_major = tonumber(value.dev_major),
			dev_minor = tonumber(value.dev_minor), kind = math.floor(tonumber(value.mode) / 4096) * 4096,
			rdev_major = tonumber(value.rdev_major), rdev_minor = tonumber(value.rdev_minor) }
	end
	local function same(a, b)
		return a and b and a.ino == b.ino and a.dev_major == b.dev_major and a.dev_minor == b.dev_minor
			and a.kind == b.kind and a.rdev_major == b.rdev_major and a.rdev_minor == b.rdev_minor
	end
	local function sysname(fd)
		local buffer = ports.new("unsigned char[64]")
		local count = tonumber(ports.ioctl(fd, UI_GET_SYSNAME_64, buffer))
		-- Kernel length includes NUL; count == capacity is ambiguous truncation.
		if not count or count % 1 ~= 0 or count <= 1 or count >= 64 then return nil end
		local bytes = ports.string(buffer, count)
		if bytes:sub(-1) ~= "\0" then return nil end
		local name = bytes:sub(1, -2)
		if name:find("\0", 1, true) or not name:match("^input[0-9]+$") then return nil end
		return name
	end
	local function close_once(entry)
		if entry.close_attempted then return false end
		entry.close_attempted = true
		local ok, result = pcall(ports.close, entry.fd)
		if not ok or result ~= 0 then metadata_debt = true; return false end
		entry.closed = true
		return true
	end
	local function retire_record(record)
		if record.retired then return record.closed == true end
		record.retired = true
		local closed = true
		for index = #record.entries, 1, -1 do
			if not close_once(record.entries[index]) then closed = false end
		end
		record.closed = closed
		return closed
	end
	local function decimal(value)
		return value == "0" or value:match("^[1-9][0-9]*$") ~= nil
	end
	local function device_numbers(fd)
		local buffer = ports.new("unsigned char[65]")
		local count = tonumber(ports.pread(fd, buffer, 65, 0))
		if not count or count % 1 ~= 0 or count <= 0 or count > 64 then return nil end
		local bytes = ports.string(buffer, count)
		local a, b = bytes:match("^([0-9]+):([0-9]+)\n$")
		if not a or not decimal(a) or not decimal(b) then return nil end
		local major, minor = tonumber(a), tonumber(b)
		if not major or not minor or major > 4294967295 or minor > 4294967295 then return nil end
		-- Refuse a prefix-only read; the held regular metadata fd must reach EOF.
		if ports.pread(fd, buffer, 1, count) ~= 0 then return nil end
		return major, minor
	end
	local function named_current(record)
		for _, entry in ipairs(record.entries) do
			if entry.closed or entry.close_attempted or not same(entry.identity, stat(entry.fd, "", EMPTY_PATH))
				or not same(entry.identity, stat(entry.parent, entry.name, NOFOLLOW)) then return false end
		end
		return true
	end
	local function acquire(fd, owner_current, path)
		if busy or metadata_debt or type(path) ~= "string" or #path > 1024
			or not path:match("^/dev/input/event[0-9]+$") or not current(owner_current) then return nil, "kernel-node-unavailable" end
		busy = true
		local record = { entries = {}, owner_current = owner_current, fd = fd, path = path }
		local disposition = "refused"
		local function open_entry(parent, name, flags, kind)
			if not current(owner_current) then return nil end
			local opened, value = pcall(ports.openat, parent, name, flags)
			if not opened then metadata_debt = true; return nil end
			local error_number = value ~= nil and tonumber(value) < 0 and ports.errno() or nil
			value = tonumber(value)
			if value and value < 0 then return nil, error_number == 2 and "missing" or "refused" end
			if not value or value % 1 ~= 0 or value < 0 or value > 2147483647 then return nil end
			local entry = { fd = value, parent = parent, name = name }
			record.entries[#record.entries + 1] = entry -- Retain before any observer.
			entry.identity = stat(value, "", EMPTY_PATH)
			if not entry.identity or entry.identity.kind ~= kind
				or not same(entry.identity, stat(parent, name, NOFOLLOW)) or not current(owner_current) then return nil end
			return entry
		end
		local ok, accepted = pcall(function()
			record.sysname = sysname(fd)
			if not record.sysname or not current(owner_current) then return false end
			local root = open_entry(AT_FDCWD, "/", DIR_FLAGS, 0x4000)
			if not root then return false end
			local dev = open_entry(root.fd, "dev", DIR_FLAGS, 0x4000)
			local input = dev and open_entry(dev.fd, "input", DIR_FLAGS, 0x4000)
			local event = path:match("(event[0-9]+)$")
			record.node = input and open_entry(input.fd, event, O_PATH + O_NOFOLLOW + O_CLOEXEC, 0x2000)
			if not record.node then return false end
			local sys = open_entry(root.fd, "sys", DIR_FLAGS, 0x4000)
			local devices = sys and open_entry(sys.fd, "devices", DIR_FLAGS, 0x4000)
			local virtual = devices and open_entry(devices.fd, "virtual", DIR_FLAGS, 0x4000)
			local inputs = virtual and open_entry(virtual.fd, "input", DIR_FLAGS, 0x4000)
			local owned = inputs and open_entry(inputs.fd, record.sysname, DIR_FLAGS, 0x4000)
			if not owned then return false end
			local child, refusal = open_entry(owned.fd, event, DIR_FLAGS, 0x4000)
			if not child then
				-- Missing only this event child under the held original Writer inputN
				-- can prove a foreign node. Permission/stat/read errors never do.
				if refusal == "missing" and named_current(record) and sysname(fd) == record.sysname and current(owner_current) then
					disposition = "nonmatch"
				end
				return false
			end
			record.dev = child and open_entry(child.fd, "dev", O_NOFOLLOW + O_CLOEXEC, 0x8000)
			if not record.dev then return false end
			local major, minor = device_numbers(record.dev.fd)
			if not major or not minor then return false end
			if major ~= record.node.identity.rdev_major or minor ~= record.node.identity.rdev_minor then
				if named_current(record) and sysname(fd) == record.sysname and current(owner_current) then disposition = "nonmatch" end
				return false
			end
			return named_current(record) and sysname(fd) == record.sysname and current(owner_current)
		end)
		if not ok or accepted ~= true then
			local closed = retire_record(record)
			busy = false
			return nil, ok and closed and not metadata_debt and disposition or "refused"
		end
		busy = false
		return record, "matched"
	end
	local function observe(record)
		if busy or not record or record.retired or metadata_debt then return false end
		busy = true
		local ok, value = pcall(function()
			if not current(record.owner_current) or sysname(record.fd) ~= record.sysname or not named_current(record) then return false end
			local major, minor = device_numbers(record.dev.fd)
			return major == record.node.identity.rdev_major and minor == record.node.identity.rdev_minor
				and named_current(record) and sysname(record.fd) == record.sysname and current(record.owner_current)
		end)
		busy = false
		return ok and value == true and not record.retired
	end
	local function retire(record)
		if busy or not record then return false end
		busy = true
		local closed = retire_record(record)
		busy = false
		return closed
	end
	-- Private metadata ports: caller retains records; none is an output capability.
	return { acquire = acquire, current = observe, retire = retire, ports_current = ports_current, closed = function() return not metadata_debt end }
end

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

	-- Resolve while the constructor/binder is reserved; public ffi table mutation
	-- cannot substitute a syscall after the native channel is acknowledged.
	local native_open, native_close = ffi.C.open, ffi.C.close
	local native_ioctl, native_write, cast = ffi.C.ioctl, ffi.C.write, ffi.cast
	local backend = {
		open = function(path, flags)
			local fd = native_open(path, flags)
			if fd < 0 then return nil, "open failed" end
			return fd
		end,
		ioctl = function(fd, request, arg)
			local rc
			if type(arg) == "string" then
				rc = native_ioctl(fd, request, cast("const char *", arg))
			else
				rc = native_ioctl(fd, request, cast("int", arg or 0))
			end
			return rc >= 0
		end,
		write = function(fd, bytes)
			local n = native_write(fd, bytes, #bytes)
			return tonumber(n) == #bytes
		end,
		close = function(fd)
			return native_close(fd) == 0
		end,
	}
	local admitted, metadata = pcall(build_kernel_node_ports, ffi)
	if admitted and metadata then kernel_backends[backend] = metadata end
	return backend
end

--- Binds the production FFI backend.
--- @return boolean True when a backend is available.
function M.use_ffi_backend()
	if _busy or _output ~= nil or _debt or _fd ~= nil then return false end
	_busy = true
	local called, backend = pcall(build_ffi_backend)
	if not called or backend == nil then
		_busy = false
		return false
	end
	_backend = backend
	pcall(Logger.debug, LOG, "FFI backend bound.")
	_busy = false
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
	local fh, _, errno = io.open(_uinput_path, "r")
	if fh then
		fh:close()
		return true
	end
	-- Unreadable but present is normal: /dev/uinput is commonly write-only for
	-- the owning group, so the honest write test is deferred to open(), where
	-- opening IS the side effect. It is never probed with a write-mode io.open:
	-- "a" CREATES a missing path, so a root process on a kernel whose uinput
	-- module is not loaded left a regular file at /dev/uinput. That file then
	-- answered every later probe as "available" and shadowed the real node the
	-- module creates on load, so injection stayed broken until a reboot.
	if errno == EACCES then return true end
	Logger.debug(LOG, "%s is not accessible — the caller keeps its existing channel.", _uinput_path)
	return false
end

--- Test seam: points every probe and open() at another node.
--- @param path string|nil nil restores /dev/uinput.
function M._set_path_for_test(path)
	if _busy or _output ~= nil or _debt then return false end
	_uinput_path = path or UINPUT_PATH
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
	if _busy or _debt then return false end
	if _fd then return true end
	-- Reserve before lazy FFI loading: even require/cdef can reenter the writer.
	_busy = true
	local backend, descriptor = _backend, nil
	local open_port, ioctl_port, write_port, close_port
	local strict = true
	pcall(Logger.start, LOG, "Creating the native virtual keyboard…")
	local called, created = pcall(function()
		if backend == nil then
			backend = build_ffi_backend()
			if backend == nil then return false end
			_backend = backend
		end
		open_port, ioctl_port, write_port, close_port = rawget(backend, "open"), rawget(backend, "ioctl"), rawget(backend, "write"), rawget(backend, "close")
		local function unchanged()
			return rawequal(backend, _backend) and rawequal(open_port, rawget(backend, "open"))
				and rawequal(ioctl_port, rawget(backend, "ioctl")) and rawequal(write_port, rawget(backend, "write"))
				and rawequal(close_port, rawget(backend, "close"))
		end
		descriptor = open_port(_uinput_path, OPEN_FLAGS)
		if not unchanged() then return false end
		if descriptor == nil or descriptor == false then return false end
		local function admit(request, argument)
			local result = ioctl_port(descriptor, request, argument)
			if not unchanged() then return false end
			if result ~= true then strict = false end
			return result
		end
		if not admit(UI_SET_EVBIT, EV_KEY) then return false end
		for code = 1, KEY_CODE_MAX do
			if not admit(UI_SET_KEYBIT, code) then return false end
		end
		if not admit(UI_SET_EVBIT, EV_SYN) then return false end
		if not admit(UI_DEV_SETUP, encode_setup()) then return false end
		if not admit(UI_DEV_CREATE, 0) then return false end
		return true
	end)
	if not called or created ~= true then
		if descriptor ~= nil and descriptor ~= false and backend ~= nil then
			local closed, ack = pcall(close_port, descriptor)
			if not closed or ack ~= true then
				_debt = true
				_constructor_debt = { backend = backend, fd = descriptor, close = close_port }
			end
		end
		pcall(Logger.error, LOG, "Native virtual keyboard creation was not acknowledged.")
		_busy = false
		return false
	end
	_fd = descriptor
	_generation = _generation + 1
	_constructor_ports = { open = open_port, ioctl = ioctl_port, write = write_port, close = close_port }
	_strict_constructor = strict and type(descriptor) == "number"
		and descriptor == math.floor(descriptor) and descriptor >= 0 and descriptor <= MAX_DESCRIPTOR
	_legacy_wire = false
	pcall(Logger.success, LOG, "Virtual keyboard created on %s.", _uinput_path)
	_busy = false
	return true
end

--- Destroys the virtual keyboard and closes the descriptor.
function M.close()
	if _busy or _debt then return false end
	if _output ~= nil then return close_owned(_output.capability) end
	if not _fd then return end
	_busy = true
	pcall(Logger.start, LOG, "Destroying the virtual keyboard…")
	pcall(_backend.ioctl, _fd, UI_DEV_DESTROY, 0)
	pcall(_backend.close, _fd)
	_fd = nil
	_strict_constructor = false
	_legacy_wire = false
	pcall(Logger.success, LOG, "Virtual keyboard destroyed.")
	_busy = false
end

--- @return boolean True when the device is open and emit() will work.
function M.is_open()
	return _fd ~= nil
end

--- Positively observes an idle unavailable channel before any caller acquires it.
--- A failed constructor can retain native debt while is_open() is false.
--- @return boolean unavailable
--- @return integer generation Last successfully created native generation.
function M.unavailable_for_output()
	return _fd == nil and not _busy and not _debt and _constructor_debt == nil
		and _output == nil and _transaction == nil and _dispatch == nil, _generation
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
	if _dispatch then
		local request = _dispatch
		if request.used or request.code ~= code or request.value ~= value then return false end
		request.used = true
		request.ack = M.transaction_emit(request.token, code, value)
		return request.ack
	end
	if _busy or _debt or _transaction ~= nil then return false end
	if _output ~= nil then return emit_owned(_output.capability, code, value) end
	if type(code) ~= "number" or type(value) ~= "number" then
		Logger.error(LOG, "emit(): invalid arguments — code=%s value=%s.",
			tostring(code), tostring(value))
		return false
	end
	if not _fd then
		Logger.error(LOG, "emit(): device is not open.")
		return false
	end

	_legacy_wire = true
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

--- Captures a fresh, strictly acknowledged channel before any untracked wire attempt.
--- @return table|nil capability Opaque; carries no descriptor/backend.
--- @return function|nil factory Original private observer issuer; grants no new rights.
function M.capture_output()
	if _busy or _debt or _transaction ~= nil or _fd == nil or not _strict_constructor or _legacy_wire then return nil end
	if _output ~= nil then
		if output_identity(_output) then return _output.capability, original_output_observer_factory end
		return nil
	end
	if _constructor_ports == nil or not rawequal(_constructor_ports.open, rawget(_backend, "open"))
		or not rawequal(_constructor_ports.ioctl, rawget(_backend, "ioctl"))
		or not rawequal(_constructor_ports.write, rawget(_backend, "write"))
		or not rawequal(_constructor_ports.close, rawget(_backend, "close")) then return nil end
	if type(rawget(_backend, "write")) ~= "function" or type(rawget(_backend, "ioctl")) ~= "function"
		or type(rawget(_backend, "close")) ~= "function" then return nil end
	local capability = {}
	_output = { capability = capability, backend = _backend, fd = _fd,
		write = rawget(_backend, "write"), ioctl = rawget(_backend, "ioctl"), close = rawget(_backend, "close"),
		generation = _generation, write_epoch = 0, down = {}, roster_known = true }
	return capability, original_output_observer_factory
end

--- Pure observation of one exact issued capability; never reads native state.
--- @param capability table Opaque capability.
--- @return boolean current
function M.output_current(capability)
	return output_current(capability)
end

--- Returns detached transport currency, never fd or backend authority.
--- @param capability table Opaque capability.
--- @return table|nil view
function M.output_view(capability)
	if not output_current(capability) then return nil end
	local down = {}
	for code in pairs(_output.down) do down[#down + 1] = code end
	table.sort(down)
	return { generation = _output.generation, write_epoch = _output.write_epoch,
		down = down, roster_known = _output.roster_known }
end

--- Captures a pure observer of this exact private output issuer.
--- It accepts only the original capability and compares the caller's expected
--- cursor/roster against private acknowledged state; public views grant no rights.
--- @param capability table Original opaque output capability.
--- @param capture_getter function|nil Original constructor getter when wiring input proof.
--- @return function|nil observer No syscall, reservation, mutation or new authority.
--- @return function|nil retired Exact original destroy/close acknowledgement only.
function M.capture_output_observer(capability, capture_getter)
	if capture_getter ~= nil and capture_getter ~= original_capture_output then return nil end
	if not output_current(capability) then return nil end
	local output = _output
	if not output.observer then
		local factory, view = M.capture_output_observer, M.output_view
		output.observer = function(original, cursor, expected)
			if not rawequal(original, output.capability) or not output_current(original)
				or not rawequal(_output, output) or rawget(M, "capture_output_observer") ~= factory
				or rawget(M, "output_view") ~= view or output.roster_known ~= true or cursor ~= output.write_epoch
				or type(expected) ~= "table" or getmetatable(expected) ~= nil then return false end
			local seen, count = {}, 0
			for index, code in pairs(expected) do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #expected
					or type(code) ~= "number" or seen[code] or output.down[code] ~= true then return false end
				seen[code], count = true, count + 1
			end
			if count ~= #expected then return false end
			for code in pairs(output.down) do if seen[code] ~= true then return false end end
			return true
		end
	end
	if not output.retirement_observer then
		-- This closure survives successor construction. It refers only to this
		-- private original lifetime, never public views or the mutable current slot.
		output.retirement_observer = function(original)
			return rawequal(original, output.capability) and output.retirement_ack == true
		end
	end
	return output.observer, output.retirement_observer
end

--- Emits one exact native key and its SYN through the captured channel.
--- @param capability table Opaque capability.
--- @param code integer evdev keycode.
--- @param value integer Native up/down/repeat value.
--- @return boolean acknowledged
function M.emit_owned(capability, code, value)
	return emit_owned(capability, code, value)
end

--- Requires exact destroy/close acknowledgements; unknown close is never retried.
--- @param capability table Opaque capability.
--- @return boolean retired
function M.close_owned(capability)
	return close_owned(capability)
end

--- Reports unresolved write/constructor/retirement custody.
--- @return boolean pending
function M.has_output_debt()
	return _debt == true or (_output ~= nil and not output_identity(_output))
end

--- Checks private transport reservation; does not assert physical/native input state.
--- @param token table Opaque transaction capability.
--- @return boolean current
local function transaction_current(token)
	local transaction = _transaction
	return not _busy and not _debt and transaction ~= nil and not transaction.retired
		and rawequal(token, transaction.capability) and output_identity(transaction.output)
		and transaction.output.roster_known == true
		and transaction.write_epoch == transaction.output.write_epoch
end

--- Checks exact acknowledged roster equality without external callbacks.
--- @param transaction table Private transaction record.
--- @return boolean restored
local function transaction_restored(transaction)
	for code in pairs(transaction.baseline) do
		if transaction.output.down[code] ~= true then return false end
	end
	for code in pairs(transaction.output.down) do
		if transaction.baseline[code] ~= true then return false end
	end
	return true
end

--- Reserves the exact acknowledged output roster against other channel callers.
--- No physical origin or global desktop modifier state is inferred from this roster.
--- @param capability table Issued output capability.
--- @return table|nil token Opaque transaction capability.
function M.acquire_transaction(capability)
	if not output_current(capability) or _output.roster_known ~= true then return nil end
	local baseline = {}
	for code in pairs(_output.down) do baseline[code] = true end
	local token = {}
	_transaction = { capability = token, output = _output, baseline = baseline,
		write_epoch = _output.write_epoch, retired = false }
	return token
end

--- Pure observation of the exact transport reservation.
--- @param token table Opaque transaction capability.
--- @return boolean current
function M.transaction_current(token)
	return transaction_current(token)
end

--- Returns detached acknowledged rows, never native descriptors or authority.
--- @param token table Opaque transaction capability.
--- @return table|nil view
function M.transaction_view(token)
	if not transaction_current(token) then return nil end
	local down, baseline = {}, {}
	for code in pairs(_transaction.output.down) do down[#down + 1] = code end
	for code in pairs(_transaction.baseline) do baseline[#baseline + 1] = code end
	table.sort(down)
	table.sort(baseline)
	return { generation = _transaction.output.generation, write_epoch = _transaction.write_epoch,
		down = down, baseline = baseline, restored = transaction_restored(_transaction) }
end

--- Emits only a transition consistent with the acknowledged transaction roster.
--- Duplicate downs, unmatched ups and unmatched repeats are refused before native IO.
--- @param token table Opaque transaction capability.
--- @param code integer Native evdev keycode.
--- @param value integer Native up/down/repeat value.
--- @return boolean acknowledged
function M.transaction_emit(token, code, value)
	if not transaction_current(token) then return false end
	local down = _transaction.output.down[code] == true
	if (value == 1 and down) or ((value == 0 or value == 2) and not down) then return false end
	return emit_owned(_transaction.output.capability, code, value, _transaction)
end

--- Invokes the forwarding adapter with exactly one reserved native attempt.
--- Reentry cannot issue another write through the ordinary channel.
--- @param token table Exact reservation.
--- @param callback function Forwarding adapter.
--- @param code integer Keycode.
--- @param value integer Transition.
--- @return boolean acknowledged
function M.dispatch_transaction(token, callback, code, value)
	if _dispatch or not transaction_current(token) or type(callback) ~= "function" then return false end
	local request = { token = token, code = code, value = value, used = false, ack = false }
	_dispatch = request
	local ok, accepted = pcall(callback, code, value)
	_dispatch = nil
	return ok and accepted == true and request.used and request.ack and transaction_current(token)
end

--- Commits an exact acknowledged persistent roster without weakening restoration.
--- @param token table Exact reservation.
--- @param expected table Sorted unique keycodes owned by the broker.
--- @return boolean committed
function M.commit_transaction(token, expected)
	if _dispatch or not transaction_current(token) or type(expected) ~= "table" or getmetatable(expected) ~= nil then return false end
	local count = 0
	for index in pairs(expected) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #expected then return false end
		count = count + 1
	end
	if count ~= #expected then return false end
	local seen = {}
	for index, code in ipairs(expected) do
		if type(code) ~= "number" or seen[code] or _transaction.output.down[code] ~= true then return false end
		if index > 1 and expected[index - 1] >= code then return false end
		seen[code] = true
	end
	for code in pairs(_transaction.output.down) do if not seen[code] then return false end end
	_transaction.retired = true
	_transaction = nil
	return true
end

--- Compensates only changes in this reservation's acknowledged roster.
--- Failed native acknowledgement retains the reservation/debt; no borrowed list is read.
--- @param token table Opaque transaction capability.
--- @return boolean restored
function M.restore_transaction(token)
	if not transaction_current(token) then return false end
	local transaction, release, restore = _transaction, {}, {}
	for code in pairs(transaction.output.down) do
		if transaction.baseline[code] ~= true then release[#release + 1] = code end
	end
	for code in pairs(transaction.baseline) do
		if transaction.output.down[code] ~= true then restore[#restore + 1] = code end
	end
	table.sort(release)
	table.sort(restore)
	for _, code in ipairs(release) do
		if not emit_owned(transaction.output.capability, code, 0, transaction) then return false end
	end
	for _, code in ipairs(restore) do
		if not emit_owned(transaction.output.capability, code, 1, transaction) then return false end
	end
	return transaction_current(token) and transaction_restored(transaction)
end

--- Opens delivery only after exact private roster restoration, without callbacks.
--- @param token table Opaque transaction capability.
--- @return boolean released
function M.release_transaction(token)
	if not transaction_current(token) or not transaction_restored(_transaction) then return false end
	_transaction.retired = true
	_transaction = nil
	return true
end

--- Retires this reservation's exact native channel after unresolved wire debt.
--- Ambiguous native close remains non-retryable; no successor descriptor is touched.
--- @param token table Opaque transaction capability.
--- @return boolean retired
function M.retire_transaction(token)
	local transaction = _transaction
	if transaction == nil or not rawequal(token, transaction.capability) or transaction.retired then return false end
	return close_owned(transaction.output.capability, transaction)
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

original_output_observer_factory, original_capture_output = M.capture_output_observer, M.capture_output


--- Private native observation issuer, bound to the original open Writer.
--- A scripted transport/backend or detached output view cannot construct it.
function M.capture_kernel_source()
	if M.capture_kernel_source ~= original_kernel_capture or M.capture_output ~= original_capture_output then return nil end
	local capability, factory = original_capture_output()
	local owned = _output
	local metadata = owned and kernel_backends[owned.backend]
	if not capability or not owned or owned.capability ~= capability
		or factory ~= original_output_observer_factory or not metadata or not output_current(capability) then return nil end
	local retired, records, unresolved = false, {}, false
	local function current()
		return not retired and not unresolved and M.capture_kernel_source == original_kernel_capture
			and M.capture_output == original_capture_output and _output == owned
			and output_current(capability) and kernel_backends[owned.backend] == metadata
			and metadata.ports_current() and metadata.closed()
	end
	local function retire_node(node)
		if not records[node] then return false end
		records[node] = nil -- Physical close is attempted only once by metadata.retire.
		local called, value = pcall(metadata.retire, node)
		if not called or value ~= true then unresolved = true; return false end
		return true
	end
	local issuer = {}
	issuer.owner_current = current
	issuer.acquire_path = function(path)
		if not current() then return nil, "refused" end
		local called, node, disposition = pcall(metadata.acquire, owned.fd, current, path)
		if not called then unresolved = true; return nil, "refused" end
		if node then records[node] = true end -- Stage before any subsequent observer.
		if not current() then
			if node then retire_node(node) end
			return nil, "refused"
		end
		return node, disposition
	end
	issuer.current = function(node)
		return records[node] == true and current() and metadata.current(node, current) == true
	end
	issuer.retire = retire_node
	issuer.closed = function() return not unresolved and metadata.closed() end
	issuer.close = function()
		retired = true
		local closed = not unresolved
		for node in pairs(records) do if not retire_node(node) then closed = false end end
		return closed and metadata.closed()
	end
	local token = {}
	local expected = {}
	for name, port in pairs(issuer) do expected[name] = port end
	kernel_sources[token] = { ports = issuer, expected = expected }
	return token
end
function M.kernel_source_ports(token)
	if M.capture_kernel_source ~= original_kernel_capture or M.kernel_source_ports ~= original_kernel_ports then return nil end
	local record = kernel_sources[token]
	if not record then return nil end
	for name, port in pairs(record.expected) do if record.ports[name] ~= port then return nil end end
	return record.ports
end
original_kernel_capture, original_kernel_ports = M.capture_kernel_source, M.kernel_source_ports

return M
