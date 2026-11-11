--- tests/hardware/run_webkit_gc_signal.lua

--- ==============================================================================
--- MODULE: The Reload Signal Survives an In-Process WebView
--- DESCRIPTION:
--- The driver control protocol rings the daemon with SIGUSR1. WebKitGTK's
--- JavaScriptCore suspends threads for its garbage collector with SIGUSR1 too,
--- unless JSC_SIGNAL_FOR_GC names another signal, and it installs its handler
--- over the daemon's ("Overriding existing handler for signal 10"). With a
--- WebView open (the first-run onboarding window), a reload request crashed the
--- daemon with SIGSEGV; found by tests/hardware/phys_live_guest.sh.
---
--- This host installs the daemon's own signal owner (infra.signal_handlers,
--- through the same start order as the daemon: the WebKit GC signal reserved
--- first), opens a real WebKit2 WebView under X11, runs JavaScript in it, then
--- raises SIGUSR1 at itself. Pass: the process survives and the daemon's
--- callback receives the signal. `--unreserved` skips the reservation, the
--- negative control, and is expected to die.
---
--- Run from the Linux driver root under X11 with LuaJIT, lgi and WebKitGTK 4.1:
---     DISPLAY=:77 luajit tests/hardware/run_webkit_gc_signal.lua
--- Exit 0 = survived and delivered; 1 = a failure; 2 = no environment.
--- ==============================================================================

local SignalHandlers = require("infra.signal_handlers")
local unreserved = arg[1] == "--unreserved"
if not unreserved then
	local reserved, why = SignalHandlers.reserve_webkit_gc_signal()
	assert(reserved, why)
end

local function environment(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end
local lgi_loaded, lgi = pcall(require, "lgi")
if not lgi_loaded then environment("lgi is unreachable from LuaJIT (lua-lgi)") end
if (os.getenv("DISPLAY") or "") == "" then environment("DISPLAY is not set") end
local webkit_loaded, WebKit2 = pcall(lgi.require, "WebKit2", "4.1")
if not webkit_loaded then environment("WebKitGTK 4.1 is unavailable") end
local Gtk = lgi.require("Gtk", "3.0")
local GLib = lgi.GLib
local uv = require("luv")
local ffi = require("ffi")
ffi.cdef([[ int kill(int pid, int sig); int getpid(void); ]])

local delivered = 0
local started, start_error = SignalHandlers.start({
	on_term = function() end,
	on_hup = function() end,
	on_usr1 = function() delivered = delivered + 1 end,
})
assert(started, start_error)

Gtk.init()
local window = Gtk.Window({ default_width = 320, default_height = 200 })
local view = WebKit2.WebView()
window:add(view)
local loaded = false
function view:on_load_changed(event)
	if event == "FINISHED" or event == WebKit2.LoadEvent.FINISHED then loaded = true end
end
-- Enough JavaScript allocation that the collector runs while the page lives.
view:load_html("<html><body><script>var a=[];for(var i=0;i<200000;i++){a.push({i:i});}"
	.. "document.title='ready';</script></body></html>", "about:blank")
window:show_all()

local context = GLib.MainContext.default()
local function pump(seconds, predicate)
	local deadline = uv.hrtime() + seconds * 1e9
	while uv.hrtime() < deadline do
		while context:pending() do context:iteration(false) end
		uv.run("nowait")
		if predicate and predicate() then return true end
		uv.sleep(10)
	end
	return predicate == nil
end

local failures = 0
local function check(condition, text)
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
end
check(pump(30, function() return loaded end), "the WebView loaded a page that runs JavaScript")
print("  ..   JSC_SIGNAL_FOR_GC=" .. tostring(os.getenv("JSC_SIGNAL_FOR_GC")))
--- Whether this process installed a handler for a signal (/proc SigCgt mask).
local function caught(signal)
	local handle = assert(io.open("/proc/self/status", "rb"))
	local mask = handle:read("*a"):match("SigCgt:%s*(%x+)")
	handle:close()
	local digit = tonumber(mask:sub(-1 - math.floor((signal - 1) / 4), -1 - math.floor((signal - 1) / 4)), 16)
	return math.floor(digit / 2 ^ ((signal - 1) % 4)) % 2 == 1
end
if not unreserved then
	check(caught(SignalHandlers.WEBKIT_GC_SIGNAL), "WebKit's collector took the reserved signal "
		.. SignalHandlers.WEBKIT_GC_SIGNAL .. " instead of the reload signal")
end
for _ = 1, 3 do
	assert(ffi.C.kill(ffi.C.getpid(), SignalHandlers.RELOAD_SIGNAL) == 0)
	pump(0.5)
end
check(delivered == 3, "the daemon's reload callback received every SIGUSR1: " .. delivered)
SignalHandlers.stop()
window:destroy()
pump(0.5)
print(failures == 0 and "PASS the reload signal survives an in-process WebView" or "FAILED")
os.exit(failures == 0 and 0 or 1)
