--- _shared/lua/module_source_identity.lua
--- Pure source-spelling comparison for the trusted normal Lua loader.
--- This never resolves a native data path, follows a symlink, or guesses a cwd.

local M = {}

--- Normalizes only an actual @file debug source, preserving case and requiring an explicit anchor for relative coordinates.
--- @param source string
--- @param directory string|nil Captured native directory for relative file sources.
--- @return string|nil
local function normalize(source, directory)
	if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return nil end
	local path = source:sub(2):gsub("\\", "/")
	if path == "" or path:find("%z") then return nil end
	local absolute = path:sub(1, 1) == "/"
	if not absolute then
		if type(directory) ~= "string" or directory:sub(1, 1) ~= "/" or directory:find("%z") then return nil end
		path = directory .. "/" .. path
		absolute = true
	end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == "." then
			-- A normal loader's explicit current-directory component adds no name.
		elseif part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			parts[#parts] = nil
		elseif part == ".." and absolute then
			return nil
		else
			parts[#parts + 1] = part
		end
	end
	if #parts == 0 then return nil end
	return "@" .. (absolute and "/" or "") .. table.concat(parts, "/")
end

--- Derives an exact relative sibling from a known native module's file suffix.
--- @param source string
--- @param suffix string
--- @param sibling string
--- @return string|nil
local function sibling_source(source, suffix, sibling, directory)
	local normalized = normalize(source, directory)
	if normalized == nil or type(suffix) ~= "string" or suffix == ""
		or type(sibling) ~= "string" or sibling == "" then return nil end
	local marker = "/" .. suffix
	local path = normalized:sub(2)
	local prefix
	if path == suffix then prefix = ""
	elseif path:sub(-#marker) == marker then prefix = path:sub(1, -#suffix - 1)
	else return nil end
	return normalize("@" .. prefix .. sibling, directory)
end

--- Compares exact normalized loader coordinates; malformed sources never match.
--- @param actual string
--- @param expected string
--- @return boolean
local function same_source(actual, expected, directory)
	local left, right = normalize(actual, directory), normalize(expected, directory)
	return left ~= nil and right ~= nil and left == right
end

M.normalize, M.sibling, M.same = normalize, sibling_source, same_source
return M
