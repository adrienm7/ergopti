--- infra/no_replace_move.lua
--- ==============================================================================
--- MODULE: Native No-Replace File Move
--- DESCRIPTION:
--- Preserves destination ownership at publication, including concurrent arrivals.
--- LuaJIT uses one atomic renameat2; stock Lua uses a checked link/unlink pair.
--- ==============================================================================

local M = {}
local AT_FDCWD, RENAME_NOREPLACE, EEXIST = -100, 1, 17 -- Linux ABI constants.
local native_rename, native_errno
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	local declared = pcall(ffi.cdef, [[
		int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
	]])
	if declared then
		local found, symbol = pcall(function() return ffi.C.renameat2 end)
		if found then native_rename, native_errno = symbol, ffi.errno end
	end
end

--- Moves a file only if the destination is still unoccupied at publication.
--- @param source string
--- @param destination string
--- @return boolean
--- @return string|nil Native failure code; EEXIST permits a new candidate.
function M.move(source, destination)
	if type(source) ~= "string" or type(destination) ~= "string"
		or source:find("\0", 1, true) or destination:find("\0", 1, true) then
		return false, "EINVAL"
	end
	if native_rename then
		if native_rename(AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE) == 0 then return true end
		local errno = native_errno()
		return false, errno == EEXIST and "EEXIST" or tostring(errno)
	end
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv.fs_link) ~= "function" or type(uv.fs_unlink) ~= "function" then
		return false, "native no-replace move unavailable"
	end
	-- link never replaces an occupied name. If unlink fails, retain both paths
	-- and report failure; do not delete a backup whose ownership may have changed.
	local linked, _, code = uv.fs_link(source, destination)
	if not linked then return false, code end
	local removed, _, removal_code = uv.fs_unlink(source)
	if not removed then return false, removal_code end
	return true
end

return M
