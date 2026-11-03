--- infra/openssl_library.lua
--- ==============================================================================
--- MODULE: Native OpenSSL Library Ownership
--- DESCRIPTION:
--- Retains the OpenSSL 3 library used by native byte primitives. Missing FFI or
--- library capability is explicit; each primitive admits its own required ABI.
--- ==============================================================================

local M = {}
local loaded, ffi = pcall(require, "ffi")
if loaded then
	local available, library = pcall(ffi.load, "libcrypto.so.3")
	if available then M.ffi, M.library = ffi, library end
end

--- Declares each C declaration, one at a time, accepting one already declared.
--- LuaJIT refuses to redefine a function, and its C namespace outlives a
--- reloaded module: the second module declaring EVP_MD_CTX_new used to fail
--- as a whole, and the signature check read that as "no OpenSSL", depending on
--- which module the process had loaded first.
--- @param declarations string[] One declaration per entry.
--- @return boolean ok
--- @return string|nil err The ffi.cdef error of the first refused declaration.
function M.declare(declarations)
	if not M.ffi then return false, "ffi unavailable" end
	for _, declaration in ipairs(declarations) do
		local ok, err = pcall(M.ffi.cdef, declaration)
		if not ok and not tostring(err):find("attempt to redefine", 1, true) then
			return false, tostring(err)
		end
	end
	return true
end

return M
