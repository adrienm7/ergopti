--- tray/adapters/status_notifier_host.lua

--- ==============================================================================
--- MODULE: Tray Host Probe (Linux)
--- DESCRIPTION:
--- Asks the session whether anything shows tray icons: a StatusNotifierWatcher
--- with a registered host (KDE Plasma, GNOME with the AppIndicator extension,
--- most panels), or an XEmbed system tray (older X11 panels, which draw the
--- GtkStatusIcon libayatana falls back to).
---
--- FEATURES & RATIONALE:
--- 1. libayatana creates its icon whether or not anything shows it: without a
---    watcher it falls back to a GtkStatusIcon, which no Wayland session and no
---    recent GNOME embeds. The daemon logged « Tray icon created » and the user
---    had no icon and no menu, with nothing said (TRAY-03). This probe is what
---    tray/engine/host_check.lua decides from.
--- 2. Bounded and read-only: two synchronous session-bus calls bounded by
---    [ui] tray_host_bus_timeout_ms, never an auto-start of the watcher, and one
---    X selection read.
--- 3. A probe that cannot run says so (nil and a reason) instead of answering
---    « no host », which would tell a user whose tray works that it is missing.
--- ==============================================================================

local M = {}

local Runtime = require("_generated.native_runtime")
local Timings = require("core.timing.engine.timings")

--- The well-known name of the StatusNotifierItem watcher every SNI host uses.
M.WATCHER_NAME = "org.kde.StatusNotifierWatcher"

local WATCHER_PATH = "/StatusNotifierWatcher"
local DBUS_NAME = "org.freedesktop.DBus"
local DBUS_PATH = "/org/freedesktop/DBus"
local PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties"
-- GBusType and GDBusCallFlags (gio/gioenums.h).
local G_BUS_TYPE_SESSION = 2
local G_DBUS_CALL_FLAGS_NO_AUTO_START = 1

local _native = nil




-- ==============================================
-- ==============================================
-- ======= 1/ Binding ===========================
-- ==============================================
-- ==============================================

--- Binds libgio and libX11 once.
--- @return table|nil native { ffi, gio, x11 }; x11 is nil when libX11 is absent.
--- @return string|nil reason Why the session bus cannot be read.
local function bind()
	if _native then return _native end
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil, "no LuaJIT FFI" end
	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		typedef struct { uint32_t domain; int code; char *message; } ErgoptiSniGError;
		void *g_bus_get_sync(int bus_type, void *cancellable, ErgoptiSniGError **error);
		void *g_dbus_connection_call_sync(void *connection, const char *bus_name, const char *path,
			const char *iface, const char *method, void *parameters, void *reply_type, int flags,
			int timeout_ms, void *cancellable, ErgoptiSniGError **error);
		void *g_variant_new_string(const char *value);
		void *g_variant_new_tuple(void **children, size_t count);
		void *g_variant_get_child_value(void *value, size_t index);
		void *g_variant_get_variant(void *value);
		int g_variant_get_boolean(void *value);
		int g_variant_is_of_type(void *value, const void *type);
		void *g_variant_type_new(const char *type_string);
		void g_variant_type_free(void *type);
		void g_variant_unref(void *value);
		void g_error_free(ErgoptiSniGError *error);
		void g_object_unref(void *object);
		typedef struct _XDisplay ErgoptiSniDisplay;
		ErgoptiSniDisplay *XOpenDisplay(const char *name);
		int XDefaultScreen(ErgoptiSniDisplay *display);
		unsigned long XInternAtom(ErgoptiSniDisplay *display, const char *name, int only_if_exists);
		unsigned long XGetSelectionOwner(ErgoptiSniDisplay *display, unsigned long selection);
		int XCloseDisplay(ErgoptiSniDisplay *display);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		return nil, "ffi.cdef refused: " .. tostring(cdef_err)
	end
	local ok_gio, gio = pcall(ffi.load, Runtime.network_runtime.libraries.gio)
	if not ok_gio then return nil, tostring(gio) end
	local ok_x11, x11 = pcall(ffi.load, Runtime.x11)
	_native = { ffi = ffi, gio = gio, x11 = ok_x11 and x11 or nil }
	return _native
end




-- ==============================================
-- ==============================================
-- ======= 2/ Session bus =======================
-- ==============================================
-- ==============================================

