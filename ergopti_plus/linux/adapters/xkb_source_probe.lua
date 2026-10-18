--- adapters/xkb_source_probe.lua

--- ==============================================================================
--- MODULE: Native X11 Physical Source Qualification
--- DESCRIPTION:
--- Owns a lazy native connection and acknowledges the actual server keymap and
--- group before conditional shortcut acquisition or delivery. XKB event receipts
--- fence away-and-back changes. There is no competing timer or layout watcher.
--- ==============================================================================

local M = {}
local number_row_sources = setmetatable({}, { __mode = "k" })
local asynchronous_number_row_sources = setmetatable({}, { __mode = "k" })
local DisplayServer = require("infra.display_server")
local Logger = require("logger.shim")
local LOG = "adapters.xkb_source_probe"
local Runtime = require("_generated.native_runtime")

local _native, _connection, _display_name = nil, nil, nil
local receiving_controllers = setmetatable({}, { __mode = "k" })
local original_receiving_capture = nil
local receiving_declared = setmetatable({}, { __mode = "k" })
local _retiring_connection, _construction, _closing, _binding = nil, nil, nil, nil
local _property_facts = { status = "unavailable", reason = "native-xi-undeclared" }
local _generation, _last_keymap, _last_group = 0, nil, nil
local _locked_generation, _last_locked = 0, nil
local _input_generation, _last_input = 0, nil
local _last_canonical_keymap = nil
local _last_expected, _last_canonical_expected = nil, nil
local CORE_KEYBOARD = 0x100
local GROUP_COMPONENTS = 0xf0
local LOCKED_COMPONENT = 0x8
local INPUT_COMPONENTS = 0xf -- Effective, depressed, latched and locked masks.
local OBSERVED_COMPONENTS = GROUP_COMPONENTS + INPUT_COMPONENTS
local SOURCE_EVENTS = 0x7





-- =========================================
-- =========================================
-- ======= 1/ Native connection ============
-- =========================================
-- =========================================

--- Declares property invalidation only; the original XKB event buffer is unchanged.
local function declare_property_abi(ffi)
	local declared = pcall(ffi.cdef, [[
		typedef struct {
			int type; unsigned long serial; int send_event; struct _XDisplay *display;
			int extension, evtype; unsigned int cookie; void *data;
		} ErgoptiXIPropertyCookieV2;
		typedef struct {
			int type; unsigned long serial; int send_event; struct _XDisplay *display;
			int extension, evtype; unsigned long time; int deviceid;
			unsigned long property; int what;
		} ErgoptiXIPropertyEventV2;
		typedef struct { int deviceid, mask_len; unsigned char *mask; } ErgoptiXIPropertyMaskV2;
		int XQueryExtension(struct _XDisplay *, const char *, int *, int *, int *);
		int XIQueryVersion(struct _XDisplay *, int *, int *);
		int XISelectEvents(struct _XDisplay *, unsigned long, ErgoptiXIPropertyMaskV2 *, int);
		int XGetEventData(struct _XDisplay *, ErgoptiXIPropertyCookieV2 *);
		void XFreeEventData(struct _XDisplay *, ErgoptiXIPropertyCookieV2 *);
	]])
	local complete = pcall(function()
		assert(ffi.sizeof("ErgoptiXIPropertyCookieV2") <= ffi.sizeof("ErgoptiXkbEvent"))
		ffi.typeof("ErgoptiXIPropertyEventV2")
		ffi.typeof("ErgoptiXIPropertyMaskV2")
		assert(ffi.offsetof("ErgoptiXIPropertyEventV2", "property") > ffi.offsetof("ErgoptiXIPropertyEventV2", "deviceid"))
	end)
	return (declared or complete) and complete
end

--- Accepts Lua test ports or FFI function/function-pointer ctypes, never handles.
--- Symbol resolution and type conversion are protected by the binding caller.
local function required_port(ffi, owner, name)
	local port = owner[name]
	if type(port) == "function" then return port end
	if type(port) == "cdata" and port ~= nil then
		local signature = tostring(ffi.typeof(port))
		if signature:match("^ctype<[^{}()]+%([^()]*%)>$")
			or signature:match("^ctype<[^{}()]+%(%*%)%([^()]*%)>$") then return port end
	end
	error("required native port is not callable: " .. name)
end

