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
local reload_gate   = require("reload_gate")

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

-- Max consecutive hold re-polls (each one 0.5 s tick) with NO new file activity,
-- before the hold is bypassed. Real activity resets the counter (see note_change),
-- so a genuine bulk write never trips it — only a quiet-but-stuck state (a STALE
-- index.lock left by a crashed git) climbs toward it. Capped so such a stale lock
-- cannot postpone auto-reload forever.
-- The poll interval itself stays the bare literal 0.5 in hs.timer.doAfter below —
-- a cross-driver single-source gate pins it to Linux's _debounce_sec
-- (tools/test/test-file-watchers-constants-single-source.cjs).
local GIT_SETTLE_MAX_DEFERRALS = 120   -- 120 * 0.5s = 60s of a quiet-but-stuck repo





-- ========================================
-- =======================================
-- ======= 1/ Auto-Reload Watchers =======
-- =======================================
-- ========================================

--- Normalises a path for comparison: lowercased, backslashes folded to slashes.
--- @param p string|nil
--- @return string
local function canonical_path(p)
	if type(p) ~= "string" then return "" end
	return p:gsub("\\", "/"):lower()
end

--- Arms every auto-reload watcher. Pins them in _G.script_watchers (the GC root
--- init.lua's shutdown callback stops on quit).
--- @param ctx table { hotstrings_dir: string, base_dir: string,
---   personal_hotstrings_dir: string, self_written_files: string[] } — absolute
---   paths resolved by the boot script.
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

	-- Global table pins the watchers so the GC cannot destroy them mid-session.
	_G.script_watchers = _G.script_watchers or {}

	-- Drop FSEvents replays delivered during the post-boot suppress window (see
	-- BOOT_SUPPRESS_SEC). Captured now because M.start runs at the tail of boot,
	-- right where the freshly-armed watchers would otherwise catch the previous
	-- session's buffered events.
	local suppress_until = hs.timer.secondsSinceEpoch() + BOOT_SUPPRESS_SEC

	local reload_timer = nil
	-- Consecutive hold re-polls with NO new file activity; reset to 0 by any real
	-- file event (note_change) and by a fired reload, capped by
	-- GIT_SETTLE_MAX_DEFERRALS so only a genuinely stuck state (a stale index.lock,
	-- or an unending write stream) can ever bypass the hold.
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
		if reload_timer then reload_timer:stop() end
		-- Bare literal 0.5: a cross-driver single-source gate pins this poll tick
		-- to Linux's _debounce_sec (do not replace it with a named constant).
		reload_timer = hs.timer.doAfter(0.5, function() fire_reload(msg) end)
	end

	--- Records a batch of changed paths and (re)arms the settle poll.
	--- @param msg string Notification message for the eventual reload.
	--- @param changed table|nil Absolute paths that changed in this event.
	local function note_change(msg, changed)
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
		-- Hold the reload while the working tree is still being written FROM ANY
		-- SOURCE, so hs.reload() never re-execs init.lua against a half-updated,
		-- internally inconsistent tree (which errors during boot and, via repeated
		-- reloads, cascades into the keyboard-freezing storm). Two signals:
		--   1. Quiescence — a bulk write (git pull, cloud sync, rsync, mass save)
		--      shows up as many distinct files; hold until BULK_SETTLE_SEC of quiet.
		--   2. Git — a git operation holds .git/index.lock for the whole update, so
		--      it is deferred exactly even if its file events pause partway through.
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
			arm_timer(msg)
			return
		end
		-- Tree is settled and consistent: clear the burst and reload.
		burst_paths, burst_count, defer_count = {}, 0, 0
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
		local hit = {}
		for _, p in ipairs(paths) do
			if (p:match("%.toml$") or p:match("_index%.json$") or p:match("%.local_ahk_path$"))
				and not is_self_written(p) then
				hit[#hit + 1] = p
			end
		end
		if #hit > 0 then note_change(i18n.get("init.reload_hotstrings"), hit) end
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
			local hit = {}
			for _, p in ipairs(paths) do
				if not p:match("^/tmp/") then hit[#hit + 1] = p end
			end
			if #hit > 0 then note_change(i18n.get("init.reload_hotstrings"), hit) end
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
						local fw = hs.pathwatcher.new(path, function(paths)
							note_change(i18n.get("init.reload_hotstrings"), paths)
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
		local hit = {}
		for _, p in ipairs(paths) do
			-- Ignore temporary files (tokens, etc.); a batch may still carry a real
			-- .lua change alongside them, so skip rather than abandon the batch.
			if not (p:find("^/tmp/") or p:find("hs_hf_token_") or p:find("hs_hf_login_")) and p:match("%.lua$") then
				hit[#hit + 1] = p
			end
		end
		if #hit > 0 then
			Logger.debug(LOG, "Lua file change detected: %s (+%d more)", hit[1], #hit - 1)
			note_change(i18n.get("init.reload_script"), hit)
		end
	end)
	project_watcher:start()
	table.insert(_G.script_watchers, project_watcher)



	-- ==================================
	-- ===== 1.2) Per-File Watchers =====
	-- ==================================

	-- Safety net for in-place edits that directory watchers may miss
	for _, fname in ipairs(fs_dir.entries(hotstrings_dir)) do
		if (fname:match("%.toml$") or fname:match("_index%.json$"))
			and not is_self_written(hotstrings_dir .. fname) then
			local w = hs.pathwatcher.new(hotstrings_dir .. fname, function(paths)
				note_change(i18n.get("init.reload_hotstrings"), paths)
			end)
			w:start()
			table.insert(_G.script_watchers, w)
		end
	end
end

return M
