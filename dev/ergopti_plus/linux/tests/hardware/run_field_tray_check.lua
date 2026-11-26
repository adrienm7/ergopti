--- tests/hardware/run_field_tray_check.lua

--- ==============================================================================
--- MODULE: The Field Run's Tray Check Against a Real dbusmenu Export
--- DESCRIPTION:
--- Shows a fixture menu through the production tray adapter (tray/adapters/menu.lua
--- → libayatana-appindicator → libdbusmenu-gtk) and runs the field run's tray
--- check (diagnostics/engine/field_check/tray_check.lua) against it with the
--- production bus requests (diagnostics/adapters/bus_query.lua: busctl from a
--- child process) and this process's real unique name, so its GetLayout,
--- GetGroupProperties, AboutToShow and Event requests, the JSON it decodes and
--- the hover replay are proven on the library a KDE panel talks to.
---
--- Only the watcher's item list is answered here: a bare dbus-run-session has
--- no StatusNotifierWatcher, and the item path is libayatana's own.
---
--- HOW TO RUN IT (from static/ergopti_plus/linux):
---   dbus-run-session -- xvfb-run -a luajit tests/hardware/run_field_tray_check.lua
--- Exit 0 = every step passed, 1 = a step failed, 2 = no tray backend here.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
if self_path:sub(1, 1) ~= "/" then self_path = assert(os.getenv("PWD"), "PWD is not set") .. "/" .. self_path end
local driver_root = assert(self_path:match("^(.*)/tests/hardware/[^/]+$"), "run from the driver tree")
package.path = table.concat({ driver_root .. "/?.lua", driver_root .. "/?/init.lua",
	driver_root .. "/../_shared/?.lua", driver_root .. "/../_shared/?/init.lua", package.path }, ";")

local uv = require("luv")
local TrayMenu = require("tray.adapters.menu")
local Indicator = require("tray.adapters.appindicator")
local Report = require("diagnostics.engine.field_check.report")
local Check = require("diagnostics.engine.field_check.tray_check")

if not Indicator.is_available() then
	io.stderr:write("ENVIRONMENT: the tray backend cannot bind (library or display missing)\n")
	os.exit(2)
end

-- The fixture menu: the shapes the check reads, built the way the daemon's are.
local state = { paused = false, emulated = "None", detailed = false }
local rows
local function rebuild() TrayMenu.setMenu(rows()) end
local function choice(label)
	return { title = label, checked = state.emulated == label, radio = true,
		fn = function() state.emulated = label; rebuild() end }
end
rows = function()
	return {
		{ title = state.paused and "Ergopti+ ⏸" or "Ergopti+ 1.0", disabled = true },
		{ title = "-" },
		{ title = "Hotstrings", checked = true, menu = { { title = "Hotstring child", fn = function() end } } },
		{ title = "Shortcuts", checked = true, menu = { { title = "Shortcut child", fn = function() end } } },
		{ title = "Layout", menu = {
			{ title = "Layout to emulate : " .. state.emulated, menu = { choice("None"), choice("Ergopti"), choice("Bépo") } },
		} },
		{ title = "Configuration", menu = {
			{ title = "— Reset —", disabled = true },
			{ title = "Restore", fn = function() end },
			{ title = "-" },
			{ title = "— Files —", disabled = true },
			{ title = "Window font: Default", fn = function() end },
		} },
		{ title = "Debug", menu = {
			{ title = "— Logs —", disabled = true },
			{ title = "Detailed log", checked = state.detailed, fn = function() end },
			{ title = "Error window", checked = true, fn = function() end },
			{ title = "-" },
			{ title = "Open logs", fn = function() end },
		} },
		{ title = "-" },
		{ title = "Suspend (AltGr + Enter)", checked = state.paused,
			fn = function() state.paused = not state.paused; rebuild() end },
		{ title = "Reload (AltGr + ⌫)", fn = function() end },
		{ title = "-" },
		{ title = "Quit (AltGr + Esc)", fn = function() end },
	}
end

for _ = 1, 1000 do Indicator.pump(32) end
assert(TrayMenu.start(), "the tray icon must come up")
for _ = 1, 3 do rebuild() end

local timers = {}
local request = require("diagnostics.adapters.bus_query").new(5000)
local name = assert(require("tray.adapters.status_notifier_host").own_bus_name())
local ports = {
	bus_name = function() return name end,
	bus = function(args, done)
		if args[1] == "get-property" and args[2] == Check.WATCHER_NAME then
			timers[#timers + 1] = { at = uv.now(), fn = function()
				done({ type = "as", data = { name .. "/org/ayatana/NotificationItem/" .. (TrayMenu.INDICATOR_ID:gsub("%-", "_")) } })
			end }
			return true
		end
		return request(args, done)
	end,
	after = function(ms, fn) timers[#timers + 1] = { at = uv.now() + ms, fn = fn }; return true end,
	expect = function()
		local function script(id, base, hint) return { id = id, base = base, label = base .. " (" .. hint .. ")" } end
		return {
			indicator_id = TrayMenu.INDICATOR_ID,
			suspend = script("suspend", "Suspend", "AltGr + Enter"), reload = script("reload", "Reload", "AltGr + ⌫"),
			quit = script("quit", "Quit", "AltGr + Esc"),
			checkable_groups = { "Hotstrings", "Shortcuts" },
			layout_group = "Layout", emulated = "Layout to emulate",
			configuration = "Configuration", configuration_titles = { "— Reset —", "— Files —" },
			reading_font = "Window font",
			debug = "Debug", console = "Console", logs_title = "— Logs —", logs_switches = { "Detailed log", "Error window" },
			detailed_log = false, problem_dot = "🔴", problem_count = 0,
		}
	end,
	emulation_state = function() return state.emulated end,
	config_snapshot = function() return {} end,
	config_restore = function() return true end,
}

local report = Report.new_report("tray")
local finished = false
Check.run(ports, report, function() finished = true end)
local deadline = os.time() + 90
while not finished and os.time() < deadline do
	TrayMenu.pump()
	uv.run("nowait")
	local now = uv.now()
	for index = #timers, 1, -1 do
		local timer = timers[index]
		if timer.at <= now then
			table.remove(timers, index)
			timer.fn()
		end
	end
	uv.sleep(5)
	uv.update_time()
end
local result = report.result()
print(Report.format_log_line(result))
TrayMenu.destroy()
if not finished then
	print("FAIL the tray check never finished")
	os.exit(1)
end
os.exit(result.passed and state.emulated == "None" and state.paused == false and 0 or 1)
