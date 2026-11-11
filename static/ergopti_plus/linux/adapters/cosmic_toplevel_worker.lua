--- adapters/cosmic_toplevel_worker.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/infra/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


--- ==============================================================================
--- MODULE: COSMIC Toplevel Worker (Linux)
--- DESCRIPTION:
--- Reads the focused window of a COSMIC session through its toplevel-info
--- protocol (`zcosmic_toplevel_info_v1`, cosmic-protocols) with
--- libwayland-client over FFI, and prints one JSON line per change for
--- adapters/compositor_focus, in the records the GNOME and KDE worker prints.
---
--- FEATURES & RATIONALE:
--- 1. Version 1 of the protocol: its `toplevel` event announces every window
---    with its title, app_id and state (activated among them) and `done` ends
---    each batch. Later versions move the announcement to
---    ext-foreign-toplevel-list, which carries no activation; binding version 1
---    needs one protocol only. The interface tables are built by hand, as the
---    clipboard owner builds data-control's (no wayland-scanner at run time).
--- 2. A process of its own: libwayland calls the listeners from C, which a
---    compiled LuaJIT trace cannot host, so the daemon's loop never does.
--- 3. Fail closed: no window, or more than one, activated after a `done` is
---    "clear" (unknown), as `lswt` listings are judged in window_info. The
---    protocol gives no process id; the record leaves it out.
--- 4. Fail fast: a missing library, display or global, `finished`, a lost
---    connection or a parent gone end the worker, which the daemon reads as
---    "unknown" for the rest of the session.
--- 5. Pure core: `M.new_tracker()` holds the window table and decides each
---    line; it needs no library and the unit tests drive it directly.
--- ==============================================================================

local M = {}

-- The class and title bounds every focus worker shares.
local Focus = require("adapters.compositor_focus")

-- The global this worker binds, and the version whose events it implements.
M.INFO_INTERFACE = "zcosmic_toplevel_info_v1"
M.HANDLE_INTERFACE = "zcosmic_toplevel_handle_v1"
M.INFO_VERSION = 1
-- zcosmic_toplevel_handle_v1.state values (cosmic-toplevel-info-unstable-v1.xml).
M.STATE_ACTIVATED = 2

-- Event opcodes of version 1, in the order the protocol declares them.
M.INFO_EVENTS = { "toplevel", "finished" }
M.HANDLE_EVENTS = { "closed", "done", "title", "app_id", "output_enter", "output_leave",
	"workspace_enter", "workspace_leave", "state" }

local PR_SET_PDEATHSIG = 1
local SIGKILL = 9




-- ===================================
-- ===================================
-- ======= 1/ Window Tracker =========
-- ===================================
-- ===================================