--- Captures all construction, queue and cookie cleanup ports before any open.
local function resolve_ports(native)
	local ffi = native.ffi
	local specs = {
		{ "open", native.x11, "XOpenDisplay" }, { "close", native.x11, "XCloseDisplay" },
		{ "query_xkb", native.x11, "XkbQueryExtension" },
		{ "select_xkb", native.x11, "XkbSelectEvents" },
		{ "select_details", native.x11, "XkbSelectEventDetails" },
		{ "xcb", native.bridge, "XGetXCBConnection" },
		{ "setup", native.xkb11, "xkb_x11_setup_xkb_extension" },
		{ "context", native.xkb, "xkb_context_new" }, { "unref", native.xkb, "xkb_context_unref" },
		{ "sync", native.x11, "XSync" }, { "pending", native.x11, "XPending" },
		{ "next", native.x11, "XNextEvent" }, { "new", ffi, "new" }, { "cast", ffi, "cast" },
	}
	if native.xi then
		specs[#specs + 1] = { "query_xi", native.x11, "XQueryExtension" }
		specs[#specs + 1] = { "root", native.x11, "XDefaultRootWindow" }
		specs[#specs + 1] = { "version_xi", native.xi, "XIQueryVersion" }
		specs[#specs + 1] = { "select_xi", native.xi, "XISelectEvents" }
		specs[#specs + 1] = { "get", native.x11, "XGetEventData" }
		specs[#specs + 1] = { "free", native.x11, "XFreeEventData" }
	end
	local ports = { specs = specs }
	for _, spec in ipairs(specs) do ports[spec[1]] = required_port(ffi, spec[2], spec[3]) end
	return ports
end

--- External symbol reads precede the final private bundle identity check.
local function ports_current(native)
	local called, current = pcall(function()
		for _, spec in ipairs(native.ports.specs) do
			if spec[2][spec[3]] ~= native.ports[spec[1]] then return false end
		end
		return true
	end)
	return called and current == true and _native == native
end

local function bind_native()
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
		unsigned long XDefaultRootWindow(struct _XDisplay *display);
		unsigned long XInternAtom(struct _XDisplay *display, const char *name, int only_if_exists);
		int XGetWindowProperty(struct _XDisplay *, unsigned long, unsigned long, long, long, int,
			unsigned long, unsigned long *, int *, unsigned long *, unsigned long *, unsigned char **);
		int XFree(void *pointer);
		struct ErgoptiNumberRowNames { const char *rules, *model, *layout, *variant, *options; };
		void xkb_context_set_log_level(struct xkb_context *context, int level);
		void xkb_context_include_path_clear(struct xkb_context *context);
		int xkb_context_include_path_append(struct xkb_context *context, const char *path);
		int xkb_context_include_path_append_default(struct xkb_context *context);
		struct xkb_keymap *xkb_keymap_new_from_names(struct xkb_context *, const struct ErgoptiNumberRowNames *, int);
		unsigned int xkb_keymap_num_layouts(struct xkb_keymap *keymap);
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
	local xi_name = rawget(Runtime, "xi")
	if xi_name ~= nil then
		if type(xi_name) ~= "string" or xi_name == "" then return nil, "native-xi-declaration-refused" end
		if not declare_property_abi(ffi) then return nil, "native-xi-declarations-refused" end
		local xi_bound, xi = pcall(ffi.load, xi_name)
		if not xi_bound or xi == nil then return nil, "native-xi-library-unavailable" end
		native.xi = xi
	end
	local resolved, ports = pcall(resolve_ports, native)
	if not resolved then return nil, "native-required-ports-refused" end
	native.ports = ports
	_native = native
	return native
end

--- Binding cannot recursively publish a second bundle during symbol lookup.
local function bind()
	if _binding then return nil, "native-binding-busy" end
	local attempt, previous = {}, _native
	_binding = attempt
	local called, native, reason = pcall(bind_native)
	local current = _binding == attempt and not attempt.cancelled
	_binding = nil
	if not called or not current then _native = previous; return nil, "native-binding-refused" end
	return native, reason
end

--- Keeps the physical Display alive until drain/cookie/cleanup custody is settled.
--- Closing admission spans Logger sinks even after the retired roster is cleared.
local function finish_retirement(connection)
	if connection.receiving then
		for controller in pairs(connection.receiving) do
			if controller.retire() ~= true then return false end
		end
	end
	if _closing or connection.draining or connection.borrowed ~= 0 or connection.cookie_debt
		or connection.cleanup_debt or connection.acquisition_debt or connection.cleanup_running then return false end
	local closing = {}
	_closing, connection.cleanup_running = closing, true
	if not connection.context_released then
		local called, value = pcall(connection.unref_context, connection.context)
		if not called or value ~= nil then
			connection.cleanup_debt = true; connection.cleanup_running = false; _closing = nil; return false
		end
		connection.context_released = true
	end
	if not connection.display_closed then
		local called, status = pcall(connection.close_display, connection.display)
		if not called or status ~= 0 then
			connection.cleanup_debt = true; connection.cleanup_running = false; _closing = nil; return false
		end
		connection.display_closed = true
	end
	connection.cleanup_running = false
	if _retiring_connection == connection then _retiring_connection = nil end
	pcall(Logger.info, LOG, "Closed the native X11 source connection.")
	if _closing == closing then _closing = nil end
	return true
end

--- Internal retirement preserves an exact ongoing construction attempt.
local function retire_published()
	local connection = _connection
	_connection, _display_name, _last_keymap, _last_group = nil, nil, nil, nil
	_last_canonical_keymap = nil
	_last_expected, _last_canonical_expected = nil, nil
	_generation = _generation + 1
	_locked_generation, _last_locked = _locked_generation + 1, nil
	_input_generation, _last_input = _input_generation + 1, nil
	_property_facts = { status = "unavailable", reason = "native-property-connection-retired" }
	if connection then connection.retired = true; _retiring_connection = connection end
	if _retiring_connection then
		finish_retirement(_retiring_connection)
		if _retiring_connection then
			_property_facts = { status = "retiring", reason = "native-cookie-retirement-pending" }
		end
	end
end

--- Public close cancels unpublished construction; returned handles are disposed
--- after the active call unwinds, never guessed absent during that call.
function M.close()
	if _binding then _binding.cancelled = true end
	if _construction then _construction.cancelled = true end
	retire_published()
end

local function construction_current(native, attempt)
	local current = ports_current(native)
	return current and _construction == attempt and not attempt.cancelled
		and _closing == nil and _retiring_connection == nil and _connection == nil
end

local function abandon_construction(attempt)
	local connection = attempt.owner
	connection.retired = true
	if connection.display ~= nil or connection.acquisition_debt then
		_retiring_connection = connection
		finish_retirement(connection)
		if _retiring_connection then
			_property_facts = { status = "retiring", reason = "native-construction-retirement-pending" }
		end
	end
end

local function connect(native, display_name)
	if _construction or _closing then return nil, "native-connection-busy" end
	if _retiring_connection then return nil, "native-cookie-retirement-pending" end
	if _connection and _display_name == display_name then return _connection end
	local ports = native.ports
	local connection = { native = native, lifetime = {}, cursor = 0, borrowed = 0,
		unref_context = ports.unref, close_display = ports.close,
		get_cookie = ports.get, free_cookie = ports.free, cast = ports.cast,
		sync = ports.sync, pending = ports.pending, next_event = ports.next,
		context_released = true, display_closed = true }
	local attempt = { owner = connection }
	_construction = attempt
	if _connection then retire_published() end
	local called, reason = pcall(function()
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		local opened, display = pcall(ports.open, display_name)
		if not opened then connection.acquisition_debt = true; return "native-display-acquisition-unresolved" end
		if display == nil then return "native-display-unavailable" end
		connection.display, connection.display_closed = display, false
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		local opcode, event, failure = ports.new("int[1]"), ports.new("int[1]"), ports.new("int[1]")
		local major, minor = ports.new("int[1]", 1), ports.new("int[1]", 0)
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		if ports.query_xkb(display, opcode, event, failure, major, minor) == 0 then return "native-xkb-unavailable" end
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		local xcb = ports.xcb(display)
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		if xcb == nil or ports.setup(xcb, 1, 0, 0, nil, nil, nil, nil) == 0 then return "native-xkb-connection-unavailable" end
		connection.xcb = xcb
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		local allocated, context = pcall(ports.context, 0)
		if not allocated then connection.acquisition_debt = true; return "native-context-acquisition-unresolved" end
		if context == nil then return "native-context-unavailable" end
		connection.context, connection.context_released = context, false
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		if ports.select_xkb(display, CORE_KEYBOARD, SOURCE_EVENTS, SOURCE_EVENTS) == 0 then return "native-source-events-unavailable" end
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		if ports.select_details(display, CORE_KEYBOARD, 2, OBSERVED_COMPONENTS, OBSERVED_COMPONENTS) == 0 then return "native-source-events-unavailable" end
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
		if native.xi then
			local extension, xi_event, xi_error = ports.new("int[1]"), ports.new("int[1]"), ports.new("int[1]")
			local xi_major, xi_minor = ports.new("int[1]", 2), ports.new("int[1]", 0)
			local mask = ports.new("unsigned char[2]")
			mask[1] = 16 -- XI_PropertyEvent (12), native XI2.h bit; no input event selection.
			local selected = ports.new("ErgoptiXIPropertyMaskV2[1]")
			selected[0].deviceid, selected[0].mask_len, selected[0].mask = 0, 2, mask -- XIAllDevices.
			if not construction_current(native, attempt) then return "native-construction-owner-retired" end
			if ports.query_xi(display, "XInputExtension", extension, xi_event, xi_error) == 0 then return "native-property-events-unavailable" end
			if not construction_current(native, attempt) then return "native-construction-owner-retired" end
			if ports.version_xi(display, xi_major, xi_minor) ~= 0 or tonumber(xi_major[0]) < 2 then return "native-property-events-unavailable" end
			if not construction_current(native, attempt) then return "native-construction-owner-retired" end
			local root = ports.root(display)
			if not construction_current(native, attempt) then return "native-construction-owner-retired" end
			if ports.select_xi(display, root, selected, 1) ~= 0 then return "native-property-events-unavailable" end
			if not construction_current(native, attempt) then return "native-construction-owner-retired" end
			connection.xi_opcode = tonumber(extension[0])
		end
		connection.event_base = tonumber(event[0])
		connection.xkb_opcode = tonumber(opcode[0])
		if not construction_current(native, attempt) then return "native-construction-owner-retired" end
	end)
	if not called or reason then
		abandon_construction(attempt)
		if _construction == attempt then _construction = nil end
		return nil, called and reason or "native-construction-refused"
	end
	_connection, _display_name = connection, display_name
	_property_facts = { status = "unavailable", reason = connection.xi_opcode and "native-property-unobserved" or "native-xi-undeclared" }
	_generation = _generation + 1
	_locked_generation, _last_locked = _locked_generation + 1, nil
	_input_generation, _last_input = _input_generation + 1, nil
	local logged = pcall(Logger.info, LOG, "Opened the native X11 source connection with group and keymap event ownership.")
	local ports_match = ports_current(native)
	local current = logged and ports_match and _construction == attempt and not attempt.cancelled
		and _connection == connection and not connection.retired and _retiring_connection == nil and _closing == nil
	if not current then
		if _connection == connection then retire_published() end
		if _construction == attempt then _construction = nil end
		return nil, "native-construction-owner-retired"
	end
	_construction = nil
	return connection
end




-- =========================================
-- =========================================
-- ======= 2/ Acknowledged receipts ========
-- =========================================
-- =========================================

--- Checks unsigned native values before any lossy Lua-number conversion.
local function scalar_unsigned(value, maximum)
	if value < 0 or value > maximum then return nil end
	local scalar = tonumber(value)
	if not scalar or scalar < 0 or scalar > maximum or scalar % 1 ~= 0 then return nil end
	return scalar
end

local function connection_current(native, connection, lifetime, cursor)
	local current = ports_current(native)
	return current and _connection == connection and not connection.retired
		and not connection.cookie_debt and connection.lifetime == lifetime and connection.cursor == cursor
		and connection.draining == true and _retiring_connection == nil and _construction == nil and _closing == nil
end

--- Borrows only the original Display and frees exactly once after successful get.
--- Initialized scalar copies are detached; payload.display is deliberately unread.
local function property_cookie(native, connection, event)
	local lifetime, cursor = connection.lifetime, connection.cursor
	local cookie = connection.cast("ErgoptiXIPropertyCookieV2 *", event)
	if not connection_current(native, connection, lifetime, cursor)
		or tonumber(cookie[0].type) ~= 35 or cookie[0].display ~= connection.display
		or tonumber(cookie[0].send_event) ~= 0 or tonumber(cookie[0].extension) ~= connection.xi_opcode
		or tonumber(cookie[0].evtype) ~= 12 then return nil, "native-property-envelope-refused" end
	connection.borrowed = connection.borrowed + 1
	local fetched, acquired = pcall(connection.get_cookie, connection.display, cookie)
	if not fetched or (acquired ~= 0 and acquired ~= 1) then
		connection.cookie_debt = true; M.close()
		return nil, "native-cookie-acquisition-unresolved"
	end
	if acquired == 0 then
		connection.borrowed = connection.borrowed - 1
		return nil, "native-property-cookie-unavailable"
	end
	local copied, facts = pcall(function()
		if not connection_current(native, connection, lifetime, cursor) or cookie[0].data == nil then return nil end
		local body = connection.cast("ErgoptiXIPropertyEventV2 *", cookie[0].data)[0]
		-- libXi wireToPropertyEvent initializes these fields, not payload.display.
		if tonumber(body.type) ~= 35 or tonumber(body.send_event) ~= 0
			or tonumber(body.extension) ~= connection.xi_opcode or tonumber(body.evtype) ~= 12
			or body.serial ~= cookie[0].serial then return nil end
		local serial = scalar_unsigned(body.serial, 9007199254740991)
		local time = scalar_unsigned(body.time, 4294967295)
		local property = scalar_unsigned(body.property, 4294967295)
		local device, what = tonumber(body.deviceid), tonumber(body.what)
		if not serial or not time or not property or property == 0 or not device
			or device < 0 or device > 2147483647 or device % 1 ~= 0
			or (what ~= 0 and what ~= 1 and what ~= 2) then return nil end
		return { serial = serial, time = time, property = property, deviceid = device, what = what }
	end)
	-- No exception/refusal path after acquired=1 bypasses this original free.
	local freed, free_value = pcall(connection.free_cookie, connection.display, cookie)
	if not freed or free_value ~= nil then
		connection.cookie_debt = true; M.close()
		return nil, "native-cookie-release-unresolved"
	end
	connection.borrowed = connection.borrowed - 1
	if not connection_current(native, connection, lifetime, cursor) then return nil, "native-property-owner-retired" end
	if not copied or not facts then return nil, "native-property-scalars-refused" end
	return facts
end

local function drain(native, connection)
	if connection.draining or connection.retired or connection.cookie_debt then return false, "native-queue-unavailable" end
	connection.draining = true
	local lifetime = connection.lifetime
	local called, reason = pcall(function()
		connection.sync(connection.display, 0)
		local event = native.ports.new("ErgoptiXkbEvent[1]")
		while connection_current(native, connection, lifetime, connection.cursor) and connection.pending(connection.display) > 0 do
			if not connection_current(native, connection, lifetime, connection.cursor) then return "native-queue-owner-retired" end
			connection.next_event(connection.display, event)
			connection.cursor = connection.cursor + 1
			if not connection_current(native, connection, lifetime, connection.cursor) then return "native-queue-owner-retired" end
		local state = event[0].state
		if tonumber(state.type) == connection.event_base then
			local kind = tonumber(state.xkb_type)
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), GROUP_COMPONENTS) ~= 0) then
				_generation = _generation + 1
			end
			if connection.receiving and (kind == 0 or kind == 1
				or (kind == 2 and native.bit.band(tonumber(state.changed), GROUP_COMPONENTS + LOCKED_COMPONENT) ~= 0)) then
				connection.receiving_revision = connection.receiving_revision + 1
			end
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), LOCKED_COMPONENT) ~= 0) then
				_locked_generation = _locked_generation + 1
			end
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), INPUT_COMPONENTS) ~= 0) then
				_input_generation = _input_generation + 1
			end
		end
			if connection.xi_opcode and tonumber(state.type) == 35 then
				local outer = connection.cast("ErgoptiXIPropertyCookieV2 *", event)
				local kind = tonumber(outer[0].evtype)
				local facts, refusal
				if connection.receiving and (kind == 1 or kind == 11) then
					-- XI_DeviceChanged / XI_HierarchyChanged. No dynamic class/info
					-- array is interpreted; any genuine event invalidates the census.
					if outer[0].display ~= connection.display or tonumber(outer[0].extension) ~= connection.xi_opcode
						or tonumber(outer[0].send_event) ~= 0 then return "native-output-cookie-refused" end
					connection.borrowed = connection.borrowed + 1
					local obtained, status = pcall(connection.get_cookie, connection.display, outer)
					local clean = obtained and status == 0
					if obtained and status == 1 then
						local released, result = pcall(connection.free_cookie, connection.display, outer)
						clean = released and result == nil
					elseif not obtained or status ~= 0 then connection.cookie_debt = true end
					connection.borrowed = connection.borrowed - 1
					connection.receiving_revision = connection.receiving_revision + 1
					if not clean then connection.cookie_debt = true; return "native-output-cookie-unresolved" end
				else
					facts, refusal = property_cookie(native, connection, event)
					if connection.receiving then connection.receiving_revision = connection.receiving_revision + 1 end
				end
				if not connection_current(native, connection, lifetime, connection.cursor) then return refusal or "native-property-owner-retired" end
				_property_facts = facts and { status = "observed", fields = facts } or { status = "refused", reason = refusal }
			end
		end
		if not connection_current(native, connection, lifetime, connection.cursor) then return "native-queue-owner-retired" end
	end)
	local current = connection_current(native, connection, lifetime, connection.cursor)
	connection.draining = false
	if connection.retired then finish_retirement(connection) end
	if not called then
		if _connection == connection then _property_facts = { status = "refused", reason = "native-queue-observation-refused" } end
		return false, "native-queue-observation-refused"
	end
	if not current or reason then return false, reason or "native-queue-owner-retired" end
	return true
