--- infra/regular_file_reader.lua
--- ==============================================================================
--- MODULE: Nonblocking Regular-File Read Admission
--- DESCRIPTION:
--- Pin a native descriptor before classifying the source. JSON persistence may
--- read regular files, including file symlinks, but must never wait on a FIFO.
--- Reopening the pinned descriptor preserves the existing Lua stream receipts.
--- ==============================================================================

local M = {}
local O_NONBLOCK, O_CLOEXEC = 2048, 524288 -- Linux open flags, with O_RDONLY = 0.
local ENOENT, EIO, EINVAL = 2, 5, 22 -- Linux errno receipts.
local AT_EMPTY_PATH, STATX_TYPE, S_IFREG = 4096, 1, 32768 -- Linux descriptor/type query.

--- Opens a nonblocking descriptor and its owned native operations.
--- @param path string
--- @return number|nil descriptor
--- @return table|string operations or failure detail
--- @return number|string|nil errno
local function native_open(path)
	local ok_uv, uv = pcall(require, "luv")
	if ok_uv and type(uv) == "table" and type(uv.fs_open) == "function"
		and type(uv.fs_fstat) == "function" and type(uv.fs_close) == "function" then
		local fd, detail, code = uv.fs_open(path, O_NONBLOCK + O_CLOEXEC, 0)
		if not fd then return nil, detail, code == "ENOENT" and ENOENT or code end
		return fd, {
			regular = function() local attrs = uv.fs_fstat(fd); return attrs and attrs.type == "file" end,
			close = function() return uv.fs_close(fd) end,
		}
	end
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or ffi.os ~= "Linux" then return nil, "native file read admission unavailable", EIO end
	pcall(ffi.cdef, [[
		int open(const char *path, int flags, ...);
		int close(int fd);
		int statx(int dirfd, const char *path, int flags, unsigned int mask, void *buffer);
		struct ergopti_read_statx {
			uint32_t mask, block_size;
			uint64_t attributes;
			uint32_t link_count, uid, gid;
			uint16_t mode;
			unsigned char remaining[226];
		};
	]])
	local has_statx, statx = pcall(function() return ffi.C.statx end)
	if not has_statx then return nil, "native descriptor metadata unavailable", EIO end
	local fd = ffi.C.open(path, O_NONBLOCK + O_CLOEXEC)
	if fd < 0 then local errno = ffi.errno(); return nil, "native open refused", errno end
	return fd, {
		regular = function()
			-- Linux's fixed 256-byte statx UAPI is independent of libc's per-arch
			-- struct stat layout. Query the owned fd without spawning a child.
			local record = ffi.new("struct ergopti_read_statx")
			assert(ffi.sizeof(record) == 256 and ffi.offsetof("struct ergopti_read_statx", "mode") == 28,
				"unexpected native statx record layout")
			if statx(fd, "", AT_EMPTY_PATH, STATX_TYPE, record) ~= 0 or tonumber(record.mask) % 2 ~= 1 then return false end
			local mode = tonumber(record.mode)
			return mode - mode % 4096 == S_IFREG
		end,
		close = function() return ffi.C.close(fd) == 0 end,
	}
end

--- Opens only an already-pinned regular file without blocking on special paths.
--- The native descriptor is released on every classified or stream-open receipt.
--- @param path string
--- @return file*|nil stream
--- @return string|nil failure
--- @return number|string|nil errno
function M.open(path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return nil, "invalid native file path", EINVAL
	end
	local fd, operations, errno = native_open(path)
	if not fd then return nil, operations, errno end
	local inspected, regular = pcall(operations.regular)
	local opened, stream, detail, open_errno = true, nil, "source is not a regular file", EINVAL
	if inspected and regular == true then
		-- Kernel-owned fd aliases cannot be redirected by a concurrent path edit.
		opened, stream, detail, open_errno = pcall(io.open, "/proc/self/fd/" .. tostring(fd), "r")
	end
	local close_ok, closed = pcall(operations.close)
	if not close_ok or not closed then
		if stream then pcall(stream.close, stream) end
		return nil, "native read descriptor close failed", EIO
	end
	if not inspected then return nil, "native file classification failed", EIO end
	if not opened then return nil, "native stream open raised", EIO end
	return stream, detail, open_errno
end

return M
