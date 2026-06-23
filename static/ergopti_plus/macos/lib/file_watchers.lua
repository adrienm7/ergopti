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

local LOG = "file_watchers"




-- ========================================
--- =======================================
-- ======= 1/ Auto-Reload Watchers =======
--- =======================================
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

	local reload_timer = nil

	local function schedule_reload(msg)
		if reload_timer then reload_timer:stop() end
		reload_timer = hs.timer.doAfter(0.5, function()
			ui_restore.defer_reload(function()
				-- snapshot() is a safety net for any UI still open at reload time;
				-- under normal deferral they are already closed so it saves nothing
				ui_restore.snapshot()
				pcall(notifications.notify, i18n.get("init.reload_title"), msg or i18n.get("init.reload_files"), "info")
				hs.reload()
			end)
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

	local function watch_personal_hotstrings_dir(dir)
		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

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
						watch_personal_hotstrings_dir(path)
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
