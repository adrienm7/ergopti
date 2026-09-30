--- modules/gestures/app_switch.lua

--- ==============================================================================
--- MODULE: Direct application switch
--- DESCRIPTION:
--- Activates the most recently used other application, on every screen or only
--- on the screen under the cursor, or the least recent one, without the macOS
--- switcher; and cycles the windows of the active application without Cmd+`.
---
--- FEATURES & RATIONALE:
--- 1. No synthetic Cmd+Tab: the Dock commits its switcher when Command itself is
---    released. A posted Tab keystroke carrying the Command flag releases nothing,
---    so one gesture did nothing and a second one left the switcher open.
--- 2. Recency is the on-screen window order, front to back. It needs no watcher
---    and no lifecycle, and it is right on the first switch after a boot.
--- 3. This runtime is never a target and never the application switched away
---    from: with one of its windows in front, the switch returns to the
---    application the user was in.
--- 4. Hidden applications and minimised windows are not on screen, so they are
---    never picked; the Windows twin (AltTabMonitor/AltTabAll) likewise only
---    activates visible windows.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local WindowManager = require("adapters.window_manager")
local MouseControl  = require("adapters.mouse_control")

local LOG = "gestures.app_switch"

--- The two scopes a switch can have.
M.SCOPE_ALL_SCREENS = "all_screens"
M.SCOPE_THIS_SCREEN = "this_screen"





-- =======================================
-- =======================================
-- ======= 1/ Previous application =======
-- =======================================
-- =======================================

--- Resolves the screen a scope restricts candidates to.
--- @param scope string SCOPE_ALL_SCREENS or SCOPE_THIS_SCREEN.
--- @return boolean usable False when the scope names a screen that cannot be read.
--- @return number|nil screen_id The screen to keep, nil for every screen.
local function scope_screen(scope)
	if scope == M.SCOPE_ALL_SCREENS then return true, nil end
	if scope ~= M.SCOPE_THIS_SCREEN then
		error("app_switch: unknown scope '" .. tostring(scope) .. "'", 3)
	end
	local screen_id = MouseControl.screen_id_under_cursor()
	if screen_id == nil then
		-- The cursor is on no screen during a display change. Switching to an
		-- application on another screen is not what this scope asked for.
		Logger.debug(LOG, "The cursor is on no screen — no application to switch to on this screen.")
		return false, nil
	end
	return true, screen_id
end

--- Lists the other applications with a window in scope, most recent first,
--- each with its frontmost usable window.
--- @param screen_id number|nil Keep only windows on this screen; nil for all.
--- @return table records One window record per application, by recency.
local function other_applications(screen_id)
	local front_pid = WindowManager.frontmost_pid()
	local own_pid = WindowManager.own_pid()
	local seen, records = {}, {}
	for _, record in ipairs(WindowManager.ordered_windows()) do
		if record.standard and not record.minimized and record.pid ~= nil
			and record.pid ~= front_pid and record.pid ~= own_pid
			and (screen_id == nil or record.screen_id == screen_id) then
			if not seen[record.pid] then
				seen[record.pid] = true
				records[#records + 1] = record
			end
		end
	end
	return records
end

--- Focuses the first candidate window that accepts focus.
--- @param records table Candidate window records, in trial order.
--- @param label string What is being switched to, for the log lines.
--- @return boolean switched
local function focus_first(records, label)
	for _, record in ipairs(records) do
		if WindowManager.focus_window(record) then
			Logger.debug(LOG, "Switched to the %s: application %s (window %s).",
				label, tostring(record.pid), tostring(record.id))
			return true
		end
		-- A window that refuses focus is skipped, not the whole switch: the next
		-- candidate still gives the user a switch.
		Logger.warn(LOG, "Window %s of application %s refused focus — trying the next candidate.",
			tostring(record.id), tostring(record.pid))
	end
	Logger.info(LOG, "Nothing to switch to (%s): no candidate window accepted focus.", label)
	return false
end

--- Activates the most recently used application other than the frontmost one.
--- @param scope string SCOPE_ALL_SCREENS or SCOPE_THIS_SCREEN (the screen under
--- the cursor).
--- @return boolean switched True when another application was activated.
function M.previous_app(scope)
	local usable, screen_id = scope_screen(scope)
	if not usable then return false end
	return focus_first(other_applications(screen_id), "previous application, " .. scope)
end

--- Activates the least recently used application, the one a Cmd+Shift+Tab tap
--- selects, on every screen.
--- @return boolean switched True when another application was activated.
function M.least_recent_app()
	local records = other_applications(nil)
	local reversed = {}
	for index = #records, 1, -1 do reversed[#reversed + 1] = records[index] end
	return focus_first(reversed, "least recent application")
end






-- ====================================================
-- ====================================================
-- ======= 2/ Windows of the active application =======
-- ====================================================
-- ====================================================

--- Focuses the next or previous window of the frontmost application, wrapping
--- around. The order is the windows' creation order (their ids), which does
--- not change when one is focused: a front-to-back order would only ever
--- alternate between the two front windows. Replaces a posted Cmd+`, which
--- the application resolves through the keyboard layout and which several
--- non-US layouts, Ergopti's among them, do not carry.
--- @param step number 1 for the next window, -1 for the previous one.
--- @return boolean switched True when another window was focused.
function M.app_window(step)
	if step ~= 1 and step ~= -1 then
		error("app_switch.app_window: step must be 1 or -1, got " .. tostring(step), 2)
	end
	local front_pid = WindowManager.frontmost_pid()
	if front_pid == nil then
		Logger.info(LOG, "No frontmost application — no window to cycle.")
		return false
	end
	local windows = {}
	for _, record in ipairs(WindowManager.application_windows(front_pid)) do
		if record.standard and not record.minimized and type(record.id) == "number" then
			windows[#windows + 1] = record
		end
	end
	local count = #windows
	if count < 2 then
		Logger.debug(LOG, "Application %s has %d window(s) to cycle — nothing to switch to.",
			tostring(front_pid), count)
		return false
	end
	table.sort(windows, function(left, right) return left.id < right.id end)

	local focused_id = WindowManager.focused_window_id()
	local current = nil
	for index, record in ipairs(windows) do
		if record.id == focused_id then current = index break end
	end
	-- A focused panel or sheet is no listed window: start from the edge the
	-- step moves away from, so the first candidate is the first or last window.
	local start = current or (step == 1 and 0 or count + 1)
	local candidates = {}
	for offset = 1, current and count - 1 or count do
		candidates[#candidates + 1] = windows[((start - 1 + step * offset) % count) + 1]
	end
	return focus_first(candidates, step == 1 and "next window" or "previous window")
end

return M
