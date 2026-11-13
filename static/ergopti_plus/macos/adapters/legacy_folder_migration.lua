--- adapters/legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: macOS Legacy Folder Migration
--- DESCRIPTION:
--- Moves, once at boot, what the builds before the single folder name kept
--- outside the Ergopti folders: paths.toml and the downloaded remap runtime of
--- the old support folder, the old default configuration folder (now
--- Ergopti/config), and every entry of the old logs, cache and reload control
--- folders. An entry whose destination is taken goes to the backup folder of
--- the support root. A paths.toml that named an old default folder is
--- rewritten to the new one, after a backup of its previous text. The old names
--- are those of app_dirs `migration.macos`.
---
--- FEATURES & RATIONALE:
--- 1. Before paths.toml: init.lua runs this before infra/config_paths reads
---    paths.toml (the launcher already exports the new path), so the first read
---    finds the moved file and the new configuration folder.
--- 2. Shared Rules: what moves and what is refused is _shared/
---    legacy_folder_migration.lua; this adapter resolves the folders from
---    app_dirs and owns the native effects (hs.fs and os.rename), none of
---    which replaces an existing destination.
--- 3. What Stays: the owned Karabiner runtime's folders keep their compiled name
---    (app_dirs owned_runtime), and the runtime state of the old support folder
---    (locks, the lease guardian, the PTY sources) stays for a build that may
---    still run until the next login.
--- 4. Maintainer Machines Only: no build was published with the old folders;
---    this goes once the maintainer's machines are moved.
--- ==============================================================================

local M = {}

local AppDirs = require("core.fs.engine.app_dirs")
local Core = require("settings.engine.migration.legacy_folder_migration_core")
local NativePath = require("core.fs.engine.native_path")

local LOG = "legacy_folder_migration"




-- ================================
-- ================================
-- ======= 1/ Native ports ========
-- ================================
-- ================================

--- The real file-system ports of the shared core.
--- @return table ports
function M.native_ports()
	local fs = hs.fs
	local function exists(path) return fs.symlinkAttributes(path, "mode") ~= nil end
	return {
		exists = exists,
		-- fs.dir raises on a folder it cannot open (no permission, gone after the
		-- stat): the refusal is returned to the core, which reports it, instead
		-- of escaping the migration and aborting init.lua.
		list = function(dir)
			if fs.attributes(dir, "mode") ~= "directory" then return nil, "not a folder" end
			local names = {}
			local listed, list_error = pcall(function()
				for name in fs.dir(dir) do
					if name ~= "." and name ~= ".." then names[#names + 1] = name end
				end
			end)
			if not listed then return nil, tostring(list_error) end
			return names
		end,
		-- os.rename replaces an existing destination file or empty folder, so a
		-- name published after the core's check would be lost. A folder first
		-- reserves its destination with mkdir, which fails on any existing name,
		-- and rename over that empty reservation fails once anything arrives in
		-- it. Anything else is hard linked, which never replaces, then unlinked.
		rename = function(from, to)
			if fs.symlinkAttributes(from, "mode") == "directory" then
				local reserved, reserve_err = fs.mkdir(to)
				if not reserved then return nil, tostring(reserve_err or "destination exists") end
				local moved, move_err = os.rename(from, to)
				if not moved then
					fs.rmdir(to)
					return nil, move_err
				end
				return true
			end
			local linked, link_err = fs.link(from, to, false)
			if linked ~= true then return nil, tostring(link_err or "hard link refused") end
			local removed, remove_err = os.remove(from)
			if not removed then
				os.remove(to)
				return nil, remove_err
			end
			return true
		end,
		make_dir = function(path)
			local current = ""
			for part in path:gmatch("[^/]+") do
				current = current .. "/" .. part
				local mode = fs.attributes(current, "mode")
				if mode == nil then
					if not fs.mkdir(current) then return false end
				elseif mode ~= "directory" then
					return false
				end
			end
			return true
		end,
		remove_empty_dir = function(path) return fs.rmdir(path) == true end,
		-- fs.attributes follows links: a legacy folder linked to the new one has
		-- the new one's device and inode.
		same_object = function(a, b)
			local left, right = fs.attributes(a), fs.attributes(b)
			return type(left) == "table" and type(right) == "table" and left.dev == right.dev and left.ino == right.ino
		end,
		read = function(path)
			local file = io.open(path, "rb")
			if not file then return nil end
			local text = file:read("*a")
			file:close()
			return text
		end,
		-- Only the core's private stage files are written; they reach their
		-- final name through rename or replace.
		write = function(path, text)
			local file = io.open(path, "wb")
			if not file then return false end
			local written = file:write(text) ~= nil
			return file:close() and written
		end,
		replace = function(from, to) return os.rename(from, to) == true end,
		remove = function(path) return os.remove(path) == true end,
	}
end




-- ================================
-- ================================
-- ======= 2/ Plan ================
-- ================================
-- ================================

--- The moves of one home folder. An old entry whose destination is taken goes
--- to <support>/<backup folder>/<its path below the home folder>.
--- @param home string Absolute home folder, without a trailing slash.
--- @return table plan
--- @return string support The new support root.
function M.plan(home)
	local legacy = AppDirs.migration.macos
	local support = home .. "/" .. AppDirs.macos.support_relative
	local backup = support .. "/" .. AppDirs.migration.backup_folder
	local function merge(old_relative, new_relative, entries)
		return { from_dir = home .. "/" .. old_relative, to_dir = home .. "/" .. new_relative,
			backup_dir = backup .. "/" .. old_relative, entries = entries }
	end
	local plan = {
		merge(legacy.legacy_support_relative, AppDirs.macos.support_relative, legacy.moved_support_entries),
		{ from = home .. "/" .. legacy.legacy_config_relative, to = home .. "/" .. AppDirs.config.macos_relative,
			backup = backup .. "/" .. legacy.legacy_config_relative },
		merge(legacy.legacy_logs_relative, AppDirs.macos.relative),
		merge(legacy.legacy_cache_relative, AppDirs.macos.cache_relative),
		merge(legacy.legacy_control_relative, AppDirs.macos.support_relative),
	}
	return plan, support
end

--- The old application folder name, the last name of the old logs default.
local function legacy_logs_name()
	return NativePath.basename(AppDirs.migration.macos.legacy_logs_relative)
end

--- The custom logs folder paths.toml names in place of the old folder name:
--- a LogsDirPath whose last name is exactly the old default's, or that
--- folder's Ergopti subfolder as config_paths saves it (any parent but the old
--- default itself), absolute or home-relative. Any other custom folder is not
--- the migration's (decided by the coordinator on 2026-11-11 overnight, to
--- review by the maintainer).
--- @param home string Absolute home folder, without a trailing slash.
--- @param value string|nil The LogsDirPath value.
--- @return string|nil folder The old-named folder, absolute, without a trailing slash.
function M.custom_legacy_logs(home, value)
	if type(value) ~= "string" then return nil end
	local folder = value:gsub("/+$", "")
	if folder:sub(1, 2) == "~/" then folder = home .. folder:sub(2) end
	if NativePath.basename(folder) == AppDirs.macos.folder_name then folder = NativePath.dirname(folder) or "" end
	if folder:sub(1, 1) ~= "/" or NativePath.basename(folder) ~= legacy_logs_name() then return nil end
	if folder == home .. "/" .. AppDirs.migration.macos.legacy_logs_relative then return nil end
	return folder
