--- infra/device_access.lua

--- ==============================================================================
--- MODULE: Nonblocking Device Access Probe (Linux)
--- DESCRIPTION:
--- Checks read admission without waiting for a FIFO peer or creating a node.
--- libuv opens descriptors close-on-exec; every successful probe also requires
--- its close receipt before it can report the path as readable.
--- ==============================================================================

local M = {}

--- Probes the same read permission as the input adapters without blocking.
--- @param path string Device path.
--- @param native table|nil Native filesystem ports; defaults to luv.
--- @return boolean readable
--- @return string|nil code Native error code, including EACCES.
function M.readable(path, native)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return false, "EINVAL" end
	local uv = native or require("luv")
	local descriptor, _, code = uv.fs_open(path, uv.constants.O_RDONLY + uv.constants.O_NONBLOCK, 0)
	if descriptor == nil then return false, code end
	local closed, _, close_code = uv.fs_close(descriptor)
	if closed ~= true then return false, close_code end
	return true
end

return M
