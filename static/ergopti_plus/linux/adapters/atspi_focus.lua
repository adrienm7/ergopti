--- adapters/atspi_focus.lua

--- ==============================================================================
--- MODULE: AT-SPI Focus Query (Linux)
--- DESCRIPTION:
--- Queries the focused accessible through libatspi. The registry D-Bus interface
--- has no GetFocused method; focus is a state on accessible objects. This adapter
--- traverses the cached accessibility tree off the input path and returns the role
--- only when exactly one current focused object is found conclusively.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")
local Timings = require("infra.timings")
local Interpreter = require("process.interpreter")
local NativeIdentity = require("adapters.atspi_native_identity")

local LOG = "adapters.atspi_focus"
local STATE_ACTIVE = 1
local STATE_FOCUSED = 12
local MAX_DEPTH = 64
local MAX_NODES = 4096

local _backend_for_test = nil
local _native_backend = nil
local _native_attempted = false
local _command_runner_for_test = nil
local _last_snapshot = nil





-- ===================================
-- ===================================
-- ======= 1/ Native Backend =========
-- ===================================
-- ===================================

local function load_native_backend()
	if _native_attempted then return _native_backend end
	_native_attempted = true

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil end
	local ok_cdef = pcall(ffi.cdef, [[
		typedef struct _AtspiAccessible AtspiAccessible;
		typedef struct _AtspiStateSet AtspiStateSet;
		typedef struct _GHashTable GHashTable;
		int atspi_init(void);
		int atspi_is_initialized(void);
		AtspiAccessible *atspi_get_desktop(int i);
		int atspi_accessible_get_child_count(AtspiAccessible *obj, void **error);
		AtspiAccessible *atspi_accessible_get_child_at_index(
			AtspiAccessible *obj, int child_index, void **error);
		AtspiStateSet *atspi_accessible_get_state_set(AtspiAccessible *obj);
		int atspi_state_set_contains(AtspiStateSet *set, int state);
		unsigned int atspi_accessible_get_role(AtspiAccessible *obj, void **error);
		char *atspi_accessible_get_name(AtspiAccessible *obj, void **error);
		GHashTable *atspi_accessible_get_attributes(AtspiAccessible *obj, void **error);
		void *g_hash_table_lookup(GHashTable *hash_table, const void *key);
		void g_hash_table_unref(GHashTable *hash_table);
		void g_free(void *mem);
		void *g_object_ref(void *object);
		void g_object_unref(void *object);
		void atspi_accessible_clear_cache(AtspiAccessible *object);
		void g_error_free(void *error);
	]])
	if not ok_cdef then return nil end

	local ok_atspi, atspi = pcall(ffi.load, "libatspi.so.0")
	local ok_gobject, gobject = pcall(ffi.load, "libgobject-2.0.so.0")
	local ok_glib, glib = pcall(ffi.load, "libglib-2.0.so.0")
	if not ok_atspi or not ok_gobject or not ok_glib then return nil end

	local function release_error(error_slot)
		if error_slot[0] ~= nil then
			glib.g_error_free(error_slot[0])
			error_slot[0] = nil
			return true
		end
		return false
	end

	local backend = {}
	function backend.root()
		if atspi.atspi_is_initialized() == 0 and atspi.atspi_init() ~= 0 then return nil end
		local root = atspi.atspi_get_desktop(0)
		return root ~= nil and root or nil
	end
	function backend.retain(node) return gobject.g_object_ref(node) end
	function backend.clear(node) atspi.atspi_accessible_clear_cache(node) end
	function backend.clear_tree(node) atspi.atspi_accessible_clear_cache(node) end
	function backend.release(node)
		if node ~= nil then gobject.g_object_unref(node) end
	end
	function backend.focused(node)
		local states = atspi.atspi_accessible_get_state_set(node)
		if states == nil then return nil end
		local focused = atspi.atspi_state_set_contains(states, STATE_FOCUSED) ~= 0
		gobject.g_object_unref(states)
		return focused
	end
	function backend.active(node)
		local states = atspi.atspi_accessible_get_state_set(node)
		if states == nil then return nil end
		local active = atspi.atspi_state_set_contains(states, STATE_ACTIVE) ~= 0
		gobject.g_object_unref(states)
		return active
	end
	function backend.role(node)
		local error_slot = ffi.new("void *[1]")
		local role = tonumber(atspi.atspi_accessible_get_role(node, error_slot))
		if release_error(error_slot) then return nil end
		return role
	end
	function backend.identity(node)
		local identity = { name = "", attributes = {} }
		local native = NativeIdentity.capture and NativeIdentity.capture(node)
		if native then
			identity.native_bus_name = native.native_bus_name
			identity.native_object_path = native.native_object_path
		end
		local name_error = ffi.new("void *[1]")
		local name = atspi.atspi_accessible_get_name(node, name_error)
		if release_error(name_error) then return nil end
		if name ~= nil then
			identity.name = ffi.string(name)
			glib.g_free(name)
		end

		local attrs_error = ffi.new("void *[1]")
		local attrs = atspi.atspi_accessible_get_attributes(node, attrs_error)
		if release_error(attrs_error) then return nil end
		if attrs ~= nil then
			for _, key in ipairs({ "id", "class", "placeholder-text", "xml-roles", "tag" }) do
				local value = glib.g_hash_table_lookup(attrs, key)
				if value ~= nil then identity.attributes[key] = ffi.string(value) end
			end
			glib.g_hash_table_unref(attrs)
		end
		return identity
	end
	function backend.children(node)
		local error_slot = ffi.new("void *[1]")
		local count = tonumber(atspi.atspi_accessible_get_child_count(node, error_slot))
		if release_error(error_slot) or not count or count < 0 then return nil end
		local children = {}
		for index = 0, count - 1 do
			local child_error = ffi.new("void *[1]")
			local child = atspi.atspi_accessible_get_child_at_index(node, index, child_error)
			if release_error(child_error) then
				for _, owned in ipairs(children) do backend.release(owned) end
				return nil
			end
			if child ~= nil then children[#children + 1] = child end
		end
		return children
	end

	_native_backend = backend
	return _native_backend
end





-- ===================================
-- ===================================
-- ======= 2/ Focus Traversal ========
-- ===================================
-- ===================================

local function traverse(backend, retain_focus)
	if not backend then return nil, false end
	local root = backend.root()
	if root == nil then return nil, false end

	local visited = 0
	local failed = false
	local focused_role = nil
	local focused_identity = nil
	local focused_count = 0
	local handles = retain_focus and { backend = backend } or nil

	local function visit(node, depth)
		if failed or depth > MAX_DEPTH then failed = true; return false end
		visited = visited + 1
		if visited > MAX_NODES then failed = true; return false end

		local focused = backend.focused(node)
		if focused == nil then failed = true; return false end
		local role = focused and backend.role(node) or nil
		if focused and type(role) ~= "number" then failed = true; return false end

		local children = backend.children(node)
		if type(children) ~= "table" then failed = true; return false end
		local focused_descendant = false
		for _, child in ipairs(children) do
			if visit(child, depth + 1) then focused_descendant = true end
			if backend.release then backend.release(child) end
		end

		-- WebKit marks its root pane, document and actual HTML input FOCUSED.
		-- Only a unique leaf identifies one destination; siblings still count
		-- separately. A password ancestor never authorizes an ordinary child.
		if focused and focused_descendant and role == 40 then failed = true end
		if focused and not focused_descendant then
			local identity = type(backend.identity) == "function"
				and backend.identity(node) or { name = "", attributes = {} }
			if type(identity) ~= "table" then failed = true; return false end
			focused_count = focused_count + 1
			focused_role = role
			focused_identity = identity
			if handles and type(backend.retain) == "function" then
				if handles.focus then backend.release(handles.focus) end
				handles.focus = backend.retain(node)
			end
		end
		return focused or focused_descendant
	end

	-- Only the ACTIVE top-level window, when the window manager says which one
	-- it is. Every application keeps FOCUSED on the widget it last focused, so a
	-- desktop-wide search found one focused field per open GTK application —
	-- measured with openbox and two windows: two FOCUSED text nodes, one ACTIVE
	-- frame — declared the answer ambiguous, and blocked every expansion as
	-- soon as a second application was open. It also walked every application's
	-- tree against a one-second deadline. Without a window manager nothing is
	-- ACTIVE and the whole desktop is searched, as before.
	local scoped, owned = {}, {}
	if type(backend.active) == "function" then
		local apps = backend.children(root)
		if type(apps) == "table" then
			for _, app in ipairs(apps) do
				owned[#owned + 1] = app
				local windows = backend.children(app)
				if type(windows) == "table" then
					for _, window in ipairs(windows) do
						if backend.active(window) == true then
							scoped[#scoped + 1] = window
						else
							owned[#owned + 1] = window
						end
					end
				end
			end
		end
	end

	if handles and #scoped == 1 and type(backend.retain) == "function" then
		handles.window = backend.retain(scoped[1])
	end
	local function discard_handles()
		if not handles then return end
		if handles.focus then backend.release(handles.focus) end
		if handles.window then backend.release(handles.window) end
	end
	local ok, traversal_error
	if #scoped > 0 then
		ok, traversal_error = pcall(function()
			for _, window in ipairs(scoped) do visit(window, 2) end
		end)
		for _, window in ipairs(scoped) do owned[#owned + 1] = window end
	else
		ok, traversal_error = pcall(visit, root, 0)
	end
	if backend.release then
		for _, node in ipairs(owned) do backend.release(node) end
		backend.release(root)
	end
	if not ok then
		discard_handles()
		Logger.debug(LOG, "AT-SPI traversal failed — %s", tostring(traversal_error))
		return nil, false
	end
	if failed or focused_count ~= 1 then discard_handles(); return nil, false, nil end
	focused_identity.active_scope = #scoped > 0
	return focused_role, true, focused_identity, handles
end

--- Runs the native traversal in the current process.
--- Exported for the bounded helper process only; daemon callers use get_role().
--- @return number|nil role
--- @return boolean conclusive
function M._get_native_role()
	return traverse(load_native_backend())
end

--- Runs the native traversal and returns the focused accessible snapshot.
--- Exported only for the bounded helper process.
--- @return table|nil snapshot
--- @return boolean conclusive
function M._get_native_snapshot()
	local role, conclusive, identity = traverse(load_native_backend())
	if not conclusive then return nil, false end
	return {
		role = role,
		name = type(identity) == "table" and identity.name or "",
		attributes = type(identity) == "table" and identity.attributes or {},
		active_scope = type(identity) == "table" and identity.active_scope == true,
		native_bus_name = type(identity) == "table" and identity.native_bus_name or nil,
		native_object_path = type(identity) == "table" and identity.native_object_path or nil,
	}, true
end

--- Retains exact native control/frame references for one resident worker.
--- Each full scan discards libatspi's old tree cache first; daemon code never
--- receives native pointers or invokes this in the keyboard process.
--- @return table|nil snapshot
--- @return boolean conclusive
--- @return table|nil handles Worker-owned GObject references.
function M._get_native_watch_snapshot()
	local backend = load_native_backend()
	if not backend then return nil, false end
	local root = backend.root()
	if root == nil then return nil, false end
	backend.clear_tree(root)
	backend.release(root)
	local role, conclusive, identity, handles = traverse(backend, true)
	if not conclusive then return nil, false end
	local snapshot = { role = role, active_scope = identity.active_scope == true,
		native_bus_name = identity.native_bus_name, native_object_path = identity.native_object_path }
	if handles then handles.snapshot = snapshot end
	return snapshot, true, handles
end

--- Rechecks exact retained native state through fresh AT-SPI GetState calls.
--- Old focus or inactive frames withhold instead of walking an application's
--- complete tree on the input admission deadline.
--- @param handles table Worker-owned native references.
--- @return table|nil snapshot
--- @return boolean conclusive
function M._check_native_watch_focus(handles)
	if not handles or not handles.focus or not handles.window then return nil, false end
	local backend = handles.backend
	backend.clear(handles.focus)
	backend.clear(handles.window)
	if backend.focused(handles.focus) ~= true or backend.active(handles.window) ~= true then return nil, false end
	local role = backend.role(handles.focus)
	if type(role) ~= "number" then return nil, false end
	return { role = role, active_scope = true, native_bus_name = handles.snapshot.native_bus_name,
		native_object_path = handles.snapshot.native_object_path }, true
end

--- Releases every GObject owned by the resident worker's exact focus receipt.
--- @param handles table|nil Worker-owned native references.
function M._release_native_watch_focus(handles)
	if not handles then return end
	for _, key in ipairs({ "focus", "window" }) do
		if handles[key] then handles.backend.release(handles[key]); handles[key] = nil end
	end
end

--- Returns the focused accessible role and whether the query was conclusive.
--- Production isolates libatspi in a hard-deadline helper: a wedged application
--- accessibility peer must not freeze the daemon's event loop. Tests with a tree
--- backend exercise the traversal directly.
--- @return number|nil role
--- @return boolean conclusive
function M.get_role()
	local snapshot, conclusive = M.get_snapshot()
	return snapshot and snapshot.role or nil, conclusive
end

--- Returns role plus stable accessible identity fields for the focused object.
--- The native call is isolated behind the same hard deadline as get_role().
--- @return table|nil snapshot { role, name, attributes }
--- @return boolean conclusive
local function read_snapshot()
	if _backend_for_test then
		local role, conclusive, identity = traverse(_backend_for_test)
		if not conclusive then return nil, false end
		return {
			role = role,
			name = type(identity) == "table" and identity.name or "",
			attributes = type(identity) == "table" and identity.attributes or {},
		active_scope = type(identity) == "table" and identity.active_scope == true,
		native_bus_name = type(identity) == "table" and identity.native_bus_name or nil,
		native_object_path = type(identity) == "table" and identity.native_object_path or nil,
		}, true
	end

	local executable = Interpreter.from_arguments(arg) or "luajit"
	local timeout_ms = Timings.ms("privacy", "atspi_probe_timeout_ms")
	local timeout_seconds = math.max(1, math.ceil(timeout_ms / 1000))
	local child_code = "local m=require('adapters.atspi_focus'); local j=require('json'); "
		.. "local s,ok=m._get_native_snapshot(); if ok then io.write('FOCUS:'..j.encode(s)) else os.exit(2) end"
	local command = string.format("env LUA_PATH=%s timeout -s KILL %ds %s -e %s 2>/dev/null",
		ShellRunner.quote(package.path), timeout_seconds,
		ShellRunner.quote(executable), ShellRunner.quote(child_code))
	local runner = _command_runner_for_test or ShellRunner.exec_checked
	local ok, output = runner(command)
	if ok ~= true or type(output) ~= "string" then return nil, false end
	local encoded = output:match("FOCUS:(.-)%s*$")
	if not encoded then return nil, false end
	local ok_json, Json = pcall(require, "json")
	if not ok_json then return nil, false end
	local ok_decode, snapshot = pcall(Json.decode, encoded)
	if not ok_decode or type(snapshot) ~= "table" or type(snapshot.role) ~= "number"
		or type(snapshot.attributes) ~= "table" then
		return nil, false
	end
	return snapshot, true
end


--- Copies admitted scalar identity fields without sharing caller-owned tables.
--- @param snapshot table Bounded helper result.
--- @return table copy Detached receipt.
local function copy_snapshot(snapshot)
	local attributes = {}
	for key, value in pairs(snapshot.attributes or {}) do
		if type(key) == "string" and type(value) == "string" then attributes[key] = value end
	end
	return { role = snapshot.role, name = snapshot.name, attributes = attributes,
		active_scope = snapshot.active_scope == true,
		native_bus_name = type(snapshot.native_bus_name) == "string" and snapshot.native_bus_name or nil,
		native_object_path = type(snapshot.native_object_path) == "string" and snapshot.native_object_path or nil }
end

--- Rechecks focus in the isolated helper, invalidating old receipts on failure.
--- @return table|nil snapshot
--- @return boolean conclusive
function M.get_snapshot()
	_last_snapshot = nil
	local snapshot, conclusive = read_snapshot()
	if conclusive ~= true then return nil, false end
	_last_snapshot = copy_snapshot(snapshot)
	return copy_snapshot(_last_snapshot), true
end

--- Reads only the receipt already obtained by the daemon's privacy probe.
--- @return table|nil snapshot Detached cached native focus identity.
function M.cached_snapshot()
	return _last_snapshot and copy_snapshot(_last_snapshot) or nil
end

--- Shares the resident privacy owner's admitted receipt with existing consumers.
--- Only scalar native identity is retained; text and accessible names are absent.
--- @param snapshot table|nil Exact active native worker receipt, or unknown.
function M._publish_resident_snapshot(snapshot)
	_last_snapshot = snapshot and copy_snapshot({ role = snapshot.role, active_scope = true,
		native_bus_name = snapshot.bus, native_object_path = snapshot.path, attributes = {} }) or nil
end

--- Installs an ownership-compatible tree backend for tests.
--- @param backend table|nil
function M._set_backend_for_test(backend)
	_backend_for_test = type(backend) == "table" and backend or nil
end

--- Installs a bounded-command runner for tests.
--- @param runner function|nil Receives the composed command.
function M._set_command_runner_for_test(runner)
	_command_runner_for_test = type(runner) == "function" and runner or nil
end

return M
