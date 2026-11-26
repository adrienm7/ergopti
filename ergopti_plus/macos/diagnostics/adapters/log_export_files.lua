--- diagnostics/adapters/log_export_files.lua

--- ==============================================================================
--- MODULE: Log Export Files (macOS)
--- DESCRIPTION:
--- The file system half of « Export the logs (zip) »: list the regular files of
--- a folder, read one, find the folder the archive goes to and write it there
--- atomically. diagnostics/ui/log_export.lua owns the decisions and receives
--- these as replaceable effects.
---
--- FEATURES & RATIONALE:
--- 1. lstat only: a link in a logs folder is never followed, listed or read.
--- 2. Atomic publication: the archive is written beside its final name and
---    renamed into place, so a refused write never leaves a partial zip in the
---    Downloads folder; the partial file is removed on every failure path.
--- ==============================================================================

local M = {}

local hs = hs

--- Lists the regular files directly in a folder.
--- @param dir string Absolute folder, with or without a trailing slash.
--- @return table|nil names Regular file names; an empty list for an absent folder.
--- @return string|nil error_message Why a present folder could not be listed.
function M.list_regular_files(dir)
	local folder = (dir:gsub("/+$", "")) .. "/"
	local inspected, attributes = pcall(hs.fs.symlinkAttributes, folder:sub(1, -2))
	if not inspected or type(attributes) ~= "table" then return {} end
	if attributes.mode ~= "directory" then return nil, "not a folder: " .. folder end
	-- The owner walks the folder in a generic-for, so its state is closed on every exit.
	local entries, listed, list_error = require("core.fs.engine.dir").try_entries_quiet(folder)
	if not listed then return nil, "cannot list " .. folder .. ": " .. tostring(list_error) end
	local names = {}
	for _, name in ipairs(entries) do
		if name ~= "." and name ~= ".." then
			local ok, entry = pcall(hs.fs.symlinkAttributes, folder .. name)
			if ok and type(entry) == "table" and entry.mode == "file" then names[#names + 1] = name end
		end
	end
	table.sort(names)
	return names
end

--- Reads a whole file.
--- @param path string Absolute path.
--- @return string|nil bytes
--- @return string|nil error_message
function M.read(path)
	local handle, open_error = io.open(path, "rb")
	if not handle then return nil, tostring(open_error) end
	local read_ok, bytes = pcall(handle.read, handle, "a")
	handle:close()
	if not read_ok or type(bytes) ~= "string" then return nil, "cannot read " .. path end
	return bytes
end

--- The folder the archive goes to: ~/Downloads, else ~/Desktop.
--- @param home string The home folder.
--- @return string|nil folder Absolute, without a trailing slash.
function M.target_folder(home)
	if type(home) ~= "string" or home == "" then return nil end
	for _, name in ipairs({ "Downloads", "Desktop" }) do
		local candidate = (home:gsub("/+$", "")) .. "/" .. name
		local ok, attributes = pcall(hs.fs.attributes, candidate)
		if ok and type(attributes) == "table" and attributes.mode == "directory" then return candidate end
	end
	return nil
end

--- Writes bytes to `dir/name` through a partial file renamed into place.
--- @param dir string Existing folder, without a trailing slash.
--- @param name string File name.
--- @param bytes string Complete content.
--- @return string|nil path The published file.
--- @return string|nil error_message
function M.write_atomic(dir, name, bytes)
	local final = dir .. "/" .. name
	local partial = dir .. "/." .. name .. ".partial"
	local handle, open_error = io.open(partial, "wb")
	if not handle then return nil, tostring(open_error) end
	local wrote, write_error = handle:write(bytes)
	local flushed = wrote and handle:flush()
	local closed = handle:close()
	if not wrote or not flushed or not closed then
		os.remove(partial)
		return nil, "cannot write " .. partial .. ": " .. tostring(write_error)
	end
	local renamed, rename_error = os.rename(partial, final)
	if not renamed then
		os.remove(partial)
		return nil, tostring(rename_error)
	end
	return final
end

return M
