--- infra/legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Linux Legacy Folder Migration
--- DESCRIPTION:
--- Moves, once at boot, the folders the builds before the single folder name
--- kept under each XDG base ($XDG_CONFIG_HOME, $XDG_STATE_HOME and
--- $XDG_DATA_HOME, named by app_dirs migration.linux.legacy_folder) into the
--- `ergopti` folder of the same base, then creates the cache folder the updater
--- writes its ETags to.
---
--- FEATURES & RATIONALE:
--- 1. Before Everything: the daemon runs this before the logger sink opens the
---    logs folder and before the bootstrap storage is read, because both live in
---    folders it moves. Its report is logged once the logger is ready.
--- 2. Shared Rules: what moves and what is refused is _shared/
---    legacy_folder_migration.lua; this module only resolves the folders and
---    owns the native effects (POSIX test, libuv scandir, mkdir, rmdir) and the
---    no-replace rename of infra/no_replace_move.
--- 3. Maintainer Machines Only: no Linux build was published with the old
---    folders; this exists for the maintainer's own installs and goes once they
---    are moved (docs/tooling/one-folder-name-handoff.md).
--- ==============================================================================

local M = {}

local AppDirs = require("core.fs.engine.app_dirs")
local Core = require("settings.engine.migration.legacy_folder_migration_core")
local NativePath = require("core.fs.engine.native_path")
local NoReplaceMove = require("core.fs.engine.no_replace_move")
-- The installer bundles luv; without it a folder is reported as unlistable
-- (so nothing is merged, and no link can be mistaken for a second folder).
local uv_loaded, uv = pcall(require, "luv")
local quote = require("core.text.engine.utils_core").shell_quote

local LOG = "infra.legacy_folder_migration"




-- ================================
-- ================================
-- ======= 1/ Native ports ========
-- ================================
-- ================================

--- Runs a shell command and reports whether it exited with status 0.
--- @param command string
--- @return boolean
local function succeeds(command)
	local result = os.execute(command)
	return result == true or result == 0
end

