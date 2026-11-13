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
--- 1. Both protocol generations, chosen by what the compositor offers:
---    version 1 announces every window through its own `toplevel` event with
---    title, app_id and state, each window committed by its `done`. Version 2
---    and later never send that event: windows come from
---    ext-foreign-toplevel-list (title, app_id, `done` per window) and the
---    worker asks `get_cosmic_toplevel` for each one's state, the batch closed
---    by the info object's `done`. Version 2 is bound when the compositor offers
---    it with the list, version 1 otherwise. The interface tables are built by
---    hand, as the clipboard owner builds data-control's (no wayland-scanner
---    at run time).
--- 2. A process of its own: libwayland calls the listeners from C, which a
---    compiled LuaJIT trace cannot host, so the daemon's loop never does.
--- 3. Fail closed: no window, or more than one, activated after a commit is
---    "clear" (unknown), as `lswt` listings are judged in window_info. The
---    protocol gives no process id; the record leaves it out.
--- 4. Fail fast: a missing library, display or global, `finished`, a lost
---    connection or a parent gone end the worker, which the daemon reads as
---    "unknown" for the rest of the session.
--- 5. Pure core: `M.choose_protocol()` and `M.new_tracker()` need no library
---    and the unit tests drive them directly.
--- ==============================================================================

local M = {}

-- The class and title bounds every focus worker shares.
local Focus = require("adapters.compositor_focus")

-- The globals this worker binds, and the versions whose events it implements.
M.INFO_INTERFACE = "zcosmic_toplevel_info_v1"
M.HANDLE_INTERFACE = "zcosmic_toplevel_handle_v1"
M.LIST_INTERFACE = "ext_foreign_toplevel_list_v1"
M.FOREIGN_HANDLE_INTERFACE = "ext_foreign_toplevel_handle_v1"
M.INFO_VERSION_V1 = 1
M.INFO_VERSION_V2 = 2
M.LIST_VERSION = 1
-- zcosmic_toplevel_handle_v1.state values (cosmic-toplevel-info-unstable-v1.xml).
M.STATE_ACTIVATED = 2

-- Event opcodes, in the order the protocols declare them.
M.INFO_EVENTS = { "toplevel", "finished", "done" }
M.HANDLE_EVENTS = { "closed", "done", "title", "app_id", "output_enter", "output_leave",
	"workspace_enter", "workspace_leave", "state", "geometry", "ext_workspace_enter", "ext_workspace_leave" }
M.LIST_EVENTS = { "toplevel", "finished" }
M.FOREIGN_HANDLE_EVENTS = { "closed", "done", "title", "app_id", "identifier" }

local PR_SET_PDEATHSIG = 1
local SIGKILL = 9




-- ===================================
-- ===================================
-- ======= 1/ Window Tracker =========
-- ===================================
-- ===================================

--- Chooses the protocol generation from the globals the compositor offers.
--- Version 2 needs the list that announces the windows; without it, version
--- 1 is bound, which every later version still serves.
--- @param offered table interface name -> { name = number, version = number }
--- @return table plan { info_version = number, list = boolean }
function M.choose_protocol(offered)
	local info = offered[M.INFO_INTERFACE]
	assert(info, "the compositor offers no " .. M.INFO_INTERFACE)
	assert(type(info.version) == "number" and info.version >= 1 and info.version % 1 == 0,
		"the toplevel info version is invalid")
	if info.version >= M.INFO_VERSION_V2 and offered[M.LIST_INTERFACE] then
		return { info_version = M.INFO_VERSION_V2, list = true }
	end
	return { info_version = M.INFO_VERSION_V1, list = false }
end