end

--- The merge of a custom old-named logs folder: the logger wrote into its
--- application-named subfolder (a folder not named after the application gets
--- one), whose entries move to the renamed folder, which is named after it.
--- Entries of the custom folder itself are the user's and stay.
--- @param home string Absolute home folder, without a trailing slash.
--- @param custom string Folder from custom_legacy_logs.
--- @return table step Merge step of the shared core.
function M.custom_logs_step(home, custom)
	local name = AppDirs.macos.folder_name
	local renamed = NativePath.dirname(custom) .. "/" .. name
	return { from_dir = custom .. "/" .. name, to_dir = renamed,
		backup_dir = home .. "/" .. AppDirs.macos.support_relative .. "/" .. AppDirs.migration.backup_folder
			.. "/custom-logs" .. custom .. "/" .. name }
end

--- The paths.toml rewrites of one home folder: each key's old default, in its
--- absolute and its home-relative spelling, becomes the new default, and a
--- custom logs folder named like the old default becomes its parent's folder
--- named after the application.
--- @param home string Absolute home folder, without a trailing slash.
--- @param custom string|nil Folder from custom_legacy_logs, when paths.toml names one.
--- @return table rewrites
function M.rewrites(home, custom)
	local legacy = AppDirs.migration.macos
	-- The configuration folder moves in one rename, so a locator that cannot
	-- follow it gets it back; the logs folder merges entry by entry and only
	-- follows.
	return {
		{ key = AppDirs.config.override_key,
			old = { home .. "/" .. legacy.legacy_config_relative, "~/" .. legacy.legacy_config_relative },
			new = home .. "/" .. AppDirs.config.macos_relative,
			source = home .. "/" .. legacy.legacy_config_relative, restorable = true },
		{ key = AppDirs.override_key,
			old = { home .. "/" .. legacy.legacy_logs_relative, "~/" .. legacy.legacy_logs_relative },
			new = home .. "/" .. AppDirs.macos.relative,
			source = home .. "/" .. legacy.legacy_logs_relative },
		custom and { key = AppDirs.override_key, old = {},
			renamed = { from = legacy_logs_name(), to = AppDirs.macos.folder_name },
			source = M.custom_logs_step(home, custom).from_dir } or nil,
	}
end

--- Runs the migration of the current user and logs its report.
--- @param logger table Logger with info and warn.
--- @param options table|nil { home, ports } test seams; defaults are the real ones.
--- @return table|nil report Nil without an absolute home folder.
function M.run(logger, options)
	options = options or {}
	local home = options.home or os.getenv(AppDirs.macos.base_env)
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" then return nil end
	home = home:gsub("/+$", "")
	local ports = options.ports or M.native_ports()
	local plan = M.plan(home)
	local report = Core.apply(plan, ports)
	local paths_file = home .. "/" .. AppDirs.config.macos_paths_file
	local text = ports.exists(paths_file) and ports.read(paths_file) or nil
	local custom = type(text) == "string" and M.custom_legacy_logs(home, Core.paths_value(text, AppDirs.override_key))
		or nil
	if custom then
		local custom_report = Core.apply({ M.custom_logs_step(home, custom) }, ports)
		for kind, rows in pairs(custom_report) do
			for _, row in ipairs(rows) do report[kind][#report[kind] + 1] = row end
		end
	end
	Core.publish_paths_file(paths_file, M.rewrites(home, custom), AppDirs.migration.backup_suffix, report, ports)
	Core.log_report(logger, LOG, report)
	return report
end

return M
