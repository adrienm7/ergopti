--- tests/hardware/lib/xtest_uinput_backend.lua

--- ==============================================================================
--- MODULE: uinput Backend Delivered Through XTest
--- DESCRIPTION:
--- A syscall backend for adapters/uinput_writer.lua (its _set_backend seam)
--- whose writes go to a real X server through XTest instead of a kernel node.
--- The writer, the modifier broker and the injector above it are production
--- code: only the last hop changes, from /dev/uinput to XTestFakeKeyEvent with
--- the X keycode evdev + 8, the offset every evdev-based X server and
--- XWayland apply. The server then maps the key through its own XKB keymap,
--- exactly as it maps a key from a uinput device on a real desktop.
---
--- WHY: Xvfb has no evdev backend, so a real uinput device never reaches it
--- (tests/hardware/run_keysym_roundtrip.sh). XTest is the one input path a
--- headless server exposes, and it enters the same core keyboard, keymap and
--- client delivery as a hardware key.
---
--- Records every KEY event too, so a check can assert what reached the wire.
--- ==============================================================================

local ffi = require("ffi")

ffi.cdef([[
	typedef struct _XDisplay Display;
	Display *XOpenDisplay(const char *);
	int XCloseDisplay(Display *);
	int XFlush(Display *);
	int XSync(Display *, int);
	int XTestFakeKeyEvent(Display *, unsigned int, int, unsigned long);
]])

local M = {}

local EV_KEY = 1
local EVENT_SIZE = 24
local X_KEYCODE_OFFSET = 8

--- Reads a little-endian unsigned integer from a byte string.
--- @param bytes string
--- @param offset integer 1-based start.
--- @param size integer Byte count.
--- @return integer
local function uint_le(bytes, offset, size)
	local value = 0
	for index = size, 1, -1 do value = value * 256 + bytes:byte(offset + index - 1) end
	return value
end

--- Builds a backend bound to the X display named by $DISPLAY.
--- @return table backend { open, ioctl, write, close, events, display }
function M.new()
	local x11 = ffi.load("libX11.so.6")
	local xtst = ffi.load("libXtst.so.6")
	local display = x11.XOpenDisplay(nil)
	assert(display ~= nil, "XTest backend: cannot open $DISPLAY")
	local backend = { events = {} }
	function backend.open() return 7 end
	function backend.ioctl() return true end
	function backend.write(_, bytes)
		if type(bytes) ~= "string" or #bytes ~= EVENT_SIZE then return false end
		local ev_type, code = uint_le(bytes, 17, 2), uint_le(bytes, 19, 2)
		local value = uint_le(bytes, 21, 4)
		if ev_type ~= EV_KEY then return true end
		backend.events[#backend.events + 1] = { code = code, value = value }
		-- An autorepeat is one more press, as the server's own repeat would be.
		local pressed = (value == 1 or value == 2) and 1 or 0
		if xtst.XTestFakeKeyEvent(display, code + X_KEYCODE_OFFSET, pressed, 0) == 0 then return false end
		x11.XSync(display, 0)
		return true
	end
	function backend.close() return true end
	function backend.shutdown() x11.XCloseDisplay(display) end
	return backend
end

return M
