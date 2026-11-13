--- tests/hardware/run_cosmic_toplevel_fake.lua

--- ==============================================================================
--- MODULE: COSMIC Toplevel Worker Against a Protocol Fake
--- DESCRIPTION:
--- Proves adapters/cosmic_toplevel_worker.lua through the real
--- libwayland-client: this script is a Wayland server of its own (the wire
--- protocol over a Unix socket, in LuaJIT FFI) that offers
--- `zcosmic_toplevel_info_v1` version 1 the way cosmic-comp does, announces
--- windows, moves the activation, closes one and finishes. The worker, run as
--- this script's child, must print ready, then exactly the focus lines the
--- activation gives, a clear when no or two windows are activated, and exit
--- once the compositor finishes. The real COSMIC desktop stays under « To
--- confirm on Linux »: this fake shares the worker's reading of the protocol.
---
--- Run from the Linux driver root (needs luajit and libwayland-client.so.0):
---     luajit tests/hardware/run_cosmic_toplevel_fake.lua
--- Exit 0 = every receipt held; 1 = a failure; 2 = no environment.
--- ==============================================================================

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[
	struct ergopti_sockaddr_un { unsigned short sun_family; char sun_path[108]; };
	struct ergopti_pollfd { int fd; short events; short revents; };
	int socket(int domain, int type, int protocol);
	int bind(int fd, const void *addr, unsigned int len);
	int listen(int fd, int backlog);
	int accept(int fd, void *addr, void *len);
	int poll(struct ergopti_pollfd *fds, unsigned long count, int timeout);
	long read(int fd, void *buffer, unsigned long count);
	long write(int fd, const void *buffer, unsigned long count);
	int close(int fd);
	int fork(void);
	int dup2(int oldfd, int newfd);
	int open(const char *path, int flags, ...);
	int execvp(const char *file, char *const argv[]);
	void _exit(int status);
	int waitpid(int pid, int *status, int options);
	int getpid(void);
	int setenv(const char *name, const char *value, int overwrite);
]])

local AF_UNIX, SOCK_STREAM = 1, 1
local POLLIN = 1
local WNOHANG = 1
local Worker = dofile("adapters/cosmic_toplevel_worker.lua")

local function fail(message)
	io.stderr:write("FAIL: " .. message .. "\n")
	os.exit(1)
end

if not pcall(ffi.load, "libwayland-client.so.0") then
	io.stderr:write("ENVIRONMENT: libwayland-client.so.0 is missing\n")
	os.exit(2)
end




-- ===================================
-- ===================================
-- ======= 1/ Wire Protocol ==========
-- ===================================
-- ===================================

local function u32(value)
	return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 16777216) % 256)
end

