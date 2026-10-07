--- _shared/lua/module_source_directory.lua
--- Captures a native cwd spelling only during trusted module construction.
--- It never supplies configuration authority or resolves native file identity.

local M = {}

--- Reads the native process directory without inherited PWD or shell fallbacks.
--- @return string|nil
function M.capture()
	local native_hs = rawget(_G, "hs")
	local fs, current
	if type(native_hs) == "table" then
		local found, value = pcall(function() return native_hs.fs end)
		if not found or value ~= nil and type(value) ~= "table" then return nil end
		fs = value
	end
	if fs ~= nil then
		local found, value = pcall(function() return fs.currentDir end)
		if not found or value ~= nil and type(value) ~= "function" then return nil end
		current = value
	end
	if type(current) == "function" then
		local called, directory = pcall(current)
		if called and type(directory) == "string" and directory:sub(1, 1) == "/" then return directory end
		return nil
	end
	local loaded, lfs = pcall(require, "lfs")
	local currentdir = loaded and type(lfs) == "table" and rawget(lfs, "currentdir") or nil
	if type(currentdir) ~= "function" then return nil end
	local called, directory = pcall(currentdir)
	if called and type(directory) == "string" and directory:sub(1, 1) == "/" then return directory end
	return nil
end

return M
