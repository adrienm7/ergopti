--- adapters/keyboard_layout_files.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Build Files
--- DESCRIPTION:
--- Writes and removes the number-row layout builds in ~/Library/Keyboard Layouts
--- (modules/keymap/layout_rows_build.lua). The file system adapter's atomic
--- write keeps a cooperative lock file beside its target, which would stay in
--- the user's layouts folder after every build and every field run.
---
--- FEATURES & RATIONALE:
--- 1. A build is always a new file under a new name, and the system reads it only
---    once the build is registered, after this write returned: a plain create is
---    safe, and an existing path is refused rather than overwritten.
--- 2. Only a regular file is removed; anything else at the path is left and named.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local FileSystem = require("adapters.file_system")

local LOG = "adapters.keyboard_layout_files"

--- Creates a new build file.
--- @param path string Absolute path ending in .keylayout.
--- @param text string The file's content.
--- @return boolean written
--- @return string|nil err
function M.write_new(path, text)
	if type(path) ~= "string" or not path:match("^/.+%.keylayout$") or type(text) ~= "string" then
		return false, "a build is an absolute .keylayout path and its text"
	end
	if FileSystem.exists(path) then return false, path .. " already exists" end
	local handle, open_err = io.open(path, "wb")
	if not handle then return false, tostring(open_err) end
	local wrote = handle:write(text) ~= nil
	local closed = handle:close() == true
	if not (wrote and closed) then
		os.remove(path)
		return false, "the build could not be written in full"
	end
	return true, nil
end

--- Removes a build file; an absent one is already removed.
--- @param path string
--- @return boolean removed
--- @return string|nil err
function M.remove(path)
	local status, mode = FileSystem.followed_mode(path)
	if status == "absent" or (status == "error" and not FileSystem.exists(path)) then return true, nil end
	if status ~= "present" or mode ~= "file" then
		Logger.warn(LOG, "'%s' is not a regular file (%s); left in place.", tostring(path), tostring(mode or status))
		return false, "not a regular file"
	end
	local removed, remove_err = os.remove(path)
	if not removed then return false, tostring(remove_err) end
	return true, nil
end

return M