end

--- Detached invalidation observations only; no native epoch or capability grant.
--- @return table Detached status/reason and optional scalar fields.
function M.property_invalidation_view()
	local result = { status = _property_facts.status, reason = _property_facts.reason }
	if _property_facts.fields then
		result.fields = {}
		for key, value in pairs(_property_facts.fields) do result.fields[key] = value end
	end
	return result
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

--- Internal implementation fragment for adapters/xkb_source_probe.lua.
--- SOURCE DRAFT: no execution, binding, native grant or standalone connection.
--- Called inside the original Probe binder, before publishing an optional owner.
--- retain/release/debt belong to that exact connection's existing Display custody.

local function build_checked_xi(ffi, native, connection, owner_current, retain, release, debt)
	if not ffi.abi("le") or not ffi.abi("64bit")
		or (ffi.arch ~= "x64" and ffi.arch ~= "arm64") or not connection.xi_opcode then return nil end
	receiving_declared[ffi] = receiving_declared[ffi] or {}
	if not receiving_declared[ffi].checked then
	ffi.cdef([[
		typedef struct { void *iov_base; size_t iov_len; } ErgoptiIovec107;
		typedef struct {
			size_t count; void *ext; uint8_t opcode, isvoid;
		} ErgoptiXcbRequest107;
		struct xcb_generic_error_t;
		uint64_t xcb_send_request64(struct xcb_connection_t *, int, ErgoptiIovec107 *, const ErgoptiXcbRequest107 *);
		int xcb_poll_for_reply64(struct xcb_connection_t *, uint64_t, void **, struct xcb_generic_error_t **);
		void xcb_discard_reply64(struct xcb_connection_t *, uint64_t);
		int xcb_connection_has_error(struct xcb_connection_t *);
	]])
	receiving_declared[ffi].checked = true
	end
	if ffi.sizeof("ErgoptiIovec107") ~= 16 or ffi.offsetof("ErgoptiIovec107", "iov_len") ~= 8
		or ffi.sizeof("ErgoptiXcbRequest107") ~= 24 or ffi.offsetof("ErgoptiXcbRequest107", "ext") ~= 8
		or ffi.offsetof("ErgoptiXcbRequest107", "opcode") ~= 16 then return nil end
	-- libxcb is an actual DT_NEEDED dependency of already declared xkb11.
	-- No new ffi.load, soname fallback, queue owner, display or input poller.
	local handle = native.xkb11
	local ports = { send = handle.xcb_send_request64,
		poll = handle.xcb_poll_for_reply64, discard = handle.xcb_discard_reply64,
		error = handle.xcb_connection_has_error,
		free = ffi.C.free, new = ffi.new, string = ffi.string, cast = ffi.cast }
	local xi_opcode, xcb, display, lifetime = connection.xi_opcode, connection.xcb, connection.display, connection.lifetime
	local xkb_opcode = connection.xkb_opcode
	local pending = setmetatable({}, { __mode = "k" })
	local broken, busy = false, false
	local function current()
		local called, value = pcall(function()
			if owner_current() ~= true then return false end
			local unchanged = native.xkb11 == handle and connection.xi_opcode == xi_opcode
				and connection.xkb_opcode == xkb_opcode
				and connection.xcb == xcb and connection.display == display and connection.lifetime == lifetime
				and handle.xcb_send_request64 == ports.send and handle.xcb_poll_for_reply64 == ports.poll
				and handle.xcb_discard_reply64 == ports.discard
				and handle.xcb_connection_has_error == ports.error and ffi.C.free == ports.free
				and ffi.new == ports.new and ffi.string == ports.string and ffi.cast == ports.cast
			return unchanged and owner_current() == true
		end)
		return not broken and called and value == true
	end
	local function unresolved(request)
		broken = true -- Set before external retirement; no replacement request is admitted.
		pcall(debt, request)
	end
	local function relinquish(request)
		if request.released then return false end
		request.released = true
		local called, value = pcall(release)
		if not called or value ~= true then unresolved(); return false end
		return true
	end
	local function destroy_buffers(reply, failure)
		local clean = true
		-- Distinct owned allocations, each attempted exactly once, including refusal paths.
		for index = 1, 2 do
			local pointer = reply
			if index == 2 then pointer = failure end
			if pointer ~= nil and (index == 1 or pointer ~= reply) then
				local called, value = pcall(ports.free, pointer)
				if not called or value ~= nil then clean = false end
			end
		end
		if not clean then unresolved() end
		return clean
	end
	local function u16(bytes, offset)
		local a, b = bytes:byte(offset + 1, offset + 2)
		if not b then return nil end
		return a + b * 256
	end
	local function u32(bytes, offset)
		local a, b, c, d = bytes:byte(offset + 1, offset + 4)
		if not d then return nil end
		return a + b * 256 + c * 65536 + d * 16777216
	end
	local function p16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
	local function p32(n) return p16(n % 65536) .. p16(math.floor(n / 65536)) end
	local function uint(n, maximum) return type(n) == "number" and n >= 0 and n <= maximum and n % 1 == 0 end
	local function send(opcode, bytes, major, isvoid)
		major = major or xi_opcode
		if busy or not current() or not uint(major, 255) or major < 128
			or #bytes > 24 or #bytes % 4 ~= 0 then return nil, "checked-xi-unavailable" end
		busy = true
		local request = { opcode = opcode, isvoid = isvoid == true, native = native, connection = connection }
		local held, held_value = pcall(retain)
		if not held or held_value ~= true then busy = false; unresolved(); return nil, "checked-xi-custody-unresolved" end
		local called, reason = pcall(function()
			if not current() or ports.error(connection.xcb) ~= 0 then return "checked-xi-connection-refused" end
			-- libxcb 1.17.0 xcb_out.c: RAW skips extension-cache/length rewriting.
			-- Bind the whole short wire header to the original negotiated XI opcode.
			bytes = string.char(major, opcode) .. p16(#bytes / 4) .. bytes:sub(5)
			request.bytes = ports.new("unsigned char[?]", #bytes, bytes)
			request.vector = ports.new("ErgoptiIovec107[4]")
			request.vector[2].iov_base, request.vector[2].iov_len = request.bytes, #bytes
			request.vector[3].iov_base, request.vector[3].iov_len = nil, 0
			request.descriptor = ports.new("ErgoptiXcbRequest107[1]")
			request.descriptor[0].count, request.descriptor[0].ext = 2, nil
			request.descriptor[0].opcode, request.descriptor[0].isvoid = opcode, request.isvoid and 1 or 0
			if not current() then return "checked-xi-owner-retired" end
			-- CHECKED|RAW=3; vector[-2] and vector[-1] are allocated and retained.
			request.sequence = ports.send(connection.xcb, 3, request.vector + 2, request.descriptor)
			if request.sequence == 0 then return "checked-xi-request-refused" end
			request.sent = true
			if ports.error(connection.xcb) ~= 0 or not current() then return "checked-xi-owner-retired" end
			-- No new flush/wait. The original Probe queue drive owns XSync and
			-- thus its existing local-X11 synchronous transport posture.
		end)
		busy = false
		if not called then
			-- A throwing send may have enqueued a request without returning its sequence.
			unresolved(request); return nil, "checked-xi-send-unresolved"
		end
		if reason then
			if request.sent then
				local discarded, value = pcall(ports.discard, connection.xcb, request.sequence)
				if not discarded or value ~= nil then unresolved(request); return nil, "checked-xi-discard-unresolved" end
			end
			relinquish(request)
			return nil, reason
		end
		local token = {}
		pending[token] = request
		return token
	end
	local function query_devices()
		return send(48, "\0\0\0\0" .. p16(0) .. p16(0)) -- XIAllDevices, no names/ID guesses.
	end
	local function query_device(device)
		if not uint(device, 65535) or device == 0 then return nil, "checked-xi-device-refused" end
		return send(48, "\0\0\0\0" .. p16(device) .. p16(0))
	end
	local function query_property(device, atom)
		if not uint(device, 65535) or device == 0 or not uint(atom, 4294967295) or atom == 0 then return nil, "checked-xi-property-refused" end
		-- Native protocol Atom is CARD32; delete=false, type=XA_STRING, offset=0,
		-- length=256 words gives at most 1024 bytes, never a write or delete.
		return send(59, "\0\0\0\0" .. p16(device) .. "\0\0" .. p32(atom) .. p32(31) .. p32(0) .. p32(256))
	end
	local function select_xkb(device)
		if not uint(device, 127) or device == 0 or not uint(xkb_opcode, 255) or xkb_opcode < 128 then return nil end
		-- XKBproto.h xkbSelectEventsReq16 / XKB.h minor1, masks7/255.
		-- No Xlib asynchronous error handler or guessed public Xlib structure.
		return send(1, "\0\0\0\0" .. p16(device) .. p16(7) .. p16(0) .. p16(7)
			.. p16(255) .. p16(255), xkb_opcode, true)
	end
	local function devices(bytes)
		local count = u16(bytes, 8)
		if not count or count > 128 then return nil end
		local result, seen, position = {}, {}, 32
		for _ = 1, count do
			if position + 12 > #bytes then return nil end
			local id, use, attachment = u16(bytes, position), u16(bytes, position + 2), u16(bytes, position + 4)
			local classes, name_length = u16(bytes, position + 6), u16(bytes, position + 8)
			local enabled = bytes:byte(position + 11)
			if not id or id == 0 or seen[id] or use < 1 or use > 5 or classes > 128 or name_length > 1024
				or (enabled ~= 0 and enabled ~= 1) then return nil end
			seen[id] = true
			local device = { id = id, use = use, attachment = attachment, enabled = enabled == 1, key_sources = {} }
			position = position + 12 + math.floor((name_length + 3) / 4) * 4
			if position > #bytes then return nil end
			for _ = 1, classes do
				if position + 8 > #bytes then return nil end
				local kind, words, source = u16(bytes, position), u16(bytes, position + 2), u16(bytes, position + 4)
				if words < 2 or position + words * 4 > #bytes then return nil end
				if kind == 0 then -- XIKeyClass, exact key prefix plus CARD32 codes.
					local keys = u16(bytes, position + 6)
					if keys > 768 or words ~= 2 + keys or device.key_sources[source] then return nil end
					local set = {}
					for k = 1, keys do
						local code = u32(bytes, position + 8 + (k - 1) * 4)
						if set[code] then return nil end
						set[code] = true
					end
					device.key_sources[source] = set
				end
				position = position + words * 4
			end
			result[#result + 1] = device
		end
		return position == #bytes and result or nil
	end
	local function property(bytes)
		local kind, remaining, count = u32(bytes, 8), u32(bytes, 12), u32(bytes, 16)
		local format = bytes:byte(21)
		if kind == 0 and remaining == 0 and count == 0 and format == 0 and #bytes == 32 then return { absent = true } end
		if kind ~= 31 or remaining ~= 0 or format ~= 8 or count == 0 or count > 1024
			or #bytes ~= 32 + math.floor((count + 3) / 4) * 4 then return nil end
		local path = bytes:sub(33, 32 + count)
		if not path:match("^/dev/input/event[0-9]+$") then return nil end
		return { path = path }
	end
	local function poll(token)
		local request = pending[token]
		if busy or not request or request.done or not current() then return nil, "checked-xi-owner-refused", false end
		busy = true
		local allocated, reply_slot, failure_slot = pcall(function()
			return ports.new("void *[1]"), ports.new("struct xcb_generic_error_t *[1]")
		end)
		if not allocated then
			busy = false
			return nil, "checked-xi-poll-storage-refused", false -- Pending request still has exact cancel custody.
		end
		local called, value = pcall(ports.poll, connection.xcb, request.sequence, reply_slot, failure_slot)
		local reply, failure = reply_slot[0], failure_slot[0]
		local copied, fields, reason
		if not called then
			unresolved(request); reason = "checked-xi-poll-unresolved"
		elseif value == 0 and reply == nil and failure == nil then
			if ports.error(connection.xcb) == 0 and current() then busy = false; return nil, "pending", false end
			reason = "checked-xi-connection-refused"
		elseif value ~= 1 or failure ~= nil or ports.error(connection.xcb) ~= 0 or not current() then
			reason = "checked-xi-reply-refused"
		elseif request.isvoid then
			-- libxcb poll_for_reply returns terminal1/nil/nil only once the
			-- checked sequence is completed. Original XSync drives that boundary.
			if reply == nil then fields = { selected = true } else reason = "checked-xkb-void-reply-refused" end
		elseif reply == nil then reason = "checked-xi-reply-refused"
		else
			copied, fields = pcall(function()
				local prefix = ports.string(reply, 32)
				local words = u32(prefix, 4)
				if prefix:byte(1) ~= 1 or prefix:byte(2) ~= request.opcode
					or u16(prefix, 2) ~= tonumber(ports.cast("uint16_t", request.sequence))
					or not words or words > 4096 then return nil end
				local bytes = ports.string(reply, 32 + words * 4)
				if request.opcode == 48 then return devices(bytes) end
				return property(bytes)
			end)
			if not copied or not fields then reason = "checked-xi-shape-refused" end
		end
		request.done = true
		pending[token] = nil
		local clean = destroy_buffers(reply, failure)
		if not called then clean = false end
		if called and value ~= 1 then
			-- No reply was received; retire only this request's reply interest.
			local discarded, ack = pcall(ports.discard, connection.xcb, request.sequence)
			if not discarded or ack ~= nil then unresolved(); clean = false end
		end
		if clean then clean = relinquish(request) end
		busy = false
		if not clean or not current() then return nil, "checked-xi-custody-unresolved", true end
		return fields, reason, true
	end
	local function cancel(token)
		local request = pending[token]
		if busy or not request or request.done then return false end
		busy = true
		request.done = true
		pending[token] = nil -- Never attempt the same discard twice.
		local ok, value = pcall(ports.discard, connection.xcb, request.sequence)
		local clean = ok and value == nil
		if not clean then unresolved() else clean = relinquish(request) end
		busy = false
		return clean
	end
	return { query_devices = query_devices, query_device = query_device, query_property = query_property,
		select_xkb = select_xkb, retirement_ready = function() return not busy end,
		poll = poll, cancel = cancel, current = current }
end

--- Internal consumer fragment for adapters/xkb_source_probe.lua.
--- Connects the two native primitives; it is not an output authorization API.
--- writer ports are private closures from the original Writer capability, not a
--- descriptor copied from a view. drive() runs only on the existing Hook pump.
--- hold/release/debt are the same original Probe Display lifetime accounting.

local function build_output_association(checked, writer, atom, owner_current, hold, release, debt)
	local records = setmetatable({}, { __mode = "k" })
	local busy = false
	local function same_device(a, b)
		if not a or not b or a.id ~= b.id or a.use ~= b.use or a.attachment ~= b.attachment
			or a.enabled ~= b.enabled then return false end
		local aa, bb = a.key_sources[a.id], b.key_sources[b.id]
		if not aa or not bb then return false end
		for key in pairs(aa) do if bb[key] ~= true then return false end end
		for key in pairs(bb) do if aa[key] ~= true then return false end end
		return true
	end
	local function current(record)
		local ok, result = pcall(function()
			if record.retired or owner_current() ~= true or checked.current() ~= true
			or writer.owner_current() ~= true or writer.closed() ~= true then return false end
			if record.node and writer.current(record.node) ~= true then return false end
			return not record.retired and owner_current() == true and checked.current() == true
				and writer.owner_current() == true and writer.closed() == true
		end)
		return ok and result == true
	end
	local function retire(record)
		if record.retired then return record.closed == true end
		record.retired = true
		local closed = true
		if record.request then
			local request = record.request
			record.request = nil
			local ok, ack = pcall(checked.cancel, request)
			if not ok or ack ~= true then closed = false end
		end
		for index = #record.nodes, 1, -1 do
			local ok, ack = pcall(writer.retire, record.nodes[index])
			if not ok or ack ~= true then closed = false end
		end
		local intact, no_debt = pcall(writer.closed)
		if not intact or no_debt ~= true then closed = false end
		if closed then
			local ok, ack = pcall(release)
			closed = ok and ack == true
		end
		record.closed = closed
		if not closed then pcall(debt, record) end -- Retain the original Display debt.
		return closed
	end
	local function start()
		if busy or owner_current() ~= true or checked.current() ~= true then return nil end
		busy = true
		local record = { phase = "devices", nodes = {} }
		local held, ack = pcall(hold)
		if not held or ack ~= true then busy = false; pcall(debt, record); return nil end
		local ok, request = pcall(checked.query_devices)
		if not ok or not request or not current(record) then
			record.request = ok and request or nil
			retire(record); busy = false; return nil
		end
		record.request = request
		local token = {}
		records[token] = record
		busy = false
		return token
	end
	local function next_property(record)
		local device = record.candidates[record.index]
		if not device then
			if #record.nodes ~= 1 then return false, "output-device-missing-or-ambiguous" end
			local selected = record.selected
			local keys = selected.key_sources[selected.id]
			if selected.id > 127 or selected.attachment > 127 or not record.masters[selected.attachment] or not keys then
				return false, "output-keymap-device-unsupported"
			end
			for code = 10, 19 do if keys[code] ~= true then return false, "output-row-keycodes-missing" end end
			record.phase = "requery"
			record.request = checked.query_device(record.selected.id)
		else
			record.phase = "property"
			record.request = checked.query_property(device.id, atom)
		end
		return record.request ~= nil
	end
	local function drive(token)
		local record = records[token]
		if busy or not record or not current(record) then return nil, "output-association-unavailable" end
		if record.phase == "observed" then
			return { device = record.selected.id, attachment = record.selected.attachment, path = record.path,
				status = "kernel-node-associated", output_authorized = false }
		end
		busy = true
		local called, fields, reason = pcall(function()
			local result, refusal, consumed = checked.poll(record.request)
			if not result then
				if refusal == "pending" then return nil, "pending" end
				if consumed == true then record.request = nil end -- Otherwise retire still owns the exact request.
				return nil, refusal
			end
			record.request = nil
			if not current(record) then return nil, "output-association-owner-retired" end
			if record.phase == "devices" then
				local masters, candidates = {}, {}
				for _, device in ipairs(result) do
					if device.use == 2 and device.enabled then masters[device.id] = true end
				end
				for _, device in ipairs(result) do
					-- Test association for every enabled keyboard slave, including IDs
					-- outside xkbcommon's narrower range. Never hide a second match.
					if device.use == 4 and device.enabled then candidates[#candidates + 1] = device end
				end
				record.candidates, record.index, record.masters = candidates, 1, masters
				local ok, refusal = next_property(record)
				return nil, ok and "pending" or refusal or "output-property-request-refused"
			elseif record.phase == "property" then
				local candidate = record.candidates[record.index]
				if not result.absent then
					local node, disposition = writer.acquire_path(result.path)
					if node and disposition == "matched" then
						record.nodes[#record.nodes + 1] = node -- Retain before any observer.
						record.selected, record.node, record.path = candidate, node, result.path
					elseif node then
						record.nodes[#record.nodes + 1] = node
						return nil, "output-node-disposition-refused"
					elseif disposition ~= "nonmatch" then
						return nil, "output-node-census-unresolved"
					end
				end
				record.index = record.index + 1
				local ok, refusal = next_property(record)
				return nil, ok and "pending" or refusal or "output-property-request-refused"
			elseif record.phase == "requery" then
				if #result ~= 1 or not same_device(record.selected, result[1]) or not current(record) then
					return nil, "output-device-replaced"
				end
				record.phase = "reproperty"
				record.request = checked.query_property(record.selected.id, atom)
				return nil, record.request and "pending" or "output-property-request-refused"
			elseif record.phase == "reproperty" then
				if result.path ~= record.path or not current(record) then return nil, "output-property-replaced" end
				record.phase = "observed"
				return { device = record.selected.id, attachment = record.selected.attachment, path = record.path,
					status = "kernel-node-associated", output_authorized = false }
			end
			return nil, "output-association-phase-refused"
		end)
		if not called or (not fields and reason ~= "pending") then
			retire(record)
			busy = false
			return nil, called and reason or "output-association-refused"
		end
		local joined = current(record)
		if not joined then retire(record) end
		busy = false
		if not joined then return nil, "output-association-owner-retired" end
		return fields, reason
	end
	local function cancel(token)
		local record = records[token]
		if busy or not record then return false end
		busy = true
		local closed = retire(record)
		busy = false
		return closed
	end
	return { start = start, drive = drive, cancel = cancel,
		retirement_ready = function() return not busy end,
		current = function(token) local record = records[token]; return record and current(record) or false end }
end

--- Internal receiving-map producer for adapters/xkb_source_probe.lua.
--- SOURCE DRAFT. Uses the same borrowed Display/Xcb/context and selected Writer.
--- No cached/core-only map can substitute for the selected slave/master join.

local function build_receiving_map(ffi, native, connection, association, token, owner_current, drain, hold, release, debt, ordered_aliases, input_epoch)
	receiving_declared[ffi] = receiving_declared[ffi] or {}
	if not receiving_declared[ffi].map then
	ffi.cdef([[
		struct xkb_state;
		struct xkb_state *xkb_x11_state_new_from_device(struct xkb_keymap *, struct xcb_connection_t *, int32_t);
		void xkb_state_unref(struct xkb_state *);
		unsigned int xkb_state_serialize_mods(struct xkb_state *, int);
		unsigned int xkb_state_serialize_layout(struct xkb_state *, int);
		unsigned int xkb_keymap_mod_get_index(struct xkb_keymap *, const char *);
		size_t strnlen(const char *, size_t);
	]])
	receiving_declared[ffi].map = true
	end
	local ports = { keymap = native.xkb11.xkb_x11_keymap_new_from_device,
		state = native.xkb11.xkb_x11_state_new_from_device,
		core = native.xkb11.xkb_x11_get_core_keyboard_device_id,
		map_unref = native.xkb.xkb_keymap_unref, state_unref = native.xkb.xkb_state_unref,
		map_text = native.xkb.xkb_keymap_get_as_string, map_parse = native.xkb.xkb_keymap_new_from_string, mod_index = native.xkb.xkb_keymap_mod_get_index,
		mods = native.xkb.xkb_state_serialize_mods, layout = native.xkb.xkb_state_serialize_layout,
		free = ffi.C.free, length = ffi.C.strnlen, string = ffi.string }
	local busy, unresolved, revision = false, false, 0
	local function current()
		local ok, value = pcall(function()
			if owner_current() ~= true or association.current(token) ~= true then return false end
			local unchanged = native.xkb11.xkb_x11_keymap_new_from_device == ports.keymap
				and native.xkb11.xkb_x11_state_new_from_device == ports.state
				and native.xkb11.xkb_x11_get_core_keyboard_device_id == ports.core
				and native.xkb.xkb_keymap_unref == ports.map_unref and native.xkb.xkb_state_unref == ports.state_unref
				and native.xkb.xkb_keymap_get_as_string == ports.map_text
				and native.xkb.xkb_keymap_new_from_string == ports.map_parse and native.xkb.xkb_keymap_mod_get_index == ports.mod_index
				and native.xkb.xkb_state_serialize_mods == ports.mods and native.xkb.xkb_state_serialize_layout == ports.layout
				and ffi.C.free == ports.free and ffi.C.strnlen == ports.length and ffi.string == ports.string
			return unchanged and owner_current() == true and association.current(token) == true
		end)
		return not unresolved and ok and value == true
	end
	local function uint(value, maximum)
		return type(value) == "number" and value >= 0 and value % 1 == 0 and value <= maximum
	end
	local function inspect(expected_map, expected_groups, receive)
		if busy or not current() or type(expected_map) ~= "string" or expected_map == ""
			or not uint(expected_groups, 255) or expected_groups == 0 or type(receive) ~= "function" then return nil end
		busy = true
		local record = { owned = {} }
		local held, held_value = pcall(hold)
		if not held or held_value ~= true then unresolved = true; pcall(debt, record); busy = false; return nil end
		local function allocation(port, kind, ...)
			if not current() then return nil end
			local called, value = pcall(port, ...)
			if not called then unresolved = true; return nil end
			if value == nil then return nil end
			record.owned[#record.owned + 1] = { value = value, kind = kind }
			return value
		end
		local function text(map)
			local pointer = allocation(ports.map_text, "text", map, 1)
			if not pointer then return nil end
			local size = tonumber(ports.length(pointer, 1048577))
			if not uint(size, 1048576) or size == 0 then return nil end
			return ports.string(pointer, size)
		end
		local function canonical(map)
			local raw = text(map)
			if not raw then return nil end
			local parsed = allocation(ports.map_parse, "map", connection.context, raw, 1, 0)
			local rendered = parsed and text(parsed)
			return rendered and ordered_aliases(rendered) or nil
		end
		local called, result = pcall(function()
			if drain() ~= true or not current() then return nil end
			local observed_input_epoch = input_epoch()
			local facts = association.drive(token)
			if not facts or facts.status ~= "kernel-node-associated" or not uint(facts.device, 127)
				or facts.device == 0 or not uint(facts.attachment, 127) or facts.attachment == 0 then return nil end
			if tonumber(ports.core(connection.xcb)) ~= facts.attachment or not current() then return nil end
			local slave = allocation(ports.keymap, "map", connection.context, connection.xcb, facts.device, 0)
			local master = allocation(ports.keymap, "map", connection.context, connection.xcb, facts.attachment, 0)
			if not slave or not master then return nil end
			local slave_map, master_map = canonical(slave), canonical(master)
			local acknowledged = ordered_aliases(expected_map)
			if not acknowledged or slave_map ~= acknowledged or master_map ~= acknowledged or not current() then return nil end
			local state = allocation(ports.state, "state", master, connection.xcb, facts.attachment)
			if not state or not current() then return nil end
			local group = tonumber(ports.layout(state, 128))
			local depressed, latched, locked = tonumber(ports.mods(state, 1)), tonumber(ports.mods(state, 2)), tonumber(ports.mods(state, 4))
			local shift, lock = tonumber(ports.mod_index(master, "Shift")), tonumber(ports.mod_index(master, "Lock"))
			if not uint(group, expected_groups - 1) or not uint(depressed, 4294967295)
				or not uint(latched, 4294967295) or not uint(locked, 4294967295)
				or not uint(shift, 31) or not uint(lock, 31) or not current() then return nil end
			revision = revision + 1
			local observed_revision = revision
			local scope = { keymap = master, state = state, group = group, raw_map = master_map,
				depressed = depressed, latched = latched, locked = locked, shift_mask = 2 ^ shift,
				caps = math.floor(locked / (2 ^ lock)) % 2 == 1, device = facts.device, attachment = facts.attachment }
			-- This current predicate is valid only within this retained buffer scope.
			local function scoped_current()
				return busy and revision == observed_revision and input_epoch() == observed_input_epoch and current()
			end
			local value = receive(scope, scoped_current)
			if not scoped_current() or drain() ~= true or not scoped_current() then return nil end
			return value
		end)
		local clean = not unresolved
		for index = #record.owned, 1, -1 do
			local item = record.owned[index]
			item.attempted = true -- Never retry an ambiguous original release.
			local port = item.kind == "state" and ports.state_unref or item.kind == "map" and ports.map_unref or ports.free
			local freed, ack = pcall(port, item.value)
			if not freed or ack ~= nil then clean = false end
		end
		if clean then
			local released, ack = pcall(release)
			clean = released and ack == true
		end
		if not clean then unresolved = true; pcall(debt, record) end
		busy = false
		if not clean or not called or not current() then return nil end
		return result
	end
	return { inspect = inspect, current = current }
end

--- Reads actual native server state, requiring the capture owner's exact map.
--- @param expected string Canonical serialization of the loaded native keymap.
--- @param groups integer Number of groups in that loaded native keymap.
--- @return table|nil receipt { group, generation, backend, observed_current }.
--- @return string|nil reason Native qualification refusal.
local function read(expected, groups, require_locked, require_input)
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
	local drained, drain_reason = drain(native, connection)
	if not drained then return nil, drain_reason end
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
	local locked = tonumber(after[0].locked_mods)
	local effective, depressed, latched = tonumber(after[0].mods), tonumber(after[0].base_mods), tonumber(after[0].latched_mods)
	if require_input and (tonumber(before[0].mods) ~= effective or tonumber(before[0].base_mods) ~= depressed
		or tonumber(before[0].latched_mods) ~= latched) then
		drain(native, connection); return nil, "native-input-modifiers-raced"
	end
	if require_locked and tonumber(before[0].locked_mods) ~= locked then
		drain(native, connection); return nil, "native-locked-modifiers-raced"
	end
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
	if _last_locked ~= locked then _last_locked = locked; _locked_generation = _locked_generation + 1 end
	if not _last_input or _last_input.mods ~= effective or _last_input.base_mods ~= depressed
		or _last_input.latched_mods ~= latched or _last_input.locked_mods ~= locked then
		_last_input = { mods = effective, base_mods = depressed, latched_mods = latched, locked_mods = locked }
		_input_generation = _input_generation + 1
	end
	local acknowledged_epoch, acknowledged_locked = _generation, _locked_generation
	local acknowledged_input = _input_generation
	drained, drain_reason = drain(native, connection)
	if not drained then return nil, drain_reason end
	if _generation ~= acknowledged_epoch then return nil, "native-source-raced" end
	if require_locked and _locked_generation ~= acknowledged_locked then return nil, "native-locked-modifiers-raced" end
	if require_input and _input_generation ~= acknowledged_input then return nil, "native-input-modifiers-raced" end
	if expected ~= _last_expected then
		local canonical = ordered_aliases(expected)
		if canonical == nil then return nil, "native-keymap-canonicalization-refused" end
		_last_expected, _last_canonical_expected = expected, canonical
	end
	if _last_canonical_keymap ~= _last_canonical_expected then return nil, "native-keymap-unacknowledged" end
	if group < 0 or group >= groups then return nil, "native-group-outside-keymap" end
	if require_input then
		local observed_connection, observed_native = connection, native
		local observed_map, observed_expected = _last_canonical_keymap, _last_canonical_expected
		local observed_source, observed_lock, observed_input = _generation, _locked_generation, _input_generation
		return { group = group, generation = _generation, backend = "x11",
			mods = effective, base_mods = depressed, latched_mods = latched, locked_mods = locked,
			locked_generation = _locked_generation, input_generation = _input_generation,
			-- This seals observed state only. It performs no native read or latch clearing.
			observed_current = function()
				return _connection == observed_connection and _native == observed_native
					and _generation == observed_source and _locked_generation == observed_lock
					and _input_generation == observed_input and _last_group == group
					and _last_locked == locked and _last_input ~= nil
					and _last_input.mods == effective and _last_input.base_mods == depressed
					and _last_input.latched_mods == latched and _last_input.locked_mods == locked
					and _last_canonical_keymap == observed_map and _last_canonical_expected == observed_expected
			end }
	end
	if require_locked then
		local observed_connection, observed_native = connection, native
		local observed_map, observed_expected = _last_canonical_keymap, _last_canonical_expected
		local observed_source, observed_lock = _generation, _locked_generation
		return { group = group, generation = _generation, backend = "x11",
			locked_mods = locked, locked_generation = _locked_generation,
			-- Seals already observed native currency after later callbacks. It
			-- performs no native reads and does not claim a kernel/source lease.
			observed_current = function()
				return _connection == observed_connection and _native == observed_native
					and _generation == observed_source and _locked_generation == observed_lock
					and _last_group == group and _last_locked == locked
					and _last_canonical_keymap == observed_map and _last_canonical_expected == observed_expected
			end }

	end
	local observed_connection, observed_native = connection, native
	local observed_map, observed_expected = _last_canonical_keymap, _last_canonical_expected
	local observed_source = _generation
	return { group = group, generation = _generation, backend = "x11",
		-- Group-only admission preserves ordinary modifier semantics while
		-- retaining the actual issuer after a later callback. No native query runs.
		observed_current = function()
			return _connection == observed_connection and _native == observed_native
				and _generation == observed_source and _last_group == group
				and _last_canonical_keymap == observed_map and _last_canonical_expected == observed_expected
		end }
end


--- Reads actual native RMLVO metadata through the already-owned X11 connection.
--- The metadata alone is never layout proof: installed() also compiles the exact
--- requested registry source and checks its full native map/group through read().
local function number_row_names(native, connection)
	local ffi = native.ffi
	local atom = native.x11.XInternAtom(connection.display, "_XKB_RULES_NAMES", 1)
	if tonumber(atom) == 0 then return nil end
	local actual, format = ffi.new("unsigned long[1]"), ffi.new("int[1]")
	local count, remaining, bytes = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]"), ffi.new("unsigned char *[1]")
	local status = native.x11.XGetWindowProperty(connection.display,
		native.x11.XDefaultRootWindow(connection.display), atom, 0, 1024, 0, 31,
		actual, format, count, remaining, bytes)
	local raw
	if status == 0 and tonumber(actual[0]) == 31 and tonumber(format[0]) == 8
		and tonumber(count[0]) <= 4096 and tonumber(remaining[0]) == 0 and bytes[0] ~= nil then
		local called, result = pcall(ffi.string, bytes[0], tonumber(count[0]))
		if called then raw = result end
	end
	if bytes[0] ~= nil then native.x11.XFree(bytes[0]) end
	if type(raw) ~= "string" or raw:sub(-1) ~= "\0" then return nil end
	local fields, offset = {}, 1
	while offset <= #raw do
		local last = raw:find("\0", offset, true)
		if not last then return nil end
		fields[#fields + 1] = raw:sub(offset, last - 1)
		offset = last + 1
	end
	if #fields ~= 5 or fields[1] == "" or fields[3] == "" then return nil end
	for _, text in ipairs(fields) do
		if #text > 1024 or (text ~= "" and not text:match("^[A-Za-z0-9_+,:%-]+$")) then return nil end
	end
	return fields, raw
end

--- Proves that the desired installed registry layout owns the native group.
--- Its full map is compiled with the installed user tree first, then compared
--- with the real server map. A preference-only activation cannot grant admission.
--- @param id string Existing installed registry id.
--- @param include_root string Absolute verified installed XKB directory.
--- @return table|nil proof Exact expected map, group and native generation.
function M.installed_number_row_source(id, include_root)
	if type(id) ~= "string" or not id:match("^[a-z][a-z0-9_]*$")
		or type(include_root) ~= "string" or include_root:sub(1, 1) ~= "/"
		or include_root:find("\0", 1, true) then return nil, "number-row-invalid-installed-source" end
	local native, reason = bind()
	if not native then return nil, reason end
	local display_name = os.getenv("DISPLAY")
	if not display_name or display_name == "" or DisplayServer.is_wayland() then return nil, "number-row-native-source-unavailable" end
	local connection
	connection, reason = connect(native, display_name)
	if not connection then return nil, reason end
	drain(native, connection)
	local fields, raw = number_row_names(native, connection)
	if not fields then return nil, "number-row-native-layout-names-unavailable" end
	local context, keymap, bytes
	local called, expected, groups = pcall(function()
		context = native.xkb.xkb_context_new(0)
		if context == nil then return nil end
		-- Suppress parser Error/Warning output from this private preparation
		-- context; ordinary source-owner contexts keep their existing logging.
		native.xkb.xkb_context_set_log_level(context, 10)
		native.xkb.xkb_context_include_path_clear(context)
		if native.xkb.xkb_context_include_path_append(context, include_root) ~= 1
			or native.xkb.xkb_context_include_path_append_default(context) ~= 1 then return nil end
		local names = native.ffi.new("struct ErgoptiNumberRowNames[1]")
		names[0].rules, names[0].model, names[0].layout, names[0].variant, names[0].options = unpack(fields)
		keymap = native.xkb.xkb_keymap_new_from_names(context, names, 0)
		if keymap == nil then return nil end
		bytes = native.xkb.xkb_keymap_get_as_string(keymap, 1)
		if bytes == nil then return nil end
		return native.ffi.string(bytes), tonumber(native.xkb.xkb_keymap_num_layouts(keymap))
	end)
	if bytes ~= nil then native.ffi.C.free(bytes) end
	if keymap ~= nil then native.xkb.xkb_keymap_unref(keymap) end
	if context ~= nil then native.xkb.xkb_context_unref(context) end
	if not called or type(expected) ~= "string" or type(groups) ~= "number" then
		return nil, "number-row-installed-map-unavailable"
	end
	local receipt = M.read(expected, groups)
	if not receipt or _native ~= native or _connection ~= connection then
		return nil, "number-row-installed-source-raced"
	end
	local _, current_raw = number_row_names(native, connection)
	if _native ~= native or _connection ~= connection or _generation ~= receipt.generation
		or _last_group ~= receipt.group or raw ~= current_raw then return nil, "number-row-installed-source-raced" end
	local layout_ids = {}
	for value in (fields[3] .. ","):gmatch("(.-),") do layout_ids[#layout_ids + 1] = value end
	if layout_ids[receipt.group + 1] ~= id then return nil, "number-row-desired-layout-inactive" end
	local capability = setmetatable({}, { __newindex = function() error("installed native proofs are immutable", 2) end, __metatable = false })
	number_row_sources[capability] = { keymap = expected, groups = groups, group = receipt.group,
		generation = receipt.generation, layout_id = id, rules = raw, include_root = include_root }
	return capability
end

--- Binds an already-acknowledged capture serialization of the same native map.
--- This keeps the existing source parser cache stable on ordinary key input.
function M.bind_number_row_capture(capability, keymap)
	local owned = number_row_sources[capability]
	if not owned or type(keymap) ~= "string" then return false end
	local receipt = M.read(keymap, owned.groups)
	if not receipt or receipt.group ~= owned.group or receipt.generation ~= owned.generation then return false end
	owned.keymap = keymap
	return true
end

--- Checks only this issuer's exact installation/source epoch, never a caller map.
function M.number_row_source_current(capability)
	local owned = number_row_sources[capability]
	if not owned then return false end
	local receipt = M.read(owned.keymap, owned.groups)
	if not receipt or receipt.group ~= owned.group or receipt.generation ~= owned.generation then return false end
	local native, connection = _native, _connection
	if not native or not connection then return false end
	local _, raw = number_row_names(native, connection)
	return raw == owned.rules
end

--- Captures actual installed-id/RMLVO currency without synchronous include compilation.
--- The current full native map is acknowledged before an owned child is started.
function M.capture_number_row_namespace(id, expected, groups)
 if type(id) ~= "string" or not id:match("^[a-z][a-z0-9_]*$") then return nil end
 local receipt = M.read(expected, groups)
 local native, connection = _native, _connection
 if not receipt or not native or not connection then return nil end
 local fields, raw = number_row_names(native, connection)
 if not fields then return nil end
 local layouts = {}; for value in (fields[3] .. ","):gmatch("(.-),") do layouts[#layouts + 1] = value end
 if layouts[receipt.group + 1] ~= id then return nil end
 local after = M.read(expected, groups)
 if not after or after.generation ~= receipt.generation or after.group ~= receipt.group
  or _native ~= native or _connection ~= connection then return nil end
 local _, current_raw = number_row_names(native, connection)
 if _native ~= native or _connection ~= connection or _generation ~= after.generation
  or _last_group ~= after.group or raw ~= current_raw then return nil end
 local cap = setmetatable({}, { __newindex = function() error("native namespace snapshots are immutable", 2) end, __metatable = false })
 asynchronous_number_row_sources[cap] = { map = expected, groups = groups, fields = fields, raw = raw,
  generation = receipt.generation, group = receipt.group, connection = connection, native = native }
 return cap
end

--- Returns only the exact issuer's detached namespace while the native epoch holds.
function M.number_row_namespace_view(capability)
 local owned = asynchronous_number_row_sources[capability]
 if not owned or _native ~= owned.native or _connection ~= owned.connection then return nil end
 local before = M.read(owned.map, owned.groups)
 if not before or before.generation ~= owned.generation or before.group ~= owned.group
  or _native ~= owned.native or _connection ~= owned.connection then return nil end
 local _, raw = number_row_names(owned.native, owned.connection)
 if _native ~= owned.native or _connection ~= owned.connection then return nil end
 local after = M.read(owned.map, owned.groups)
 if not after or after.generation ~= owned.generation or after.group ~= owned.group
  or _native ~= owned.native or _connection ~= owned.connection or _generation ~= after.generation
  or _last_group ~= after.group or raw ~= owned.raw then return nil end
 local fields = owned.fields
 return { rules = fields[1], model = fields[2], layout = fields[3], variant = fields[4], options = fields[5],
  generation = owned.generation, group = owned.group }
end

--- Canonicalizes only a fully resolved child projection, never user include syntax.
--- This native string parser cannot read include paths under the closed token gate.
function M.acknowledge_number_row_projection(capability, projected, groups)
 local owned = asynchronous_number_row_sources[capability]
 if not owned or not M.number_row_namespace_view(capability) or type(projected) ~= "string"
  or projected == "" or #projected > 1048576 or projected:find("%z")
  or projected:lower():find("%f[%a_]include%f[^%w_]") or groups ~= owned.groups then return nil end
 local native = _native
 local context, keymap, pointer
 local called, canonical = pcall(function()
  context = native.xkb.xkb_context_new(0)
  if context == nil then return nil end
  native.xkb.xkb_context_set_log_level(context, 10)
  keymap = native.xkb.xkb_keymap_new_from_string(context, projected, 1, 0)
  if keymap == nil then return nil end
  pointer = native.xkb.xkb_keymap_get_as_string(keymap, 1)
  if pointer == nil then return nil end
  return native.ffi.string(pointer)
 end)
 if pointer ~= nil then native.ffi.C.free(pointer) end
 if keymap ~= nil then native.xkb.xkb_keymap_unref(keymap) end
 if context ~= nil then native.xkb.xkb_context_unref(context) end
 if not called or type(canonical) ~= "string" then return nil end
 local receipt = M.read(canonical, groups)
 if not receipt or receipt.generation ~= owned.generation or receipt.group ~= owned.group
  or not M.number_row_namespace_view(capability) then return nil end
 return canonical
end

--- Existing group/keymap receipt retains its generation semantics across locks.
function M.read(expected, groups) return read(expected, groups, false) end

--- Detached native locked-modifier receipt. Locked XKB event epochs reject
--- away-and-back races without treating ordinary key transitions as rebinds.
function M.read_locked(expected, groups) return read(expected, groups, true) end

--- Reads actual depressed, latched, effective and locked native modifiers.
--- Input epochs detect observed away-and-back changes independently of the
--- existing group-only and locked-only receipt semantics. No mask is cleared.
function M.read_input_state(expected, groups) return read(expected, groups, true, true) end


--- Captures the receiving device on this Probe's original queue and connection.
--- Writer supplies only its original opaque kernel issuer; no profile boolean.

function M.capture_receiving_source(kernel)
	local Writer = require("adapters.uinput_writer")
	local kernel_ports = Writer.kernel_source_ports
	if type(kernel_ports) ~= "function" then return nil end
	local writer = kernel_ports(kernel)
	if M.capture_receiving_source ~= original_receiving_capture or type(writer) ~= "table"
		or type(writer.owner_current) ~= "function" or type(writer.acquire_path) ~= "function"
		or type(writer.current) ~= "function" or type(writer.retire) ~= "function"
		or type(writer.closed) ~= "function" or type(writer.close) ~= "function" then return nil end
	local display_name = os.getenv("DISPLAY")
	if DisplayServer.is_wayland() or type(display_name) ~= "string" or display_name == "" then return nil end
	local native = bind()
	if not native or not native.xi then return nil end -- No undeclared soname fallback.
	local connection = connect(native, display_name)
	if not connection or not connection.xi_opcode or not drain(native, connection) then return nil end
	connection.receiving = connection.receiving or {}
	connection.receiving_revision = connection.receiving_revision or 0
	local revision, lifetime = connection.receiving_revision, connection.lifetime
	local intern_atom = native.x11.XInternAtom
	local retired, constructing, unresolved = false, true, false
	local controller, association, token, target, checked = {}, nil, nil, nil, nil
	local subscriptions = { index = 1, complete = false }
	local writer_ports = {}
	for _, name in ipairs({ "owner_current", "acquire_path", "current", "retire", "closed", "close" }) do writer_ports[name] = writer[name] end
	local function current()
		if retired or unresolved or M.capture_receiving_source ~= original_receiving_capture
			or package.loaded["adapters.uinput_writer"] ~= Writer or Writer.kernel_source_ports ~= kernel_ports
			or kernel_ports(kernel) ~= writer or native.x11.XInternAtom ~= intern_atom
			or _native ~= native or _connection ~= connection or connection.retired
			or connection.lifetime ~= lifetime or connection.receiving_revision ~= revision
			or connection.cookie_debt or connection.cleanup_debt or not ports_current(native) then return false end
		for name, port in pairs(writer_ports) do if writer[name] ~= port then return false end end
		return writer_ports.owner_current() == true and writer_ports.closed() == true
	end
	local function hold()
		if not current() then return false end
		connection.borrowed = connection.borrowed + 1
		return true
	end
	local function release()
		if connection.borrowed <= 0 then return false end
		connection.borrowed = connection.borrowed - 1
		-- No recursive close while controller cleanup is in flight.
		return true
	end
	local function debt(record)
		unresolved, connection.cleanup_debt = true, true
		controller.debt = record or controller.debt or {}
	end
	controller.retire = function()
		if controller.retiring then return false end
		if controller.closed then return true end
		retired, controller.retiring = true, true
		if constructing or (association and association.retirement_ready() ~= true)
			or (checked and checked.retirement_ready() ~= true) then
			controller.retiring = false; return false
		end
		local clean = not unresolved
		if subscriptions.request then
			local owned = subscriptions.request; subscriptions.request = nil
			local called, value = pcall(checked.cancel, owned)
			if not called or value ~= true then clean = false end
		end
		if token then
			local owned = token; token = nil
			local called, value = pcall(association.cancel, owned)
			if not called or value ~= true then clean = false end
		end
		local called, value = pcall(writer_ports.close)
		if not called or value ~= true then clean = false end
		controller.retiring = false
		if clean then controller.closed = true; connection.receiving[controller] = nil else debt(controller) end
		return clean
	end
	connection.receiving[controller] = true -- Before any constructor/FFI callbacks.
	local called, value = pcall(function()
		local mask = native.ports.new("unsigned char[2]")
		mask[0], mask[1] = 2, 24 -- DeviceChanged (1), Hierarchy (11), Property (12).
		local selected = native.ports.new("ErgoptiXIPropertyMaskV2[1]")
		selected[0].deviceid, selected[0].mask_len, selected[0].mask = 0, 2, mask
		if not current() or native.ports.select_xi(connection.display, native.ports.root(connection.display), selected, 1) ~= 0
			or not current() then return false end
		local atom = tonumber(intern_atom(connection.display, "Device Node", 1))
		if not atom or atom <= 0 or atom > 4294967295 or atom % 1 ~= 0 or not current() then return false end
		checked = build_checked_xi(native.ffi, native, connection, current, hold, release, debt)
		if not checked then return false end
		association = build_output_association(checked, writer_ports, atom, current, hold, release, debt)
		token = association.start()
		if not token or not current() then return false end
		target = build_receiving_map(native.ffi, native, connection, association, token, current,
			function() return drain(native, connection) end, hold, release, debt, ordered_aliases,
			function() return _input_generation end)
		return target ~= nil and current()
	end)
	constructing = false
	if not called or value ~= true or retired then controller.retire(); return nil end
	local capability = {}
	receiving_controllers[capability] = controller
	controller.current = function() return current() and target.current() == true end
	controller.drive = function()
		if not current() or not drain(native, connection) or not current() then return false end
		local facts, reason = association.drive(token)
		if not facts then
			if reason == "pending" then return nil end
			return false
		end
		if not subscriptions.complete then
			if subscriptions.request then
				local observed, refusal, consumed = checked.poll(subscriptions.request)
				if consumed == true then subscriptions.request = nil end
				if not observed then
					if refusal == "pending" then return nil end
					return false
				end
				if observed.selected ~= true or not current() then return false end
				subscriptions.index = subscriptions.index + 1
			end
			if subscriptions.index <= 2 then
				local id = subscriptions.index == 1 and facts.device or facts.attachment
				subscriptions.request = checked.select_xkb(id)
				if not subscriptions.request or not current() then return false end
				return nil -- Retained checked void ACK on the next original queue drive.
			end
			subscriptions.complete = true
		end
		return controller.current()
	end
	controller.input_allowed = function(source)
		-- Data exclusion only. An input lease is authenticated separately by Hook.
		-- Canonical kernel event names exclude symlink/by-id/hardlink aliases that
		-- are absent from the original /proc device inventory.
		if type(source) ~= "string" or #source > 1024 or not current() or not subscriptions.complete then return false end
		local number = source:match("^/dev/input/event([0-9]+)$")
		if not number or (#number > 1 and number:sub(1, 1) == "0") then return false end
		local facts = association.drive(token)
		return facts ~= nil and facts.status == "kernel-node-associated" and facts.path ~= source and current()
	end
	controller.inspect = function(expected, groups, receive)
		if controller.drive() ~= true then return nil end
		return target.inspect(expected, groups, receive)
	end
	return capability
end
function M.receiving_source_ports(capability)
	local controller = receiving_controllers[capability]
	if not controller then return nil end
	return { current = controller.current, drive = controller.drive,
		inspect = controller.inspect, retire = controller.retire, input_allowed = controller.input_allowed }
end
original_receiving_capture = M.capture_receiving_source

return M
