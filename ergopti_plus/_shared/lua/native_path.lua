--- _shared/lua/native_path.lua

--- ==============================================================================
--- MODULE: Native Path Text
--- DESCRIPTION:
--- The one owner of path splitting and joining for the Lua drivers. A
--- backslash is ordinary filename data on macOS and Linux and separates
--- components only when the host itself is Windows, which is where the
--- headless test suites run on a maintainer's machine.
---
--- FEATURES & RATIONALE:
--- 1. Host rule read per call: package.config names the host separator, so a
---    test can model either host without reloading the module.
--- 2. Pure text: nothing here touches the file system, so every boot stage can
---    use it once the shared Lua root is on package.path.
--- 3. Windows-path parsing proper (a path typed for a Windows machine) is a
---    different job and does not belong here.
--- ==============================================================================

local M = {}

--- Returns the separator class of the host, as a Lua pattern class body.
--- @return string "/" on POSIX, "/\\" on a Windows host.
function M.separators()
	return package.config:sub(1, 1) == "\\" and "/\\" or "/"
end

--- Reports whether a path starts at the root of the file system.
--- @param path string Native path.
--- @return boolean
function M.is_rooted(path)
	return path:match("^[" .. M.separators() .. "]") ~= nil
end

--- Reports whether a path is absolute on the host: rooted, or on a Windows
--- host a drive-qualified path.
--- @param path string Native path.
--- @return boolean
function M.is_absolute(path)
	if M.is_rooted(path) then return true end
	return package.config:sub(1, 1) == "\\" and path:match("^%a:[/\\]") ~= nil
end

--- Reports whether a path ends with a separator.
--- @param path string Native path.
--- @return boolean
function M.has_trailing_separator(path)
	return path:match("[" .. M.separators() .. "]$") ~= nil
end

--- Appends "/" unless the path already ends with a separator.
--- @param path string Native path.
--- @return string
function M.with_trailing_separator(path)
	if M.has_trailing_separator(path) then return path end
	return path .. "/"
end

--- Removes every trailing separator.
--- @param path string Native path.
--- @return string
function M.without_trailing_separators(path)
	return (path:gsub("[" .. M.separators() .. "]+$", ""))
end

--- Returns the parent of a path, without its trailing separator.
--- @param path string Native path without a trailing separator.
--- @return string|nil parent Nil when the path has no separator before its last component.
function M.dirname(path)
	local sep = M.separators()
	return path:match("^(.*)[" .. sep .. "][^" .. sep .. "]+$")
end

--- Returns everything up to and including the last separator.
--- @param path string Native path.
--- @return string|nil prefix Nil when the path holds no separator.
function M.directory_prefix(path)
	return path:match("^(.*[" .. M.separators() .. "])")
end

--- Returns the last component of a path.
--- @param path string Native path without a trailing separator.
--- @return string|nil name Nil for an empty path or one ending with a separator.
function M.basename(path)
	return path:match("([^" .. M.separators() .. "]+)$")
end

--- Splits a path into its non-empty components.
--- @param path string Native path.
--- @return table components Array of strings.
function M.components(path)
	local parts = {}
	for part in path:gmatch("[^" .. M.separators() .. "]+") do parts[#parts + 1] = part end
	return parts
end

--- Reports whether a name holds a separator, so it cannot be one component.
--- @param name string Candidate file name.
--- @return boolean
function M.has_separator(name)
	return name:find("[" .. M.separators() .. "]") ~= nil
end

return M
