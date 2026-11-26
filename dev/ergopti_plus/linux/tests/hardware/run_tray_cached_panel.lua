--- tests/hardware/run_tray_cached_panel.lua

--- ==============================================================================
--- MODULE: Consecutive Tray Clicks Under a Caching Panel
--- DESCRIPTION:
--- Serves a tray menu through the production adapter (tray/adapters/menu.lua →
--- libayatana-appindicator → libdbusmenu-gtk) and the daemon's own rebuild
--- owner (menu/ui/builder/rebuild_owner.lua), so tests/hardware/plasma_panel.py
--- can click one switch several times in a row as KDE Plasma does: from its
--- cached layout, never reloading the menu.
---
--- The switch sits in a submenu whose other row changes its title with the
--- switch (a greyed row gains its reason), as a category switch does in the
--- daemon's menu: each click reshapes that submenu. Before the fix of
--- 2026-11-25 the submenu was rebuilt under its unchanged parent row, Plasma
--- kept the rows of before, and the second click reached a row id that no
--- longer existed.
---
--- HOW TO RUN IT (from static/ergopti_plus/linux):
---   dbus-run-session -- sh -c 'python3 tests/hardware/plasma_panel.py --ready-file R
---     --path "Shortcuts probe > Switch probe" --clicks 2 & …;
---     xvfb-run -a luajit tests/hardware/run_tray_cached_panel.lua 20'
--- Writes "clicks <n> on=<state>" to $ERGOPTI_TRAY_CLICK_FILE after each click.
--- Exit 0 = served, 2 = the machine cannot host a tray at all.
--- ==============================================================================

local TrayMenu = require("tray.adapters.menu")
local Indicator = require("tray.adapters.appindicator")

local seconds = tonumber(arg and arg[1]) or 20

if not Indicator.is_available() then
	io.stderr:write("ENVIRONMENT: the tray backend cannot bind (library or display missing)\n")
	os.exit(2)
end

local click_file = os.getenv("ERGOPTI_TRAY_CLICK_FILE")
local state = { on = true, clicks = 0 }
local owner

--- The switch's action: it commits, records the click, and asks the owner for
--- a refresh, as every setting row of the daemon does.
local function toggle()
	state.on = not state.on
	state.clicks = state.clicks + 1
	if click_file then
		local handle = assert(io.open(click_file, "w"))
		handle:write(string.format("clicks %d on=%s\n", state.clicks, tostring(state.on)))
		handle:close()
	end
	owner.request()
end

--- The menu of the current state.
--- @return table
local function rows()
	return {
		{ title = "Ergopti+ cached panel probe", disabled = true },
		{ title = "-" },
		{ title = "Shortcuts probe", checked = state.on, menu = {
			{ title = "Switch probe", checked = state.on, fn = toggle },
			{ title = state.on and "Child probe" or "Child probe — Off", disabled = not state.on, fn = function() end },
		} },
		{ title = "Quit probe", fn = function() os.exit(0) end },
	}
end

owner = require("menu.ui.builder.rebuild_owner").new({
	current = function() return true end,
	build = function() return rows(), false end,
	publish = TrayMenu.setMenu,
	on_error = function(reason) io.stderr:write("tray refresh refused: " .. tostring(reason) .. "\n") end,
})

-- Hot pump before the first Lua callback, as tests/hardware/run_tray_icon.lua explains.
for _ = 1, 1000 do Indicator.pump(32) end
assert(TrayMenu.start(), "the tray icon must come up")
owner.request()
owner.pump()
print("ok   tray served through the production adapter and the rebuild owner")

-- The daemon's idle tick: the tray's GTK events, then the menu publication.
local deadline = os.time() + seconds
while os.time() < deadline do
	TrayMenu.pump()
	owner.pump()
	os.execute("sleep 0.02")
end
TrayMenu.destroy()
os.exit(0)
