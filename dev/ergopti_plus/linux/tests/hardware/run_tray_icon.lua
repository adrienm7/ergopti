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

TrayMenu.setIcon({ title = "Ergopti" })
-- The clickable row proves the whole click path: the panel's dbusmenu Event,
-- libdbusmenu's "activate", the shared dispatcher, and this row's function.
local click_file = os.getenv("ERGOPTI_TRAY_CLICK_FILE")
local rows = {
	{ title = "Ergopti+ tray probe" },
	{ title = "-" },
	{ title = "Click probe", fn = function()
		if click_file then
			local fh = io.open(click_file, "w")
			if fh then fh:write("clicked\n"); fh:close() end
		end
	end },
	{ title = "Quit probe", fn = function() os.exit(0) end },
}
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
