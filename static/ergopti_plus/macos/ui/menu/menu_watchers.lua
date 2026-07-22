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
local hs          = hs
local Logger      = require("lib.logger")
local git_status  = require("lib.git_status")
local reload_gate = require("reload_gate")
local LOG         = "menu_watchers"





-- =====================================
-- ======================================
-- ======= 1/ Config File Watcher =======
-- ======================================
-- =====================================

-- Debounce delay (seconds): absorbs rapid bursts of file-change events
-- (e.g. a git commit touching several .lua files at once) so that only a
-- single hs.reload() fires instead of one per changed file. It doubles as the
-- settle poll interval below.
local DEBOUNCE_SEC = 0.5

-- Max consecutive hold re-polls (each DEBOUNCE_SEC) with NO new file activity,
-- before the hold is bypassed. Real activity resets the counter (see
-- reload_config), so a genuine bulk write never trips it — only a quiet-but-stuck
-- state (a STALE index.lock left by a crashed git) does. Kept identical to
-- lib/file_watchers' GIT_SETTLE_MAX_DEFERRALS.
local GIT_SETTLE_MAX_DEFERRALS = 120   -- 120 * 0.5s = 60s of a quiet-but-stuck repo

--- Creates and starts a pathwatcher on base_dir that triggers a reload on .lua/.toml changes.
--- Ignores changes that arrive while the suppress window is active (e.g. after opening a file
--- for editing from within the menu itself).
--- @param base_dir string Directory to watch.
--- @param on_reload function Callback invoked when a relevant file change is detected.
--- @param get_suppress_until function Returns the epoch timestamp until which events are suppressed.
--- @param ui_restore table lib.ui_restore module (provides defer_reload).
--- @return userdata|nil The hs.pathwatcher object, or nil on failure.
function M.start_config_watcher(base_dir, on_reload, get_suppress_until, ui_restore)
	-- Single debounce/poll timer shared across all pathwatcher callbacks; cancelled
	-- and restarted on every new event so that a burst of changes produces only
	-- one reload fired once the burst settles.
	local _debounce_timer = nil
	-- Consecutive hold re-polls with no new file activity; reset to 0 by any real
	-- file event (reload_config) and by a fired reload, capped by
	-- GIT_SETTLE_MAX_DEFERRALS so only a quiet-but-stuck state can bypass the hold.
	local defer_count = 0
	-- Distinct source paths changed since the current burst began, and the epoch
	-- time (s) of the last change — together they drive the adaptive settle so a
	-- BULK write (git pull, OneDrive / Dropbox sync, rsync, mass save) is held
	-- until activity has been quiet, while a lone edit still reloads fast
	-- (macos-reload-during-git-pull).
	local burst_paths     = {}
	local burst_count     = 0
	local last_change_sec = 0

	-- ``fire_reload`` is forward-declared so the debounce closure can call it
	-- while ``fire_reload`` itself re-arms through ``arm_reload`` (the Lua
	-- local-after-closure trap: a closure only captures a local declared above it).
	local fire_reload

	local function arm_reload()
		-- Cancel any pending timer and restart it; the reload fires only once the
		-- burst settles.
		if _debounce_timer then
			pcall(function() _debounce_timer:stop() end)
		end
		_debounce_timer = hs.timer.doAfter(DEBOUNCE_SEC, function()
			_debounce_timer = nil
			fire_reload()
		end)
	end

	fire_reload = function()
		-- Hold the reload while base_dir is still being written FROM ANY SOURCE, so
		-- the driver never reloads init.lua against a half-updated tree (the freeze).
		-- Two signals, shared with lib/file_watchers through reload_gate: quiescence
		-- for a bulk write of many files, and the precise git index.lock guard. Both
		-- watchers must hold for the same window, or the unguarded one reloads mid-op.
		local elapsed = hs.timer.secondsSinceEpoch() - last_change_sec
		local hold, why
		if not reload_gate.is_settled(elapsed, burst_count) then
			hold, why = true, "filesystem settling"
		elseif git_status.operation_in_progress(base_dir) then
			hold, why = true, "git operation in progress"
		end
		if hold and defer_count < GIT_SETTLE_MAX_DEFERRALS then
			defer_count = defer_count + 1
			Logger.debug(LOG, "Reload held (%s) on '%s' (%d/%d).", why, base_dir, defer_count, GIT_SETTLE_MAX_DEFERRALS)
			arm_reload()
			return
		end
		burst_paths, burst_count, defer_count = {}, 0, 0
		ui_restore.defer_reload(on_reload)
	end

	local function reload_config(files)
		-- HTML/CSS/JS are webview assets loaded at open-time — changing them
		-- never requires hs.reload(); only .lua and .toml affect runtime behavior
		if hs.timer.secondsSinceEpoch() < get_suppress_until() then return end
		if type(files) ~= "table" then return end
		local matched = false
		for _, file in pairs(files) do
			if type(file) == "string"
				and (file:match("%.lua$") or file:match("%.toml$"))
				and not file:match("logs/")
				-- paths.toml is auto-generated at each boot — treating it as a source
				-- change would cause an infinite reload loop (HS writes it, the
				-- watcher fires, the reload rewrites it, and so on).
				and not file:match("paths%.toml$") then
				if not burst_paths[file] then
					burst_paths[file] = true
					burst_count = burst_count + 1
				end
				matched = true
			end
		end
		if matched then
			Logger.debug(LOG, "File change detected (%d distinct in burst) — settle armed.", burst_count)
			last_change_sec = hs.timer.secondsSinceEpoch()
			-- A genuine file event resets the stuck-state counter.
			defer_count = 0
			arm_reload()
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