--- The real file-system ports of the shared core.
--- @return table ports
function M.native_ports()
	return {
		exists = function(path)
			return succeeds("test -e " .. quote(path) .. " || test -L " .. quote(path))
		end,
		-- libuv's scandir returns each name's exact bytes, a newline included,
		-- and an error for a folder it cannot read: a line-split `ls` invented
		-- names for a newline and reported a refused folder as empty.
		list = function(dir)
			if not uv_loaded then return nil, "libuv (luv) is unavailable" end
			local request, open_error = uv.fs_scandir(dir)
			if not request then return nil, tostring(open_error) end
			local names = {}
			while true do
				local name, next_error = uv.fs_scandir_next(request)
				if not name then
					if next_error ~= nil then return nil, tostring(next_error) end
					return names
				end
				names[#names + 1] = name
			end
		end,
		-- os.rename replaces an existing destination, so a file published after
		-- the core's check would be lost; renameat2 RENAME_NOREPLACE never does.
		rename = function(from, to) return NoReplaceMove.move(from, to) end,
		make_dir = function(path) return succeeds("mkdir -p -- " .. quote(path) .. " 2>/dev/null") end,
		remove_empty_dir = function(path) return succeeds("rmdir -- " .. quote(path) .. " 2>/dev/null") end,
		-- stat follows links: a legacy folder linked to the new one has the new
		-- one's device and inode.
		same_object = function(a, b)
			if not uv_loaded then return false end
			local left, right = uv.fs_stat(a), uv.fs_stat(b)
			return type(left) == "table" and type(right) == "table" and left.dev == right.dev and left.ino == right.ino
		end,
	}
end




-- ================================
-- ================================
-- ======= 2/ Plan ================
-- ================================
-- ================================

--- The merge steps of every XDG base that held a legacy folder. An old entry
--- whose destination is taken goes to <base>/ergopti/<backup folder>/<old
--- folder>/, on the volume of that base.
--- @param config_paths table infra/config_paths (or a test double with the same bases).
--- @return table plan
function M.plan(config_paths)
	local legacy = AppDirs.migration.linux.legacy_folder
	local name = AppDirs.linux.folder_name
	local plan = {}
	for _, base in ipairs({ config_paths.config_home(), config_paths.state_home(), config_paths.data_home() }) do
		local root = base .. "/" .. name
		plan[#plan + 1] = { from_dir = base .. "/" .. legacy, to_dir = root,
			backup_dir = root .. "/" .. AppDirs.migration.backup_folder .. "/" .. legacy }
	end
	return plan
end

--- Points the bootstrap folder settings at where their folder moved.
---
--- A configuration or logs folder the user chose inside an old folder moved
--- with it, while storage.json still named the old path. When the setting
--- cannot be stored, the folder moves back to the path it names.
--- @param report table Core report; receives relocated and restored rows.
--- @param storage table|nil adapters.storage (get, set); loaded only after a move.
--- @param ports table Native effects.
local function follow_locators(report, storage, ports)
	report.relocated, report.restored = {}, report.restored or {}
	if #report.moved + #report.backed_up == 0 then return end
	-- Loaded after the moves: its path is the default folder that now holds
	-- the moved storage.json.
	local store = storage or require("core.fs.adapters.storage")
	for _, key in ipairs(require("infra.config_paths").LOCATOR_STORAGE_KEYS) do
		local value = store.get(key, nil)
		local target, entry = nil, nil
		if type(value) == "string" and value:sub(1, 1) == "/" then target, entry = Core.relocated(report, value) end
		if target then
			if store.set(key, target) then
				report.relocated[#report.relocated + 1] = { key = key, from = value, to = target }
			else
				local back, why = ports.rename(entry.to, entry.from)
				if back then
					report.restored[#report.restored + 1] = { from = entry.to, to = entry.from }
				else
					report.kept[#report.kept + 1] = { from = entry.to, to = entry.from, reason = "restore_failed",
						detail = why }
				end
			end
		end
	end
end

--- The custom logs folder named like the old folder: a logs setting whose
--- last name is exactly the old one, or that folder's ergopti subfolder as
--- config_paths stores it. Any other custom folder is not the migration's
--- (decided by the coordinator on 2026-11-11 overnight, to review by the
--- maintainer; the macOS LogsDirPath follows the same rule).
--- @param value any The logs setting.
--- @return string|nil folder The old-named folder, without a trailing slash.
function M.custom_legacy_logs(value)
	if type(value) ~= "string" or value:sub(1, 1) ~= "/" then return nil end
	local folder = value:gsub("/+$", "")
	if NativePath.basename(folder) == AppDirs.linux.folder_name then folder = NativePath.dirname(folder) or "" end
	if NativePath.basename(folder) ~= AppDirs.migration.linux.legacy_folder then return nil end
	if not NativePath.dirname(folder) then return nil end
	return folder
end

--- Renames a custom logs folder named like the old folder: the setting names
--- its parent's ergopti folder first, then the logs the logger wrote into the
--- old folder's ergopti subfolder move there. The user's own entries of the old
--- folder stay. A refused setting moves nothing.
--- @param report table Core report; receives relocated, moved and kept rows.
--- @param store table adapters.storage (get, set).
--- @param ports table Native effects.
local function rename_custom_logs(report, store, ports)
	local key = AppDirs.linux_storage_key
	local value = store.get(key, nil)
	local custom = M.custom_legacy_logs(value)
	if not custom then return end
	local name = AppDirs.linux.folder_name
	local renamed = NativePath.dirname(custom) .. "/" .. name
	if not store.set(key, renamed) then
		report.kept[#report.kept + 1] = { from = custom, to = renamed, reason = "refused" }
		return
	end
	report.relocated[#report.relocated + 1] = { key = key, from = value, to = renamed }
	local step = { from_dir = custom .. "/" .. name, to_dir = renamed,
		backup_dir = renamed .. "/" .. AppDirs.migration.backup_folder .. "/" .. AppDirs.migration.linux.legacy_folder }
	if not ports.exists(step.from_dir) then return end
	local moved = Core.apply({ step }, ports)
	for kind, rows in pairs(moved) do
		for _, row in ipairs(rows) do report[kind][#report[kind] + 1] = row end
	end
end

--- Runs the migration and prepares the cache folder.
--- @param options table|nil { config_paths, ports, storage } test seams; defaults are the real ones.
--- @return table report The shared core report, logged later by log().
function M.run(options)
	options = options or {}
	local config_paths = options.config_paths or require("infra.config_paths")
	local ports = options.ports or M.native_ports()
	local report = Core.apply(M.plan(config_paths), ports)
	follow_locators(report, options.storage, ports)
	rename_custom_logs(report, options.storage or require("core.fs.adapters.storage"), ports)
	-- The updater sends a conditional request only when its cache folder exists
	-- and never creates it from the event loop, so boot creates it here.
	report.cache_ready = ports.make_dir(config_paths.cache())
	return report
end

--- Logs a report through the started logger.
--- @param logger table Logger with info and warn.
--- @param report table Report returned by run().
function M.log(logger, report)
	Core.log_report(logger, LOG, report)
	for _, entry in ipairs(report.relocated or {}) do
		logger.info(LOG, "The bootstrap setting %s now names %s, where %s moved.", entry.key, entry.to, entry.from)
	end
	if report.cache_ready == false then
		logger.warn(LOG, "The cache folder could not be created; update checks will not be conditional.")
	end
end

return M
