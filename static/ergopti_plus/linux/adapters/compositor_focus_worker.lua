--- adapters/compositor_focus_worker.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/core/lifecycle/engine/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


--- ==============================================================================
--- MODULE: Compositor Focus Worker (Linux)
--- DESCRIPTION:
--- Owns the org.ergopti.Focus session-bus name that the Ergopti GNOME Shell
--- extension and KWin script call back on every focus change, and turns each
--- admitted call into one JSON line on stdout for adapters/compositor_focus.
---
--- FEATURES & RATIONALE:
--- 1. A process of its own: GDBus dispatches method calls from a GLib main loop
---    and LuaJIT FFI callbacks re-entered from compiled code panic, so the
---    daemon's input loop never hosts them (the AT-SPI worker's reason too).
--- 2. Only the desktop answers: a call is admitted when its sender is the
---    current owner of org.gnome.Shell or org.kde.KWin, asked of the bus for
---    every call with a bounded timeout. Any other session client gets an
---    error and changes nothing.
--- 3. Fail fast: a name already owned, a lost bus, a parent gone or a write
---    refused end the worker, which the daemon reads as "unknown".
--- 4. Bounded fields: an oversized or malformed argument is refused, never
---    truncated into a different identity.
--- ==============================================================================

local M = {}

local G_BUS_TYPE_SESSION = 2
local REQUEST_NAME_DO_NOT_QUEUE = 4
local REQUEST_NAME_PRIMARY_OWNER = 1
local G_DBUS_CALL_FLAGS_NO_AUTO_START = 1
local PR_SET_PDEATHSIG = 1
local SIGKILL = 9
local LIVENESS_INTERVAL_MS = 1000
local MAX_ID_BYTES = 128
local KWIN_SCRIPT_ID = "ergopti-focus"

-- Exposed so the shipped desktop files are checked against the values this
-- worker serves rather than against a copy of its text.
M.KWIN_SCRIPT_ID = KWIN_SCRIPT_ID




-- ======================================
-- ======================================
-- ======= 1/ Admission (pure) ==========
-- ======================================
-- ======================================

--- Validates one Activated call's arguments into the stdout record.
--- @param class string WM class or resource class.
--- @param title string Window title.
--- @param pid string Decimal process id, or "" when the desktop has none.
--- @param id string Desktop window id.
--- @return table|nil record, string|nil reason
function M.activation_record(class, title, pid, id)
	for _, value in ipairs({ class, title, pid, id }) do
		if type(value) ~= "string" or value:find("\0", 1, true) then return nil, "malformed argument" end
	end
	local Focus = require("adapters.compositor_focus")
	if #class > Focus.MAX_CLASS_BYTES or #title > Focus.MAX_TITLE_BYTES or #id > MAX_ID_BYTES then
		return nil, "oversized argument"
	end
	if id == "" or not id:match("^[%w{}%-_]+$") then return nil, "malformed window id" end
	local number = nil
	if pid ~= "" then
		number = pid:match("^[1-9]%d*$") and tonumber(pid) or nil
		if not number or number > 2147483647 then return nil, "malformed process id" end
	end
	return { kind = "focus", class = class, title = title, pid = number, id = id }
end




-- ======================================
-- ======================================
-- ======= 2/ Native Bus ================
-- ======================================
-- ======================================

local INTROSPECTION = [[
<node>
  <interface name="org.ergopti.Focus1">
    <method name="Activated">
      <arg type="s" name="wm_class" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="s" name="pid" direction="in"/>
      <arg type="s" name="window_id" direction="in"/>
    </method>
    <method name="Cleared"/>
  </interface>
</node>
]]
M.INTROSPECTION = INTROSPECTION

