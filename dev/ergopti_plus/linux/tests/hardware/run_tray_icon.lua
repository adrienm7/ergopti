--- tests/hardware/run_tray_icon.lua

--- ==============================================================================
--- MODULE: The Tray Icon Reaches a Real Panel Protocol
--- DESCRIPTION:
--- Shows the tray through the production adapter (adapters/tray_menu.lua →
--- platform/tray/appindicator.lua → libayatana-appindicator) and keeps its GTK
--- loop pumping, so tests/hardware/sni_host.py — a StatusNotifierWatcher, the
--- protocol every modern Linux panel speaks — can register the item and read
--- its icon and menu over D-Bus.
---
--- WHY A SEPARATE PROCESS FROM THE HOST:
--- The menu is served by THIS process's GTK loop. A host that inspected it from
--- inside the same loop would deadlock on its own GetLayout call, and one that
--- ran after this exited would find nothing — which is exactly the symptom
--- ("no icon") this test exists to tell apart from a working tray.
---
--- HOW TO RUN IT:
---   dbus-run-session -- sh -c 'python3 sni_host.py --ready-file R & …;
---     xvfb-run -a luajit tests/hardware/run_tray_icon.lua 20'
--- Exit 0 = the icon was created and pumped, 1 = the adapter refused to create
--- it, 2 = the machine cannot host a tray at all (no library, no display).
--- ==============================================================================

local TrayMenu = require("adapters.tray_menu")
local Indicator = require("platform.tray.appindicator")

local seconds = tonumber(arg and arg[1]) or 20

if not Indicator.is_available() then
	io.stderr:write("ENVIRONMENT: the tray backend cannot bind (library or display missing)\n")
	os.exit(2)
end

-- Warm the production pump with native events before its first Lua callback.
-- A cold pump conceals LuaJIT's forbidden compiled-FFI-to-Lua transition.
local ffi = require("ffi")
ffi.cdef[[
	typedef int (*ErgoptiProbeSource)(void*);
	void *g_idle_source_new(void);
	void g_source_set_callback(void*, ErgoptiProbeSource, void*, void*);
	unsigned int g_source_attach(void*, void*);
	unsigned int g_source_get_id(void*);
	void g_source_destroy(void*);
	void g_source_unref(void*);
	unsigned int g_idle_add(ErgoptiProbeSource, void*);
]]
local glib = ffi.load("libglib-2.0.so.0")
local source = glib.g_idle_source_new()
-- A positive source ID keeps this entirely native callback pending.
glib.g_source_set_callback(source,
	ffi.cast("ErgoptiProbeSource", glib.g_source_get_id), source, nil)
assert(glib.g_source_attach(source, nil) > 0)
local function pump()
	Indicator.pump(32)
end
for _ = 1, 1000 do pump() end
glib.g_source_destroy(source)
glib.g_source_unref(source)
local called = 0
local callback = ffi.cast("ErgoptiProbeSource", function()
	called = called + 1
	return 0
end)
assert(glib.g_idle_add(callback, nil) > 0)
pump()
assert(called == 1, "GTK must enter Lua after the pump becomes hot")
callback:free()

TrayMenu.setIcon({ title = "Ergopti" })
-- The clickable row proves the whole click path: the panel's dbusmenu Event,
-- libdbusmenu's "activate", the shared dispatcher, and this row's function.
local click_file = os.getenv("ERGOPTI_TRAY_CLICK_FILE")
local rebuilds = 0
local function clicked()
	if click_file then
		local fh = assert(io.open(click_file, "w"))
		fh:write("clicked " .. tostring(rebuilds) .. "\n")
		fh:close()
	end
end
local rows = {
	{ title = "Ergopti+ tray probe" },
	{ title = "-" },
	{ title = "Parent probe", menu = {
		{ title = "Child probe", menu = {
			{ title = "Click probe", fn = clicked },
		} },
	} },
	{ title = "Checked probe", checked = true, menu = {
		{ title = "Checked child probe", fn = function() error("wrong nested callback") end },
	} },
	{ title = "Quit probe", fn = function() os.exit(0) end },
}
rows[#rows + 1] = { title = "Rebuild probe", fn = function()
	rebuilds = rebuilds + 1
	rows[#rows + 1] = { title = "Rebuilt marker" }
	TrayMenu.setMenu(rows)
end }
-- Rebuilt a few times first, as the daemon does at boot: the row's id must
-- still reach the function of the CURRENT menu.
for _ = 1, 3 do TrayMenu.setMenu(rows) end
if TrayMenu.getBackend() ~= "appindicator" then
	print("FAIL the adapter reports no live backend after setIcon")
	os.exit(1)
end
print("ok   tray icon created through the production adapter")

-- Pump without blocking, as the daemon's idle callback does, until the host
-- has had time to register and inspect the item.
local deadline = os.time() + seconds
while os.time() < deadline do
	TrayMenu.pump()
	os.execute("sleep 0.05")
end
TrayMenu.destroy()
os.exit(0)
