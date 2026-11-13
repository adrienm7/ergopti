--- tests/hardware/desktop/run_window_toggle.lua

--- ==============================================================================
--- MODULE: The Ten Window-Toggle Actions On A Real Desktop
--- DESCRIPTION:
--- Runs each of the ten `open_*` page actions of the shared catalogue through
--- the real gestures manager (modules/gestures/manager.lua execute_action) and
--- the real webview manager, with real WebKit2GTK windows on the session the
--- launcher started (run_window_toggle.sh: X11 under openbox, or GNOME Shell on
--- Wayland). For every action, three presses:
--- 1. Closed: the page opens and the compositor gives it the keyboard focus.
--- 2. Covered by a focused window of another process that the user types in
---    (xdotool on the session's keyboard, read back from that window's field):
---    the page is raised and focused again, the same page (its epoch is
---    unchanged), never closed.
--- 3. Frontmost: the page closes.
---
--- Exit 0 = every check held. 1 = a failure. 2 = no environment.
--- ==============================================================================

local WAIT_ATTEMPTS = 100
local WAIT_SECONDS  = 0.05

--- The ten actions and the page each toggles, as the maintainer decision of
--- 2026-10-27 lists them (docs/memory/maintainer-decisions.md).
local ACTIONS = {
	{ "open_metrics_typing", "metrics_typing" },
	{ "open_metrics_apps", "metrics_apps" },
	{ "open_hotstrings_editor", "hotstring_editor" },
	{ "open_paths_editor", "paths_editor" },
	{ "open_hotstrings_settings", "hotstrings_config_window" },
	{ "open_layout_manager", "layout_manager" },
	{ "open_layer_editor", "layer_editor" },
	{ "open_model_browser", "model_browser" },
	{ "open_changelog", "changelog" },
	{ "open_healthcheck", "healthcheck" },
}

local _failures, _checks = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print(string.format("  %s %s", condition and "ok  " or "FAIL", what))
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then abort("no display server.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local Gtk = lgi.require("Gtk", "3.0")
require("core.lifecycle.engine.compat.utf8").install()

local cover_script, scratch = assert(arg[1]), assert(arg[2])
local session = os.getenv("ERGOPTI_PROOF_SESSION") or "unnamed"

--- Pumps the GTK loop until `predicate` holds or the wait runs out.
--- @param predicate function
--- @return boolean
local function pump_until(predicate)
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if predicate() then return true end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return predicate()
end

--- Opens the covering window in its own process and waits until it is focused.
--- @return string|nil pid
local function open_cover()
	local ready = scratch .. "/cover.ready"
	os.remove(ready)
	local handle = assert(io.popen("luajit " .. cover_script .. " " .. ready .. " >/dev/null 2>&1 & echo $!"))
	local pid = handle:read("*l")
	handle:close()
	local focused = pump_until(function()
		local file = io.open(ready, "r")
		if file then file:close() end
		return file ~= nil
	end)
	if not focused then return nil, pid end
	-- The user types in the covering window, so a compositor that weighs the
	-- last user interaction sees one there, as on a real desktop.
	os.execute("DISPLAY=" .. assert(os.getenv("ERGOPTI_PROOF_HOST_DISPLAY"))
		.. " xdotool mousemove 40 40 type --delay 20 typed >/dev/null 2>&1")
	local typed = pump_until(function()
		local file = io.open(ready .. ".typed", "r")
		local text = file and file:read("*a")
		if file then file:close() end
		return text == "typed"
	end)
	return typed and pid or nil, pid
end

local Manager = require("ui.webview_manager")
local Gestures = require("modules.gestures.manager")

local function run()
	Manager.init()
	if not Manager.native_available() then abort("WebKit2GTK is not available to lgi.") end
	Gestures.init({ enabled = true, persist = false })
	print(string.format("=== ten window-toggle actions, session %s ===", session))
	for _, row in ipairs(ACTIONS) do
		local action, page = row[1], row[2]
		print("--- " .. action .. " ---")
		check(Gestures.execute_action(action, "proof") == true, action .. ": the manager dispatches it")
		local opened = pump_until(function() return Manager.is_frontmost(page) end)
		check(opened, action .. ": closed -> opened and focused")
		local epoch = Manager.current_epoch(page)

		local cover, spawned = open_cover()
		local covered = cover ~= nil and pump_until(function() return not Manager.is_frontmost(page) end)
		check(covered and Manager.is_visible(page), action .. ": a focused window of another process, typed in, covers the page")
		Gestures.execute_action(action, "proof")
		local raised = pump_until(function() return Manager.is_frontmost(page) end)
		check(raised and Manager.current_epoch(page) == epoch,
			action .. ": covered -> raised and focused, the same page, not closed")
		if spawned then os.execute("kill " .. spawned .. " 2>/dev/null") end
		pump_until(function() return Manager.is_frontmost(page) end)

		Gestures.execute_action(action, "proof")
		local closed = pump_until(function() return Manager.current_epoch(page) == nil end)
		check(closed, action .. ": frontmost -> closed")
	end
	print(string.format("=== %d check(s), %d failure(s), session %s ===", _checks, _failures, session))
	return _failures == 0 and 0 or 1
end

local ran, result = pcall(run)
pcall(Manager.shutdown)
if not ran then error(result, 0) end
os.exit(result)
