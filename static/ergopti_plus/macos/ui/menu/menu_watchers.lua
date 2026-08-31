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
local Logger      = require("infra.logger")
local git_status  = require("infra.git_status")
local reload_gate = require("reload_gate")
local LOG         = "menu_watchers"





-- ======================================
-- ======================================
-- ======= 1/ Config File Watcher =======
-- ======================================
-- ======================================

-- Debounce delay (seconds): absorbs rapid bursts of file-change events
-- (e.g. a git commit touching several .lua files at once) so that only a
-- single hs.reload() fires instead of one per changed file. It doubles as the
-- settle poll interval below.
local DEBOUNCE_SEC = 0.5

-- Consecutive Git-hold re-polls before one visible warning is emitted. A live
-- index.lock remains authoritative regardless of elapsed time: bypassing it can
-- reload a half-checked-out tree. Kept identical to infra/file_watchers.
local GIT_HOLD_WARN_DEFERRALS = 120   -- 120 * 0.5s = 60s before one warning

--- Checks the complete lifecycle surface before any native activation.
--- @param candidate any Constructor result.
--- @return boolean valid
local function valid_native_watcher(candidate)
	local candidate_type = type(candidate)
	if candidate_type ~= "table" and candidate_type ~= "userdata" then return false end
	local ok, valid = pcall(function()
		return type(candidate.start) == "function" and type(candidate.stop) == "function"
	end)
	return ok and valid == true
end

--- Activates one watcher only when Hammerspoon returns that exact capability.
--- @param candidate table|userdata Native watcher candidate.
--- @param label string Diagnostic owner.
--- @return boolean committed
local function start_native_watcher(candidate, label)
	local started, owner_or_err = xpcall(function()
		return candidate:start()
	end, debug.traceback)
	if not started or owner_or_err ~= candidate then
		Logger.error(LOG, "%s activation did not commit exact ownership: %s.",
			label, tostring(owner_or_err))
		return false
	end
	return true
end

