--- ui/modal.lua

--- ==============================================================================
--- MODULE: Blocking Dialogs Under The Keyboard Grab
--- DESCRIPTION:
--- Every zenity or kdialog window the tray opens blocks the daemon's event loop
--- until it closes, and that loop is the only path from the grabbed keyboard to
--- the desktop. Run through here, a dialog gets the keyboard for as long as it
--- is open (see keyboard_hook.while_released).
--- ==============================================================================

local M = {}

--- Runs a blocking dialog with the keyboard handed to the desktop.
--- @param fn function The dialog; its results are returned.
--- @return any
function M.run(fn)
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if ok and type(hook) == "table" and type(hook.while_released) == "function" then
		return hook.while_released(fn)
	end
	return fn()
end

return M
