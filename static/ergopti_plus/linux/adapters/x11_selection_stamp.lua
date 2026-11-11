--- adapters/x11_selection_stamp.lua

--- ==============================================================================
--- MODULE: X11 Clipboard Owner Timestamp (Linux)
--- DESCRIPTION:
--- Asks the X11 CLIPBOARD owner for its ICCCM TIMESTAMP target through libX11,
--- the value `xclip -t TIMESTAMP` prints, so the tap-hold copy check has its
--- change counter on an X11 session without xclip.
---
--- WHY NATIVE:
--- xsel, the other X11 clipboard tool, cannot request an arbitrary target, so
--- without xclip the copy went unchecked. libX11 is already one of the
--- driver's declared native libraries (_shared/data/linux_native_runtime.json).
---
--- FEATURES & RATIONALE:
--- 1. One connection per read: a copy check reads twice, and a connection that
---    lives no longer than the read needs no lifecycle owner.
--- 2. Bounded wait: the owner's answer is awaited for at most the caller's
---    timeout, polling without blocking, then the read is "unreadable".
--- 3. No owner, no stamp: a clipboard nobody owns answers 0, which a later
---    copy moves, as an owner's renewed timestamp does. M.owned answers the
---    owner question alone, for the clipboard borrower, and M.disown gives an
---    unowned clipboard back as it was found.
--- ==============================================================================

local M = {}

local Runtime = require("_generated.native_runtime")

-- X11 constants (X.h).
local SELECTION_NOTIFY = 31
local NONE = 0
local CURRENT_TIME = 0
local ANY_PROPERTY_TYPE = 0
local POLL_STEP_S = 0.002

-- Each declaration on its own: another module may have declared the same
-- function with the same signature, which LuaJIT reports as a redefinition.
local DECLARATIONS = {
	"struct _XDisplay *XOpenDisplay(const char *display);",
	"int XCloseDisplay(struct _XDisplay *display);",
	"unsigned long XDefaultRootWindow(struct _XDisplay *display);",
	"unsigned long XInternAtom(struct _XDisplay *display, const char *name, int only_if_exists);",
	"int XGetWindowProperty(struct _XDisplay *, unsigned long, unsigned long, long, long, int,"
		.. " unsigned long, unsigned long *, int *, unsigned long *, unsigned long *, unsigned char **);",
	"int XFree(void *pointer);",
	"unsigned long XCreateSimpleWindow(struct _XDisplay *, unsigned long, int, int, unsigned int,"
		.. " unsigned int, unsigned int, unsigned long, unsigned long);",
	"int XDestroyWindow(struct _XDisplay *, unsigned long);",
	"int XConvertSelection(struct _XDisplay *, unsigned long, unsigned long, unsigned long, unsigned long,"
		.. " unsigned long);",
	"int XFlush(struct _XDisplay *);",
	"unsigned long XGetSelectionOwner(struct _XDisplay *, unsigned long);",
	"int XSetSelectionOwner(struct _XDisplay *, unsigned long, unsigned long, unsigned long);",
	"typedef union { long pad[24]; } ErgoptiSelectionStampEvent;",
	"typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long requestor,"
		.. " selection, target, property, time; } ErgoptiSelectionStampNotify;",
	"int XCheckTypedWindowEvent(struct _XDisplay *, unsigned long, int, ErgoptiSelectionStampEvent *);",
}

local _bound = nil

--- Binds libX11 once.
--- @return table|nil native { ffi, x11, sleep }
--- @return string|nil reason
local function bind()
	if _bound then return _bound end
	local has_ffi, ffi = pcall(require, "ffi")
	if not has_ffi then return nil, "unsupported" end
	for _, declaration in ipairs(DECLARATIONS) do
		local ok, err = pcall(ffi.cdef, declaration)
		if not ok and not tostring(err):find("redefin", 1, true) then return nil, "unsupported" end
	end
	local loaded, x11 = pcall(ffi.load, Runtime.x11)
	if not loaded then return nil, "unsupported" end
	local sleep = require("infra.native_sleep").bind(ffi)
	if not sleep then return nil, "unsupported" end
	_bound = { ffi = ffi, x11 = x11, sleep = sleep }
	return _bound
end

