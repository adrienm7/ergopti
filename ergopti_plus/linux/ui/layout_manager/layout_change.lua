--- ui/layout_manager/layout_change.lua

--- ==============================================================================
--- MODULE: Layout Change In Place (Linux)
--- DESCRIPTION:
--- Applies what an installed, updated or removed layout changes without
--- restarting the daemon (maintainer decision, 2026-11-25): the layout manager
--- window that asked for it stays open and shows the result. The layout
--- manager's bridge and the tray's window-less Ergopti rows both call it.
---
--- FEATURES & RATIONALE:
--- 1. The emulation reloads only when the changed layout is the emulated one:
---    an uninstalled one stays chosen and stops, a reinstalled one resumes
---    (maintainer decision, 2026-11-12).
--- 2. A layout that ships a hotstring extension reloads the hotstring
---    catalogue in this process (the daemon's reload_layout_extensions), which
---    discovers the extension roots again, so its packs load or drop. The tray
---    is rebuilt, which scans the extensions' shortcut menus again. Restarting
---    the daemon for this closed the window the user was in (Arch field
---    report, 2026-11-25).
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "ui.layout_manager.layout_change"

--- Applies a layout's change in place.
--- @param state table The daemon state (reload_layout_extensions, on_config_changed).
--- @param emulation table|nil The layout emulation (status, reload_if_started).
--- @param id string The changed layout's registry id.
--- @param extension boolean Whether the layout ships a hotstring extension.
--- @return boolean applied False when the extension packs could not be reloaded.
function M.apply(state, emulation, id, extension)
	assert(type(state) == "table" and type(id) == "string" and id ~= "", "a layout change needs the daemon state and an id")
	local emulated = false
	if type(emulation) == "table" and type(emulation.status) == "function" then
		local ok, status = pcall(emulation.status)
		emulated = ok and type(status) == "table" and status.id == id
		if emulated then emulation.reload_if_started() end
	end
	local applied = true
	if extension then
		Logger.start(LOG, "Reloading the hotstring extensions in place after the '%s' layout changed…", id)
		if type(state.reload_layout_extensions) ~= "function" then
			Logger.error(LOG, "The extension of '%s' changed but this daemon cannot reload its hotstrings.", id)
			applied = false
		else
			local ok, reloaded = pcall(state.reload_layout_extensions)
			if ok and reloaded == true then
				Logger.success(LOG, "Hotstring extensions reloaded after the '%s' layout changed.", id)
			else
				Logger.error(LOG, "The hotstring extensions were not reloaded after the '%s' layout changed: %s.",
					id, tostring(reloaded))
				applied = false
			end
		end
	end
	if (emulated or extension) and type(state.on_config_changed) == "function" then
		local ok, err = pcall(state.on_config_changed)
		if not ok then Logger.error(LOG, "The tray could not be rebuilt after the '%s' layout changed: %s.", id, tostring(err)) end
	end
	return applied
end

return M
