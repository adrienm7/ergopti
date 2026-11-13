--- core/fs/engine/corrupt_aside.lua

--- ==============================================================================
--- MODULE: Corrupt Source Set-Aside
--- DESCRIPTION:
--- Keeps a malformed JSON store's bytes aside before the owner starts empty.
--- The bytes move to the first free `<path>.corrupt`, `<path>.corrupt.1`, ...
--- through a no-replace move, so an older set-aside, or one another process
--- makes at the same instant, is never replaced: a taken name (EEXIST) moves
--- the candidate on, any other refusal is returned.
--- ==============================================================================

local M = {}
local NoReplaceMove = require("core.fs.engine.no_replace_move")

--- Moves `path` aside without replacing any earlier set-aside.
--- @param path string Malformed source file.
--- @return string|nil aside Where the bytes now are; nil when they stayed.
--- @return string|nil failure Native failure of the refused move.
function M.preserve(path)
	assert(type(path) == "string" and path ~= "", "corrupt set-aside needs a source path")
	local candidate, suffix = path .. ".corrupt", 0
	while true do
		local called, moved, failure = pcall(NoReplaceMove.move, path, candidate)
		if called and moved == true then return candidate, nil end
		if not called then return nil, tostring(moved) end
		if failure ~= "EEXIST" then return nil, tostring(failure) end
		suffix = suffix + 1
		candidate = path .. ".corrupt." .. suffix
	end
end

return M
