--- modules/shortcuts/script_actions.lua
--- Owns the daemon lifecycle actions exposed through gesture/shortcut bindings,
--- and the pause state every other dispatcher consults.

local Logger = require("logger.shim")

local M = {}
local LOG = "ScriptActions"

local REQUIRED_CALLBACKS = { "reset", "reload", "quit" }

-- Prefix shared by every script-control action id in the shared catalogue.
local SCRIPT_ACTION_PREFIX = "script_"

-- The notice each settled pause state shows, keyed by the new paused flag: the
-- shared locale keys and levels macOS publish_pause_state uses, so a pause and a
-- resume read and weigh the same on both drivers.
M.PAUSE_NOTICES = {
	[true]  = { key = "script_control.paused",  level = "warning" },
	[false] = { key = "script_control.resumed", level = "success" },
}

--- Whether an action id belongs to the script-control family (pause, reload,
--- quit…). This names the family only; whether an action still runs through a
--- pause is runs_while_paused, read from the shared catalogue.
--- @param action_name any
--- @return boolean
function M.is_script_action(action_name)
	return type(action_name) == "string"
		and action_name:sub(1, #SCRIPT_ACTION_PREFIX) == SCRIPT_ACTION_PREFIX
end

--- Whether an action still runs while the driver is paused: the shared
--- `paused_actions` list of `_shared/modules/actions/script_chords.json`, the
--- one Windows and macOS read, so a pause lets through the same actions on the
--- three drivers (SCD-1, decided by the maintainer on 2026-11-11).
--- @param action_name any
--- @return boolean
function M.runs_while_paused(action_name)
	if type(action_name) ~= "string" then return false end
	return require("modules.shortcuts.script_chords").catalogue().paused_actions[action_name] == true
end

--- Builds one pause/reload/quit controller for the running daemon.
--- @param opts table Lifecycle callbacks plus optional hide/cancel callbacks and
---   on_pause_change(paused), called after every pause transition so the tray
---   can redraw, and notify(key, level), called with the PAUSE_NOTICES entry once
---   a transition and its listener succeeded.
--- @return table controller { handlers, is_paused, toggle_pause, allows }
function M.new(opts)
	if type(opts) ~= "table" then error("script actions options must be a table") end
	for _, name in ipairs(REQUIRED_CALLBACKS) do
		if type(opts[name]) ~= "function" then
			error("script actions requires a " .. name .. " callback")
		end
	end
	for _, name in ipairs({ "hide_preview", "hide_prediction", "cancel_prediction", "on_pause_change", "notify" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("script actions " .. name .. " callback must be a function")
		end
	end

	local paused = false
	local pause_epoch = 0
	local controller = {}

	--- Flips the pause state, clears transient automation on the way in, and
	--- tells the tray so the menu greys or un-greys its feature rows.
	local function toggle_pause()
		paused = not paused
		pause_epoch = pause_epoch + 1
		if paused then
			opts.reset()
			if opts.hide_preview then opts.hide_preview() end
			if opts.hide_prediction then opts.hide_prediction() end
			if opts.cancel_prediction then opts.cancel_prediction() end
		end
		Logger.info(LOG, "Script automation %s.", paused and "paused" or "resumed")
		if opts.on_pause_change then
			local ok, err = pcall(opts.on_pause_change, paused)
			if not ok or err == false then
				Logger.error(LOG, "Pause change listener failed: %s.", tostring(err))
				return false
			end
		end
		-- Told only after the listener settled, as macOS publishes only a
		-- committed state: a refused transition must not claim it happened.
		if opts.notify then
			local notice = M.PAUSE_NOTICES[paused]
			local ok, err = pcall(opts.notify, notice.key, notice.level)
			if not ok then
				Logger.error(LOG, "Pause notice '%s' failed: %s.", notice.key, tostring(err))
			end
		end
		return true
	end

	controller.handlers = {
		["script_pause_toggle"] = toggle_pause,
		["script_reload"] = function()
			opts.reload("a gesture or shortcut")
		end,
		["script_save_reload"] = function()
			-- Linux settings are persisted by their owner at mutation time. There is
			-- no editor buffer to save, so the parity operation is the reload itself.
			opts.reload("a save-and-reload gesture or shortcut")
		end,
		["script_quit"] = function()
			opts.quit("gesture or shortcut quit")
		end,
	}

	--- Toggles the pause from the tray (the title row resumes a paused script).
	controller.toggle_pause = toggle_pause

	function controller.is_paused()
		return paused
	end

	--- Returns the transition counter used to retire actions claimed before a pause.
	--- @return number epoch
	function controller.pause_epoch() return pause_epoch end

	--- Whether an action may run now: everything while running, only the
	--- shared catalogue's paused actions while paused.
	--- @param action_name string
	--- @return boolean
	function controller.allows(action_name)
		return not paused or M.runs_while_paused(action_name)
	end

	return controller
end

return M
