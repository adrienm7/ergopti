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
--- 2. Shared Rules: what moves and what is refused is _shared/lua/
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

local AppDirs = require("app_dirs")
local Core = require("legacy_folder_migration")

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
		read = function(path)
			local file = io.open(path, "rb")
			if not file then return nil end
			local text = file:read("*a")
			file:close()
			return text
		end,
		write = function(path, text)
			local file = io.open(path, "wb")
			if not file then return false end
			local written = file:write(text) ~= nil
			return file:close() and written
		end,
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

--- The paths.toml rewrites of one home folder: each key's old default, in its
--- absolute and its home-relative spelling, becomes the new default.
--- @param home string Absolute home folder, without a trailing slash.
--- @return table rewrites
function M.rewrites(home)
	local legacy = AppDirs.migration.macos
	return {
		{ key = AppDirs.config.override_key,
			old = { home .. "/" .. legacy.legacy_config_relative, "~/" .. legacy.legacy_config_relative },
			new = home .. "/" .. AppDirs.config.macos_relative },
		{ key = AppDirs.override_key,
			old = { home .. "/" .. legacy.legacy_logs_relative, "~/" .. legacy.legacy_logs_relative },
			new = home .. "/" .. AppDirs.macos.relative },
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
	report.paths_file = Core.rewrite_paths_file(home .. "/" .. AppDirs.config.macos_paths_file, M.rewrites(home),
		AppDirs.migration.backup_suffix, ports)
	Core.log_report(logger, LOG, report)
	return report
end

return M
