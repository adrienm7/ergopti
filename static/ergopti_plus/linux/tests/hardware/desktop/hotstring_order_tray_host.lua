--- tests/hardware/desktop/hotstring_order_tray_host.lua

--- ==============================================================================
--- MODULE: Hotstring Section Order Tray Host
--- DESCRIPTION:
--- The daemon's tray without its keyboard: the real hotstring catalogue
--- (modules/hotstrings/hotstrings_config.lua over the bundled packs), the real
--- menu builder (ui/menu/builder.lua) and the real tray (adapters/tray_menu.lua
--- over libayatana-appindicator), rebuilt through the daemon's own rebuild owner
--- after every committed click. tray_panel.py clicks it over D-Bus.
---
--- The daemon itself refuses to start without an evdev keyboard, which this
--- container has none of (no /dev/input, no uinput module); everything the
--- section-order rows touch is above that boundary.
---
--- Writes "<state>/ready" once the menu is published, then serves until
--- "<state>/stop" appears or the deadline passes. Exit 0 = served; 2 = no tray.
--- ==============================================================================

local state, seconds = assert(arg[1], "a state directory"), tonumber(arg[2]) or 30
require("compat.utf8").install()
local uv = require("luv")
local Logger = require("logger.shim")
Logger.set_level("info")
-- The driver routes its lines to a file sink; this host prints them for the proof.
Logger.set_sink(function(line) io.stdout:write(line, "\n"); io.stdout:flush() end)
local Indicator = require("platform.tray.appindicator")
local TrayMenu = require("adapters.tray_menu")

if not Indicator.is_available() then
	io.stderr:write("ENVIRONMENT: the tray backend cannot bind (library or display missing)\n")
	os.exit(2)
end

local LOG = "tests.desktop.hotstring_order"
local Config = require("modules.hotstrings.hotstrings_config")
local Builder = require("ui.menu.builder")
local rebuild = nil
assert(Config.init(require("modules.hotstrings.engine").new(), nil, function() if rebuild then rebuild() end end))
assert(select(2, Config.load_all(nil, true)) == true, "the bundled catalogue must load")

local function context()
	return {
		paused = false,
		is_paused = function() return false end,
		config = Config,
		on_menu_changed = function() if rebuild then rebuild() end end,
	}
end

local owner = require("ui.menu.rebuild_owner").new({
	current = function() return true end,
	build = function()
		local ctx = context()
		return require("ui.menu.timed_build").run(Builder.build, ctx), false
	end,
	publish = TrayMenu.setMenu,
	on_error = function(reason) Logger.error(LOG, "Tray menu refresh refused: %s.", reason) end,
})
rebuild = owner.request
TrayMenu.setIcon({ icon = "input-keyboard" })
rebuild()
owner.pump()

local function exists(path) return uv.fs_stat(path) ~= nil end
local ready = assert(io.open(state .. "/ready", "w"))
ready:write("ready\n")
ready:close()
local deadline = uv.hrtime() + seconds * 1e9
while uv.hrtime() < deadline and not exists(state .. "/stop") do
	TrayMenu.pump()
	owner.pump()
	uv.sleep(20)
end
TrayMenu.destroy()
os.exit(0)
