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
--- 2. Shared Rules: what moves and what is refused is _shared/lua/
---    legacy_folder_migration.lua; this module only resolves the folders and
---    owns the shell effects (POSIX test, ls, mkdir, rmdir) and the no-replace
---    rename of infra/no_replace_move.
--- 3. Maintainer Machines Only: no Linux build was published with the old
---    folders; this exists for the maintainer's own installs and goes once they
---    are moved (docs/tooling/one-folder-name-handoff.md).
--- ==============================================================================

local M = {}

local AppDirs = require("app_dirs")
local Core = require("legacy_folder_migration")
local NoReplaceMove = require("infra.no_replace_move")
local quote = require("text_utils").shell_quote

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
		list = function(dir)
			local pipe = io.popen("ls -A -- " .. quote(dir) .. " 2>/dev/null")
			if not pipe then return nil end
			local names = {}
			for line in pipe:lines() do
				if line ~= "" then names[#names + 1] = line end
			end
			pipe:close()
			return names
		end,
		-- os.rename replaces an existing destination, so a file published after
		-- the core's check would be lost; renameat2 RENAME_NOREPLACE never does.
		rename = function(from, to) return NoReplaceMove.move(from, to) end,
		make_dir = function(path) return succeeds("mkdir -p -- " .. quote(path) .. " 2>/dev/null") end,
		remove_empty_dir = function(path) return succeeds("rmdir -- " .. quote(path) .. " 2>/dev/null") end,
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

--- Runs the migration and prepares the cache folder.
--- @param options table|nil { config_paths, ports } test seams; defaults are the real ones.
--- @return table report The shared core report, logged later by log().
function M.run(options)
	options = options or {}
	local config_paths = options.config_paths or require("infra.config_paths")
	local ports = options.ports or M.native_ports()
	local report = Core.apply(M.plan(config_paths), ports)
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
	if report.cache_ready == false then
		logger.warn(LOG, "The cache folder could not be created; update checks will not be conditional.")
	end
end

return M