--- Creates the window table one connection feeds.
--- Each window accumulates title, app_id and state until its `done`, which
--- commits them; the focus line is decided after every commit or close.
--- With `atomic_states` (version 2), states are committed only by
--- `batch_done`, the info object's `done`, so an activation moving between
--- two windows is never seen half-way.
--- @param options table|nil { atomic_states = boolean }
--- @return table tracker { add, title, app_id, state, done, batch_done, closed, current }
function M.new_tracker(options)
	options = options or {}
	local atomic_states = options.atomic_states == true
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

	local function line_of(record)
		return record.kind .. "\0" .. tostring(record.class) .. "\0" .. tostring(record.title)
			.. "\0" .. tostring(record.id)
	end

	--- The record to print after a change, nil when it repeats the last one.
	--- @return table|nil record
	local function changed()
		local record = focus_record()
		local line = line_of(record)
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
			pending = {}, pending_state = nil, committed = false }
	end

	local function window_of(key)
		local window = windows[key]
		assert(window, "an event names an unknown toplevel handle")
		return window
	end

	--- Records a pending title, refusing an oversized one as malformed.
	function tracker.title(key, value)
		assert(type(value) == "string" and #value <= Focus.MAX_TITLE_BYTES, "toplevel title exceeds its bound")
		window_of(key).pending.title = value
	end

	--- Records a pending app_id.
	function tracker.app_id(key, value)
		assert(type(value) == "string" and #value <= Focus.MAX_CLASS_BYTES, "toplevel app_id exceeds its bound")
		window_of(key).pending.app_id = value
	end

	--- Records the pending state list.
	--- @param states table Array of state values.
	function tracker.state(key, states)
		local activated = false
		for _, value in ipairs(states) do
			if value == M.STATE_ACTIVATED then activated = true end
		end
		local window = window_of(key)
		if atomic_states then window.pending_state = activated else window.pending.activated = activated end
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

	--- Commits every window's pending state at once (version 2 only).
	--- @return table|nil record The line to print, nil when focus did not change.
	function tracker.batch_done()
		assert(atomic_states, "a batch done belongs to version 2 only")
		for _, window in pairs(windows) do
			if window.pending_state ~= nil then
				window.activated, window.pending_state = window.pending_state, nil
			end
		end
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
		last_line = line_of(record)
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

--- Builds the interface tables of the chosen generation.
--- The two COSMIC interfaces declare every event up to version 3: binding
--- version 2 then dispatches each one the compositor may send.
--- @param ffi table
--- @param anchor table Keeps every C object alive for the process lifetime.
--- @param info_version number The version bound.
--- @return table interfaces { info, handle, list, foreign } interface pointers.
local function build_interfaces(ffi, anchor, info_version)
	local function str(text)
		local buffer = ffi.new("char[?]", #text + 1, text)
		anchor[#anchor + 1] = buffer
		return buffer
	end
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
	local tables = {}
	local pointers = {}
	for _, name in ipairs({ "info", "handle", "list", "foreign" }) do
		tables[name] = ffi.new("struct wl_interface[1]")
		anchor[#anchor + 1] = tables[name]
		pointers[name] = ffi.cast("const struct wl_interface *", tables[name])
	end
	local function fill(key, name, version, requests, events)
		local target = tables[key]
		target[0].name = str(name)
		target[0].version = version
		target[0].methods, target[0].method_count = messages(requests)
		target[0].events, target[0].event_count = messages(events)
	end
	fill("info", M.INFO_INTERFACE, info_version,
		{ { "stop", "" }, { "get_cosmic_toplevel", "2no", { pointers.handle, pointers.foreign } } },
		{ { "toplevel", "n", { pointers.handle } }, { "finished", "" }, { "done", "2" } })
	-- Object arguments are typed NULL: libwayland then skips the interface check
	-- for the outputs and workspaces this worker never binds.
	fill("handle", M.HANDLE_INTERFACE, info_version, { { "destroy", "" } }, {
		{ "closed", "" }, { "done", "" }, { "title", "s", { null } }, { "app_id", "s", { null } },
		{ "output_enter", "o", { null } }, { "output_leave", "o", { null } },
		{ "workspace_enter", "o", { null } }, { "workspace_leave", "o", { null } },
		{ "state", "a", { null } }, { "geometry", "2oiiii", { null, null, null, null, null } },
		{ "ext_workspace_enter", "3o", { null } }, { "ext_workspace_leave", "3o", { null } },
	})
	fill("list", M.LIST_INTERFACE, M.LIST_VERSION, { { "stop", "" }, { "destroy", "" } },
		{ { "toplevel", "n", { pointers.foreign } }, { "finished", "" } })
	fill("foreign", M.FOREIGN_HANDLE_INTERFACE, M.LIST_VERSION, { { "destroy", "" } }, {
		{ "closed", "" }, { "done", "" }, { "title", "s", { null } }, { "app_id", "s", { null } },
		{ "identifier", "s", { null } },
	})
	return pointers
end

--- Builds a listener array, every slot not named ignored.
--- @param ffi table
--- @param events table The interface's event names, in opcode order.
--- @param callbacks table name -> C callback.
--- @param ignored cdata The callback of an unread event.
--- @return cdata listener
local function listener(ffi, events, callbacks, ignored)
	local slots = {}
	for index, name in ipairs(events) do slots[index] = ffi.cast("void *", callbacks[name] or ignored) end
	return ffi.new("void *[?]", #slots, slots)
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

	local registry = wl.wl_proxy_marshal_array_constructor_versioned(display, 1, ffi.new("union wl_argument[1]"),
		ffi.cast("const struct wl_interface *", wl.wl_registry_interface), wl.wl_proxy_get_version(display))
	assert(registry ~= nil, "registry request refused")
	local offered = {}
	local on_global = ffi.cast("void (*)(void *, void *, uint32_t, const char *, uint32_t)",
		function(_, _, name, interface, version)
			local text = ffi.string(interface)
			if (text == M.INFO_INTERFACE or text == M.LIST_INTERFACE) and not offered[text] then
				offered[text] = { name = name, version = version }
			end
		end)
	local on_global_remove = ffi.cast("void (*)(void *, void *, uint32_t)", function() end)
	local registry_listener = ffi.new("void *[2]", { ffi.cast("void *", on_global), ffi.cast("void *", on_global_remove) })
	anchor[#anchor + 1] = { on_global, on_global_remove, registry_listener }
	wl.wl_proxy_add_listener(registry, registry_listener, nil)
	assert(wl.wl_display_roundtrip(display) >= 0, "Wayland connection lost")
	local plan = M.choose_protocol(offered)
	local interfaces = build_interfaces(ffi, anchor, plan.info_version)

	local function bind(interface_name, interface, version)
		local name = ffi.new("char[?]", #interface_name + 1, interface_name)
		local args = ffi.new("union wl_argument[4]")
		args[0].u, args[1].s, args[2].u, args[3].n = offered[interface_name].name, name, version, 0
		local proxy = wl.wl_proxy_marshal_array_constructor_versioned(registry, 0, args, interface, version)
		assert(proxy ~= nil, interface_name .. " bind refused")
		return proxy
	end
	local info = bind(M.INFO_INTERFACE, interfaces.info, plan.info_version)

	local tracker = M.new_tracker({ atomic_states = plan.list })
	local ready, stopped, parent_gone = false, nil, false
	-- Version 2: each COSMIC handle's key is the list handle it extends.
	local owner = {}
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
	local function destroy(proxy)
		wl.wl_proxy_marshal_array(proxy, 0, nil)
		wl.wl_proxy_destroy(proxy)
	end
	local function read_states(array)
		local states = {}
		local values = ffi.cast("uint32_t *", array.data)
		for index = 0, tonumber(array.size) / 4 - 1 do states[#states + 1] = tonumber(values[index]) end
		return states
	end

	local ignored = ffi.cast("void (*)(void *, void *)", function() end)
	local text_callback = "void (*)(void *, void *, const char *)"
	local handle_listener
	if plan.list then
		local cosmic_callbacks = {
			state = ffi.cast("void (*)(void *, void *, struct wl_array *)", guarded(function(_, handle, array)
				local key = owner[key_of(handle)]
				assert(key, "a state names an unknown COSMIC toplevel")
				tracker.state(key, read_states(array))
			end)),
		}
		handle_listener = listener(ffi, M.HANDLE_EVENTS, cosmic_callbacks, ignored)
		local cosmic_of = {}
		local foreign_callbacks = {
			closed = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
				local key = key_of(handle)
				publish(tracker.closed(key))
				local cosmic = cosmic_of[key]
				cosmic_of[key] = nil
				owner[key_of(cosmic)] = nil
				destroy(cosmic)
				destroy(handle)
			end)),
			done = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
				publish(tracker.done(key_of(handle)))
			end)),
			title = ffi.cast(text_callback, guarded(function(_, handle, value)
				tracker.title(key_of(handle), ffi.string(value))
			end)),
			app_id = ffi.cast(text_callback, guarded(function(_, handle, value)
				tracker.app_id(key_of(handle), ffi.string(value))
			end)),
		}
		local foreign_listener = listener(ffi, M.FOREIGN_HANDLE_EVENTS, foreign_callbacks, ignored)
		local on_toplevel = ffi.cast("void (*)(void *, void *, void *)", guarded(function(_, _, handle)
			local key = key_of(handle)
			tracker.add(key)
			assert(wl.wl_proxy_add_listener(handle, foreign_listener, nil) == 0, "foreign toplevel listener refused")
			local args = ffi.new("union wl_argument[2]")
			args[0].n, args[1].o = 0, handle
			local cosmic = wl.wl_proxy_marshal_array_constructor_versioned(info, 1, args, interfaces.handle,
				plan.info_version)
			assert(cosmic ~= nil, "get_cosmic_toplevel refused")
			cosmic_of[key], owner[key_of(cosmic)] = cosmic, key
			assert(wl.wl_proxy_add_listener(cosmic, handle_listener, nil) == 0, "COSMIC toplevel listener refused")
		end))
		local on_list_finished = ffi.cast("void (*)(void *, void *)",
			function() stop("the compositor finished the toplevel list") end)
		local list_listener = ffi.new("void *[2]", { ffi.cast("void *", on_toplevel), ffi.cast("void *", on_list_finished) })
		local info_callbacks = {
			finished = ffi.cast("void (*)(void *, void *)", function() stop("the compositor finished toplevel info") end),
			done = ffi.cast("void (*)(void *, void *)", guarded(function() publish(tracker.batch_done()) end)),
		}
		local info_listener = listener(ffi, M.INFO_EVENTS, info_callbacks, ignored)
		anchor[#anchor + 1] = { cosmic_callbacks, foreign_callbacks, foreign_listener, on_toplevel, on_list_finished,
			list_listener, info_callbacks, info_listener }
		assert(wl.wl_proxy_add_listener(info, info_listener, nil) == 0, "toplevel info listener refused")
		local list = bind(M.LIST_INTERFACE, interfaces.list, M.LIST_VERSION)
		assert(wl.wl_proxy_add_listener(list, list_listener, nil) == 0, "toplevel list listener refused")
	else
		local handle_callbacks = {
			closed = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
				publish(tracker.closed(key_of(handle)))
				destroy(handle)
			end)),
			done = ffi.cast("void (*)(void *, void *)", guarded(function(_, handle)
				publish(tracker.done(key_of(handle)))
			end)),
			title = ffi.cast(text_callback, guarded(function(_, handle, value)
				tracker.title(key_of(handle), ffi.string(value))
			end)),
			app_id = ffi.cast(text_callback, guarded(function(_, handle, value)
				tracker.app_id(key_of(handle), ffi.string(value))
			end)),
			state = ffi.cast("void (*)(void *, void *, struct wl_array *)", guarded(function(_, handle, array)
				tracker.state(key_of(handle), read_states(array))
			end)),
		}
		handle_listener = listener(ffi, M.HANDLE_EVENTS, handle_callbacks, ignored)
		local on_toplevel = ffi.cast("void (*)(void *, void *, void *)", guarded(function(_, _, handle)
			tracker.add(key_of(handle))
			assert(wl.wl_proxy_add_listener(handle, handle_listener, nil) == 0, "toplevel listener refused")
		end))
		local on_finished = ffi.cast("void (*)(void *, void *)", function() stop("the compositor finished toplevel info") end)
		local info_listener = ffi.new("void *[2]", { ffi.cast("void *", on_toplevel), ffi.cast("void *", on_finished) })
		anchor[#anchor + 1] = { handle_callbacks, on_toplevel, on_finished, info_listener }
		assert(wl.wl_proxy_add_listener(info, info_listener, nil) == 0, "toplevel info listener refused")
	end
	anchor[#anchor + 1] = { ignored, handle_listener }

	-- Round trips: the bind, the first batch of every window, and in version 2
	-- the states the windows' COSMIC handles answer.
	for _ = 1, plan.list and 3 or 2 do assert(wl.wl_display_roundtrip(display) >= 0, "Wayland connection lost") end
	if stopped then return stopped, false end
	ready = true
	if not emit({ kind = "ready", protocol = plan.info_version }) then return "stdout closed" end
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
	local Json = require("core.text.engine.json")
	local function emit(record)
		local written = io.stdout:write(Json.encode(record), "\n")
		return written ~= nil and io.stdout:flush() ~= nil
	end
	local ok, detail, parent_gone = pcall(M.run, arg[1], tonumber(arg[2]), emit)
	io.stderr:write("COSMIC toplevel worker stopped: " .. tostring(detail) .. "\n")
	os.exit(ok and parent_gone and 0 or 1)
end

return M
