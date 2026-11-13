--- adapters/x11_focus.lua

--- ==============================================================================
--- MODULE: X11 Focused Window Query (Linux)
--- DESCRIPTION:
--- Answers "which window is active, what is it called, and which process owns
--- it" from the X server directly through libxcb, in this process. The daemon
--- asks four times a second; the xdotool route it replaces forked two programs
--- per question (eight forks a second on an idle desktop, each costing several
--- milliseconds of CPU and a wakeup).
---
--- FEATURES & RATIONALE:
--- 1. Same answers as xdotool. The active window is the root window's
---    _NET_ACTIVE_WINDOW (the EWMH property xdotool reads), the title is
---    _NET_WM_NAME with WM_NAME as the fallback, and the owner is _NET_WM_PID.
---    An empty title is "no answer", as an empty xdotool line was. The
---    application identity is the WM_CLASS class (window_class), as on Wayland.
--- 2. libxcb, not Xlib. A dead X server makes Xlib call exit() from an IO error
---    handler, which would take the keyboard grab's owner down with it; libxcb
---    reports the broken connection and lets the caller carry on.
--- 3. The protocol logic is separate from the transport. The transport (a few
---    xcb calls) is the only FFI surface; decoding titles, ids and pids is plain
---    Lua, tested against a scripted transport.
--- 4. Explicit lifecycle: one connection, opened on the first query, closed when
---    it errors (the next query reconnects, at most every RECONNECT_MS) and by
---    close(). A failure to connect is returned as a reason, never hidden.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Monotonic = require("core.logger.engine.monotonic")

local LOG = "adapters.x11_focus"

-- Predefined core atoms (X11 protocol appendix B), so no intern round trip.
local ATOM_ATOM, ATOM_STRING, ATOM_WINDOW, ATOM_CARDINAL, ATOM_WM_NAME, ATOM_WM_CLASS = 4, 31, 33, 6, 39, 67

-- Most _NET_WM_STATE atoms one window's state reads.
local MAX_STATE_ATOMS = 32

-- Longest title read, in 32-bit units (16 KiB). A longer title is truncated.
local MAX_TITLE_LONGS = 4096

-- Most managed windows one listing reads (the property is read in 32-bit units).
M.MAX_CLIENTS = 1024

-- Most monitors one RandR listing reads.
M.MAX_MONITORS = 16

-- Minimum milliseconds between two connection attempts after a failure.
M.RECONNECT_MS = 2000

