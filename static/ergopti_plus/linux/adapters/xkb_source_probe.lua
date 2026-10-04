--- adapters/xkb_source_probe.lua

--- ==============================================================================
--- MODULE: Native X11 Physical Source Qualification
--- DESCRIPTION:
--- Owns a lazy native connection and acknowledges the actual server keymap and
--- group before conditional shortcut acquisition or delivery. XKB event receipts
--- fence away-and-back changes. There is no competing timer or layout watcher.
--- ==============================================================================

local M = {}
local DisplayServer = require("infra.display_server")
local Logger = require("logger.shim")
local LOG = "adapters.xkb_source_probe"
local Runtime = require("_generated.native_runtime")

local _native, _connection, _display_name = nil, nil, nil
local _generation, _last_keymap, _last_group = 0, nil, nil
local _last_canonical_keymap = nil
local _last_expected, _last_canonical_expected = nil, nil
local CORE_KEYBOARD = 0x100
local GROUP_COMPONENTS = 0xf0
local SOURCE_EVENTS = 0x7





-- =========================================
-- =========================================
-- ======= 1/ Native connection ============
-- =========================================
-- =========================================

local function bind()
	if _native then return _native end
	local ok, ffi = pcall(require, "ffi")
	if not ok then return nil, "native-ffi-unavailable" end
	local declared, detail = pcall(ffi.cdef, [[
		struct _XDisplay;
		struct xcb_connection_t;
		struct xkb_context;
		struct xkb_keymap;
		typedef struct {
			unsigned char group, locked_group;
			unsigned short base_group, latched_group;
			unsigned char mods, base_mods, latched_mods, locked_mods, compat_state;
			unsigned char grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods;
			unsigned short ptr_buttons;
		} ErgoptiXkbState;
		typedef struct {
			int type; unsigned long serial; int send_event; struct _XDisplay *display;
			unsigned long time; int xkb_type; int device; unsigned int changed;
			int group, base_group, latched_group, locked_group;
			unsigned int mods, base_mods, latched_mods, locked_mods;
			int compat_state;
			unsigned char grab_mods, compat_grab_mods, lookup_mods, compat_lookup_mods;
			int ptr_buttons; unsigned char keycode; char event_type, req_major, req_minor;
		} ErgoptiXkbStateEvent;
		typedef union { long pad[24]; ErgoptiXkbStateEvent state; } ErgoptiXkbEvent;
		struct _XDisplay *XOpenDisplay(const char *display);
		int XCloseDisplay(struct _XDisplay *display);
		int XSync(struct _XDisplay *display, int discard);
		int XPending(struct _XDisplay *display);
		int XNextEvent(struct _XDisplay *display, ErgoptiXkbEvent *event);
		int XkbQueryExtension(struct _XDisplay *, int *, int *, int *, int *, int *);
		int XkbGetState(struct _XDisplay *, unsigned int, ErgoptiXkbState *);
		int XkbSelectEvents(struct _XDisplay *, unsigned int, unsigned int, unsigned int);
		int XkbSelectEventDetails(struct _XDisplay *, unsigned int, unsigned int, unsigned long, unsigned long);
		struct xcb_connection_t *XGetXCBConnection(struct _XDisplay *display);
		int xkb_x11_setup_xkb_extension(struct xcb_connection_t *, unsigned short, unsigned short, int,
			unsigned short *, unsigned short *, unsigned char *, unsigned char *);
		int xkb_x11_get_core_keyboard_device_id(struct xcb_connection_t *);
		struct xkb_keymap *xkb_x11_keymap_new_from_device(struct xkb_context *, struct xcb_connection_t *, int, int);
		struct xkb_context *xkb_context_new(int flags);
		void xkb_context_unref(struct xkb_context *context);
		void xkb_keymap_unref(struct xkb_keymap *keymap);
		struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *, const char *, int, int);
		char *xkb_keymap_get_as_string(struct xkb_keymap *keymap, int format);
		void free(void *pointer);
	]])
	if not declared and not tostring(detail):find("redefin", 1, true) then return nil, "native-declarations-refused" end
	local bound, native = pcall(function()
		return { ffi = ffi, x11 = ffi.load(Runtime.x11), bridge = ffi.load(Runtime.x11_xcb),
			xkb = ffi.load(Runtime.xkbcommon), xkb11 = ffi.load(Runtime.xkbcommon_x11), bit = require("bit") }
	end)
	if not bound then return nil, "native-x11-libraries-unavailable" end
	_native = native
	return native
