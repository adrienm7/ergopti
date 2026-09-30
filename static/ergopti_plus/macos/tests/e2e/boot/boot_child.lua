--- tests/e2e/boot/boot_child.lua

--- ==============================================================================
--- MODULE: One Headless Boot Of The Installed Application
--- DESCRIPTION:
--- Runs the REAL init.lua of an installed ErgoptiPlus.app copy (staged by
--- boot_scenarios.lua) with only the operating-system edges replaced
--- (tests/e2e/boot/world.lua), drives its timers for a virtual minute, then
--- performs the scenario's action and prints what a user would have seen.
---
--- Usage: lua boot_child.lua <repo macOS driver> <app root> <machine root>
---   <home> <action> [<settings.lua>, a file returning the hs.settings values
---   an older release left in the application's preference domain]
--- Actions: boot (boot and idle), restore_recommended (boot, then the menu's
--- « Restore recommended values » answered Yes).
--- Output: the driver's log lines, E2E_* observation lines from the world,
--- E2E_FACT key=value lines, and a final E2E_DONE line.
--- ==============================================================================

local REPO_DRIVER, APP_ROOT, MACHINE_ROOT, HOME, ACTION, SETTINGS_FILE = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
assert(REPO_DRIVER and APP_ROOT and MACHINE_ROOT and HOME and ACTION,
	"usage: boot_child.lua <repo driver> <app root> <machine root> <home> <action>")

local RESOURCES = APP_ROOT .. "/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus"
local DRIVER = RESOURCES .. "/macos"
local SHARED = RESOURCES .. "/_shared"

-- Production modules resolve only inside the installed copy; test support
-- modules (the hs stub and this harness) come from the repository.
package.path = table.concat({
	DRIVER .. "/?.lua", DRIVER .. "/?/init.lua",
	SHARED .. "/lua/?.lua", SHARED .. "/lua/?/init.lua",
	package.path,
}, ";")
table.insert(package.searchers, 2, function(name)
	if not name:match("^tests%.") then return nil end
	local relative = name:gsub("%.", "/")
	for _, candidate in ipairs({ REPO_DRIVER .. "/" .. relative .. ".lua", REPO_DRIVER .. "/" .. relative .. "/init.lua" }) do
		local fh = io.open(candidate, "r")
		if fh then
			fh:close()
			return loadfile(candidate)
		end
	end
	return "\n\tno test module " .. name .. " under " .. REPO_DRIVER
end)

local World = require("tests.e2e.boot.world")
_G.hs = require("tests.stubs.hs")
local env = World.install(hs, {
	app_root = APP_ROOT,
	machine_root = MACHINE_ROOT,
	home = HOME,
	-- Package-only files: every release has them, a checkout never does.
	shipped_optional = { [SHARED .. "/build_stamp.txt"] = true },
})

if SETTINGS_FILE then
	for key, value in pairs(dofile(SETTINGS_FILE)) do hs.settings.set(key, value) end
end

local VIRTUAL_MINUTE_SEC = 60
local MAX_TIMER_FIRES = 20000

--- Advances the virtual clock, delivering log records after every callback.
--- @param seconds number
local function idle(seconds)
	return World.run(seconds, MAX_TIMER_FIRES, World.flush_logs)
end





-- =============================
-- =============================
-- ======= 1/ Boot =============
-- =============================
-- =============================

local booted, boot_error = xpcall(function() dofile(env.ERGOPTI_CONFIG_DIR .. "/init.lua") end, debug.traceback)
World.flush_logs()
if not booted then World.record("BOOT_RAISED", boot_error) end
World.record("FACT", "timers_fired=" .. idle(VIRTUAL_MINUTE_SEC))
World.flush_logs()





-- ==================================
-- ==================================
-- ======= 2/ Scenario action =======
-- ==================================
-- ==================================

-- The user, back at the Mac, moves and clicks the pointer: the pointer
-- watchers probe Karabiner (the CapsWord probe exited 2 on every movement,
-- 7919cf8e9). Spaced by more than their throttle.
local pointer_taps = 0
for _, event_type in ipairs({ "mouseMoved", "leftMouseDown", "mouseMoved" }) do
	pointer_taps = pointer_taps + World.pointer_event(hs, event_type)
	idle(2)
end
World.record("FACT", "pointer_taps=" .. pointer_taps)

if ACTION == "restore_recommended" then
	-- The user's click on Configuration › « Restore recommended values », the
	-- row that restores every category at once.
	local i18n = require("infra.i18n")
	local path = { i18n.get("menu.configuration.title"), i18n.get("common.restore_recommended") }
	local row = World.find_row(World.menu_items(), path)
	if type(row) ~= "table" or type(row.fn) ~= "function" then
		World.record("SCENARIO_FAILED", "no menu row at " .. table.concat(path, " › "))
	else
		local clicked, click_error = xpcall(function() return row.fn({}) end, debug.traceback)
		if not clicked then World.record("SCENARIO_FAILED", click_error) end
		World.record("FACT", "restore_timers_fired=" .. idle(VIRTUAL_MINUTE_SEC))
	end
elseif ACTION == "open_windows" then
	-- Every window and file the menu, a gesture or a shortcut can open through
	-- the action catalogue: each must find its data outside the bundle.
	local Actions = require("modules.gestures.actions")
	for _, name in ipairs({
		"open_metrics_typing", "open_metrics_apps", "open_hotstrings_editor", "open_paths_editor",
		"open_config", "open_personal_info", "open_personal_hotstrings", "open_personal_shortcuts",
		"open_logs_folder", "open_today_log", "open_error_log",
	}) do
		-- As a keyboard shortcut slot runs it: the shortcut scope is admitted in
		-- every preset, the gesture scope only with Gestures on.
		local ran, result = xpcall(function() return Actions.execute_single(name, "keyboard__e2e") end,
			debug.traceback)
		if not ran or result ~= true then
			World.record("SCENARIO_FAILED", name .. " did not run: " .. tostring(result))
		end
		idle(5)
	end
elseif ACTION ~= "boot" then
	World.record("SCENARIO_FAILED", "unknown action " .. tostring(ACTION))
end
World.flush_logs()
World.record("DONE", ACTION)
