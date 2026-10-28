--- tests/hardware/run_x11_focus_receipt.lua

--- ==============================================================================
--- MODULE: X11 Focus Query Receipt
--- DESCRIPTION:
--- Checks the libxcb focus query (adapters/x11_focus) against a real X server and
--- against xdotool, which it replaces. A synthetic window carries a UTF-8
--- _NET_WM_NAME, a Latin-1 WM_NAME, a multi-line title or no title, and is made
--- the root's _NET_ACTIVE_WINDOW; both routes are then asked and must agree on
--- the window id, the title and the owner. The unit tests script the transport;
--- only a real server proves the struct layouts and the property decoding.
---
--- Run from the Linux driver root with DISPLAY set and xdotool installed:
---   luajit tests/hardware/run_x11_focus_receipt.lua
--- Exits 0 and prints "ALL SAME" when every case agrees.
--- ==============================================================================

require("compat.utf8").install()
local ffi = require("ffi")
local luv = require("luv")
local DisplayServer = require("infra.display_server")
assert(DisplayServer.is_x11(), "the focus receipt needs an X11 display")
local Focus = require("adapters.x11_focus")
local bound, reason = Focus.use_xcb()
assert(bound, "libxcb transport unavailable: " .. tostring(reason))

-- Only the calls the module does not declare; its typedefs are reused.
ffi.cdef([[
	uint32_t xcb_generate_id(ergopti_xcb_connection_t *c);
	ergopti_xcb_cookie_t xcb_create_window(ergopti_xcb_connection_t *c, uint8_t depth, uint32_t wid, uint32_t parent, int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t border, uint16_t class_, uint32_t visual, uint32_t mask, const uint32_t *values);
	ergopti_xcb_cookie_t xcb_change_property(ergopti_xcb_connection_t *c, uint8_t mode, uint32_t window, uint32_t property, uint32_t type, uint8_t format, uint32_t data_len, const void *data);
	int xcb_flush(ergopti_xcb_connection_t *c);
]])
local xcb = ffi.load("xcb")
local connection = xcb.xcb_connect(nil, ffi.new("int[1]"))
assert(xcb.xcb_connection_has_error(connection) == 0, "cannot reach the X server")
local root = xcb.xcb_setup_roots_iterator(xcb.xcb_get_setup(connection)).data.root

local ATOM_CARDINAL, ATOM_WINDOW, ATOM_STRING = 6, 33, 31

--- Interns an atom; the reply also proves the server applied earlier requests.
--- @param name string
--- @return integer
local function intern(name)
	local reply = xcb.xcb_intern_atom_reply(connection, xcb.xcb_intern_atom(connection, 0, #name, name), nil)
	local atom = tonumber(reply.atom)
	ffi.C.free(reply)
	return atom
end

local function set(window, property, type_atom, format, data, length)
	xcb.xcb_change_property(connection, 0, window, intern(property), type_atom, format, length, data)
end

local function new_window()
	local id = xcb.xcb_generate_id(connection)
	xcb.xcb_create_window(connection, 0, id, root, 0, 0, 10, 10, 0, 1, 0, 0, nil)
	return id
end

local function activate(window)
	set(root, "_NET_ACTIVE_WINDOW", ATOM_WINDOW, 32, ffi.new("uint32_t[1]", window), 1)
	xcb.xcb_flush(connection)
	intern("WM_NAME") -- a round trip: the server has applied our writes
end

local function ask_tool(command)
	local pipe = io.popen(command .. " 2>/dev/null")
	local output = pipe:read("*a")
	pipe:close()
	return output:match("^([^\r\n]*)") or ""
end

local utf8_string = intern("UTF8_STRING")
local failures = 0

--- Compares the native answer with xdotool's for the active window.
--- @param label string
--- @param window integer
local function compare(label, window)
	activate(window)
	local id, title, owner = Focus.query()
	local tool_id = ask_tool("xdotool getactivewindow")
	local tool_title = ask_tool("xdotool getwindowname " .. tool_id)
	local tool_owner = ask_tool("xdotool getwindowpid " .. tool_id)
	-- An untitled window is "no answer" natively and an empty line from xdotool.
	local same = (id or tool_id) == tool_id and (title or "") == tool_title and (owner or "") == tool_owner
	if title == nil and tool_title ~= "" then same = false end
	print(string.format("%-24s native={%s,%q,%s} xdotool={%s,%q,%s} %s", label, tostring(id), tostring(title),
		tostring(owner), tool_id, tool_title, tool_owner, same and "SAME" or "DIFFERENT"))
	if not same then failures = failures + 1 end
end

local utf8_window = new_window()
local utf8_title = "Ergopti \195\169t\195\169 focus"
set(utf8_window, "_NET_WM_NAME", utf8_string, 8, utf8_title, #utf8_title)
set(utf8_window, "_NET_WM_PID", ATOM_CARDINAL, 32, ffi.new("uint32_t[1]", tonumber(luv.os_getpid())), 1)
compare("UTF-8 title and owner", utf8_window)

local latin1_window = new_window()
set(latin1_window, "WM_NAME", ATOM_STRING, 8, "plain latin1 caf\233", 16)
compare("WM_NAME only", latin1_window)

local multiline_window = new_window()
local multiline_title = "first line\nsecond line"
set(multiline_window, "_NET_WM_NAME", utf8_string, 8, multiline_title, #multiline_title)
compare("multi-line title", multiline_window)

compare("no title", new_window())

print(failures == 0 and "ALL SAME" or ("DIFFERENCES: " .. failures))
os.exit(failures == 0 and 0 or 1)
