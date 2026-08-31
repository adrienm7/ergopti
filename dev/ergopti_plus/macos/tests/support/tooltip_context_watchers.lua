--- tests/support/tooltip_context_watchers.lua

--- ==============================================================================
--- MODULE: Tooltip Native-Context Watcher Test Support
--- DESCRIPTION:
--- Supplies contract-faithful Space and focused-window watcher capabilities to
--- tooltip tests whose subject is a different lifecycle boundary. HS-062 has a
--- dedicated behavioral test that observes and fires the real callbacks.
--- ==============================================================================

local M = {}

--- Creates a minimal native watcher with exact start/stop return contracts.
--- @return table watcher
local function watcher()
	local owner = { running = false }
	function owner:start()
		self.running = true
		return self
	end
	function owner:stop()
		self.running = false
		return self
	end
	return owner
end

--- Installs context-watcher capabilities on the current fresh hs test stub.
--- @return function restore Restores the exact prior surface.
function M.install()
	local target = hs
	local previous_spaces = target.spaces
	local previous_uielement = target.uielement
	local previous_focused_window = target.window.focusedWindow

	local spaces = {}
	for key, value in pairs(previous_spaces or {}) do spaces[key] = value end
	spaces.watcher = { new = function() return watcher() end }
	target.spaces = spaces

	local uielement = {}
	for key, value in pairs(previous_uielement or {}) do uielement[key] = value end
	uielement.watcher = { elementDestroyed = "elementDestroyed" }
	target.uielement = uielement
	target.window.focusedWindow = function()
		return { newWatcher = function() return watcher() end }
	end

	return function()
		target.spaces = previous_spaces
		target.uielement = previous_uielement
		target.window.focusedWindow = previous_focused_window
	end
end

return M
