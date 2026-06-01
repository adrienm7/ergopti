--- ui/menu/menu_watchers.lua

--- ==============================================================================
--- MODULE: Menu Watchers
--- DESCRIPTION:
--- Sets up and manages file system watchers that trigger menu rebuilds when
--- configuration files change on disk.
---
--- FEATURES & RATIONALE:
--- 1. Isolation: watcher lifecycle (start/stop/callback) separated from menu logic.
--- 2. Each watcher type (config TOML, system theme) is managed independently.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "menu_watchers"




-- =====================================
--- ======================================
-- ======= 1/ Config File Watcher =======
--- ======================================
-- =====================================

-- Debounce delay (seconds): absorbs rapid bursts of file-change events
-- (e.g. a git commit touching several .lua files at once) so that only a
-- single hs.reload() fires instead of one per changed file.
local DEBOUNCE_SEC = 0.5

--- Creates and starts a pathwatcher on base_dir that triggers a reload on .lua/.toml changes.
--- Ignores changes that arrive while the suppress window is active (e.g. after opening a file
--- for editing from within the menu itself).
--- @param base_dir string Directory to watch.
--- @param on_reload function Callback invoked when a relevant file change is detected.
--- @param get_suppress_until function Returns the epoch timestamp until which events are suppressed.
--- @param ui_restore table lib.ui_restore module (provides defer_reload).
--- @return userdata|nil The hs.pathwatcher object, or nil on failure.
function M.start_config_watcher(base_dir, on_reload, get_suppress_until, ui_restore)
	-- Single debounce timer shared across all pathwatcher callbacks; cancelled
	-- and restarted on every new event so that a burst of changes produces only
	-- one reload fired DEBOUNCE_SEC after the last event in the burst.
	local _debounce_timer = nil

	local function reload_config(files)
		-- HTML/CSS/JS are webview assets loaded at open-time — changing them
		-- never requires hs.reload(); only .lua and .toml affect runtime behavior
		if hs.timer.secondsSinceEpoch() < get_suppress_until() then return end
		if type(files) == "table" then
			for _, file in pairs(files) do
				if type(file) == "string"
					and (file:match("%.lua$") or file:match("%.toml$"))
					and not file:match("logs/")
					-- paths.toml is auto-generated at each boot — treating it as a
					-- source change would cause an infinite reload loop (HS writes
					-- it → watcher fires → reload → HS writes it again → …)
					and not file:match("paths%.toml$") then
					Logger.debug(LOG, "File change detected: %s — debounce armed.", file)
					-- Cancel any pending debounce and restart it; the reload
					-- fires only once the burst settles
					if _debounce_timer then
						pcall(function() _debounce_timer:stop() end)
					end
					_debounce_timer = hs.timer.doAfter(DEBOUNCE_SEC, function()
						_debounce_timer = nil
						ui_restore.defer_reload(on_reload)
					end)
					return
				end
			end
		end
	end

	local ok_w, watcher = pcall(hs.pathwatcher.new, base_dir, reload_config)
	if ok_w and watcher then
		pcall(function() watcher:start() end)
		Logger.debug(LOG, "Config pathwatcher started on '%s'.", base_dir)
		return watcher
	else
		Logger.warn(LOG, "Failed to create config pathwatcher for '%s'.", base_dir)
		return nil
	end
end





-- =====================================
--- =======================================
--- ======= 2/ Theme Change Watcher =======
--- =======================================
-- =====================================

--- Creates and starts a distributed-notification watcher for macOS theme changes.
--- Calls on_update when the interface style switches between Light and Dark.
--- @param on_update function Callback invoked on theme change.
--- @return userdata The hs.distributednotifications object (already started).
function M.start_theme_watcher(on_update)
	local watcher = hs.distributednotifications.new(function(name)
		if name == "AppleInterfaceThemeChangedNotification" then
			on_update()
		end
	end, "AppleInterfaceThemeChangedNotification")
	watcher:start()
	Logger.debug(LOG, "Theme change watcher started.")
	return watcher
end

return M