-- The transport: nil until bound. A table with
--   connect() -> boolean, string|nil reason
--   intern(name) -> atom|nil
--   property(window, property_atom, type_atom, max_longs) -> { type, format, bytes }|nil
--   root() -> window id
--   pointer() -> root_x, root_y|nil (the cursor on the root window's screen)
--   geometry(window) -> x, y, width, height|nil (root coordinates of the window's origin)
--   monitors() -> array of { x, y, width, height }|nil (RandR 1.5; nil without the extension)
--   healthy() -> boolean
--   disconnect()
local _transport = nil
local _last_attempt_ms = nil
local _connected = false
local _atoms = {}




-- =========================================
-- =========================================
-- ======= 1/ Protocol Logic ===============
-- =========================================
-- =========================================

--- Reads a little-endian 32-bit unsigned integer from the start of a byte string.
--- @param bytes string
--- @return integer|nil
local function u32(bytes)
	if type(bytes) ~= "string" or #bytes < 4 then return nil end
	local b1, b2, b3, b4 = bytes:byte(1, 4)
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- Converts Latin-1 bytes (the STRING property type) to UTF-8.
--- @param bytes string
--- @return string
local function latin1_to_utf8(bytes)
	return (bytes:gsub("[\128-\255]", function(char)
		local code = char:byte()
		return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
	end))
end

--- The first line of a title, or nil when it is empty (xdotool's empty line).
--- @param text string
--- @return string|nil
local function first_line(text)
	local line = text:match("^([^\r\n]*)")
	if line == nil or line == "" then return nil end
	return line
end

--- Interns an atom once per connection.
--- @param name string
--- @return integer|nil
local function atom(name)
	local cached = _atoms[name]
	if cached then return cached end
	local value = _transport.intern(name)
	if value and value ~= 0 then _atoms[name] = value end
	return value
end

--- Reads the active window id from the root window.
--- @return integer|nil id
local function active_window()
	local property = atom("_NET_ACTIVE_WINDOW")
	if not property then return nil end
	local reply = _transport.property(_transport.root(), property, ATOM_WINDOW, 1)
	if not reply or reply.format ~= 32 then return nil end
	local id = u32(reply.bytes)
	if id == nil or id == 0 then return nil end
	return id
end

--- Reads a window's title: _NET_WM_NAME, else WM_NAME.
--- @param window integer
--- @return string|nil title
local function window_title(window)
	local utf8_type = atom("UTF8_STRING")
	local net_name = atom("_NET_WM_NAME")
	if utf8_type and net_name then
		local reply = _transport.property(window, net_name, utf8_type, MAX_TITLE_LONGS)
		if reply and reply.format == 8 and #reply.bytes > 0 then return first_line(reply.bytes) end
	end
	local reply = _transport.property(window, ATOM_WM_NAME, 0, MAX_TITLE_LONGS)
	if not reply or reply.format ~= 8 or #reply.bytes == 0 then return nil end
	if reply.type == ATOM_STRING then return first_line(latin1_to_utf8(reply.bytes)) end
	return first_line(reply.bytes)
end

--- Reads a window's application class: the second string of WM_CLASS (ICCCM
--- "instance\0Class\0"), the identity sway reports as window_properties.class
--- and the desktop compositors as their WM class (ADD-3).
--- @param window integer
--- @return string|nil class nil when the window states none.
local function window_class(window)
	-- Two short names: the title's bound is ample.
	local reply = _transport.property(window, ATOM_WM_CLASS, ATOM_STRING, MAX_TITLE_LONGS)
	if not reply or reply.format ~= 8 or #reply.bytes == 0 then return nil end
	local instance, class = reply.bytes:match("^([^%z]*)%z([^%z]*)")
	local name = (class ~= nil and class ~= "") and class or instance
	if name == nil or name == "" then return nil end
	return latin1_to_utf8(name)
end

--- Reads a window's owning process id.
--- @param window integer
--- @return string|nil pid Decimal text, as xdotool prints it.
local function window_pid(window)
	local property = atom("_NET_WM_PID")
	if not property then return nil end
	local reply = _transport.property(window, property, ATOM_CARDINAL, 1)
	if not reply or reply.format ~= 32 then return nil end
	local pid = u32(reply.bytes)
	if pid == nil then return nil end
	return tostring(pid)
end




-- =========================================
-- =========================================
-- ======= 2/ Lifecycle ====================
-- =========================================
-- =========================================

--- Binds a transport. Test seam, and the production binding through use_xcb().
--- @param transport table|nil
function M._set_transport(transport)
	if _transport and _connected then pcall(_transport.disconnect) end
	_transport = transport
	_connected, _last_attempt_ms, _atoms = false, nil, {}
end

--- Whether a transport is bound.
--- @return boolean
function M.has_transport()
	return _transport ~= nil
end

--- Closes the connection; the next query reconnects.
function M.close()
	if _transport and _connected then
		pcall(_transport.disconnect)
		Logger.info(LOG, "X server connection closed.")
	end
	_connected, _atoms = false, {}
end

--- Opens the connection when none is open, at most once per RECONNECT_MS after a failure.
--- @return boolean connected
--- @return string|nil reason
local function ensure_connected()
	if _connected and _transport.healthy() then return true end
	if _connected then
		Logger.warn(LOG, "X server connection broke — reconnecting on the next query.")
		pcall(_transport.disconnect)
		_connected, _atoms = false, {}
	end
	local now = Monotonic.now_ms()
	if _last_attempt_ms and now - _last_attempt_ms < M.RECONNECT_MS then
		return false, "connection retry pending"
	end
	_last_attempt_ms = now
	local ok, reason = _transport.connect()
	if not ok then return false, reason or "connect refused" end
	_connected = true
	Logger.success(LOG, "Connected to the X server for focus queries.")
	return true
end




-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Asks the X server for the active window, its title and its owning process.
--- @return string|nil window Decimal window id (what xdotool prints); nil with a reason when unanswerable.
--- @return string|nil title First line of the title; nil when empty.
--- @return string|nil pid Decimal owner process id when the window states one.
--- @return string|nil reason Why there is no answer (transport trouble only).
function M.query()
	if not _transport then return nil, nil, nil, "no X transport" end
	local connected, reason = ensure_connected()
	if not connected then return nil, nil, nil, reason end
	local window = active_window()
	if not window then return nil end
	local title = window_title(window)
	if title == nil then return nil end
	return tostring(window), title, window_pid(window)
end

--- The application class of a window the caller already identified.
--- @param window string|number Decimal window id, as query() returns it.
--- @return string|nil class nil when the window states none or the server cannot answer.
function M.window_class(window)
	if not _transport then return nil end
	local id = tonumber(window)
	if not id or id == 0 then return nil end
	local connected = ensure_connected()
	if not connected then return nil end
	return window_class(id)
end

--- The index of the current virtual desktop, the root window's EWMH
--- _NET_CURRENT_DESKTOP (what wmctrl -d marks with a star).
--- @return integer|nil desktop nil when the window manager publishes none, or with a reason on transport trouble.
--- @return string|nil reason
function M.current_desktop()
	if not _transport then return nil, "no X transport" end
	local connected, reason = ensure_connected()
	if not connected then return nil, reason end
	local property = atom("_NET_CURRENT_DESKTOP")
	if not property then return nil, "the window manager publishes no current desktop" end
	local reply = _transport.property(_transport.root(), property, ATOM_CARDINAL, 1)
	if not reply or reply.format ~= 32 then return nil, "the window manager publishes no current desktop" end
	return u32(reply.bytes)
end

--- The cursor position in screen pixels on the root window, as Windows reads
--- GetCursorPos and macOS hs.mouse.absolutePosition.
--- @return integer|nil x nil with a reason when unanswerable.
--- @return integer|string|nil y_or_reason
function M.pointer_position()
	if not _transport then return nil, "no X transport" end
	local connected, reason = ensure_connected()
	if not connected then return nil, reason end
	if type(_transport.pointer) ~= "function" then return nil, "this transport cannot read the pointer" end
	local x, y = _transport.pointer()
	if type(x) ~= "number" or type(y) ~= "number" then return nil, "the pointer is on another screen" end
	return x, y
end

--- The EWMH state of a window in the Windows vocabulary: _NET_WM_STATE_HIDDEN
--- is minimized; both maximized axes, or fullscreen, is maximized.
--- @param window integer
--- @return string state "normal", "maximized" or "minimized".
local function window_state(window)
	local property = atom("_NET_WM_STATE")
	if not property then return "normal" end
	local reply = _transport.property(window, property, ATOM_ATOM, MAX_STATE_ATOMS)
	if not reply or reply.format ~= 32 then return "normal" end
	local present = {}
	for offset = 1, #reply.bytes - 3, 4 do
		local value = u32(reply.bytes:sub(offset, offset + 3))
		if value then present[value] = true end
	end
	local function has(name)
		local value = atom(name)
		return value ~= nil and present[value] == true
	end
	if has("_NET_WM_STATE_HIDDEN") then return "minimized" end
	if has("_NET_WM_STATE_FULLSCREEN")
		or (has("_NET_WM_STATE_MAXIMIZED_VERT") and has("_NET_WM_STATE_MAXIMIZED_HORZ")) then
		return "maximized"
	end
	return "normal"
end

--- The RandR monitor holding a point, identified by its bounds (the Windows
--- fallback identity: the bounds do not move when outputs are enumerated anew).
--- @param x number
--- @param y number
--- @return table|nil monitor { id, width }
local function monitor_at(x, y)
	if type(_transport.monitors) ~= "function" then return nil end
	local monitors = _transport.monitors()
	if type(monitors) ~= "table" then return nil end
	for _, m in ipairs(monitors) do
		if x >= m.x and x < m.x + m.width and y >= m.y and y < m.y + m.height then
			return { id = string.format("%d,%d,%d,%d", m.x, m.y, m.x + m.width, m.y + m.height), width = m.width }
		end
	end
	return nil
end

--- The focused window's topology: its root-relative geometry, its EWMH state
--- and the monitor holding its centre. One in-process round trip per reading.
--- @return table|nil observation { window, x, y, w, h, state, monitor }; nil with a reason when unanswerable.
--- @return string|nil reason
function M.active_topology()
	if not _transport then return nil, "no X transport" end
	if type(_transport.geometry) ~= "function" then return nil, "this transport cannot read window geometry" end
	local connected, reason = ensure_connected()
	if not connected then return nil, reason end
	local window = active_window()
	if not window then return nil, "no active window" end
	local x, y, w, h = _transport.geometry(window)
	if type(x) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
		return nil, "the active window has no geometry"
	end
	return {
		window = window, x = x, y = y, w = w, h = h, state = window_state(window),
		monitor = monitor_at(x + math.floor(w / 2), y + math.floor(h / 2)),
	}
end

--- Lists the managed top-level windows from the root window's _NET_CLIENT_LIST,
--- as wmctrl -lp does, but in this process and without forking.
--- @return table|nil windows Array of { id, title, pid }; nil with a reason on transport trouble.
--- @return string|nil reason
function M.clients()
	if not _transport then return nil, "no X transport" end
	local connected, reason = ensure_connected()
	if not connected then return nil, reason end
	local property = atom("_NET_CLIENT_LIST")
	if not property then return {} end
	local reply = _transport.property(_transport.root(), property, ATOM_WINDOW, M.MAX_CLIENTS)
	if not reply or reply.format ~= 32 then return {} end
	local windows = {}
	for offset = 1, #reply.bytes - 3, 4 do
		local id = u32(reply.bytes:sub(offset, offset + 3))
		if id ~= nil and id ~= 0 then
			windows[#windows + 1] = { id = id, title = window_title(id) or "", pid = tonumber(window_pid(id)),
				class = window_class(id) }
		end
	end
	return windows
end



-- =========================================
-- =========================================
-- ======= 4/ libxcb Transport =============
-- =========================================
-- =========================================

--- Binds libxcb-randr for the monitor list, or raises when it is unavailable.
--- @param ffi table The LuaJIT FFI.
--- @return table randr { negotiate(connection) -> boolean, monitors(connection, root) -> table|nil }
local function build_randr(ffi)
	local defined, define_error = pcall(ffi.cdef, [[
		typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, major_version, minor_version; uint8_t pad1[16]; } ergopti_xcb_randr_query_version_reply_t;
		ergopti_xcb_cookie_t xcb_randr_query_version(ergopti_xcb_connection_t *connection, uint32_t major_version, uint32_t minor_version);
		ergopti_xcb_randr_query_version_reply_t *xcb_randr_query_version_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, timestamp, nMonitors, nOutputs; uint8_t pad1[12]; } ergopti_xcb_randr_get_monitors_reply_t;
		typedef struct { uint32_t name; uint8_t primary, automatic; uint16_t nOutput; int16_t x, y; uint16_t width, height; uint32_t width_in_millimeters, height_in_millimeters; } ergopti_xcb_randr_monitor_info_t;
		typedef struct { ergopti_xcb_randr_monitor_info_t *data; int rem; int index; } ergopti_xcb_randr_monitor_info_iterator_t;
		ergopti_xcb_cookie_t xcb_randr_get_monitors(ergopti_xcb_connection_t *connection, uint32_t window, uint8_t get_active);
		ergopti_xcb_randr_get_monitors_reply_t *xcb_randr_get_monitors_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		ergopti_xcb_randr_monitor_info_iterator_t xcb_randr_get_monitors_monitors_iterator(const ergopti_xcb_randr_get_monitors_reply_t *reply);
		void xcb_randr_monitor_info_next(ergopti_xcb_randr_monitor_info_iterator_t *iterator);
	]])
	if not defined and not tostring(define_error):find("redefin", 1, true) then error(define_error) end
	local loaded, library = pcall(ffi.load, "xcb-randr")
	if not loaded then library = ffi.load("libxcb-randr.so.0") end
	local randr = {}

	--- RandR answers GetMonitors only to a client that announced version 1.5.
	function randr.negotiate(connection)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_randr_query_version_reply(connection,
			library.xcb_randr_query_version(connection, 1, 5), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return false end
		local major, minor = tonumber(reply.major_version), tonumber(reply.minor_version)
		ffi.C.free(reply)
		return major > 1 or (major == 1 and minor >= 5)
	end

	function randr.monitors(connection, root)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_randr_get_monitors_reply(connection,
			library.xcb_randr_get_monitors(connection, root, 1), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return nil end
		local out = {}
		local iterator = library.xcb_randr_get_monitors_monitors_iterator(reply)
		while iterator.rem > 0 and #out < M.MAX_MONITORS do
			local m = iterator.data
			out[#out + 1] = { x = tonumber(m.x), y = tonumber(m.y), width = tonumber(m.width), height = tonumber(m.height) }
			library.xcb_randr_monitor_info_next(iterator)
		end
		ffi.C.free(reply)
		return out
	end

	return randr
end

--- Builds the libxcb transport, or nil with a reason when libxcb is unavailable.
--- @return table|nil transport
--- @return string|nil reason
local function build_xcb_transport()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil, "LuaJIT FFI unavailable" end
	local defined, define_error = pcall(ffi.cdef, [[
		typedef struct ergopti_xcb_connection_t ergopti_xcb_connection_t;
		typedef struct { unsigned int sequence; } ergopti_xcb_cookie_t;
		typedef struct { uint8_t response_type, format; uint16_t sequence; uint32_t length, type, bytes_after, value_len; uint8_t pad0[12]; } ergopti_xcb_property_reply_t;
		typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, atom; } ergopti_xcb_atom_reply_t;
		typedef struct { uint32_t root; } ergopti_xcb_screen_t;
		typedef struct { ergopti_xcb_screen_t *data; int rem; int index; } ergopti_xcb_screen_iterator_t;
		typedef struct ergopti_xcb_setup_t ergopti_xcb_setup_t;
		ergopti_xcb_connection_t *xcb_connect(const char *display, int *screen);
		void xcb_disconnect(ergopti_xcb_connection_t *connection);
		int xcb_connection_has_error(ergopti_xcb_connection_t *connection);
		const ergopti_xcb_setup_t *xcb_get_setup(ergopti_xcb_connection_t *connection);
		ergopti_xcb_screen_iterator_t xcb_setup_roots_iterator(const ergopti_xcb_setup_t *setup);
		void xcb_screen_next(ergopti_xcb_screen_iterator_t *iterator);
		ergopti_xcb_cookie_t xcb_intern_atom(ergopti_xcb_connection_t *connection, uint8_t only_if_exists, uint16_t name_len, const char *name);
		ergopti_xcb_atom_reply_t *xcb_intern_atom_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		ergopti_xcb_cookie_t xcb_get_property(ergopti_xcb_connection_t *connection, uint8_t delete_property, uint32_t window, uint32_t property, uint32_t type, uint32_t long_offset, uint32_t long_length);
		ergopti_xcb_property_reply_t *xcb_get_property_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		void *xcb_get_property_value(const ergopti_xcb_property_reply_t *reply);
		int xcb_get_property_value_length(const ergopti_xcb_property_reply_t *reply);
		typedef struct { uint8_t response_type, same_screen; uint16_t sequence; uint32_t length, root, child; int16_t root_x, root_y, win_x, win_y; uint16_t mask; uint8_t pad0[2]; } ergopti_xcb_query_pointer_reply_t;
		ergopti_xcb_cookie_t xcb_query_pointer(ergopti_xcb_connection_t *connection, uint32_t window);
		ergopti_xcb_query_pointer_reply_t *xcb_query_pointer_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		typedef struct { uint8_t response_type, depth; uint16_t sequence; uint32_t length, root; int16_t x, y; uint16_t width, height, border_width; uint8_t pad0[2]; } ergopti_xcb_get_geometry_reply_t;
		ergopti_xcb_cookie_t xcb_get_geometry(ergopti_xcb_connection_t *connection, uint32_t drawable);
		ergopti_xcb_get_geometry_reply_t *xcb_get_geometry_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		typedef struct { uint8_t response_type, same_screen; uint16_t sequence; uint32_t length, child; int16_t dst_x, dst_y; } ergopti_xcb_translate_coordinates_reply_t;
		ergopti_xcb_cookie_t xcb_translate_coordinates(ergopti_xcb_connection_t *connection, uint32_t src_window, uint32_t dst_window, int16_t src_x, int16_t src_y);
		ergopti_xcb_translate_coordinates_reply_t *xcb_translate_coordinates_reply(ergopti_xcb_connection_t *connection, ergopti_xcb_cookie_t cookie, void **error);
		void free(void *pointer);
	]])
	if not defined and not tostring(define_error):find("redefin", 1, true) then
		return nil, "ffi.cdef failed: " .. tostring(define_error)
	end
	local loaded, library = pcall(ffi.load, "xcb")
	if not loaded then
		loaded, library = pcall(ffi.load, "libxcb.so.1")
		if not loaded then return nil, "libxcb is not installed" end
	end

	local connection, root = nil, 0
	local transport = {}
	-- RandR is a separate library; a runtime without it still answers geometry.
	local randr_bound, randr_library = pcall(build_randr, ffi)
	if not randr_bound then
		Logger.info(LOG, "libxcb-randr unavailable (%s): window topology records no monitor changes.", tostring(randr_library))
	end
	local randr = nil

	function transport.connect()
		local screen = ffi.new("int[1]")
		local opened = library.xcb_connect(nil, screen)
		if opened == nil or library.xcb_connection_has_error(opened) ~= 0 then
			if opened ~= nil then library.xcb_disconnect(opened) end
			return false, "cannot connect to the X server (is DISPLAY set?)"
		end
		local iterator = library.xcb_setup_roots_iterator(library.xcb_get_setup(opened))
		for _ = 1, screen[0] do
			if iterator.rem <= 1 then break end
			library.xcb_screen_next(iterator)
		end
		if iterator.data == nil then
			library.xcb_disconnect(opened)
			return false, "the X server reported no screen"
		end
		connection, root = opened, iterator.data.root
		randr = nil
		if randr_bound then
			local negotiated, supported = pcall(randr_library.negotiate, connection)
			if negotiated and supported then randr = randr_library end
		end
		return true
	end

	function transport.disconnect()
		if connection ~= nil then library.xcb_disconnect(connection) end
		connection, root = nil, 0
	end

	function transport.healthy()
		return connection ~= nil and library.xcb_connection_has_error(connection) == 0
	end

	function transport.root() return root end

	function transport.intern(name)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_intern_atom_reply(connection,
			library.xcb_intern_atom(connection, 0, #name, name), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return nil end
		local value = tonumber(reply.atom)
		ffi.C.free(reply)
		return value
	end

	function transport.pointer()
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_query_pointer_reply(connection, library.xcb_query_pointer(connection, root), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return nil end
		local x, y, same = tonumber(reply.root_x), tonumber(reply.root_y), reply.same_screen ~= 0
		ffi.C.free(reply)
		if not same then return nil end
		return x, y
	end

	function transport.geometry(window)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_get_geometry_reply(connection, library.xcb_get_geometry(connection, window), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return nil end
		local w, h = tonumber(reply.width), tonumber(reply.height)
		ffi.C.free(reply)
		local moved = library.xcb_translate_coordinates_reply(connection,
			library.xcb_translate_coordinates(connection, window, root, 0, 0), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if moved == nil then return nil end
		local x, y = tonumber(moved.dst_x), tonumber(moved.dst_y)
		ffi.C.free(moved)
		return x, y, w, h
	end

	function transport.monitors()
		if randr == nil then return nil end
		return randr.monitors(connection, root)
	end

	function transport.property(window, property, type_atom, max_longs)
		local error_slot = ffi.new("void*[1]")
		local reply = library.xcb_get_property_reply(connection,
			library.xcb_get_property(connection, 0, window, property, type_atom, 0, max_longs), error_slot)
		if error_slot[0] ~= nil then ffi.C.free(error_slot[0]) end
		if reply == nil then return nil end
		local length = library.xcb_get_property_value_length(reply)
		local result = { type = tonumber(reply.type), format = tonumber(reply.format),
			bytes = length > 0 and ffi.string(library.xcb_get_property_value(reply), length) or "" }
		ffi.C.free(reply)
		if result.type == 0 then return nil end
		return result
	end

	return transport
end

--- Binds the production libxcb transport.
--- @return boolean bound
--- @return string|nil reason
function M.use_xcb()
	local transport, reason = build_xcb_transport()
	if not transport then return false, reason end
	M._set_transport(transport)
	return true
end

return M
