--- infra/regular_file_writer.lua
--- ==============================================================================
--- MODULE: Nonblocking Regular-File Write Admission
--- DESCRIPTION:
--- Pin a writable descriptor without truncation, then classify that descriptor.
--- A FIFO cannot wait for a reader or receive bytes through the file port. Only
--- an admitted regular inode is reopened for buffered overwrite or append.
--- ==============================================================================

local M = {}
local O_WRONLY, O_CREAT, O_APPEND = 1, 64, 1024 -- Linux open flags.
local O_NONBLOCK, O_CLOEXEC = 2048, 524288 -- Linux open flags.
local EIO, EINVAL = 5, 22 -- Linux errno receipts.
local AT_EMPTY_PATH, STATX_TYPE, S_IFREG = 4096, 1, 32768 -- Linux descriptor/type query.

--- Opens without truncating and returns operations for this owned descriptor.
--- @param path string
--- @param mode string Buffered stream mode, "w" or "a".
--- @return number|nil descriptor
--- @return table|string operations or failure detail
--- @return number|string|nil errno
local function native_open(path, mode)
	local flags = O_WRONLY + O_CREAT + O_NONBLOCK + O_CLOEXEC
	if mode == "a" then flags = flags + O_APPEND end
	local ok_uv, uv = pcall(require, "luv")
	if ok_uv and type(uv) == "table" and type(uv.fs_open) == "function"
		and type(uv.fs_fstat) == "function" and type(uv.fs_close) == "function" then
		local fd, detail, code = uv.fs_open(path, flags, 438) -- 0666, subject to the process umask.
		if not fd then return nil, detail, code end
		return fd, {
			regular = function() local attrs = uv.fs_fstat(fd); return attrs and attrs.type == "file" end,
			close = function() return uv.fs_close(fd) end,
		}
	end
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or ffi.os ~= "Linux" then return nil, "native file write admission unavailable", EIO end
	-- Device adapters declare a two-argument open. A private symbol alias retains
	-- the creation-mode argument regardless of which adapter loaded its FFI first.
	pcall(ffi.cdef, [[
		int ergopti_write_open(const char *path, int flags, ...) __asm__("open");
		int close(int fd);
		int statx(int dirfd, const char *path, int flags, unsigned int mask, void *buffer);
		struct ergopti_write_statx {
			uint32_t mask, block_size;
			uint64_t attributes;
			uint32_t link_count, uid, gid;
			uint16_t mode;
			unsigned char remaining[226];
		};
	]])
	local has_statx, statx = pcall(function() return ffi.C.statx end)
	if not has_statx then return nil, "native descriptor metadata unavailable", EIO end
	-- FFI varargs require the exact C integer type for the creation mode.
	local fd = ffi.C.ergopti_write_open(path, flags, ffi.new("unsigned int", 438))
	if fd < 0 then local errno = ffi.errno(); return nil, "native open refused", errno end
	return fd, {
		regular = function()
			local record = ffi.new("struct ergopti_write_statx")
			assert(ffi.sizeof(record) == 256 and ffi.offsetof("struct ergopti_write_statx", "mode") == 28,
				"unexpected native statx record layout")
			if statx(fd, "", AT_EMPTY_PATH, STATX_TYPE, record) ~= 0 or tonumber(record.mask) % 2 ~= 1 then return false end
			local mode_bits = tonumber(record.mode)
			return mode_bits - mode_bits % 4096 == S_IFREG
		end,
		close = function() return ffi.C.close(fd) == 0 end,
	}
end

--- Opens an already-pinned regular inode; special endpoints never reach stdio.
--- The admission descriptor is released on every classification/open receipt.
--- @param path string
--- @param mode string Buffered stream mode, "w" or "a".
--- @return file*|nil stream
--- @return string|nil failure
--- @return number|string|nil errno
function M.open(path, mode)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or (mode ~= "w" and mode ~= "a") then
		return nil, "invalid native write path or mode", EINVAL
	end
	local fd, operations, errno = native_open(path, mode)
	if not fd then return nil, operations, errno end
	local inspected, regular = pcall(operations.regular)
	local opened, stream, detail, open_errno = true, nil, "destination is not a regular file", EINVAL
	if inspected and regular == true then
		-- The alias addresses the admitted inode even after a competing rename.
		-- Only here may mode "w" truncate; mode "a" retains native append behavior.
		opened, stream, detail, open_errno = pcall(io.open, "/proc/self/fd/" .. tostring(fd), mode)
	end
	local close_ok, closed = pcall(operations.close)
	if not close_ok or not closed then
		if stream then pcall(stream.close, stream) end
		return nil, "native write descriptor close failed", EIO
	end
	if not inspected then return nil, "native file classification failed", EIO end
	if not opened then return nil, "native stream open raised", EIO end
	return stream, detail, open_errno
end

return M
