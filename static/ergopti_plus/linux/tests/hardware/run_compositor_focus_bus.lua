--- tests/hardware/run_compositor_focus_bus.lua

--- ==============================================================================
--- MODULE: Compositor Focus Worker On A Real Session Bus
--- DESCRIPTION:
--- Runs adapters/compositor_focus_worker.lua against a real dbus-daemon, with
--- this process standing in for GNOME Shell (it owns org.gnome.Shell) and
--- calling the worker exactly as the Ergopti extension does. Pins what no fake
--- can: the name is owned, the (ssss) call is admitted from the desktop's
--- owner only, a malformed report clears the focus, and a second worker
--- refuses to queue behind the first.
---
--- Run from the driver root under a private bus:
---   dbus-run-session -- luajit tests/hardware/run_compositor_focus_bus.lua
--- Exit 0 = every check held; 1 = a check failed; 2 = no session bus or libgio.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

local ffi = require("ffi")
local Json = require("json")
local Focus = require("adapters.compositor_focus")

if (os.getenv("DBUS_SESSION_BUS_ADDRESS") or "") == "" then
	io.stderr:write("ENVIRONMENT: no session bus (run under dbus-run-session)\n")
	os.exit(2)
end
local loaded, gio = pcall(ffi.load, "libgio-2.0.so.0")
if not loaded then
	io.stderr:write("ENVIRONMENT: libgio-2.0 is missing\n")
	os.exit(2)
end

ffi.cdef([[
	typedef struct { uint32_t domain; int code; char *message; } TestGError;
	int getpid(void);
	void *g_dbus_connection_new_for_address_sync(const char *address, int flags, void *observer,
		void *cancellable, TestGError **error);
	void *g_dbus_connection_call_sync(void *connection, const char *bus_name, const char *path,
		const char *iface, const char *method, void *parameters, void *reply_type, int flags,
		int timeout_ms, void *cancellable, TestGError **error);
	void *g_variant_new_string(const char *value);
	void *g_variant_new_uint32(uint32_t value);
	void *g_variant_new_tuple(void **children, size_t count);
	void g_variant_unref(void *value);
	void g_error_free(TestGError *error);
]])

local failures = 0
local function check(condition, label)
	if condition then
		print("PASS  " .. label)
	else
		failures = failures + 1
		print("FAIL  " .. label)
	end
end

--- A fresh private connection: each stands for one session client.
local function connect()
	local slot = ffi.new("TestGError *[1]")
	-- AUTHENTICATION_CLIENT (1) | MESSAGE_BUS_CONNECTION (8).
	local connection = gio.g_dbus_connection_new_for_address_sync(os.getenv("DBUS_SESSION_BUS_ADDRESS"), 9, nil, nil, slot)
	assert(slot[0] == nil and connection ~= nil, "session bus connection refused")
	return connection
end

--- Calls a method; returns true, or false and the bus error message.
local function call(connection, bus, path, iface, method, strings, uint)
	local children = {}
	for _, value in ipairs(strings or {}) do children[#children + 1] = gio.g_variant_new_string(value) end
	if uint then children[#children + 1] = gio.g_variant_new_uint32(uint) end
	local parameters = nil
	if strings or uint then
		local array = ffi.new("void *[?]", #children)
		for index, child in ipairs(children) do array[index - 1] = child end
		parameters = gio.g_variant_new_tuple(array, #children)
	end
	local slot = ffi.new("TestGError *[1]")
	local reply = gio.g_dbus_connection_call_sync(connection, bus, path, iface, method, parameters, nil, 0, 2000, nil, slot)
	if slot[0] ~= nil then
		local message = ffi.string(slot[0].message)
		gio.g_error_free(slot[0])
		return false, message
	end
	if reply ~= nil then gio.g_variant_unref(reply) end
	return true
end

local function report(connection, method, strings)
	return call(connection, Focus.BUS_NAME, Focus.OBJECT_PATH, Focus.INTERFACE, method, strings)
end

local shell = connect()
check(call(shell, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
	{ Focus.SERVICES.gnome }, 4), "the stand-in Shell owns org.gnome.Shell")

local worker_command = "exec luajit adapters/compositor_focus_worker.lua " .. Focus.SERVICES.gnome .. " "
	.. tostring(ffi.C.getpid()) .. " ../_shared/lua"
local worker = assert(io.popen(worker_command, "r"))
local function next_record()
	local line = worker:read("*l")
	return line and Json.decode(line) or nil
end
check((next_record() or {}).kind == "ready", "the worker owns its name and says so")

check(report(shell, "Activated", { "org.gnome.Nautilus", "Documents", "4242", "17" }),
	"the desktop's report is acknowledged")
local record = next_record() or {}
check(record.kind == "focus" and record.class == "org.gnome.Nautilus" and record.title == "Documents"
	and record.pid == 4242 and record.id == "17", "the report reaches stdout intact")

local intruder = connect()
local admitted, reason = report(intruder, "Activated", { "keepassxc", "Fake", "1", "1" })
check(not admitted and tostring(reason):find("Denied", 1, true) ~= nil,
	"another session client is refused")

local invalid = report(shell, "Activated", { "firefox", "Page", "not-a-pid", "18" })
check(not invalid, "a malformed process id is refused")
check((next_record() or {}).kind == "clear", "a refused desktop report clears the focus, never keeps the last one")

check(report(shell, "Activated", { "firefox", "Page", "", "19" }), "a report without a process is admitted")
record = next_record() or {}
check(record.kind == "focus" and record.id == "19" and record.pid == nil,
	"the intruder's call left no line: the next one is the desktop's")

check(report(shell, "Cleared"), "a cleared focus is acknowledged")
check((next_record() or {}).kind == "clear", "a cleared focus reaches stdout")

local second = io.popen(worker_command .. " 2>&1", "r")
local second_output = second:read("*a")
local _, _, second_status = second:close()
check(second_status ~= 0 and second_output:find("already owned", 1, true) ~= nil,
	"a second worker refuses to queue behind the first")

-- No pclose: it would wait for a worker that lives until its parent goes.
-- PR_SET_PDEATHSIG ends it when this process exits.
os.exit(failures == 0 and 0 or 1)
