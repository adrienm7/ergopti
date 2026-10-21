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
---   <home> <action> <arch> [<settings.lua>, a file returning the hs.settings
---   values an older release left in the application's preference domain]
---   [<machine>, a world.MACHINES name; standard by default]
--- Arch: the processor `uname -m` names (arm64 or x86_64).
--- Actions: boot (boot and idle), restore_recommended (boot, then the menu's
--- « Restore recommended values » answered Yes), python_helper (boot, then the
--- display-mirror shortcut, a helper that runs Python).
--- type_for_wpm boots Metrics, types physical keys and observes its floating canvas.
--- Output: the driver's log lines, E2E_* observation lines from the world,
--- E2E_FACT key=value lines (the lease workers started, the final lease phase
--- and the native reloads among them), and a final E2E_DONE line.
--- ==============================================================================

local REPO_DRIVER, APP_ROOT, MACHINE_ROOT, HOME, ACTION, ARCH, SETTINGS_FILE, MACHINE =
	arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7], arg[8]
assert(REPO_DRIVER and APP_ROOT and MACHINE_ROOT and HOME and ACTION and ARCH,
	"usage: boot_child.lua <repo driver> <app root> <machine root> <home> <action> <arch>")

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
	arch = ARCH,
	machine = MACHINE,
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
-- What follows is the scenario's action, not the boot (hardening-h counts the
-- Pythons each one started).
World.record("PHASE", "action")





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
elseif ACTION == "select_layout_natively" then
	-- A real menu click must leave ABC even when setLayout declines the name.
	local i18n = require("infra.i18n")
	local path = { i18n.get("menu.layout.title"), "French" }
	local row = World.find_row(World.menu_items(), path)
	if type(row) ~= "table" or type(row.fn) ~= "function" or row.disabled then
		World.record("SCENARIO_FAILED", "no enabled layout row at " .. table.concat(path, " › "))
	else
		local clicked, click_error = xpcall(function() return row.fn({}) end, debug.traceback)
		if not clicked then World.record("SCENARIO_FAILED", click_error) end
		idle(5)
	end
	World.record("FACT", "layout_set_attempts=" .. World.layout_attempts)
	World.record("FACT", "layout_native_selections=" .. World.native_selections)
	World.record("FACT", "layout_native_environment=" .. tostring(World.native_selection_environment))
	World.record("FACT", "layout_native_result=" .. tostring(World.native_selection_result))
	World.record("FACT", "layout_native_role=" .. tostring(World.native_selection_role))
	World.record("FACT", "layout_selected_source=" .. tostring(hs.keycodes.currentSourceID()))
	local refreshed = World.find_row(World.menu_items(), path)
	World.record("FACT", "layout_french_checked=" .. tostring(type(refreshed) == "table" and refreshed.checked == true))
	-- A missing identifier must complete with failure and leave that source intact.
	local before_missing = hs.keycodes.currentSourceID()
	local missing_refused = false
	require("modules.keymap.input_sources").set_input_source_async(nil, "com.ergopti.e2e.missing", function(ok)
		missing_refused = ok == false
	end)
	idle(1)
	World.record("FACT", "layout_missing_refused=" .. tostring(missing_refused))
	World.record("FACT", "layout_missing_unchanged=" .. tostring(hs.keycodes.currentSourceID() == before_missing))
	World.record("FACT", "layout_missing_native_result=" .. tostring(World.native_selection_result))
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
elseif ACTION == "python_helper" then
	-- As a keyboard shortcut slot runs it; its Python answers "single_screen".
	local Actions = require("modules.gestures.actions")
	local ran, result = xpcall(function() return Actions.execute_single("display_mirror_toggle", "keyboard__e2e") end,
		debug.traceback)
	if not ran or result ~= true then
		World.record("SCENARIO_FAILED", "display_mirror_toggle did not run: " .. tostring(result))
	end
	idle(5)
elseif ACTION == "type_for_wpm" then
	-- A user types after the configured application's real menu started Metrics
	-- and the floating widget. No keylogger, model or widget method is stubbed.
	for _, key in ipairs({ { 0, "a" }, { 11, "b" }, { 8, "c" } }) do
		World.keyboard_event(hs, key[1], key[2], true)
		World.keyboard_event(hs, key[1], key[2], false)
		idle(0.1)
	end
	idle(0.3)
	local stats = require("modules.keylogger").get_live_stats()
	World.record("FACT", "wpm_input_counted=" .. tostring(stats.wpm > 0))
	local visible, recovered = 0, false
	local config = require("toml_codec").decode(require("tests.support.source_file").read(
		SHARED .. "/modules/wpm_widget/constants.toml"))
	local compact = config.compact
	local screen = hs.screen.mainScreen():fullFrame()
	for _, canvas in ipairs(hs.canvas.__instances) do
		local frame = canvas:frame()
		if canvas:isShowing() and frame.w == compact.width and frame.h == compact.height
			and canvas[3] and tonumber(canvas[3].text) then
			visible = visible + 1
			recovered = frame.x == screen.x + screen.w - compact.width - compact.edge_margin
				and frame.y == screen.y + screen.h - compact.height - compact.edge_margin
		end
	end
	World.record("FACT", "wpm_canvas_visible=" .. visible)
	World.record("FACT", "wpm_position_recovered=" .. tostring(recovered))
elseif ACTION ~= "boot" then
	World.record("SCENARIO_FAILED", "unknown action " .. tostring(ACTION))
end
-- What the boot did with its Karabiner lease: a phantom layout change fenced
-- the boot's activation and started a second worker (layout-name-forms).
local lease_ok, lease_phase = pcall(function()
	-- A fresh install stops at the wizard, before the controller exists.
	local controller = require("platform.remap.lease_controller")
	if controller.is_initialized() ~= true then return "uninitialized" end
	return (controller.status())
end)
World.record("FACT", "lease_workers=" .. World.lease_workers_started)
World.record("FACT", "lease_phase=" .. (lease_ok and tostring(lease_phase) or "unreadable"))
World.record("FACT", "native_reloads=" .. World.native_reloads)
World.flush_logs()
World.record("DONE", ACTION)