--- One bounded call; the reply, or nil and the bus error.
local function call(native, connection, bus_name, path, iface, method, strings)
	local ffi, gio = native.ffi, native.gio
	local children = ffi.new("void *[?]", #strings)
	for index, text in ipairs(strings) do children[index - 1] = gio.g_variant_new_string(text) end
	local slot = ffi.new("ErgoptiSniGError *[1]")
	local reply = gio.g_dbus_connection_call_sync(connection, bus_name, path, iface, method,
		gio.g_variant_new_tuple(children, #strings), nil, G_DBUS_CALL_FLAGS_NO_AUTO_START,
		Timings.ms("ui", "tray_host_bus_timeout_ms"), nil, slot)
	if slot[0] ~= nil then
		local message = ffi.string(slot[0].message)
		gio.g_error_free(slot[0])
		return nil, message
	end
	return reply
end

--- The boolean of a reply, unwrapping one variant level when asked.
local function reply_boolean(native, reply, wrapped)
	local gio = native.gio
	local child = gio.g_variant_get_child_value(reply, 0)
	local value = child
	if wrapped then value = gio.g_variant_get_variant(child) end
	local boolean_type = gio.g_variant_type_new("b")
	local typed = gio.g_variant_is_of_type(value, boolean_type) ~= 0
	gio.g_variant_type_free(boolean_type)
	local result = nil
	if typed then result = gio.g_variant_get_boolean(value) ~= 0 end
	if wrapped then gio.g_variant_unref(value) end
	gio.g_variant_unref(child)
	gio.g_variant_unref(reply)
	return result
end

--- Reads the watcher's presence and whether a host registered with it.
--- @return boolean|nil watcher, boolean|nil host, string|nil reason
local function read_watcher(native)
	local ffi, gio = native.ffi, native.gio
	local slot = ffi.new("ErgoptiSniGError *[1]")
	local connection = gio.g_bus_get_sync(G_BUS_TYPE_SESSION, nil, slot)
	if slot[0] ~= nil or connection == nil then
		local message = slot[0] ~= nil and ffi.string(slot[0].message) or "no connection"
		if slot[0] ~= nil then gio.g_error_free(slot[0]) end
		return nil, nil, "session bus unavailable: " .. message
	end
	local owned_reply, owned_err = call(native, connection, DBUS_NAME, DBUS_PATH, DBUS_NAME, "NameHasOwner",
		{ M.WATCHER_NAME })
	if owned_reply == nil then
		gio.g_object_unref(connection)
		return nil, nil, "NameHasOwner refused: " .. tostring(owned_err)
	end
	local watcher = reply_boolean(native, owned_reply, false)
	local host = nil
	if watcher then
		local host_reply = call(native, connection, M.WATCHER_NAME, WATCHER_PATH, PROPERTIES_INTERFACE, "Get",
			{ M.WATCHER_NAME, "IsStatusNotifierHostRegistered" })
		-- A watcher that does not answer the property is taken at its word:
		-- the name is only owned by something that hosts icons.
		if host_reply ~= nil then host = reply_boolean(native, host_reply, true) end
	end
	gio.g_object_unref(connection)
	return watcher, host, nil
end

--- Whether an X11 system tray manager owns its selection on the default screen.
--- @return boolean
local function read_xembed(native)
	if native.x11 == nil or (os.getenv("DISPLAY") or "") == "" then return false end
	local x11 = native.x11
	local display = x11.XOpenDisplay(nil)
	if display == nil then return false end
	local selection = "_NET_SYSTEM_TRAY_S" .. tostring(x11.XDefaultScreen(display))
	local atom = x11.XInternAtom(display, selection, 1)
	local owned = atom ~= 0 and x11.XGetSelectionOwner(display, atom) ~= 0
	x11.XCloseDisplay(display)
	return owned
end




-- ==============================================
-- ==============================================
-- ======= 3/ Probe =============================
-- ==============================================
-- ==============================================

--- Reads what shows tray icons in this session.
--- @return table|nil facts { watcher = boolean, host = boolean|nil, xembed = boolean };
---   host is nil when the watcher is absent or does not answer the property.
--- @return string|nil reason Why the session could not be read.
function M.probe()
	local native, reason = bind()
	if not native then return nil, reason end
	local watcher, host, failure = read_watcher(native)
	if watcher == nil then return nil, failure end
	return { watcher = watcher, host = host, xembed = read_xembed(native) }, nil
end

return M
