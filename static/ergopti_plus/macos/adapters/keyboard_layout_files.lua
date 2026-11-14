--- adapters/keyboard_layout_files.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Build Files
--- DESCRIPTION:
--- Writes and removes the number-row layout builds in ~/Library/Keyboard Layouts
--- (modules/keymap/layout_rows_build.lua). Create-only publication uses the
--- file system adapter's lock outside the user's layouts folder.
---
--- FEATURES & RATIONALE:
--- 1. A build is always a new file under a new name, and the system reads it only
---    once the build is registered, after this write returned. Create-only
---    publication refuses occupied paths, including dangling symbolic links.
--- 2. Only a regular file is removed; anything else at the path is left and named.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local FileSystem = require("core.fs.adapters.file_system")

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
	local created, status, detail = FileSystem.create_if_absent(path, text)
	if created == true then return true, nil end
	if status == "exists" then return false, path .. " already exists" end
	return false, tostring(detail or "the build could not be created")
end

--- Removes a build file; an absent one is already removed.
--- @param path string
--- @return boolean removed
--- @return string|nil err
function M.remove(path)
	local attributes, status, detail = FileSystem.classify_no_follow(path)
	if status == "absent" then return true, nil end
	if status ~= "ok" or not attributes or attributes.mode ~= "file" then
		Logger.warn(LOG, "'%s' is not a regular file (%s); left in place.", tostring(path), tostring(detail or (attributes and attributes.mode) or status))
		return false, "not a regular file"
	end
	local removed, remove_err = os.remove(path)
	if not removed then return false, tostring(remove_err) end
	return true, nil
end

return M
