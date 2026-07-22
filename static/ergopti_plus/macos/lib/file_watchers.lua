--- lib/file_watchers.lua

--- ==============================================================================
--- MODULE: Auto-Reload File Watchers
--- DESCRIPTION:
--- Boot-time hs.pathwatcher setup that reloads Hammerspoon when the user edits a
--- hotstring TOML (in the shared dir, the personal dir tree, or in place) or any
--- project .lua file. Extracted verbatim from init.lua Section 7 so the boot
--- orchestrator stays thin; behaviour is unchanged.
---
--- FEATURES & RATIONALE:
--- 1. GC-rooting: every watcher is pinned in the _G.script_watchers global so the
---    collector cannot destroy it mid-session; init.lua's shutdown callback stops
---    them by walking that same global, so the contract is preserved.
--- 2. Debounced reload: rapid successive saves collapse into a single reload via a
---    0.5 s timer, and the reload is deferred through ui_restore so open UI is
---    snapshotted/closed first.
--- 3. Reentrant personal-dir scan: watch_personal_hotstrings_dir recurses into
---    sub-folders and arms a per-file watcher for each .toml so in-place edits a
---    directory watcher might miss still trigger a reload.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("lib.logger")
local i18n          = require("lib.i18n")
local notifications = require("lib.notifications")
local ui_restore    = require("lib.ui_restore")
local fs_dir        = require("lib.fs_dir")
local git_status    = require("lib.git_status")

local LOG = "file_watchers"

-- Hard cap on how deep the recursive personal-hotstrings watcher scan descends.
-- Same rationale as lib/personal_hotstrings.lua's SCAN_MAX_DEPTH: the scanned
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

-- Max consecutive re-polls (each one 0.5 s debounce tick) with the git lock held
-- but NO new file activity, before the guard is bypassed. A real pull keeps
-- writing, which resets the counter (see schedule_reload), so this can only trip
-- on a STALE index.lock left by a crashed git — never on a genuine pull, however
-- long. Capped so such a stale lock cannot postpone auto-reload forever.
-- The debounce interval itself stays the bare literal 0.5 in hs.timer.doAfter
-- below — a cross-driver single-source gate pins it to Linux's _debounce_sec
-- (tools/test/test-file-watchers-constants-single-source.cjs).
local GIT_SETTLE_MAX_DEFERRALS = 120   -- 120 * 0.5s = 60s of a quiet-but-locked repo





-- ========================================
-- =======================================
-- ======= 1/ Auto-Reload Watchers =======
-- =======================================
-- ========================================