--- Creates the window table one connection feeds.
--- Each handle accumulates title, app_id and state until its `done`, which
--- commits them; the focus line is decided after every commit or close.
--- @return table tracker { add, title, app_id, state, done, closed, line }
function M.new_tracker()
	local tracker = {}
	local windows = {}
	local serial = 0
	local last_line = nil

	--- The record of the single activated window, or a clear.
	--- @return table record
	local function focus_record()
		local active = nil
		for _, window in pairs(windows) do
			if window.committed and window.activated then
				if active then return { kind = "clear" } end
				active = window
			end
		end
		if not active then return { kind = "clear" } end
		return { kind = "focus", class = active.app_id, title = active.title, id = active.id }
	end

	--- The record to print after a change, nil when it repeats the last one.
	--- @return table|nil record
	local function changed()
		local record = focus_record()
		local line = record.kind .. "\0" .. tostring(record.class) .. "\0" .. tostring(record.title)
			.. "\0" .. tostring(record.id)
		if line == last_line then return nil end
		last_line = line
		return record
	end

	--- Announces a window.
	--- @param key any The handle's identity in this connection.
	function tracker.add(key)
		assert(windows[key] == nil, "a toplevel handle was announced twice")
		serial = serial + 1
		windows[key] = { id = "cosmic-" .. serial, title = "", app_id = "", activated = false,
			pending = {}, committed = false }
	end

	local function pending(key)
		local window = windows[key]
		assert(window, "an event names an unknown toplevel handle")
		return window.pending
	end

	--- Records a pending title, refusing an oversized one as malformed.
	function tracker.title(key, value)
		assert(type(value) == "string" and #value <= Focus.MAX_TITLE_BYTES, "toplevel title exceeds its bound")
		pending(key).title = value
	end

	--- Records a pending app_id.
	function tracker.app_id(key, value)
		assert(type(value) == "string" and #value <= Focus.MAX_CLASS_BYTES, "toplevel app_id exceeds its bound")
		pending(key).app_id = value
	end

	--- Records the pending state list.
	--- @param states table Array of state values.
	function tracker.state(key, states)
		local activated = false
		for _, value in ipairs(states) do
			if value == M.STATE_ACTIVATED then activated = true end
		end
		pending(key).activated = activated
	end

	--- Commits a window's pending values.
	--- @return table|nil record The line to print, nil when focus did not change.
	function tracker.done(key)
		local window = windows[key]
		assert(window, "done names an unknown toplevel handle")
		for field, value in pairs(window.pending) do window[field] = value end
		window.pending, window.committed = {}, true
		return changed()
	end

	--- Forgets a closed window.
	--- @return table|nil record The line to print, nil when focus did not change.
	function tracker.closed(key)
		assert(windows[key], "closed names an unknown toplevel handle")
		windows[key] = nil
		return changed()
	end

	--- The record the current table gives, for the line after readiness.
	--- @return table record
	function tracker.current()
		local record = focus_record()
		last_line = record.kind .. "\0" .. tostring(record.class) .. "\0" .. tostring(record.title)
			.. "\0" .. tostring(record.id)
		return record
	end

	return tracker
end




-- ===================================
-- ===================================
-- ======= 2/ Wayland Client =========
-- ===================================
-- ===================================

local DECLARATIONS = {
	"struct wl_interface;",
	"struct wl_message { const char *name; const char *signature; const struct wl_interface **types; };",
	"struct wl_interface { const char *name; int version; int method_count; const struct wl_message *methods;"
		.. " int event_count; const struct wl_message *events; };",
	"union wl_argument { int32_t i; uint32_t u; int32_t f; const char *s; void *o; uint32_t n; void *a; int32_t h; };",
	"struct wl_array { size_t size; size_t alloc; void *data; };",
	"void *wl_display_connect(const char *name);",
	"void wl_display_disconnect(void *display);",
	"int wl_display_roundtrip(void *display);",
	"int wl_display_dispatch(void *display);",
	"void *wl_proxy_marshal_array_constructor_versioned(void *proxy, uint32_t opcode, union wl_argument *args,"
		.. " const struct wl_interface *interface, uint32_t version);",
	"void wl_proxy_marshal_array(void *proxy, uint32_t opcode, union wl_argument *args);",
	"int wl_proxy_add_listener(void *proxy, void **implementation, void *data);",
	"uint32_t wl_proxy_get_version(void *proxy);",
	"void wl_proxy_destroy(void *proxy);",
	"int prctl(int option, ...);",
	"int getppid(void);",
	"extern const struct wl_interface wl_registry_interface;",
}

--- Declares the C calls, tolerating another module's identical declaration.
--- @param ffi table
local function declare(ffi)
	for _, declaration in ipairs(DECLARATIONS) do
		local ok, err = pcall(ffi.cdef, declaration)
		if not ok and not tostring(err):find("redefin", 1, true) then error(err, 0) end
	end
end

--- Builds the two interfaces of version 1.
--- @param ffi table
--- @param anchor table Keeps every C object alive for the process lifetime.
--- @return cdata info, cdata handle Interface pointers.
local function build_interfaces(ffi, anchor)
	local function str(text)
		local buffer = ffi.new("char[?]", #text + 1, text)
		anchor[#anchor + 1] = buffer
		return buffer
	end
	local info = ffi.new("struct wl_interface[1]")
	local handle = ffi.new("struct wl_interface[1]")
	anchor[#anchor + 1], anchor[#anchor + 2] = info, handle
	local null = ffi.cast("const struct wl_interface *", nil)
	local function types(list)
		local array = ffi.new("const struct wl_interface *[?]", math.max(#list, 1))
		for index, value in ipairs(list) do array[index - 1] = value end
		anchor[#anchor + 1] = array
		return array
	end
	local function messages(list)
		local array = ffi.new("struct wl_message[?]", math.max(#list, 1))
		for index, message in ipairs(list) do
			array[index - 1].name = str(message[1])
			array[index - 1].signature = str(message[2])
			array[index - 1].types = types(message[3] or {})
		end
		anchor[#anchor + 1] = array
		return array, #list
	end
	local function fill(target, name, requests, events)
		target[0].name = str(name)
		target[0].version = M.INFO_VERSION
		target[0].methods, target[0].method_count = messages(requests)
		target[0].events, target[0].event_count = messages(events)
	end
	local handle_pointer = ffi.cast("const struct wl_interface *", handle)
	fill(info, M.INFO_INTERFACE, { { "stop", "" } },
		{ { "toplevel", "n", { handle_pointer } }, { "finished", "" } })
	-- Object arguments are typed NULL: libwayland then skips the interface check
	-- for the outputs and workspaces this worker never binds.
	fill(handle, M.HANDLE_INTERFACE, { { "destroy", "" } }, {
		{ "closed", "" }, { "done", "" }, { "title", "s", { null } }, { "app_id", "s", { null } },
		{ "output_enter", "o", { null } }, { "output_leave", "o", { null } },
		{ "workspace_enter", "o", { null } }, { "workspace_leave", "o", { null } },
		{ "state", "a", { null } },
	})
	return ffi.cast("const struct wl_interface *", info), handle_pointer
end

--- Runs the worker until the compositor, the connection or the parent goes.
--- @param soname string libwayland-client's soname.
--- @param parent_pid number The daemon's process id.
--- @param emit function(record) Prints one record; false when stdout is gone.
--- @return string detail Why the worker stopped, for its stderr line.
--- @return boolean parent_gone True when it stopped because the daemon exited.
function M.run(soname, parent_pid, emit)
	require("jit").off()
	local ffi = require("ffi")
	declare(ffi)
	-- PR_SET_PDEATHSIG ends the worker even after an unclean daemon SIGKILL;
	-- checking the parent afterwards closes the startup race.
	assert(ffi.C.prctl(PR_SET_PDEATHSIG, ffi.cast("unsigned long", SIGKILL), 0, 0, 0) == 0, "parent lifetime binding failed")
	assert(tonumber(ffi.C.getppid()) == parent_pid, "COSMIC toplevel worker parent already exited")
	local loaded, wl = pcall(ffi.load, soname)
	assert(loaded, "libwayland-client unavailable: " .. tostring(wl))
	local display = wl.wl_display_connect(nil)
	assert(display ~= nil, "no Wayland display")
	local anchor = {}
	local info_interface, handle_interface = build_interfaces(ffi, anchor)

	local registry = wl.wl_proxy_marshal_array_constructor_versioned(display, 1, ffi.new("union wl_argument[1]"),
		ffi.cast("const struct wl_interface *", wl.wl_registry_interface), wl.wl_proxy_get_version(display))
	assert(registry ~= nil, "registry request refused")
	local info_global = nil
	local on_global = ffi.cast("void (*)(void *, void *, uint32_t, const char *, uint32_t)",
		function(_, _, name, interface, version)
			if ffi.string(interface) == M.INFO_INTERFACE and not info_global then
				info_global = { name = name, version = version }
			end
		end)
	local on_global_remove = ffi.cast("void (*)(void *, void *, uint32_t)", function() end)
	local registry_listener = ffi.new("void *[2]", { ffi.cast("void *", on_global), ffi.cast("void *", on_global_remove) })
	anchor[#anchor + 1] = { on_global, on_global_remove, registry_listener }
	wl.wl_proxy_add_listener(registry, registry_listener, nil)
	assert(wl.wl_display_roundtrip(display) >= 0, "Wayland connection lost")
	assert(info_global, "the compositor offers no " .. M.INFO_INTERFACE)

	local name = ffi.new("char[?]", #M.INFO_INTERFACE + 1, M.INFO_INTERFACE)
	local bind = ffi.new("union wl_argument[4]")
	bind[0].u, bind[1].s, bind[2].u, bind[3].n = info_global.name, name, M.INFO_VERSION, 0
	local info = wl.wl_proxy_marshal_array_constructor_versioned(registry, 0, bind, info_interface, M.INFO_VERSION)
	assert(info ~= nil, "toplevel info bind refused")

	local tracker = M.new_tracker()
	local ready, stopped, parent_gone = false, nil, false
	local keys = {}
	local function key_of(handle) return tostring(ffi.cast("uintptr_t", handle)) end
	local function stop(detail) if not stopped then stopped = detail end end
	local function publish(record)
		if record and ready and not emit(record) then stop("stdout closed") end
	end
	local function guarded(body)
		return function(...)
			if stopped then return end
			local ok, failure = pcall(body, ...)
			if not ok then stop(tostring(failure)) end
		end
	end

	local handle_callbacks = {
		closed = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
			local key = key_of(handle)
			keys[key] = nil
			publish(tracker.closed(key))
			wl.wl_proxy_marshal_array(handle, 0, nil)
			wl.wl_proxy_destroy(handle)
		end)),
		done = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
			publish(tracker.done(key_of(handle)))
		end)),
		title = ffi.cast("void (*)(void *, void *, const char *)", guarded(function(_, handle, value)
			tracker.title(key_of(handle), ffi.string(value))
		end)),
		app_id = ffi.cast("void (*)(void *, void *, const char *)", guarded(function(_, handle, value)
			tracker.app_id(key_of(handle), ffi.string(value))
		end)),
		ignored = ffi.cast("void (*)(void *, void *, void *)", function() end),
		state = ffi.cast("void (*)(void *, void *, struct wl_array *)", guarded(function(_, handle, array)
			local states = {}
			local values = ffi.cast("uint32_t *", array.data)
			for index = 0, tonumber(array.size) / 4 - 1 do states[#states + 1] = tonumber(values[index]) end
			tracker.state(key_of(handle), states)
		end)),
	}
	local handle_listener = ffi.new("void *[9]", {
		ffi.cast("void *", handle_callbacks.closed), ffi.cast("void *", handle_callbacks.done),
		ffi.cast("void *", handle_callbacks.title), ffi.cast("void *", handle_callbacks.app_id),
		ffi.cast("void *", handle_callbacks.ignored), ffi.cast("void *", handle_callbacks.ignored),
		ffi.cast("void *", handle_callbacks.ignored), ffi.cast("void *", handle_callbacks.ignored),
		ffi.cast("void *", handle_callbacks.state),
	})
	local on_toplevel = ffi.cast("void (*)(void *, void *, void *)", guarded(function(_, _, handle)
		local key = key_of(handle)
		tracker.add(key)
		keys[key] = handle
		assert(wl.wl_proxy_add_listener(handle, handle_listener, nil) == 0, "toplevel listener refused")
	end))
	local on_finished = ffi.cast("void (*)(void *, void *)", function() stop("the compositor finished toplevel info") end)
	local info_listener = ffi.new("void *[2]", { ffi.cast("void *", on_toplevel), ffi.cast("void *", on_finished) })
	anchor[#anchor + 1] = { handle_callbacks, handle_listener, on_toplevel, on_finished, info_listener }
	assert(wl.wl_proxy_add_listener(info, info_listener, nil) == 0, "toplevel info listener refused")

	-- Two round trips: the bind, then the first batch of every window.
	for _ = 1, 2 do assert(wl.wl_display_roundtrip(display) >= 0, "Wayland connection lost") end
	if stopped then return stopped, false end
	ready = true
	if not emit({ kind = "ready" }) then return "stdout closed" end
	publish(tracker.current())
	while not stopped do
		if wl.wl_display_dispatch(display) < 0 then stop("Wayland connection lost") end
		if tonumber(ffi.C.getppid()) ~= parent_pid then
			parent_gone = not stopped
			stop("parent exited")
		end
	end
	wl.wl_display_disconnect(display)
	return stopped, parent_gone
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:match("cosmic_toplevel_worker%.lua$") then
	local shared_lua = arg[3]
	assert(type(shared_lua) == "string" and shared_lua ~= "", "canonical shared Lua directory unavailable")
	if literal_driver then
		local resolver = assert(package.loaded["infra.literal_module_loader"])
		resolver.prepend({ { ".", ".lua" }, { ".", "/init.lua" },
			{ shared_lua, ".lua" }, { shared_lua, "/init.lua" } })
	else
		package.path = "./?.lua;./?/init.lua;" .. shared_lua .. "/?.lua;" .. shared_lua .. "/?/init.lua;" .. package.path
	end
	local Json = require("json")
	local function emit(record)
		local written = io.stdout:write(Json.encode(record), "\n")
		return written ~= nil and io.stdout:flush() ~= nil
	end
	local ok, detail, parent_gone = pcall(M.run, arg[1], tonumber(arg[2]), emit)
	io.stderr:write("COSMIC toplevel worker stopped: " .. tostring(detail) .. "\n")
	os.exit(ok and parent_gone and 0 or 1)
end

return M
