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

local LOG = "adapters.atspi_focus"
local STATE_FOCUSED = 12
local MAX_DEPTH = 64
local MAX_NODES = 4096

local _backend_for_test = nil
local _native_backend = nil
local _native_attempted = false
local _command_runner_for_test = nil





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
		void g_object_unref(void *object);
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
	function backend.role(node)
		local error_slot = ffi.new("void *[1]")
		local role = tonumber(atspi.atspi_accessible_get_role(node, error_slot))
		if release_error(error_slot) then return nil end
		return role
	end
	function backend.identity(node)
		local identity = { name = "", attributes = {} }
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

local function traverse(backend)
	if not backend then return nil, false end
	local root = backend.root()
	if root == nil then return nil, false end

	local visited = 0
	local failed = false
	local focused_role = nil
	local focused_identity = nil
	local focused_count = 0

	local function visit(node, depth)
		if failed or depth > MAX_DEPTH then failed = true; return end
		visited = visited + 1
		if visited > MAX_NODES then failed = true; return end

		local focused = backend.focused(node)
		if focused == nil then failed = true; return end
		if focused then
			local role = backend.role(node)
			if type(role) ~= "number" then failed = true; return end
			local identity = type(backend.identity) == "function"
				and backend.identity(node) or { name = "", attributes = {} }
			if type(identity) ~= "table" then failed = true; return end
			focused_count = focused_count + 1
			focused_role = role
			focused_identity = identity
		end

		local children = backend.children(node)
		if type(children) ~= "table" then failed = true; return end
		for _, child in ipairs(children) do
			visit(child, depth + 1)
			if backend.release then backend.release(child) end
		end
	end

	local ok, traversal_error = pcall(visit, root, 0)
	if backend.release then backend.release(root) end
	if not ok then
		Logger.debug(LOG, "AT-SPI traversal failed — %s", tostring(traversal_error))
		return nil, false
	end
	if failed or focused_count ~= 1 then return nil, false, nil end
	return focused_role, true, focused_identity
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
	}, true
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
function M.get_snapshot()
	if _backend_for_test then
		local role, conclusive, identity = traverse(_backend_for_test)
		if not conclusive then return nil, false end
		return {
			role = role,
			name = type(identity) == "table" and identity.name or "",
			attributes = type(identity) == "table" and identity.attributes or {},
		}, true
	end

	local executable = type(arg) == "table" and arg[-1] or nil
	if type(executable) ~= "string" or executable == "" then executable = "luajit" end
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
