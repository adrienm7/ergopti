--- infra/http_body_pipe.lua
--- ==============================================================================
--- MODULE: Native HTTP Body Pipe Allocation
--- DESCRIPTION:
--- Produces genuine anonymous pipes for curl's inherited body descriptor.
--- Jammy's Lua-luv predates luv.pipe; its already-required LuaJIT runtime can
--- allocate the same Linux pipe directly without a pathname or helper process.
--- ==============================================================================

local M = {}
local O_NONBLOCK, O_CLOEXEC = 2048, 524288 -- Linux pipe2 flags.
local native_pipe, native_ffi

--- Allocates two nonblocking close-on-exec descriptors for handle transfer.
--- @param backend table Native libuv binding.
--- @return table|nil { read, write } or no admitted descriptors.
--- @return string|nil Native refusal detail.
function M.allocate(backend)
	if type(backend.pipe) == "function" then
		return backend.pipe({ nonblock = true }, { nonblock = true })
	end
	if not native_pipe then
		local loaded, ffi = pcall(require, "ffi")
		if not loaded or ffi.os ~= "Linux" then return nil, "native body pipe unavailable" end
		local declared = pcall(ffi.cdef, "int pipe2(int pipefd[2], int flags);")
		if not declared then return nil, "native body pipe declaration refused" end
		local found, symbol = pcall(function() return ffi.C.pipe2 end)
		if not found then return nil, "native body pipe unavailable" end
		native_pipe, native_ffi = symbol, ffi
	end
	local descriptors = native_ffi.new("int[2]")
	if native_pipe(descriptors, O_NONBLOCK + O_CLOEXEC) ~= 0 then
		return nil, "native body pipe allocation refused"
	end
	return { read = tonumber(descriptors[0]), write = tonumber(descriptors[1]) }
end

return M