--- Serves the bus name until the parent, the bus or stdout goes away.
--- @param service string org.gnome.Shell or org.kde.KWin.
--- @param parent_pid number The daemon's process id.
--- @return boolean completed False when the worker had to stop on a failure.
function M.run(service, parent_pid)
	local Focus = require("adapters.compositor_focus")
	assert(Focus.is_desktop_service(service), "unsupported desktop service")
	require("jit").off()
	local ffi = require("ffi")
	local Json = require("core.text.engine.json")
	ffi.cdef([[
		typedef struct { uint32_t domain; int code; char *message; } ErgoptiGError;
		typedef void (*ErgoptiMethodCall)(void *, const char *, const char *, const char *,
			const char *, void *, void *, void *);
		typedef struct { ErgoptiMethodCall method_call; void *get_property; void *set_property;
			void *padding[8]; } ErgoptiInterfaceVTable;
		int prctl(int option, ...);
		int getppid(void);
		void *g_bus_get_sync(int bus_type, void *cancellable, ErgoptiGError **error);
		void *g_dbus_node_info_new_for_xml(const char *xml, ErgoptiGError **error);
		void *g_dbus_node_info_lookup_interface(void *info, const char *name);
		void g_dbus_node_info_unref(void *info);
		unsigned int g_dbus_connection_register_object(void *connection, const char *path, void *info,
			const ErgoptiInterfaceVTable *vtable, void *data, void *free_data, ErgoptiGError **error);
		void *g_dbus_connection_call_sync(void *connection, const char *bus_name, const char *path,
			const char *iface, const char *method, void *parameters, void *reply_type, int flags,
			int timeout_ms, void *cancellable, ErgoptiGError **error);
		int g_dbus_connection_is_closed(void *connection);
		void g_dbus_method_invocation_return_value(void *invocation, void *parameters);
		void g_dbus_method_invocation_return_dbus_error(void *invocation, const char *name, const char *message);
		void *g_variant_new_string(const char *value);
		void *g_variant_new_uint32(uint32_t value);
		void *g_variant_new_tuple(void **children, size_t count);
		const char *g_variant_get_type_string(void *value);
		void *g_variant_get_child_value(void *value, size_t index);
		const char *g_variant_get_string(void *value, size_t *length);
		uint32_t g_variant_get_uint32(void *value);
		void g_variant_unref(void *value);
		void g_error_free(ErgoptiGError *error);
		void g_object_unref(void *object);
		void *g_main_loop_new(void *context, int running);
		void g_main_loop_run(void *loop);
		void g_main_loop_quit(void *loop);
		void g_main_loop_unref(void *loop);
		unsigned int g_timeout_add(unsigned int interval, int (*callback)(void *), void *data);
	]])
	local gio = ffi.load("libgio-2.0.so.0")
	local glib = ffi.load("libglib-2.0.so.0")
	local timeout_ms = Focus.CALL_TIMEOUT_MS

	-- PR_SET_PDEATHSIG ends the worker even after an unclean daemon SIGKILL;
	-- checking the parent afterwards closes the startup race.
	assert(ffi.C.prctl(PR_SET_PDEATHSIG, ffi.cast("unsigned long", SIGKILL), 0, 0, 0) == 0, "parent lifetime binding failed")
	assert(tonumber(ffi.C.getppid()) == parent_pid, "compositor focus worker parent already exited")

	local function checked(value, error_slot, what)
		if error_slot[0] ~= nil then
			local message = ffi.string(error_slot[0].message)
			gio.g_error_free(error_slot[0])
			error(what .. ": " .. message, 0)
		end
		assert(value ~= nil, what)
		return value
	end
	local error_slot = ffi.new("ErgoptiGError *[1]")
	local connection = checked(gio.g_bus_get_sync(G_BUS_TYPE_SESSION, nil, error_slot), error_slot, "session bus unavailable")

	--- One bounded synchronous call; nil when the bus refuses or times out.
	local function call(bus_name, path, iface, method, children)
		local parameters = nil
		if children then
			local array = ffi.new("void *[?]", #children)
			for index, child in ipairs(children) do array[index - 1] = child end
			parameters = gio.g_variant_new_tuple(array, #children)
		end
		local slot = ffi.new("ErgoptiGError *[1]")
		local reply = gio.g_dbus_connection_call_sync(connection, bus_name, path, iface, method, parameters,
			nil, G_DBUS_CALL_FLAGS_NO_AUTO_START, timeout_ms, nil, slot)
		if slot[0] ~= nil then gio.g_error_free(slot[0]); return nil end
		return reply
	end
	local function string_child(value, index)
		local child = gio.g_variant_get_child_value(value, index)
		local text = ffi.string(gio.g_variant_get_string(child, nil))
		gio.g_variant_unref(child)
		return text
	end

	-- The desktop calls this unique name back; DO_NOT_QUEUE refuses to wait
	-- behind another owner, which would be a second daemon or an impostor.
	local requested = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
		{ gio.g_variant_new_string(Focus.BUS_NAME), gio.g_variant_new_uint32(REQUEST_NAME_DO_NOT_QUEUE) })
	assert(requested ~= nil, "bus name request refused")
	local child = gio.g_variant_get_child_value(requested, 0)
	local granted = gio.g_variant_get_uint32(child)
	gio.g_variant_unref(child)
	gio.g_variant_unref(requested)
	assert(granted == REQUEST_NAME_PRIMARY_OWNER, "bus name " .. Focus.BUS_NAME .. " already owned")

	local loop = assert(glib.g_main_loop_new(nil, 0), "main loop unavailable")
	local failed = nil
	local function stop(reason)
		failed = failed or reason
		glib.g_main_loop_quit(loop)
	end
	local function emit(record)
		local written = io.stdout:write(Json.encode(record), "\n")
		if not written or not io.stdout:flush() then stop("stdout closed") end
	end
	local function current_owner()
		local reply = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
			{ gio.g_variant_new_string(service) })
		if reply == nil then return nil end
		local owner = string_child(reply, 0)
		gio.g_variant_unref(reply)
		return owner
	end

	local method_callback = ffi.cast("ErgoptiMethodCall", function(_, sender, _, _, method, parameters, invocation)
		local accepted, failure = pcall(function()
			local caller = sender ~= nil and ffi.string(sender) or ""
			if caller == "" or caller ~= current_owner() then
				gio.g_dbus_method_invocation_return_dbus_error(invocation, "org.ergopti.Focus.Error.Denied",
					"only the desktop shell may report focus")
				return
			end
			local name = ffi.string(method)
			local record, reason = nil, "unknown method"
			if name == "Cleared" then
				record = { kind = "clear" }
			elseif name == "Activated" and ffi.string(gio.g_variant_get_type_string(parameters)) == "(ssss)" then
				record, reason = M.activation_record(string_child(parameters, 0), string_child(parameters, 1),
					string_child(parameters, 2), string_child(parameters, 3))
			end
			if not record then
				-- A refused report from the desktop itself must not leave the
				-- previous window current.
				emit({ kind = "clear" })
				gio.g_dbus_method_invocation_return_dbus_error(invocation, "org.ergopti.Focus.Error.Invalid", reason)
				return
			end
			emit(record)
			gio.g_dbus_method_invocation_return_value(invocation, nil)
		end)
		if not accepted then stop(tostring(failure)) end
	end)

	local node = checked(gio.g_dbus_node_info_new_for_xml(INTROSPECTION, error_slot), error_slot, "interface description refused")
	local info = assert(gio.g_dbus_node_info_lookup_interface(node, Focus.INTERFACE), "interface description incomplete")
	local vtable = ffi.new("ErgoptiInterfaceVTable")
	vtable.method_call = method_callback
	local registration = gio.g_dbus_connection_register_object(connection, Focus.OBJECT_PATH, info, vtable, nil, nil, error_slot)
	checked(registration ~= 0 and registration or nil, error_slot, "object registration refused")

	local liveness = ffi.cast("int (*)(void *)", function()
		if tonumber(ffi.C.getppid()) ~= parent_pid then stop("parent exited"); return 0 end
		if gio.g_dbus_connection_is_closed(connection) ~= 0 then stop("session bus closed"); return 0 end
		return 1
	end)
	glib.g_timeout_add(LIVENESS_INTERVAL_MS, liveness, nil)

	emit({ kind = "ready" })
	if service == Focus.SERVICES.kde then
		-- A KWin script runs once when loaded and reports the active window
		-- then; reloading it now tells a daemon started after KWin which window
		-- is active. A refusal only means "unknown until the next activation".
		local unloaded = call("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript",
			{ gio.g_variant_new_string(KWIN_SCRIPT_ID) })
		if unloaded ~= nil then gio.g_variant_unref(unloaded) end
		local started = call("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start", nil)
		if started ~= nil then gio.g_variant_unref(started) end
	end
	if not failed then glib.g_main_loop_run(loop) end

	glib.g_main_loop_unref(loop)
	gio.g_dbus_node_info_unref(node)
	gio.g_object_unref(connection)
	method_callback:free()
	liveness:free()
	if failed and failed ~= "parent exited" then
		io.stderr:write("Compositor focus worker stopped: " .. failed .. "\n")
		return false
	end
	return true
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:match("/compositor_focus_worker%.lua$") then
	local shared_lua = arg[3]
	assert(type(shared_lua) == "string" and shared_lua ~= "", "canonical shared Lua directory unavailable")
	if literal_driver then
		local resolver = assert(package.loaded["core.lifecycle.engine.literal_module_loader"])
		resolver.prepend({ { ".", ".lua" }, { ".", "/init.lua" },
			{ shared_lua, ".lua" }, { shared_lua, "/init.lua" } })
	else
		package.path = "./?.lua;./?/init.lua;" .. shared_lua .. "/?.lua;" .. shared_lua .. "/?/init.lua;" .. package.path
	end
	local ok, completed = pcall(M.run, arg[1], tonumber(arg[2]))
	if not ok then io.stderr:write("Compositor focus worker refused: " .. tostring(completed) .. "\n") end
	if not ok or completed ~= true then os.exit(1) end
end

return M