end

--- Releases only the native connection owned by this adapter.
function M.close()
	if _connection then
		_native.xkb.xkb_context_unref(_connection.context)
		_native.x11.XCloseDisplay(_connection.display)
		Logger.info(LOG, "Closed the native X11 source connection.")
	end
	_connection, _display_name, _last_keymap, _last_group = nil, nil, nil, nil
	_last_canonical_keymap = nil
	_last_expected, _last_canonical_expected = nil, nil
	_generation = _generation + 1
end

local function connect(native, display_name)
	if _connection and _display_name == display_name then return _connection end
	if _connection then M.close() end
	local display = native.x11.XOpenDisplay(display_name)
	if display == nil then return nil, "native-display-unavailable" end
	local ffi = native.ffi
	local opcode, event, failure = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
	local major, minor = ffi.new("int[1]", 1), ffi.new("int[1]", 0)
	if native.x11.XkbQueryExtension(display, opcode, event, failure, major, minor) == 0 then
		native.x11.XCloseDisplay(display)
		return nil, "native-xkb-unavailable"
	end
	local xcb = native.bridge.XGetXCBConnection(display)
	if xcb == nil or native.xkb11.xkb_x11_setup_xkb_extension(xcb, 1, 0, 0, nil, nil, nil, nil) == 0 then
		native.x11.XCloseDisplay(display)
		return nil, "native-xkb-connection-unavailable"
	end
	local context = native.xkb.xkb_context_new(0)
	if context == nil then native.x11.XCloseDisplay(display) return nil, "native-context-unavailable" end
	if native.x11.XkbSelectEvents(display, CORE_KEYBOARD, SOURCE_EVENTS, SOURCE_EVENTS) == 0
		or native.x11.XkbSelectEventDetails(display, CORE_KEYBOARD, 2, GROUP_COMPONENTS, GROUP_COMPONENTS) == 0 then
		native.xkb.xkb_context_unref(context)
		native.x11.XCloseDisplay(display)
		return nil, "native-source-events-unavailable"
	end
	_connection = { display = display, xcb = xcb, context = context, event_base = tonumber(event[0]) }
	_display_name = display_name
	_generation = _generation + 1
	Logger.info(LOG, "Opened the native X11 source connection with group and keymap event ownership.")
	return _connection
end





-- =========================================
-- =========================================
-- ======= 2/ Acknowledged receipts ========
-- =========================================
-- =========================================

local function drain(native, connection)
	native.x11.XSync(connection.display, 0)
	local event = native.ffi.new("ErgoptiXkbEvent[1]")
	while native.x11.XPending(connection.display) > 0 do
		native.x11.XNextEvent(connection.display, event)
		local state = event[0].state
		if tonumber(state.type) == connection.event_base then
			local kind = tonumber(state.xkb_type)
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), GROUP_COMPONENTS) ~= 0) then
				_generation = _generation + 1
			end
		end
	end
end

