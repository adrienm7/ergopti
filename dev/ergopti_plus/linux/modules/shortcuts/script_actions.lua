--- modules/shortcuts/script_actions.lua
--- Owns the daemon lifecycle actions exposed through gesture/shortcut bindings,
--- and the pause state every other dispatcher consults.

local Logger = require("logger.shim")

local M = {}
local LOG = "ScriptActions"

local REQUIRED_CALLBACKS = { "reset", "reload", "quit" }

-- Prefix shared by every script-control action id in the shared catalogue.
local SCRIPT_ACTION_PREFIX = "script_"

--- Whether an action id is a script-control action (pause, reload, quit…).
--- These stay live while the script is paused and after « Disable all »: they
--- are how a user gets the script back.
--- @param action_name any
--- @return boolean
function M.is_script_action(action_name)
	return type(action_name) == "string"
		and action_name:sub(1, #SCRIPT_ACTION_PREFIX) == SCRIPT_ACTION_PREFIX
end

--- Builds one pause/reload/quit controller for the running daemon.
--- @param opts table Lifecycle callbacks plus optional hide/cancel callbacks and
---   on_pause_change(paused), called after every pause transition so the tray
---   can redraw.
--- @return table controller { handlers, is_paused, toggle_pause, allows }
function M.new(opts)
	if type(opts) ~= "table" then error("script actions options must be a table") end
	for _, name in ipairs(REQUIRED_CALLBACKS) do
		if type(opts[name]) ~= "function" then
			error("script actions requires a " .. name .. " callback")
		end
	end
	for _, name in ipairs({ "hide_preview", "hide_prediction", "cancel_prediction", "on_pause_change" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("script actions " .. name .. " callback must be a function")
		end
	end

	local paused = false
	local controller = {}

	--- Flips the pause state, clears transient automation on the way in, and
	--- tells the tray so the menu greys or un-greys its feature rows.
	local function toggle_pause()
		paused = not paused
		if paused then
			opts.reset()
			if opts.hide_preview then opts.hide_preview() end
			if opts.hide_prediction then opts.hide_prediction() end
			if opts.cancel_prediction then opts.cancel_prediction() end
		end
		Logger.info(LOG, "Script automation %s.", paused and "paused" or "resumed")
		if opts.on_pause_change then
			local ok, err = pcall(opts.on_pause_change, paused)
			if not ok then
				Logger.error(LOG, "Pause change listener failed: %s.", tostring(err))
			end
		end
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

	--- Whether an action may run now: everything while running, only the
	--- script-control actions while paused.
	--- @param action_name string
	--- @return boolean
	function controller.allows(action_name)
		return not paused or M.is_script_action(action_name)
	end

	return controller
end

return M
