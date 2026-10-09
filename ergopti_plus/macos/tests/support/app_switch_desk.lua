--- tests/support/app_switch_desk.lua

--- ==============================================================================
--- MODULE: App Switch Desk Fixture
--- DESCRIPTION:
--- Serves a desk of windows to modules/gestures/app_switch.lua through a
--- recording window adapter, and dispatches actions through the real registry
--- the way a gesture does, firing the switch the action schedules.
--- ==============================================================================

local M = {}

-- Stable process ids of a desk. OWN is this runtime.
M.FRONT, M.OTHER, M.THIRD, M.OWN = 101, 202, 303, 909
M.LEFT_SCREEN, M.RIGHT_SCREEN = 1, 2

local INJECTED = {
	"adapters.window_manager",
	"adapters.mouse_control",
	"modules.gestures.app_switch",
}

--- @return table A standard, visible window record.
function M.window(id, pid, screen_id, extra)
	local record = { id = id, pid = pid, screen_id = screen_id, standard = true, minimized = false }
	for key, value in pairs(extra or {}) do record[key] = value end
	return record
end

--- Serves a desk to the switch and records every focus request.
--- @param desk table { front, focused, cursor_screen, windows = { record... } },
--- windows front to back.
--- @param body function body(focused) runs with the desk installed.
function M.with_desk(desk, body)
	local saved = {}
	for _, name in ipairs(INJECTED) do saved[name] = package.loaded[name] end
	local focused = {}
	local function copy_where(keep)
		local copy = {}
		for _, record in ipairs(desk.windows) do
			if keep(record) then copy[#copy + 1] = record end
		end
		return copy
	end
	package.loaded["adapters.window_manager"] = {
		-- Minimised windows stay listed: the switch must pass over them itself.
		ordered_windows = function()
			return copy_where(function() return true end)
		end,
		application_windows = function(pid)
			return copy_where(function(record) return record.pid == pid end)
		end,
		frontmost_pid = function() return desk.front end,
		focused_window_id = function() return desk.focused end,
		own_pid = function() return M.OWN end,
		focus_window = function(record)
			focused[#focused + 1] = record.id
			return record.refuses_focus ~= true
		end,
	}
	package.loaded["adapters.mouse_control"] = {
		screen_id_under_cursor = function() return desk.cursor_screen end,
	}
	package.loaded["modules.gestures.app_switch"] = nil
	local ok, err = xpcall(body, debug.traceback, focused)
	for _, name in ipairs(INJECTED) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Dispatches one action like a tap and fires what it scheduled.
--- @param fresh_actions function gesture_actions_fixture constructor.
--- @param action string Action id.
--- @param binding string|nil Binding identity, a gesture slot by default.
--- @return boolean accepted, table calls
function M.tap(fresh_actions, action, binding)
	local actions, calls = fresh_actions()
	local accepted = actions.execute_single(action, binding or "tap_3")
	for _, entry in ipairs(calls.after) do calls.fire(entry.token) end
	return accepted, calls
end

return M
