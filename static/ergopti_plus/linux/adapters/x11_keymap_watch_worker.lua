--- adapters/x11_keymap_watch_worker.lua
--- The owned X11 keymap watch child. This file needs only LuaJIT's built-in
--- ffi, so its literal script path is sufficient even when the application
--- directory contains Lua template delimiters.

--- ==============================================================================
--- MODULE: X11 Keymap Watch Worker (Linux)
--- DESCRIPTION:
--- Prints "ready" once it listens, then one "keymap" line each time the X
--- server's core keyboard gets a new keymap (XkbNewKeyboardNotify, and
--- XkbMapNotify for a keymap edited in place), for
--- modules/keymap/x11_layout_reapply.lua.
---
--- FEATURES & RATIONALE:
--- 1. A process of its own: XNextEvent blocks, so the daemon's input loop never
---    waits on the X connection; it reads these lines off its event loop.
--- 2. Only the fact is printed, never the keymap: the daemon reads the keymap
---    itself once the events settle, so a burst of events costs one read.
--- 3. Fail fast: no library, display or XKB extension, a lost connection, a
---    closed stdout or a parent gone end the worker; the daemon then stops
---    re-applying for the session.
--- ==============================================================================

local ffi = require("ffi")

local M = {}

-- XkbUseCoreKbd, XkbNewKeyboardNotifyMask | XkbMapNotifyMask.
local CORE_KEYBOARD = 0x100
local KEYMAP_EVENTS = 0x3
-- XEvent is a 24-long union (192 bytes on LP64); room to spare.
local EVENT_BYTES = 256

-- Declared only when the child runs: requiring this file must neither touch
-- ffi.C nor exit the caller.
local DECLARATIONS = [[
struct _XDisplay;
struct _XDisplay *XOpenDisplay(const char *);
int XCloseDisplay(struct _XDisplay *);
int XNextEvent(struct _XDisplay *, void *);
int XkbQueryExtension(struct _XDisplay *, int *, int *, int *, int *, int *);
int XkbSelectEvents(struct _XDisplay *, unsigned int, unsigned int, unsigned int);
int XSync(struct _XDisplay *, int);
int getppid(void);
int prctl(int, ...);
]]

--- Whether an event is one of the XKB extension's events.
--- @param event_type integer The XEvent's type field.
--- @param xkb_base integer The extension's first event code.
--- @return boolean
function M.is_xkb_event(event_type, xkb_base)
	return event_type == xkb_base
end

--- Listens until the parent or the server goes, printing through `emit`.
--- @param soname string The libX11 soname.
--- @param parent_pid integer The daemon's process id.
--- @param emit function emit(line) -> boolean written.
--- @return string reason Why it stopped.
--- @return boolean parent_gone
function M.run(soname, parent_pid, emit)
	assert(type(soname) == "string" and soname:match("^[%w_+%.%-]+$"), "invalid X11 soname")
	assert(parent_pid and parent_pid > 0 and parent_pid % 1 == 0, "invalid parent")
	ffi.cdef(DECLARATIONS)
	-- PR_SET_PDEATHSIG, SIGKILL: the worker never outlives the daemon.
	assert(ffi.C.prctl(1, ffi.cast("unsigned long", 9), 0, 0, 0) == 0, "parent binding failed")
	assert(tonumber(ffi.C.getppid()) == parent_pid, "parent already exited")
	local x = ffi.load(soname)
	local display = x.XOpenDisplay(nil)
	assert(display ~= nil, "X display unavailable")
	local opcode, base, errors = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
	local major, minor = ffi.new("int[1]", 1), ffi.new("int[1]", 0)
	assert(x.XkbQueryExtension(display, opcode, base, errors, major, minor) ~= 0, "XKB extension unavailable")
	assert(x.XkbSelectEvents(display, CORE_KEYBOARD, KEYMAP_EVENTS, KEYMAP_EVENTS) ~= 0, "XKB event selection refused")
	x.XSync(display, 0)
	if not emit("ready") then
		x.XCloseDisplay(display)
		return "stdout closed", false
	end
	local event = ffi.new("char[?]", EVENT_BYTES)
	local event_type = ffi.cast("int *", event)
	while true do
		-- XNextEvent exits the process through the I/O error handler when the
		-- connection is lost: the daemon reads that as the worker ending.
		x.XNextEvent(display, event)
		if tonumber(ffi.C.getppid()) ~= parent_pid then
			x.XCloseDisplay(display)
			return "parent exited", true
		end
		if M.is_xkb_event(event_type[0], base[0]) and not emit("keymap") then
			x.XCloseDisplay(display)
			return "stdout closed", false
		end
	end
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:gsub("\\", "/"):match("([^/]+)$") == "x11_keymap_watch_worker.lua" then
	local function emit(line)
		local written = io.stdout:write(line, "\n")
		return written ~= nil and io.stdout:flush() ~= nil
	end
	local ok, detail, parent_gone = pcall(M.run, arg[1], tonumber(arg[2]), emit)
	io.stderr:write("X11 keymap watch worker stopped: " .. tostring(detail) .. "\n")
	os.exit(ok and parent_gone and 0 or 1)
end

return M