--- Arms every auto-reload watcher. Pins them in _G.script_watchers (the GC root
--- init.lua's shutdown callback stops on quit).
--- @param ctx table { hotstrings_dir: string, base_dir: string,
---   personal_hotstrings_dir: string } — absolute paths resolved by the boot script.
function M.start(ctx)
	local hotstrings_dir = ctx.hotstrings_dir
	local base_dir       = ctx.base_dir
	local personal_dir   = ctx.personal_hotstrings_dir or ""

	-- Global table pins the watchers so the GC cannot destroy them mid-session.
	_G.script_watchers = _G.script_watchers or {}

	-- Drop FSEvents replays delivered during the post-boot suppress window (see
	-- BOOT_SUPPRESS_SEC). Captured now because M.start runs at the tail of boot,
	-- right where the freshly-armed watchers would otherwise catch the previous
	-- session's buffered events.
	local suppress_until = hs.timer.secondsSinceEpoch() + BOOT_SUPPRESS_SEC

	local reload_timer    = nil
	-- Consecutive git-settle re-polls with the lock held but no new file activity;
	-- reset to 0 by any real file event (schedule_reload) and by a fired reload,
	-- capped by GIT_SETTLE_MAX_DEFERRALS so only a stale lock can wedge it.
	local git_defer_count = 0

	-- ``fire_reload`` is forward-declared so the debounce timer closure can call it
	-- while ``fire_reload`` itself re-arms through ``arm_timer``. The Lua
	-- local-after-closure trap: a closure only captures a local declared ABOVE it,
	-- so both names must exist before either body runs.
	local fire_reload

	local function arm_timer(msg)
		if reload_timer then reload_timer:stop() end
		-- Bare literal 0.5: a cross-driver single-source gate pins this debounce
		-- to Linux's _debounce_sec (do not replace it with a named constant).
		reload_timer = hs.timer.doAfter(0.5, function() fire_reload(msg) end)
	end

	local function schedule_reload(msg)
		-- Ignore the FSEvents batch macOS replays right after an hs.reload(): during
		-- the boot window these are the previous session's changes, not a new edit.
		if hs.timer.secondsSinceEpoch() < suppress_until then return end
		-- A genuine file event resets the git-settle counter, so a long-running pull
		-- that keeps writing never trips the stale-lock cap — only a lock held with
		-- NO further activity climbs toward it.
		git_defer_count = 0
		arm_timer(msg)
	end

	fire_reload = function(msg)
		-- Never reload while git is still rewriting the driver's own working tree.
		-- A `git pull` run against a live driver rewrites init.lua and dozens of
		-- required modules; firing hs.reload() mid-pull boots against a
		-- half-updated, internally inconsistent tree, which errors during boot and
		-- leaves Hammerspoon with no config AND no watchers armed — a dead,
		-- must-relaunch state. Re-poll each 0.5 s debounce tick until git settles,
		-- capped so a stale index.lock can never postpone the reload forever
		-- (macos-reload-during-git-pull).
		if git_defer_count < GIT_SETTLE_MAX_DEFERRALS and git_status.operation_in_progress(base_dir) then
			git_defer_count = git_defer_count + 1
			Logger.debug(LOG, "Reload held — git operation in progress on '%s' (%d/%d).",
				base_dir, git_defer_count, GIT_SETTLE_MAX_DEFERRALS)
			arm_timer(msg)
			return
		end
		git_defer_count = 0
		ui_restore.defer_reload(function()
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
	local dir_watcher = hs.pathwatcher.new(hotstrings_dir, function(paths)
		for _, p in ipairs(paths) do
			if p:match("%.toml$") or p:match("_index%.json$") or p:match("%.local_ahk_path$") then
				schedule_reload(i18n.get("init.reload_hotstrings"))
				return
			end
		end
	end)
	dir_watcher:start()
	table.insert(_G.script_watchers, dir_watcher)

	-- ``visited`` is a set of canonical (lowercased, trailing-slash-stripped)
	-- absolute directory paths already entered; combined with the depth cap
	-- below it guarantees the walk terminates even on a self-referential
	-- symlink cycle in the user's folder (F-LOW-4 — same guard as
	-- lib/personal_hotstrings.lua's scan_recursive).
	local visited = {}
	local function watch_personal_hotstrings_dir(dir, depth)
		depth = depth or 1
		if depth > SCAN_MAX_DEPTH then
			Logger.warn(LOG, "Personal hotstrings watcher scan hit max depth %d at '%s' — not descending further (directory cycle?).",
				SCAN_MAX_DEPTH, dir)
			return
		end

		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local canonical = dir:gsub("[/\\]+$", ""):lower()
		if visited[canonical] then
			Logger.warn(LOG, "Personal hotstrings watcher scan revisited '%s' — skipping to break a directory cycle.", dir)
			return
		end
		visited[canonical] = true

		local w = hs.pathwatcher.new(dir, function(paths)
			for _, p in ipairs(paths) do
				if not p:match("^/tmp/") then
					schedule_reload(i18n.get("init.reload_hotstrings"))
					return
				end
			end
		end)
		w:start()
		table.insert(_G.script_watchers, w)

		for _, fname in ipairs(fs_dir.entries(dir)) do
			if fname ~= "." and fname ~= ".." then
				local path = dir .. "/" .. fname
				local ok_a, a = pcall(hs.fs.attributes, path)
				if ok_a and type(a) == "table" then
					if a.mode == "directory" then
						watch_personal_hotstrings_dir(path, depth + 1)
					elseif a.mode == "file" and fname:match("%.toml$") then
						local fw = hs.pathwatcher.new(path, function()
							schedule_reload(i18n.get("init.reload_hotstrings"))
						end)
						fw:start()
						table.insert(_G.script_watchers, fw)
					end
				end
			end
		end
	end

	watch_personal_hotstrings_dir((personal_dir):gsub("[/\\]+$", ""))

	-- HTML/CSS/JS are webview assets loaded at open-time — only .lua changes
	-- drive Hammerspoon runtime behavior and warrant a reload
	Logger.debug(LOG, "Configuring file watchers for auto-reloading…")
	local project_watcher = hs.pathwatcher.new(base_dir, function(paths)
		for _, p in ipairs(paths) do
			-- Ignore temporary files (tokens, etc.)
			if p:find("^/tmp/") or p:find("hs_hf_token_") or p:find("hs_hf_login_") then
				return
			end
			if p:match("%.lua$") then
				Logger.debug(LOG, "Lua file change detected: %s", p)
				schedule_reload(i18n.get("init.reload_script"))
				return
			end
		end
	end)
	project_watcher:start()
	table.insert(_G.script_watchers, project_watcher)



	-- ==================================
	-- ===== 1.2) Per-File Watchers =====
	-- ==================================

	-- Safety net for in-place edits that directory watchers may miss
	for _, fname in ipairs(fs_dir.entries(hotstrings_dir)) do
		if fname:match("%.toml$") or fname:match("_index%.json$") then
			local w = hs.pathwatcher.new(hotstrings_dir .. fname, function()
				schedule_reload(i18n.get("init.reload_hotstrings"))
			end)
			w:start()
			table.insert(_G.script_watchers, w)
		end
	end
end

return M