local function read_u32(bytes, at)
	local a, b, c, d = bytes:byte(at, at + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

local function padded(bytes)
	return bytes .. string.rep("\0", (4 - #bytes % 4) % 4)
end

local function wl_string(text)
	return u32(#text + 1) .. padded(text .. "\0")
end

local function wl_array(values)
	local body = {}
	for _, value in ipairs(values) do body[#body + 1] = u32(value) end
	local data = table.concat(body)
	return u32(#data) .. padded(data)
end

local function message(object, opcode, body)
	body = body or ""
	return u32(object) .. u32(bit.bor(bit.lshift(8 + #body, 16), opcode)) .. body
end




-- ===================================
-- ===================================
-- ======= 2/ Server =================
-- ===================================
-- ===================================

local runtime = os.tmpname()
os.remove(runtime)
assert(os.execute("mkdir -m 700 -- '" .. runtime .. "'"))
local socket_name = "wayland-ergopti-fake"
local socket_path = runtime .. "/" .. socket_name
local listener = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
assert(listener >= 0, "socket refused")
local address = ffi.new("struct ergopti_sockaddr_un")
address.sun_family = AF_UNIX
ffi.copy(address.sun_path, socket_path)
assert(ffi.C.bind(listener, address, ffi.sizeof(address)) == 0, "bind refused")
assert(ffi.C.listen(listener, 1) == 0, "listen refused")

local output_path = runtime .. "/worker.out"
local errors_path = runtime .. "/worker.err"
ffi.C.setenv("XDG_RUNTIME_DIR", runtime, 1)
ffi.C.setenv("WAYLAND_DISPLAY", socket_name, 1)
local parent = ffi.C.getpid()
local argv_strings = { "luajit", "adapters/cosmic_toplevel_worker.lua", "libwayland-client.so.0", tostring(parent),
	"../_shared" }
local argv = ffi.new("char *[?]", #argv_strings + 1)
local anchor = {}
for index, text in ipairs(argv_strings) do
	anchor[index] = ffi.new("char[?]", #text + 1, text)
	argv[index - 1] = anchor[index]
end
local child = ffi.C.fork()
if child == 0 then
	-- open's mode is variadic: a plain Lua number reaches it as a double and the
	-- files are created mode 0000, which only root can read back.
	local mode = ffi.cast("unsigned int", 420) -- 0644
	local out = ffi.C.open(output_path, 0x241, mode) -- O_WRONLY | O_CREAT | O_TRUNC
	local err = ffi.C.open(errors_path, 0x241, mode)
	ffi.C.dup2(out, 1)
	ffi.C.dup2(err, 2)
	ffi.C.execvp("luajit", argv)
	ffi.C._exit(127)
end
assert(child > 0, "fork refused")

local function wait_readable(fd, timeout_ms)
	local fds = ffi.new("struct ergopti_pollfd[1]")
	fds[0].fd, fds[0].events = fd, POLLIN
	return ffi.C.poll(fds, 1, timeout_ms) > 0
end

if not wait_readable(listener, 5000) then fail("the worker never connected") end
local client = ffi.C.accept(listener, nil, nil)
assert(client >= 0, "accept refused")

local function send(bytes)
	assert(ffi.C.write(client, bytes, #bytes) == #bytes, "write to the worker refused")
end

-- Object ids the client allocated, and the server's own ids.
local registry_id, info_id = nil, nil
local next_server_id = 0xff000000
local INFO_GLOBAL_NAME = 7
local buffer = ""

--- Reads and answers the client's requests for up to `timeout_ms`.
local function serve(timeout_ms)
	-- Counted in poll slices: os.clock is CPU time, which waiting does not spend.
	local slices = math.max(1, math.ceil(timeout_ms / 50))
	for _ = 1, slices do
		if wait_readable(client, 50) then
			local chunk = ffi.new("uint8_t[4096]")
			local got = tonumber(ffi.C.read(client, chunk, 4096))
			if got <= 0 then return false end
			buffer = buffer .. ffi.string(chunk, got)
		end
		while #buffer >= 8 do
			local object = read_u32(buffer, 1)
			local word = read_u32(buffer, 5)
			local size, opcode = math.floor(word / 65536), word % 65536
			if #buffer < size then break end
			local body = buffer:sub(9, size)
			buffer = buffer:sub(size + 1)
			if object == 1 and opcode == 1 then -- wl_display.get_registry
				registry_id = read_u32(body, 1)
				send(message(registry_id, 0, u32(1) .. wl_string("wl_compositor") .. u32(4)))
				send(message(registry_id, 0, u32(INFO_GLOBAL_NAME) .. wl_string(Worker.INFO_INTERFACE) .. u32(3)))
			elseif object == 1 and opcode == 0 then -- wl_display.sync
				local callback = read_u32(body, 1)
				send(message(callback, 0, u32(1)))
				send(message(1, 1, u32(callback))) -- wl_display.delete_id
			elseif object == registry_id and opcode == 0 then -- wl_registry.bind
				local name = read_u32(body, 1)
				local length = read_u32(body, 5)
				local interface = body:sub(9, 8 + length - 1)
				local after = 9 + math.ceil(length / 4) * 4
				local version = read_u32(body, after)
				if name ~= INFO_GLOBAL_NAME or interface ~= Worker.INFO_INTERFACE or version ~= Worker.INFO_VERSION then
					fail(string.format("unexpected bind %d %s v%d", name, interface, version))
				end
				info_id = read_u32(body, after + 4)
			end
			-- Every other request (a handle's destroy) needs no answer.
		end
	end
	return true
end

--- Announces one window and its first batch.
local function announce(title, app_id, states)
	local handle = next_server_id
	next_server_id = next_server_id + 1
	send(message(info_id, 0, u32(handle)))
	send(message(handle, 2, wl_string(title)))
	send(message(handle, 3, wl_string(app_id)))
	send(message(handle, 8, wl_array(states)))
	send(message(handle, 1))
	return handle
end

local function set_state(handle, states)
	send(message(handle, 8, wl_array(states)))
	send(message(handle, 1))
end

local function lines()
	local file = io.open(output_path, "rb")
	local text = file and file:read("*a") or ""
	if file then file:close() end
	local out = {}
	for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
	return out
end

--- Serves until the worker has printed `count` lines.
local function expect_lines(count, what)
	for _ = 1, 100 do
		serve(50)
		if #lines() >= count then return lines() end
	end
	fail(what .. ": the worker printed " .. #lines() .. " line(s), stderr: "
		.. (io.open(errors_path, "rb") and io.open(errors_path, "rb"):read("*a") or ""))
end




-- ===================================
-- ===================================
-- ======= 3/ Receipts ===============
-- ===================================
-- ===================================

-- The bind, then the windows of the first batch before the worker's second round trip.
for _ = 1, 40 do
	serve(50)
	if info_id then break end
end
if not info_id then fail("the worker never bound " .. Worker.INFO_INTERFACE) end
local editor = announce("notes.txt — Text Editor", "com.system76.CosmicEdit", { Worker.STATE_ACTIVATED })
local terminal = announce("~ — Terminal", "com.system76.CosmicTerm", {})

local seen = expect_lines(2, "readiness and the first focus")
local receipts = 0
local function check(index, pattern, what)
	if not seen[index] or not seen[index]:find(pattern) then
		fail(what .. ": line " .. index .. " is " .. tostring(seen[index]))
	end
	receipts = receipts + 1
	print("ok  " .. what)
end
check(1, '"kind":"ready"', "the worker is ready once its first batch is read")
check(2, '"class":"com.system76.CosmicEdit"', "the activated window is the focus")

set_state(editor, {})
set_state(terminal, { 0, Worker.STATE_ACTIVATED })
seen = expect_lines(4, "the activation moving")
-- The first done leaves no window activated: unknown, until the second.
check(3, '"kind":"clear"', "no activated window is unknown")
check(4, '"class":"com.system76.CosmicTerm"', "the newly activated window is the focus")

set_state(editor, { Worker.STATE_ACTIVATED })
seen = expect_lines(5, "two activated windows")
check(5, '"kind":"clear"', "two activated windows are unknown, never a guess")

send(message(terminal, 0)) -- closed
seen = expect_lines(6, "a closed window")
check(6, '"class":"com.system76.CosmicEdit"', "closing one leaves the other the focus")
if not seen[6]:find('"title":"notes.txt — Text Editor"', 1, true) then fail("the title is carried byte for byte") end
if seen[6]:find('"pid"', 1, true) then fail("COSMIC gives no process id; none is invented") end

send(message(info_id, 1)) -- finished
local status = ffi.new("int[1]")
local exited = false
for _ = 1, 100 do
	serve(20)
	if ffi.C.waitpid(child, status, WNOHANG) == child then exited = true; break end
end
if not exited then fail("the worker kept running after the compositor finished") end
if status[0] == 0 then fail("a finished compositor must end the worker with a failure") end
print("ok  the worker exits with a failure once the compositor finishes")
receipts = receipts + 1

ffi.C.close(client)
ffi.C.close(listener)
os.execute("rm -rf -- '" .. runtime .. "'")
print(string.format("%d COSMIC toplevel receipts held.", receipts))
os.exit(0)
