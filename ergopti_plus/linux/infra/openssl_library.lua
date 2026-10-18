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

return M
