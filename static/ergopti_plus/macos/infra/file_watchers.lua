--- infra/file_watchers.lua

--- ==============================================================================
--- MODULE: Auto-Reload File Watchers
--- DESCRIPTION:
--- Boot-time hs.pathwatcher setup that reloads Hammerspoon when the user edits a
--- hotstring TOML (in the shared dir, the personal dir tree, or in place) or any
--- project .lua file. The required hotstrings/project watchers and any available
--- personal-root watcher commit as one startup transaction so boot never
--- publishes a partially armed required reload surface.
---
--- FEATURES & RATIONALE:
--- 1. GC-rooting: one composite owner is pinned in _G.script_watchers so neither
---    its native watchers nor their shared timer can be collected or stopped in
---    the wrong order; init.lua stops that owner through the same global.
--- 2. Debounced reload: rapid successive saves collapse into a single reload via a
---    0.5 s timer, and the reload is deferred through ui_restore so open UI is
---    snapshotted/closed first.
--- 3. Transactional Arming: constructor/start refusal revokes callbacks before a
---    reverse rollback; any exact capability whose stop refuses remains rooted
---    for shutdown retry without being advertised as a successful startup.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local notifications = require("infra.notifications")
local ui_restore    = require("infra.ui_restore")
local fs_dir        = require("infra.fs_dir")
local git_status    = require("infra.git_status")
local reload_gate   = require("reload_gate")

local LOG = "file_watchers"

-- Hard cap on how deep the recursive personal-hotstrings watcher scan descends.
-- Same rationale as infra/personal_hotstrings.lua's SCAN_MAX_DEPTH: the scanned
-- tree is a user-writable folder, so a self-referential symlink would make a
-- naive recursion loop forever and abort boot with a stack overflow (F-LOW-4).
local SCAN_MAX_DEPTH = 16

-- Ignore file-change events for this long after the watchers are armed. macOS
-- FSEvents buffers events across an hs.reload() and replays them to the freshly
-- armed watcher; without this window a `git pull` whose writes landed during the
-- previous boot would re-fire a reload immediately after the next boot — and,
-- because the replay recurs every boot, cascade into the keyboard-freezing reload
-- storm (fe57ce045). Mirrors the menu watcher's identical guard
-- (ui/menu/init.lua BOOT_SUPPRESS_SEC) — the sibling this one was missing.
local BOOT_SUPPRESS_SEC = 5

-- Consecutive Git-hold re-polls before one visible warning is emitted. A live
-- index.lock remains authoritative regardless of elapsed time: bypassing it can
-- reload a half-checked-out tree. The counter saturates after the warning so a
-- stale lock remains safe without flooding the log.
-- The poll interval itself stays the bare literal 0.5 in hs.timer.doAfter below —
-- a cross-driver single-source gate pins it to Linux's _debounce_sec
-- (tools/test/test-file-watchers-constants-single-source.cjs).
local GIT_HOLD_WARN_DEFERRALS = 120   -- 120 * 0.5s = 60s before one warning





-- =======================================
-- =======================================
-- ======= 1/ Auto-Reload Watchers =======
-- =======================================
-- =======================================

--- Normalises a path for comparison: lowercased, backslashes folded to slashes.
--- @param p string|nil
--- @return string
local function canonical_path(p)
	if type(p) ~= "string" then return "" end
	return (p:gsub("\\", "/"):lower())
end