--- Waits for the owner's SelectionNotify and reads the TIMESTAMP it stored.
--- @return number|nil stamp
local function await_stamp(native, display, window, property, timeout_s)
	local ffi, x11 = native.ffi, native.x11
	local event = ffi.new("ErgoptiSelectionStampEvent[1]")
	local waited = 0
	while waited <= timeout_s do
		if x11.XCheckTypedWindowEvent(display, window, SELECTION_NOTIFY, event) ~= 0 then
			local notify = ffi.cast("ErgoptiSelectionStampNotify *", event)
			if notify.property == NONE then return nil end
			local actual_type = ffi.new("unsigned long[1]")
			local format = ffi.new("int[1]")
			local count = ffi.new("unsigned long[1]")
			local after = ffi.new("unsigned long[1]")
			local data = ffi.new("unsigned char *[1]")
			local status = x11.XGetWindowProperty(display, window, property, 0, 1, 1, ANY_PROPERTY_TYPE,
				actual_type, format, count, after, data)
			if status ~= 0 or data[0] == nil then return nil end
			local stamp = nil
			-- Xlib hands format-32 items back as C longs.
			if format[0] == 32 and count[0] >= 1 then
				stamp = tonumber(ffi.cast("unsigned long *", data[0])[0]) % 4294967296
			end
			x11.XFree(data[0])
			return stamp
		end
		native.sleep(POLL_STEP_S)
		waited = waited + POLL_STEP_S
	end
	return nil
end

--- Whether any client owns the CLIPBOARD selection. xclip cannot tell an
--- ownerless clipboard from a failed read (both exit 1), and an ownerless
--- clipboard is simply empty.
--- @return boolean|nil owned
--- @return string|nil reason "unsupported" without libX11 or a display.
function M.owned()
	local native, reason = bind()
	if not native then return nil, reason end
	local x11 = native.x11
	local display = x11.XOpenDisplay(nil)
	if display == nil then return nil, "unsupported" end
	local owner = x11.XGetSelectionOwner(display, x11.XInternAtom(display, "CLIPBOARD", 0))
	x11.XCloseDisplay(display)
	return owner ~= NONE
end

--- Leaves the CLIPBOARD selection without an owner, as it was before a
--- borrow found it unowned: the ICCCM way to empty it, which macOS
--- (clearContents) matches. The owner Ergopti's writer started receives
--- SelectionClear and exits; nothing records an empty entry (ADD-2).
--- @return boolean cleared true once the server reports no owner.
--- @return string|nil reason "unsupported" without libX11 or a display, "owned" when an owner remains.
function M.disown()
	local native, reason = bind()
	if not native then return false, reason end
	local x11 = native.x11
	local display = x11.XOpenDisplay(nil)
	if display == nil then return false, "unsupported" end
	local clipboard = x11.XInternAtom(display, "CLIPBOARD", 0)
	x11.XSetSelectionOwner(display, clipboard, NONE, CURRENT_TIME)
	x11.XFlush(display)
	local owner = x11.XGetSelectionOwner(display, clipboard)
	x11.XCloseDisplay(display)
	if owner ~= NONE then return false, "owned" end
	return true
end

--- The CLIPBOARD owner's TIMESTAMP.
--- @param timeout_s number Longest wait for the owner's answer.
--- @return number|nil stamp 0 when nobody owns the clipboard.
--- @return string|nil reason "unsupported" without libX11 or a display, "unreadable" when the owner did not answer.
function M.read(timeout_s)
	local native, reason = bind()
	if not native then return nil, reason end
	local x11 = native.x11
	local display = x11.XOpenDisplay(nil)
	if display == nil then return nil, "unsupported" end
	local clipboard = x11.XInternAtom(display, "CLIPBOARD", 0)
	if x11.XGetSelectionOwner(display, clipboard) == NONE then
		x11.XCloseDisplay(display)
		return 0
	end
	local window = x11.XCreateSimpleWindow(display, x11.XDefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0)
	local property = x11.XInternAtom(display, "ERGOPTI_SELECTION_STAMP", 0)
	x11.XConvertSelection(display, clipboard, x11.XInternAtom(display, "TIMESTAMP", 0), property, window, CURRENT_TIME)
	x11.XFlush(display)
	local ok, stamp = pcall(await_stamp, native, display, window, property, timeout_s)
	x11.XDestroyWindow(display, window)
	x11.XCloseDisplay(display)
	if not ok or stamp == nil then return nil, "unreadable" end
	return stamp
end

return M
