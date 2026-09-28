--- infra/log_folders.lua

--- ==============================================================================
--- MODULE: Log Folders
--- DESCRIPTION:
--- The one formula of the macOS default logs folder, ~/Library/Logs/ergopti_plus/,
--- built on the generated application-folders data. Pure and dependency-free:
--- the logger (early-boot fallback) and the paths.toml resolver both need it,
--- and the logger is loaded before anything else can be.
--- ==============================================================================

local M = {}
local AppDirs = require("app_dirs")

--- The OS-default logs folder of a home folder.
--- @param home string|nil Absolute home folder.
--- @return string|nil folder With a trailing slash, or nil without a home.
function M.default_logs_dir(home)
	if type(home) ~= "string" or home == "" then return nil end
	return (home:gsub("/+$", "")) .. "/" .. AppDirs.macos.relative .. "/"
end

--- The folder used when there is no home folder at all, so no user-private
--- location exists to prefer.
--- @return string folder With a trailing slash.
function M.homeless_logs_dir()
	return "/tmp/" .. AppDirs.folder_name .. "/"
end

return M
