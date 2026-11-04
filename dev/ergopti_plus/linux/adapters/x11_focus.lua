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
---    An empty title is "no answer", as an empty xdotool line was.
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

local Logger = require("logger.shim")
local Monotonic = require("infra.monotonic")

local LOG = "adapters.x11_focus"

-- Predefined core atoms (X11 protocol appendix B), so no intern round trip.
local ATOM_STRING, ATOM_WINDOW, ATOM_CARDINAL, ATOM_WM_NAME = 31, 33, 6, 39

-- Longest title read, in 32-bit units (16 KiB). A longer title is truncated.
local MAX_TITLE_LONGS = 4096

-- Most managed windows one listing reads (the property is read in 32-bit units).
M.MAX_CLIENTS = 1024

-- Minimum milliseconds between two connection attempts after a failure.
M.RECONNECT_MS = 2000

-- The transport: nil until bound. A table with
--   connect() -> boolean, string|nil reason
--   intern(name) -> atom|nil
--   property(window, property_atom, type_atom, max_longs) -> { type, format, bytes }|nil
--   root() -> window id
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
			windows[#windows + 1] = { id = id, title = window_title(id) or "", pid = tonumber(window_pid(id)) }
		end
	end
	return windows
end



-- =========================================
-- =========================================
-- ======= 4/ libxcb Transport =============
-- =========================================
-- =========================================

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