--- Arms every auto-reload watcher. Pins them in _G.script_watchers (the GC root
--- init.lua's shutdown callback stops on quit).
--- @param ctx table { hotstrings_dir: string, base_dir: string,
---   personal_hotstrings_dir: string, self_written_files: string[] } — absolute
---   paths resolved by the boot script.
--- @return boolean committed True only when both required watchers, plus the
---   personal watcher when available, are started and their owner is published.
function M.start(ctx)
	local hotstrings_dir = ctx.hotstrings_dir
	local base_dir       = ctx.base_dir
	local personal_dir   = ctx.personal_hotstrings_dir or ""

	-- Files this session writes ITSELF, which must never look like an external
	-- change. The hotstrings directory resolves to the config ROOT whenever that
	-- root holds any ordinary .toml — and the real tree does, wrap_symbols.toml —
	-- so the recursive pathwatcher covers hammerspoon/config.toml too. Every
	-- save_prefs, meaning every single menu toggle, then looked exactly like a
	-- user editing a hotstring file and reloaded the whole driver half a second
	-- later. config_karabiner.toml is worse still: the driver regenerates it
	-- whenever the layout changes.
	--
	-- Matched by resolved PATH rather than by filename, and resolved by the
	-- caller from menu_paths, so there is no second spelling of these names to
	-- drift from the one the writers use.
	local self_written = {}
	for _, p in ipairs(ctx.self_written_files or {}) do
		local key = canonical_path(p)
		if key ~= "" then self_written[key] = true end
	end

	--- True when a changed path is one this session wrote itself.
	--- @param path string
	--- @return boolean
	local function is_self_written(path)
		return self_written[canonical_path(path)] == true
	end

	-- Directories inside the watched trees that hold RUNTIME artefacts rather
	-- than source. The TOML snapshot cache is the reason this exists: it lives
	-- under the driver directory and writes .lua files, so every cache refresh
	-- looked exactly like a source edit — and the reload it triggered re-warmed
	-- the cache, which wrote again.
	local ignored_dirs = {}
	for _, d in ipairs(ctx.ignored_dirs or {}) do
		local key = canonical_path(d):gsub("/+$", "")
		if key ~= "" then ignored_dirs[#ignored_dirs + 1] = key .. "/" end
	end

	--- True when a changed path lies inside an ignored runtime directory.
	--- @param path string
	--- @return boolean
	local function is_runtime_artefact(path)
		local key = canonical_path(path)
		for _, prefix in ipairs(ignored_dirs) do
			if key:sub(1, #prefix) == prefix then return true end
		end
		return false
	end

	-- Every tree whose git state can invalidate a reload. The driver repo is one;
	-- the personal hotstrings tree is usually ANOTHER repository entirely, and a
	-- pull there rewrites files this watcher is watching while the driver's own
	-- .git sits perfectly idle — so probing only the driver left the config repo
	-- completely unguarded.
	local git_roots = {}
	for _, r in ipairs(ctx.git_roots or { base_dir }) do
		if type(r) == "string" and r ~= "" then git_roots[#git_roots + 1] = r end
	end

	--- True when a git write-operation is in flight in ANY watched tree.
	--- @return boolean, string|nil The verdict and the repository that is busy.
	local function any_git_operation_in_progress()
		for _, root in ipairs(git_roots) do
			if git_status.operation_in_progress(root) then return true, root end
		end
		return false, nil
	end

	-- Global table pins one composite owner so the native watchers and their
	-- shared debounce timer are revoked as one lifecycle. A separate timer owner
	-- would make shutdown order-dependent: the watcher could enqueue another
	-- reload between the two stop calls.
	local watcher_roots = rawget(_G, "script_watchers")
	if watcher_roots ~= nil and type(watcher_roots) ~= "table" then
		Logger.error(LOG, "File-watcher owner root is malformed; startup refused.")
		return false
	end
	watcher_roots = watcher_roots or {}
	local lifecycle_active = false
	local lifecycle_generation = 0
	local native_watchers = {}
	local timer_cleanup_backlog = {}
	local callback_admissions = {}
	local owner_published = false

	-- Drop FSEvents replays delivered during the post-boot suppress window (see
	-- BOOT_SUPPRESS_SEC). Captured now because M.start runs at the tail of boot,
	-- right where the freshly-armed watchers would otherwise catch the previous
	-- session's buffered events.
	local suppress_until = hs.timer.secondsSinceEpoch() + BOOT_SUPPRESS_SEC

	local reload_timer = nil

	--- Stops one exact native capability without discarding it on uncertainty.
	--- hs.pathwatcher:stop() is a void API, so non-throw is its exact commitment;
	--- explicit false is reserved by stateful test doubles to model refusal.
	--- @param handle table|userdata Native watcher or timer.
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

	local owner = {}
	function owner:stop()
		-- Logical revocation precedes native cleanup. A callback already queued by
		-- FSEvents/NSTimer is therefore inert even when native stop is uncertain.
		lifecycle_active = false
		for _, admission in ipairs(callback_admissions) do admission.active = false end
		lifecycle_generation = lifecycle_generation + 1
		local all_stopped = true
		if reload_timer then
			if stop_capability(reload_timer, "File-watcher debounce timer") then
				reload_timer = nil
			else
				all_stopped = false
			end
		end
		for index = #timer_cleanup_backlog, 1, -1 do
			if stop_capability(timer_cleanup_backlog[index], "Superseded file-watcher debounce timer") then
				table.remove(timer_cleanup_backlog, index)
			else
				all_stopped = false
			end
		end
		for index = #native_watchers, 1, -1 do
			if stop_capability(native_watchers[index], "File watcher") then
				table.remove(native_watchers, index)
			else
				all_stopped = false
			end
		end
		return all_stopped
	end

	--- Publishes the composite owner once, either after a full startup commit or
	--- as the root for exact rollback debt. A fully settled refusal publishes
	--- nothing and therefore cannot be mistaken for operational ownership.
	local function publish_owner()
		if owner_published then return end
		watcher_roots[#watcher_roots + 1] = owner
		_G.script_watchers = watcher_roots
		owner_published = true
	end

	--- Revokes callbacks and rolls every staged watcher back in reverse order.
	--- @return boolean Always false: this helper is a startup refusal boundary.
	local function rollback_startup()
		local settled = owner:stop()
		if not settled then
			publish_owner()
			Logger.error(LOG, "File-watcher startup rollback remains incomplete and retryable.")
		end
		return false
	end

	--- Tests whether a constructor returned the complete native watcher surface.
	--- Construction does not activate hs.pathwatcher, so a malformed candidate is
	--- rejected before start and owns no native cleanup obligation.
	--- @param candidate any Constructor result.
	--- @return boolean valid
	local function valid_watcher(candidate)
		local candidate_type = type(candidate)
		if candidate_type ~= "table" and candidate_type ~= "userdata" then return false end
		local ok, valid = pcall(function()
			return type(candidate.start) == "function" and type(candidate.stop) == "function"
		end)
		return ok and valid == true
	end

	--- Constructs and starts one exact watcher, staging its constructor result
	--- before activation so even a partial-then-throw start remains rollback-owned.
	--- hs.pathwatcher:start() commits only by returning that same watcher object.
	--- @param path string Watched root.
	--- @param callback function Native event callback.
	--- @param label string Diagnostic owner.
	--- @param allow_unavailable boolean Whether constructor unavailability may be skipped.
	--- @return boolean committed
	local function acquire_watcher(path, callback, label, allow_unavailable)
		local admission = { active = false }
		local function guarded_callback(...)
			if not lifecycle_active or admission.active ~= true then return end
			return callback(...)
		end
		local constructed, candidate_or_err = xpcall(function()
			return hs.pathwatcher.new(path, guarded_callback)
		end, debug.traceback)
		if not constructed or not valid_watcher(candidate_or_err) then
			local detail = tostring(constructed and "malformed watcher" or candidate_or_err)
			if allow_unavailable then
				Logger.warn(LOG, "%s is unavailable and was skipped: %s.", label, detail)
				return true
			end
			Logger.error(LOG, "%s construction did not commit: %s.", label, detail)
			return false
		end

		local candidate = candidate_or_err
		native_watchers[#native_watchers + 1] = candidate
		local started, owner_or_err = xpcall(function()
			return candidate:start()
		end, debug.traceback)
		if not started or owner_or_err ~= candidate then
			Logger.error(LOG, "%s activation did not commit exact ownership: %s.", label,
				tostring(owner_or_err))
			return false
		end
		callback_admissions[#callback_admissions + 1] = admission
		return true
	end
	-- Consecutive Git-hold re-polls with no new file activity; reset by an event or
	-- committed reload. The threshold is diagnostic only: a live lock is never bypassed.
	local defer_count = 0
	-- Distinct source paths changed since the current burst began, and the epoch
	-- time (s) of the last change. Together they drive the adaptive settle: a lone
	-- edit reloads after EDIT_SETTLE_SEC, but a BULK write — git pull, OneDrive /
	-- Dropbox sync, rsync, mass save, any source that touches many files — is held
	-- until activity has been quiet for BULK_SETTLE_SEC, so the reload never fires
	-- mid-operation (macos-reload-during-git-pull).
	local burst_paths     = {}
	local burst_count     = 0
	local last_change_sec = 0

	-- ``fire_reload`` is forward-declared so the debounce timer closure can call it
	-- while ``fire_reload`` itself re-arms through ``arm_timer``. The Lua
	-- local-after-closure trap: a closure only captures a local declared ABOVE it,
	-- so both names must exist before either body runs.
	local fire_reload

	local function arm_timer(msg)
		if not lifecycle_active then return false end
		lifecycle_generation = lifecycle_generation + 1
		local generation = lifecycle_generation
		if reload_timer then
			if not stop_capability(reload_timer, "Superseded file-watcher debounce timer") then
				timer_cleanup_backlog[#timer_cleanup_backlog + 1] = reload_timer
			end
			reload_timer = nil
		end
		-- Bare literal 0.5: a cross-driver single-source gate pins this poll tick
		-- to Linux's _debounce_sec (do not replace it with a named constant).
		local timer
		local ok, timer_or_err = pcall(hs.timer.doAfter, 0.5, function()
			if not lifecycle_active or generation ~= lifecycle_generation then return end
			if reload_timer == timer then reload_timer = nil end
			fire_reload(msg)
		end)
		timer = ok and timer_or_err or nil
		local timer_type = type(timer)
		if not ok or (timer_type ~= "table" and timer_type ~= "userdata")
			or type(timer.stop) ~= "function" then
			Logger.error(LOG, "Could not arm file-watcher debounce timer: %s",
				tostring(ok and "timer unavailable" or timer_or_err))
			return false
		end
		reload_timer = timer
		return true
	end

	--- Records a batch of changed paths and (re)arms the settle poll.
	--- @param msg string Notification message for the eventual reload.
	--- @param changed table|nil Absolute paths that changed in this event.
	local function note_change(msg, changed)
		if not lifecycle_active then return end
		local now = hs.timer.secondsSinceEpoch()
		-- Ignore the FSEvents batch macOS replays right after an hs.reload(): during
		-- the boot window these are the previous session's changes, not a new edit.
		if now < suppress_until then return end
		if type(changed) == "table" then
			for _, p in ipairs(changed) do
				if not burst_paths[p] then
					burst_paths[p] = true
					burst_count = burst_count + 1
				end
			end
		end
		last_change_sec = now
		-- Genuine activity resets the stuck-state counter, so an ongoing write never
		-- bypasses the hold; only a quiet-but-stuck state climbs toward the cap.
		defer_count = 0
		arm_timer(msg)
	end

	fire_reload = function(msg)
		if not lifecycle_active then return end
		-- Hold the reload while the working tree is still being written FROM ANY
		-- SOURCE, so hs.reload() never re-execs init.lua against a half-updated,
		-- internally inconsistent tree (which errors during boot and, via repeated
		-- reloads, cascades into the keyboard-freezing storm). Two signals:
		--   1. Quiescence — a bulk write (git pull, cloud sync, rsync, mass save)
		--      shows up as many distinct files; hold until BULK_SETTLE_SEC of quiet.
		--   2. Git — a git operation holds .git/index.lock for the whole update, so
		--      it is deferred exactly even if its file events pause partway through.
		local elapsed = hs.timer.secondsSinceEpoch() - last_change_sec
		if not reload_gate.is_settled(elapsed, burst_count) then
			Logger.debug(LOG, "Reload held (filesystem settling) on '%s'.", base_dir)
			arm_timer(msg)
			return
		end
		local busy, repo = any_git_operation_in_progress()
		if busy then
			if defer_count < GIT_HOLD_WARN_DEFERRALS then
				defer_count = defer_count + 1
				if defer_count == GIT_HOLD_WARN_DEFERRALS then
					Logger.warn(LOG,
						"Git operation in '%s' still owns the reload fence after %d checks; reload remains pending.",
						tostring(repo), GIT_HOLD_WARN_DEFERRALS)
				else
					Logger.debug(LOG, "Reload held (git operation in progress in %s) on '%s' (%d/%d).",
						tostring(repo), base_dir, defer_count, GIT_HOLD_WARN_DEFERRALS)
				end
			end
			arm_timer(msg)
			return
		end
		-- Tree is settled and consistent: clear the burst and reload.
		burst_paths, burst_count, defer_count = {}, 0, 0
		local reload_generation = lifecycle_generation
		ui_restore.defer_reload(function()
			if not lifecycle_active or reload_generation ~= lifecycle_generation then return end
			-- Re-check at FIRE time, not only at schedule time. defer_reload holds
			-- the reload for as long as a UI stays open — seconds, or minutes if
			-- the user leaves a window up — and the verdict computed before that
			-- wait says nothing about the tree now. A pull that starts during the
			-- hold would otherwise be re-exec'd into mid-write, which is the
			-- half-updated-tree boot failure the gate exists to prevent.
			local busy, repo = any_git_operation_in_progress()
			if busy then
				Logger.info(LOG, "Reload aborted at fire time: git operation started in '%s' during the "
					.. "UI hold — re-arming.", tostring(repo))
				arm_timer(msg)
				return
			end
			-- snapshot() is a safety net for any UI still open at reload time;
			-- under normal deferral they are already closed so it saves nothing
			ui_restore.snapshot()
			pcall(notifications.notify, i18n.get("init.reload_title"), msg or i18n.get("init.reload_files"), "info")
			hs.reload()
		end)
	end



	-- ========================================
	-- ===== 1.1) Directory-Level Watcher =====
	-- ========================================

	-- Catches file creation, deletion, and renames in the hotstrings directory
	local function hotstrings_changed(paths)
		if not lifecycle_active then return end
		local hit = {}
		for _, p in ipairs(paths) do
			if (p:match("%.toml$") or p:match("_index%.json$") or p:match("%.local_ahk_path$"))
				and not is_self_written(p) and not is_runtime_artefact(p) then
				hit[#hit + 1] = p
			end
		end
		if #hit > 0 then note_change(i18n.get("init.reload_hotstrings"), hit) end
	end
	if not acquire_watcher(hotstrings_dir, hotstrings_changed,
		"Hotstrings directory watcher", false) then
		return rollback_startup()
	end

	-- ONE recursive watcher on the personal root, filtered exactly like the
	-- directory watcher above.
	--
	-- This replaced a recursive walk that armed an hs.pathwatcher per DIRECTORY
	-- and another per .toml FILE, so the number of FSEvents streams grew with the
	-- size of the user's corpus - and every one of them was created synchronously
	-- after the typing eventtap was already armed. All of it was redundant:
	-- hs.pathwatcher is recursive and already reports the individual changed
	-- paths, so the root watcher sees every event its descendants did. The walk's
	-- depth cap and `visited` cycle guard existed only to survive a symlink loop
	-- that no longer has to be walked at all.
	local personal_root = (personal_dir):gsub("[/\\]+$", "")
	local function personal_hotstrings_changed(paths)
		if not lifecycle_active then return end
		local hit = {}
		for _, p in ipairs(paths) do
			-- /tmp is excluded for the same reason the old per-directory callback
			-- excluded it. The self-written and runtime-artefact filters are the
			-- ones the sibling watcher already applies; the per-file watchers had
			-- neither, so a write the driver made itself could trigger a reload.
			if not p:match("^/tmp/")
				and not is_self_written(p) and not is_runtime_artefact(p) then
				hit[#hit + 1] = p
			end
		end
		if #hit > 0 then note_change(i18n.get("init.reload_hotstrings"), hit) end
	end
	if personal_root ~= "" and not acquire_watcher(personal_root, personal_hotstrings_changed,
		"Personal hotstrings watcher", true) then
		return rollback_startup()
	end

	-- HTML/CSS/JS are webview assets loaded at open-time — only .lua changes
	-- drive Hammerspoon runtime behavior and warrant a reload
	Logger.debug(LOG, "Configuring file watchers for auto-reloading…")
	local function project_changed(paths)
		if not lifecycle_active then return end
		local hit = {}
		for _, p in ipairs(paths) do
			-- Ignore temporary files (tokens, etc.); a batch may still carry a real
			-- .lua change alongside them, so skip rather than abandon the batch.
			if not (p:find("^/tmp/") or p:find("hs_hf_token_") or p:find("hs_hf_login_"))
				and not is_runtime_artefact(p) and p:match("%.lua$") then
				hit[#hit + 1] = p
			end
		end
		if #hit > 0 then
			Logger.debug(LOG, "Lua file change detected: %s (+%d more)", hit[1], #hit - 1)
			note_change(i18n.get("init.reload_script"), hit)
		end
	end
	if not acquire_watcher(base_dir, project_changed, "Project source watcher", false) then
		return rollback_startup()
	end



	-- The per-file watchers that used to live here were described as "a safety net
	-- for in-place edits that directory watchers may miss". They were not: the
	-- directory watcher above is recursive and reports the individual changed
	-- paths, so it already saw every in-place edit these duplicated - while ALSO
	-- applying the is_runtime_artefact filter they lacked.
	publish_owner()
	lifecycle_active = true
	for _, admission in ipairs(callback_admissions) do admission.active = true end
	return true
end

return M
