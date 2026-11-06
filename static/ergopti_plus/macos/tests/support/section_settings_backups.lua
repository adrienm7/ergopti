--- tests/support/section_settings_backups.lua

--- ==============================================================================
--- MODULE: Section Settings Backup Cleanup
--- DESCRIPTION:
--- Removes the durable native-cell backups a changed section batch leaves
--- beside config.toml, so scratch folders can still prove they hold nothing else.
--- ==============================================================================

local lfs = require("lfs")
local M = {}

--- Splits a config path into its folder and the exact backup name prefix.
--- @param config_path string
--- @return string folder
--- @return string prefix
local function backup_prefix(config_path)
	assert(type(config_path) == "string" and config_path ~= "", "config path required")
	local folder, name = config_path:match("^(.*)/([^/]+)$")
	assert(folder and name, "config path must name a file inside a folder")
	return folder, name .. ".section-settings-"
end

--- Tells whether a name has the exact backup spelling after its prefix.
local function backup_suffix(suffix)
	return suffix:match("^%d+%-%d+$") ~= nil
end

--- Tells whether a path is a section settings backup of one config.toml.
--- Fixtures use it to keep these backups apart from the publications they count.
--- @param config_path string The config.toml path the registry was given.
--- @param path string Any path a file adapter was asked to write.
--- @return boolean
function M.is_beside(config_path, path)
	local folder, prefix = backup_prefix(config_path)
	local head = folder .. "/" .. prefix
	return type(path) == "string" and path:sub(1, #head) == head and backup_suffix(path:sub(#head + 1))
end

--- Removes every section settings backup written beside one config.toml.
--- The registry keeps these files on purpose: a pathname cannot prove that the
--- bytes still belong to it. Only the exact backup spelling is removed, so any
--- other residue still fails the caller's empty-folder check.
--- @param config_path string The config.toml path the registry was given.
--- @return integer removed Number of backups removed.
function M.remove_beside(config_path)
	local folder, prefix = backup_prefix(config_path)
	if lfs.attributes(folder, "mode") ~= "directory" then return 0 end
	local removed = 0
	for entry in lfs.dir(folder) do
		if entry:sub(1, #prefix) == prefix and backup_suffix(entry:sub(#prefix + 1)) then
			assert(os.remove(folder .. "/" .. entry))
			removed = removed + 1
		end
	end
	return removed
end

return M
