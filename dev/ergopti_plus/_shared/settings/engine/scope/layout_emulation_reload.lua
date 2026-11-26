--- _shared/settings/engine/scope/layout_emulation_reload.lua

--- ==============================================================================
--- MODULE: Layout Scope Emulation Reload
--- DESCRIPTION:
--- The layout scope holds the layout emulation's rows too (the emulated layout,
--- its base, variant, AltGr and row switches). Once a global restore or clear
--- committed or reverted them, a started emulation must type what config.toml
--- now holds: it used to keep its old session until the next reload. The
--- macOS and Linux layout participants both call this one reload.
--- ==============================================================================

local M = {}

--- Has a started layout emulation type the rows config.toml now holds; a
--- stopped one reads them when it starts. A refusal is logged: the rows stay
--- stored and the emulation reports its own error in the menu.
--- @param emulation table|nil The layout emulation owner (tests replace it);
---   modules.keymap.layout_emulation when nil.
--- @param logger table The caller's logger (error, warn).
--- @param log string The caller's log tag.
function M.reload(emulation, logger, log)
	local called, reloaded = pcall(function()
		return (emulation or require("modules.keymap.layout_emulation")).reload_if_started()
	end)
	if not called then
		logger.error(log, "The layout emulation reload raised after the layout scope: %s.", tostring(reloaded))
	elseif reloaded == false then
		logger.warn(log, "The layout emulation did not reload the rows of the layout scope.")
	end
end

return M
