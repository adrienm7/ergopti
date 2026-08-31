--- modules/shortcuts/script_actions.lua
--- Owns the daemon lifecycle actions exposed through gesture/shortcut bindings.

local Logger = require("logger.shim")

local M = {}
local LOG = "ScriptActions"

local REQUIRED_CALLBACKS = { "reset", "reload", "quit" }

--- Builds one pause/reload/quit controller for the running daemon.
--- @param opts table Lifecycle callbacks plus optional hide/cancel callbacks.
--- @return table controller { handlers, is_paused }
function M.new(opts)
	if type(opts) ~= "table" then error("script actions options must be a table") end
	for _, name in ipairs(REQUIRED_CALLBACKS) do
		if type(opts[name]) ~= "function" then
			error("script actions requires a " .. name .. " callback")
		end
	end
	for _, name in ipairs({ "hide_preview", "hide_prediction", "cancel_prediction" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("script actions " .. name .. " callback must be a function")
		end
	end

	local paused = false
	local controller = {}
	controller.handlers = {
		["script_pause_toggle"] = function()
			paused = not paused
			if paused then
				opts.reset()
				if opts.hide_preview then opts.hide_preview() end
				if opts.hide_prediction then opts.hide_prediction() end
				if opts.cancel_prediction then opts.cancel_prediction() end
			end
			Logger.info(LOG, "Script automation %s.", paused and "paused" or "resumed")
		end,
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

	function controller.is_paused()
		return paused
	end

	return controller
end

return M
