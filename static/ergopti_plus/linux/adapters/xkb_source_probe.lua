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
	_locked_generation, _last_locked = _locked_generation + 1, nil
	_input_generation, _last_input = _input_generation + 1, nil
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
		or native.x11.XkbSelectEventDetails(display, CORE_KEYBOARD, 2, OBSERVED_COMPONENTS, OBSERVED_COMPONENTS) == 0 then
		native.xkb.xkb_context_unref(context)
		native.x11.XCloseDisplay(display)
		return nil, "native-source-events-unavailable"
	end
	_connection = { display = display, xcb = xcb, context = context, event_base = tonumber(event[0]) }
	_display_name = display_name
	_generation = _generation + 1
	_locked_generation, _last_locked = _locked_generation + 1, nil
	_input_generation, _last_input = _input_generation + 1, nil
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
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), LOCKED_COMPONENT) ~= 0) then
				_locked_generation = _locked_generation + 1
			end
			if kind == 0 or kind == 1 or (kind == 2 and native.bit.band(tonumber(state.changed), INPUT_COMPONENTS) ~= 0) then
				_input_generation = _input_generation + 1
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
	drain(native, connection)
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
	return { group = group, generation = _generation, backend = "x11" }
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

return M