--- Creates and starts a pathwatcher on base_dir that triggers a reload on .lua/.toml changes.
--- Ignores changes that arrive while the suppress window is active (e.g. after opening a file
--- for editing from within the menu itself).
--- @param base_dir string Directory to watch.
--- @param on_reload function Callback invoked when a relevant file change is detected.
--- @param get_suppress_until function Returns the epoch timestamp until which events are suppressed.
--- @param ui_restore table lib.ui_restore module (provides defer_reload).
--- @return table|nil Composite watcher/timer lifecycle owner, or nil on failure.
function M.start_config_watcher(base_dir, on_reload, get_suppress_until, ui_restore, ignored_dirs, self_written_files)
	-- Single debounce/poll timer shared across all pathwatcher callbacks; cancelled
	-- and restarted on every new event so that a burst of changes produces only
	-- one reload fired once the burst settles.
	local _debounce_timer = nil
	local _timer_cleanup_backlog = {}
	local _lifecycle_active = true
	local _lifecycle_generation = 0
	local _callback_admitted = false
	-- Consecutive Git-hold re-polls with no new file activity; reset by an event or
	-- committed reload. The threshold is diagnostic only: a live lock is never bypassed.
	local defer_count = 0
	-- Distinct source paths changed since the current burst began, and the epoch
	-- time (s) of the last change — together they drive the adaptive settle so a
	-- BULK write (git pull, OneDrive / Dropbox sync, rsync, mass save) is held
	-- until activity has been quiet, while a lone edit still reloads fast
	-- (macos-reload-during-git-pull).
	local burst_paths     = {}
	local burst_count     = 0
	local last_change_sec = 0
	local reload_refusal_logged = false

	-- ``fire_reload`` is forward-declared so the debounce closure can call it
	-- while ``fire_reload`` itself re-arms through ``arm_reload`` (the Lua
	-- local-after-closure trap: a closure only captures a local declared above it).
	local fire_reload

	--- Stops one exact native capability without dropping it after uncertainty.
	--- @param handle table|userdata Native pathwatcher or timer.
	--- @param label string Diagnostic owner.
	--- @return boolean stopped
	local function stop_capability(handle, label)
		local ok, result = pcall(function() return handle:stop() end)
		if not ok or result == false then
			Logger.error(LOG, "%s stop failed; exact capability retained for retry: %s",
				tostring(label), tostring(result))
			return false
		end
		return true
	end

	local function arm_reload()
		if not _lifecycle_active then return false end
		_lifecycle_generation = _lifecycle_generation + 1
		local generation = _lifecycle_generation
		-- Cancel any pending timer and restart it; the reload fires only once the
		-- burst settles.
		if _debounce_timer then
			if not stop_capability(_debounce_timer, "Superseded menu debounce timer") then
				_timer_cleanup_backlog[#_timer_cleanup_backlog + 1] = _debounce_timer
			end
			_debounce_timer = nil
		end
		local timer
		local ok, timer_or_err = pcall(hs.timer.doAfter, DEBOUNCE_SEC, function()
			if not _lifecycle_active or generation ~= _lifecycle_generation then return end
			if _debounce_timer == timer then _debounce_timer = nil end
			fire_reload()
		end)
		timer = ok and timer_or_err or nil
		local timer_type = type(timer)
		if not ok or (timer_type ~= "table" and timer_type ~= "userdata")
			or type(timer.stop) ~= "function" then
			Logger.error(LOG, "Could not arm menu debounce timer: %s",
				tostring(ok and "timer unavailable" or timer_or_err))
			return false
		end
		_debounce_timer = timer
		return true
	end

	fire_reload = function()
		if not _lifecycle_active then return end
		-- Hold the reload while base_dir is still being written FROM ANY SOURCE, so
		-- the driver never reloads init.lua against a half-updated tree (the freeze).
		-- Two signals, shared with infra/file_watchers through reload_gate: quiescence
		-- for a bulk write of many files, and the precise git index.lock guard. Both
		-- watchers must hold for the same window, or the unguarded one reloads mid-op.
		local elapsed = hs.timer.secondsSinceEpoch() - last_change_sec
		if not reload_gate.is_settled(elapsed, burst_count) then
			Logger.debug(LOG, "Reload held (filesystem settling) on '%s'.", base_dir)
			arm_reload()
			return
		end
		if git_status.operation_in_progress(base_dir) then
			if defer_count < GIT_HOLD_WARN_DEFERRALS then
				defer_count = defer_count + 1
				if defer_count == GIT_HOLD_WARN_DEFERRALS then
					Logger.warn(LOG,
						"Git operation still owns the reload fence after %d checks on '%s'; reload remains pending.",
						GIT_HOLD_WARN_DEFERRALS, base_dir)
				else
					Logger.debug(LOG, "Reload held (git operation in progress) on '%s' (%d/%d).",
						base_dir, defer_count, GIT_HOLD_WARN_DEFERRALS)
				end
			end
			arm_reload()
			return
		end
		-- A settled filesystem burst is still owned until the exclusive reload
		-- transaction accepts it. Refusal is non-terminal and must re-arm this owner.
		local reload_generation = _lifecycle_generation
		local callback_invoked = false
		local defer_ok, deferred = xpcall(function()
			return ui_restore.defer_reload(function()
				callback_invoked = true
				if not _lifecycle_active or reload_generation ~= _lifecycle_generation then return end
				if git_status.operation_in_progress(base_dir) then
					Logger.info(LOG,
						"Reload aborted at fire time: a Git operation started during the UI hold; re-arming.")
					arm_reload()
					return
				end
				local request_ok, accepted = xpcall(on_reload, debug.traceback)
				if not request_ok or accepted ~= true then
					if not reload_refusal_logged then
						reload_refusal_logged = true
						Logger.warn(LOG,
							"Menu reload request was refused; the source-file burst remains pending for retry: %s.",
							tostring(request_ok and accepted or accepted))
					else
						Logger.debug(LOG, "Menu reload request remains refused; retaining the source-file burst.")
					end
					arm_reload()
					return false
				end
				burst_paths, burst_count, defer_count = {}, 0, 0
				reload_refusal_logged = false
				return true
			end)
		end, debug.traceback)
		if (not defer_ok or deferred ~= true) and not callback_invoked then
			if not reload_refusal_logged then
				reload_refusal_logged = true
				Logger.warn(LOG,
					"Deferred menu reload owner refused the source-file burst; retaining it for retry: %s.",
					tostring(defer_ok and deferred or deferred))
			end
			arm_reload()
		end
	end

	--- The files the driver rewrites itself, as a set keyed by path. config.toml is
	--- rewritten on EVERY persisted preference change, so under a layout where the
	--- config directory sits inside base_dir — the symlink and copy layouts — a
	--- menu toggle looked exactly like a source edit to this watcher and armed a
	--- reload. infra/file_watchers is given the same list and has always used it;
	--- this watcher covers the same tree and was not, which is the whole of the
	--- asymmetry: the exclusion was applied to one of two watchers on one tree.
	local self_written = {}
	for _, p in ipairs(self_written_files or {}) do
		if type(p) == "string" and p ~= "" then self_written[p] = true end
	end

	--- True when a changed path is one the driver wrote itself.
	--- @param file string Absolute path reported by the pathwatcher.
	--- @return boolean
	local function is_self_written(file)
		return self_written[file] == true
	end

	--- True when a changed path lies inside a directory the driver writes itself.
	--- @param file string Absolute path reported by the pathwatcher.
	--- @return boolean
	local function is_ignored(file)
		if type(ignored_dirs) ~= "table" then return false end
		for _, dir in ipairs(ignored_dirs) do
			if type(dir) == "string" and dir ~= "" and file:sub(1, #dir) == dir then
				return true
			end
		end
		return false
	end

	local function reload_config(files)
		if not _lifecycle_active or not _callback_admitted then return end
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
				and not file:match("paths%.toml$")
				-- Directories the DRIVER ITSELF writes into. This watcher is the second
				-- recursive one on this tree; infra/file_watchers arms the other and is
				-- given the same list, but only that one used it. The TOML snapshot
				-- cache writes files named "<base>_<hash>.lua" — the exact extension
				-- treated as a source change here — so under the symlink/copy layout a
				-- snapshot write reloaded the driver, the reload re-parsed and rewrote
				-- snapshots, and the cycle repeated. That is the same loop the
				-- paths.toml exclusion above was added for.
				and not is_ignored(file)
				-- Files the driver rewrites itself: config.toml on every preference
				-- toggle, the Karabiner config on every regenerate. Treating those as a
				-- source change makes the driver reload because the user ticked a menu
				-- item.
				and not is_self_written(file) then
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
			reload_refusal_logged = false
			-- A genuine file event resets the stuck-state counter.
			defer_count = 0
			arm_reload()
		end
	end

	local constructed, watcher_or_err = xpcall(function()
		return hs.pathwatcher.new(base_dir, reload_config)
	end, debug.traceback)
	if not constructed or not valid_native_watcher(watcher_or_err) then
		Logger.error(LOG, "Failed to create config pathwatcher for '%s': %s.",
			base_dir, tostring(constructed and "malformed watcher" or watcher_or_err))
		return nil
	end

	local watcher = watcher_or_err
	-- The returned object is the sole lifecycle owner. Keeping the timer as a
	-- sibling would let the pathwatcher enqueue another reload between stops.
	local owner = {}
	function owner:stop()
		_lifecycle_active = false
		_callback_admitted = false
		_lifecycle_generation = _lifecycle_generation + 1
		local all_stopped = true
		if _debounce_timer then
			if stop_capability(_debounce_timer, "Menu debounce timer") then
				_debounce_timer = nil
			else
				all_stopped = false
			end
		end
		for index = #_timer_cleanup_backlog, 1, -1 do
			if stop_capability(_timer_cleanup_backlog[index], "Superseded menu debounce timer") then
				table.remove(_timer_cleanup_backlog, index)
			else
				all_stopped = false
			end
		end
		if watcher then
			if stop_capability(watcher, "Menu config pathwatcher") then
				watcher = nil
			else
				all_stopped = false
			end
		end
		return all_stopped
	end

	if not start_native_watcher(watcher, "Menu config pathwatcher") then
		if owner:stop() then return nil end
		Logger.error(LOG, "Config pathwatcher startup rollback remains retryable.")
		return owner
	end
	_callback_admitted = true
	Logger.debug(LOG, "Config pathwatcher started on '%s'.", base_dir)
	return owner
end





--- =======================================
--- =======================================
--- ======= 2/ Theme Change Watcher =======
--- =======================================
--- =======================================

--- Creates and starts a distributed-notification watcher for macOS theme changes.
--- Calls on_update when the interface style switches between Light and Dark.
--- @param on_update function Callback invoked on theme change.
--- @return table|nil Composite watcher lifecycle owner, or nil on settled failure.
function M.start_theme_watcher(on_update)
	local callback_admitted = false
	local constructed, watcher_or_err = xpcall(function()
		return hs.distributednotifications.new(function(name)
			if callback_admitted and name == "AppleInterfaceThemeChangedNotification" then
				on_update()
			end
		end, "AppleInterfaceThemeChangedNotification")
	end, debug.traceback)
	if not constructed or not valid_native_watcher(watcher_or_err) then
		Logger.error(LOG, "Failed to create theme watcher: %s.",
			tostring(constructed and "malformed watcher" or watcher_or_err))
		return nil
	end

	local watcher = watcher_or_err
	local owner = {}
	function owner:stop()
		callback_admitted = false
		if not watcher then return true end
		local stopped, result = xpcall(function() return watcher:stop() end, debug.traceback)
		if not stopped or result == false then
			Logger.error(LOG, "Menu theme watcher stop failed; exact capability retained for retry: %s.",
				tostring(result))
			return false
		end
		watcher = nil
		return true
	end

	if not start_native_watcher(watcher, "Menu theme watcher") then
		if owner:stop() then return nil end
		Logger.error(LOG, "Theme watcher startup rollback remains retryable.")
		return owner
	end
	callback_admitted = true
	Logger.debug(LOG, "Theme change watcher started.")
	return owner
end

return M
