--- adapters/atspi_focus_watch_worker.lua

--- ==============================================================================
--- MODULE: Resident Accessibility Focus Worker (Linux)
--- DESCRIPTION:
--- Runs libatspi outside the input process. Focus notifications publish unknown
--- before any potentially blocking traversal. The private pipe contains only
--- role, native identity and monotonic lifecycle receipts, never accessible text.
--- ==============================================================================

local M = {}

--- Owns one native AT-SPI listener until its parent or accessibility bus leaves.
--- @param pipe_path string Private daemon-owned FIFO.
--- @param parent_pid number Exact native daemon process.
--- @param heartbeat_ms number Shared privacy scheduling interval.
--- @param control_path string Private refresh request FIFO.
--- @return boolean completed
function M.run(pipe_path, parent_pid, heartbeat_ms, control_path)
	local ffi = require("ffi")
	ffi.cdef([[
		int open(const char *path, int flags, ...);
		long write(int fd, const void *buffer, unsigned long count);
		long read(int fd, void *buffer, unsigned long count);
		int close(int fd);
		int getppid(void);
		int prctl(int option, ...);
		int atspi_init(void);
		int atspi_exit(void);
		typedef struct _AtspiAccessible AtspiAccessible;
		AtspiAccessible *atspi_get_desktop(int index);
		void atspi_accessible_clear_cache(AtspiAccessible *object);
		void atspi_set_timeout(int timeout, int startup_timeout);
		void *atspi_get_a11y_bus(void);
		void *atspi_event_listener_new(void (*callback)(void *, void *), void *data, void *destroy);
		int atspi_event_listener_register(void *listener, const char *type, void **error);
		int atspi_event_listener_deregister(void *listener, const char *type, void **error);
		unsigned long atspi_event_get_type(void);
		void g_boxed_free(unsigned long type, void *boxed);
		void g_object_unref(void *object);
		void g_error_free(void *error);
		int dbus_connection_get_is_connected(void *connection);
		void *g_main_loop_new(void *context, int running);
		void g_main_loop_run(void *loop);
		void g_main_loop_quit(void *loop);
		void g_main_loop_unref(void *loop);
		unsigned int g_timeout_add(unsigned int interval, int (*callback)(void *), void *data);
		int g_source_remove(unsigned int id);
		unsigned int g_idle_add(int (*callback)(void *), void *data);
		unsigned int g_unix_fd_add(int fd, int conditions, int (*callback)(int, int, void *), void *data);
	]])
	local atspi = ffi.load("libatspi.so.0")
	local glib = ffi.load("libglib-2.0.so.0")
	local gobject = ffi.load("libgobject-2.0.so.0")
	local dbus = ffi.load("libdbus-1.so.3")
	local Focus = require("adapters.atspi_focus")
	local Json = require("json")
	local Monotonic = require("infra.monotonic")
	local timeout_ms = require("infra.timings").ms("privacy", "atspi_probe_timeout_ms")

	-- PR_SET_PDEATHSIG closes the detached helper even after an unclean SIGKILL.
	-- Checking the original parent after prctl closes the startup parent-death race.
	assert(ffi.C.prctl(1, ffi.cast("unsigned long", 9), 0, 0, 0) == 0, "parent lifetime binding failed")
	assert(tonumber(ffi.C.getppid()) == parent_pid, "focus worker parent already exited")
	local descriptor = ffi.C.open(pipe_path, 1 + 524288) -- O_WRONLY | O_CLOEXEC.
	assert(descriptor >= 0, "private focus pipe could not be opened")
	local sequence, request, dirty, failed = 0, 0, true, false
	local control = ffi.C.open(control_path, 2048 + 524288)
	assert(control >= 0, "private focus request pipe could not be opened")
	local control_source, idle_source = nil, nil
	local control_callback, idle_callback = nil, nil
	local loop, listener, timer = nil, nil, nil
	local event_callback, timer_callback = nil, nil
	local events = { "object:state-changed:focused", "window:activate", "window:deactivate" }
	local registered = {}

	local function emit(kind, snapshot)
		sequence = sequence + 1
		local message = { kind = kind, sequence = sequence, request = request, at_ms = Monotonic.now_ms() }
		if snapshot then
			message.role = snapshot.role
			message.active_scope = snapshot.active_scope == true
			message.bus = snapshot.native_bus_name
			message.path = snapshot.native_object_path
		end
		local encoded = Json.encode(message) .. "\n"
		assert(ffi.C.write(descriptor, encoded, #encoded) == #encoded, "private focus pipe write failed")
	end
	local handles = nil
	local needs_scan = true
	local function publish()
		if handles then
			local snapshot, conclusive = Focus._check_native_watch_focus(handles)
			if conclusive == true then emit("snapshot", snapshot); return end
			Focus._release_native_watch_focus(handles)
			handles = nil
			needs_scan = true
			emit("unknown")
			return
		end
		local snapshot, conclusive, retained = Focus._get_native_watch_snapshot()
		handles = retained
		needs_scan = false
		if conclusive == true then emit("snapshot", snapshot) else emit("unknown") end
	end
	local function abort()
		failed = true
		if loop ~= nil then glib.g_main_loop_quit(loop) end
	end
	local function schedule()
		dirty = true
		if idle_source == nil then
			idle_source = glib.g_idle_add(idle_callback, nil)
			assert(idle_source ~= 0, "native focus refresh scheduling failed")
		end
	end
	local ok, error_message = pcall(function()
		emit("unknown")
		atspi.atspi_set_timeout(timeout_ms, timeout_ms)
		assert(atspi.atspi_init() == 0, "AT-SPI listener initialization failed")
		loop = assert(glib.g_main_loop_new(nil, 0))
		idle_callback = ffi.cast("int (*)(void *)", function()
			idle_source = nil
			local accepted = pcall(function()
				dirty = false
				publish()
				if needs_scan then schedule() end
			end)
			if not accepted then abort() end
			return 0
		end)
		event_callback = ffi.cast("void (*)(void *, void *)", function(event)
			local accepted = pcall(function() emit("unknown"); schedule() end)
			gobject.g_boxed_free(atspi.atspi_event_get_type(), event)
			if not accepted then abort() end
		end)
		listener = atspi.atspi_event_listener_new(event_callback, nil, nil)
		assert(listener ~= nil, "AT-SPI listener allocation failed")
		for _, event_type in ipairs(events) do
			local error_slot = ffi.new("void *[1]")
			local admitted = atspi.atspi_event_listener_register(listener, event_type, error_slot) ~= 0
			if error_slot[0] ~= nil then glib.g_error_free(error_slot[0]); admitted = false end
			assert(admitted, "AT-SPI focus subscription failed")
			registered[#registered + 1] = event_type
		end

		local control_buffer, control_pending = ffi.new("char[4096]"), ""
		control_callback = ffi.cast("int (*)(int, int, void *)", function()
			local accepted = pcall(function()
				local count = tonumber(ffi.C.read(control, control_buffer, 4096))
				assert(count >= 0 or ffi.errno() == 11, "native focus request read failed")
				if count <= 0 then return end
				control_pending = control_pending .. ffi.string(control_buffer, count)
				assert(#control_pending <= 4096, "native focus request exceeded bound")
				while true do
					local newline = control_pending:find("\n", 1, true)
					if not newline then break end
					local next_request = tonumber(control_pending:sub(1, newline - 1):match("^R(%d+)$"))
					assert(next_request and next_request > request, "native focus request sequence invalid")
					request = next_request
					control_pending = control_pending:sub(newline + 1)
				end
				schedule()
			end)
			if not accepted then abort(); control_source = nil; return 0 end
			return 1
		end)
		control_source = glib.g_unix_fd_add(control, 1, control_callback, nil)
		assert(control_source ~= 0, "native focus request watch refused")
		emit("ready")
		timer_callback = ffi.cast("int (*)(void *)", function()
			local accepted = pcall(function()
				local bus = atspi.atspi_get_a11y_bus()
				assert(tonumber(ffi.C.getppid()) == parent_pid and bus ~= nil
					and dbus.dbus_connection_get_is_connected(bus) ~= 0, "focus listener authority ended")
				if dirty then dirty = false; publish() else emit("heartbeat") end
			end)
			if not accepted then abort(); timer = nil; return 0 end
			return 1
		end)
		timer = glib.g_timeout_add(heartbeat_ms, timer_callback, nil)
		assert(timer ~= 0, "AT-SPI listener timer refused")
		dirty = false
		publish()
		glib.g_main_loop_run(loop)
	end)
	if timer then glib.g_source_remove(timer) end
	if control_source then glib.g_source_remove(control_source) end
	if idle_source then glib.g_source_remove(idle_source) end
	if listener ~= nil then
		for _, event_type in ipairs(registered) do
			local error_slot = ffi.new("void *[1]")
			atspi.atspi_event_listener_deregister(listener, event_type, error_slot)
			if error_slot[0] ~= nil then glib.g_error_free(error_slot[0]) end
		end
		gobject.g_object_unref(listener)
	end
	if loop ~= nil then glib.g_main_loop_unref(loop) end
	if event_callback then event_callback:free() end
	if timer_callback then timer_callback:free() end
	if control_callback then control_callback:free() end
	if idle_callback then idle_callback:free() end
	Focus._release_native_watch_focus(handles)
	atspi.atspi_exit()
	assert(ffi.C.close(control) == 0, "private focus request pipe did not close")
	assert(ffi.C.close(descriptor) == 0, "private focus pipe did not close")
	if not ok then error(error_message, 0) end
	return not failed
end

if type(arg) == "table" and type(arg[0]) == "string"
	and arg[0]:match("/atspi_focus_watch_worker%.lua$") then
	local shared_lua = arg[5]
	assert(type(shared_lua) == "string" and shared_lua ~= "", "canonical shared Lua directory unavailable")
	package.path = "./?.lua;./?/init.lua;" .. shared_lua .. "/?.lua;" .. shared_lua .. "/?/init.lua;" .. package.path
	local ok, completed = pcall(M.run, arg[1], tonumber(arg[2]), tonumber(arg[3]), arg[4])
	if not ok or completed ~= true then
		io.stderr:write("Native accessibility focus worker stopped without authority.\n")
		os.exit(1)
	end
end

return M
