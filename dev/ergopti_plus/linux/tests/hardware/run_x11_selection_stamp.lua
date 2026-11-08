--- tests/hardware/run_x11_selection_stamp.lua

--- ==============================================================================
--- MODULE: X11 Clipboard Owner Timestamp Receipt
--- DESCRIPTION:
--- Proves adapters/x11_selection_stamp.lua against a real X server: on a
--- private Xvfb display, a CLIPBOARD owner started by this script answers the
--- TIMESTAMP target, and the native read must return the owner's stamp, a new
--- stamp after the clipboard changes hands, and 0 with no owner. The unit
--- tests cover the backend choice; only a real server proves the protocol.
---
--- Run from the Linux driver root:
---     LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;" \
---         luajit tests/hardware/run_x11_selection_stamp.lua
--- ==============================================================================

local DISPLAY = os.getenv("ERGOPTI_STAMP_DISPLAY") or ":93"

--- The CLIPBOARD owner, run as its own LuaJIT process: it takes the selection
--- and answers TIMESTAMP requests with the stamp it was given, until killed.
local OWNER = [=[
local ffi = require("ffi")
ffi.cdef[[
	typedef union { long pad[24]; } OwnerEvent;
	typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long owner,
		requestor, selection, target, property, time; } OwnerRequest;
	typedef struct { int type; unsigned long serial; int send_event; void *display; unsigned long requestor,
		selection, target, property, time; } OwnerNotify;
	void *XOpenDisplay(const char *);
	unsigned long XDefaultRootWindow(void *);
	unsigned long XCreateSimpleWindow(void *, unsigned long, int, int, unsigned int, unsigned int,
		unsigned int, unsigned long, unsigned long);
	unsigned long XInternAtom(void *, const char *, int);
	int XSetSelectionOwner(void *, unsigned long, unsigned long, unsigned long);
	int XNextEvent(void *, OwnerEvent *);
	int XChangeProperty(void *, unsigned long, unsigned long, unsigned long, int, int, const unsigned char *, int);
	int XSendEvent(void *, unsigned long, int, long, OwnerEvent *);
	int XFlush(void *);
]]
local x = ffi.load("libX11.so.6")
local d = assert(x.XOpenDisplay(nil) ~= nil and x.XOpenDisplay(nil))
local w = x.XCreateSimpleWindow(d, x.XDefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0)
local clipboard, timestamp = x.XInternAtom(d, "CLIPBOARD", 0), x.XInternAtom(d, "TIMESTAMP", 0)
x.XSetSelectionOwner(d, clipboard, w, 0)
x.XFlush(d)
io.write("owned\n") io.flush()
local stamp = ffi.new("long[1]", tonumber(arg[1]))
local event = ffi.new("OwnerEvent[1]")
while true do
	x.XNextEvent(d, event)
	local request = ffi.cast("OwnerRequest *", event)
	if request.type == 30 then
		local reply = ffi.new("OwnerEvent[1]")
		local notify = ffi.cast("OwnerNotify *", reply)
		notify.type, notify.requestor, notify.selection = 31, request.requestor, request.selection
		notify.target, notify.time, notify.property = request.target, request.time, 0
		if request.target == timestamp then
			x.XChangeProperty(d, request.requestor, request.property, 19, 32, 0, ffi.cast("const unsigned char *", stamp), 1)
			notify.property = request.property
		end
		x.XSendEvent(d, request.requestor, 0, 0, reply)
		x.XFlush(d)
	end
end
]=]

local function sh(command)
	local result = os.execute(command)
	return result == true or result == 0
end

local scratch = os.tmpname()
local owner_file = scratch .. ".owner.lua"
local handle = assert(io.open(owner_file, "wb"))
handle:write(OWNER)
handle:close()

assert(sh("Xvfb " .. DISPLAY .. " -nolisten tcp >/dev/null 2>&1 & echo $! > " .. scratch .. ".xvfb"), "Xvfb start")
sh("sleep 1")
local function stop(file)
	local pid_file = io.open(file, "rb")
	if pid_file then
		local pid = pid_file:read("*l")
		pid_file:close()
		if pid then sh("kill " .. pid .. " 2>/dev/null; sleep 0.2") end
	end
	os.remove(file)
end

local function start_owner(stamp)
	sh("DISPLAY=" .. DISPLAY .. " luajit " .. owner_file .. " " .. stamp .. " > " .. scratch .. ".ready 2>&1 & echo $! > "
		.. scratch .. ".owner")
	for _ = 1, 50 do
		local ready = io.open(scratch .. ".ready", "rb")
		local line = ready and ready:read("*l")
		if ready then ready:close() end
		if line == "owned" then return end
		sh("sleep 0.1")
	end
	error("the test owner did not take the clipboard")
end

local ok, err = pcall(function()
	-- libX11 reads DISPLAY from the process environment, so run each read in a child.
	local function read()
		local pipe = assert(io.popen("DISPLAY=" .. DISPLAY .. " luajit -e '"
			.. "local S = require(\"adapters.x11_selection_stamp\"); local v, r = S.read(0.5); io.write(tostring(v), \" \", tostring(r))'"))
		local out = pipe:read("*a")
		pipe:close()
		return out
	end
	assert(read() == "0 nil", "no owner reads 0: " .. read())
	start_owner(1111)
	local first = read()
	assert(first == "1111 nil", "the owner's stamp: " .. first)
	stop(scratch .. ".owner")
	start_owner(2222)
	local second = read()
	assert(second == "2222 nil", "a new owner moves the stamp: " .. second)
	stop(scratch .. ".owner")
end)
stop(scratch .. ".owner")
stop(scratch .. ".xvfb")
os.remove(owner_file)
os.remove(scratch .. ".ready")
os.remove(scratch)
if not ok then error(err, 0) end
io.write("x11 selection stamp receipts: ok\n")