--- Orders complete alias declarations without changing any alias name or target.
--- The codec preserves declaration order, which differs between X11 and xkbcomp.
local function ordered_aliases(text)
	local result, sections = text:gsub("(xkb_keycodes[^\n]*{\n)(.-)(\n};)", function(header, body, footer)
		body = body .. "\n"
		local aliases = {}
		-- Native serializers align alias columns; only horizontal spacing is syntax.
		local declaration = "\talias[ \t]+<[^<>\n]+>[ \t]+=[ \t]+<[^<>\n]+>;\n"
		for line in body:gmatch(declaration) do aliases[#aliases + 1] = line end
		table.sort(aliases)
		local index = 0
		body = body:gsub(declaration, function()
			index = index + 1
			return aliases[index]
		end)
		return header .. body .. footer:sub(2)
	end)
	return sections == 1 and result or nil
end

--- Projects native serialization through the capture owner's exact parser codec.
--- X11 may retain unreferenced types and interprets that a parsed map omits.
local function canonical_keymap(native, connection, text)
	local keymap = native.xkb.xkb_keymap_new_from_string(connection.context, text, 1, 0)
	if keymap == nil then return nil end
	local bytes = native.xkb.xkb_keymap_get_as_string(keymap, 1)
	local canonical = bytes ~= nil and native.ffi.string(bytes) or nil
	if bytes ~= nil then native.ffi.C.free(bytes) end
	native.xkb.xkb_keymap_unref(keymap)
	return canonical and ordered_aliases(canonical) or nil
end

--- Reads actual native server state, requiring the capture owner's exact map.
--- @param expected string Canonical serialization of the loaded native keymap.
--- @param groups integer Number of groups in that loaded native keymap.
--- @return table|nil receipt { group, generation, backend }.
--- @return string|nil reason Native qualification refusal.
function M.read(expected, groups)
	assert(type(expected) == "string" and expected ~= "", "the acknowledged keymap identity is required")
	assert(type(groups) == "number" and groups >= 1 and groups % 1 == 0, "the native group count is required")
	local display_name = os.getenv("DISPLAY")
	if not display_name or display_name == "" then
		if _connection then M.close() end
		return nil, "native-display-unavailable"
	end
	if DisplayServer.is_wayland() then return nil, "native-wayland-seat-unqualified" end
	local native, reason = bind()
	if not native then return nil, reason end
	local connection
	connection, reason = connect(native, display_name)
	if not connection then return nil, reason end
	drain(native, connection)
	local before, after = native.ffi.new("ErgoptiXkbState[1]"), native.ffi.new("ErgoptiXkbState[1]")
	if native.x11.XkbGetState(connection.display, CORE_KEYBOARD, before) ~= 0 then return nil, "native-group-unavailable" end
	local device = native.xkb11.xkb_x11_get_core_keyboard_device_id(connection.xcb)
	if device < 0 then return nil, "native-keyboard-unavailable" end
	local keymap = native.xkb11.xkb_x11_keymap_new_from_device(connection.context, connection.xcb, device, 0)
	if keymap == nil then return nil, "native-keymap-unavailable" end
	local bytes = native.xkb.xkb_keymap_get_as_string(keymap, 1)
	local actual = bytes ~= nil and native.ffi.string(bytes) or nil
	if bytes ~= nil then native.ffi.C.free(bytes) end
	native.xkb.xkb_keymap_unref(keymap)
	if native.x11.XkbGetState(connection.display, CORE_KEYBOARD, after) ~= 0 then return nil, "native-group-unavailable" end
	local group = tonumber(after[0].group)
	if tonumber(before[0].group) ~= group then drain(native, connection) return nil, "native-group-raced" end
	if actual == nil then return nil, "native-keymap-identity-unavailable" end
	if actual ~= _last_keymap then
		local canonical = canonical_keymap(native, connection, actual)
		if canonical == nil then return nil, "native-keymap-canonicalization-refused" end
		_last_canonical_keymap = canonical
	end
	if actual ~= _last_keymap or group ~= _last_group then
		_last_keymap, _last_group = actual, group
		_generation = _generation + 1
	end
	local acknowledged_epoch = _generation
	drain(native, connection)
	if _generation ~= acknowledged_epoch then return nil, "native-source-raced" end
	if expected ~= _last_expected then
		local canonical = ordered_aliases(expected)
		if canonical == nil then return nil, "native-keymap-canonicalization-refused" end
		_last_expected, _last_canonical_expected = expected, canonical
	end
	if _last_canonical_keymap ~= _last_canonical_expected then return nil, "native-keymap-unacknowledged" end
	if group < 0 or group >= groups then return nil, "native-group-outside-keymap" end
	return { group = group, generation = _generation, backend = "x11" }
end

return M
