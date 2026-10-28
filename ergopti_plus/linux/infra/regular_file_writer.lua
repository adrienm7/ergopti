--- infra/regular_file_writer.lua
--- ==============================================================================
--- MODULE: Nonblocking Regular-File Write Admission
--- DESCRIPTION:
--- Pin a writable descriptor without truncation, then classify that descriptor.
--- A FIFO cannot wait for a reader or receive bytes through the file port. Only
--- an admitted regular inode is reopened for buffered overwrite or append.
--- ==============================================================================

local M = {}
local O_WRONLY, O_CREAT, O_EXCL, O_APPEND = 1, 64, 128, 1024 -- Linux open flags.
local O_NONBLOCK, O_CLOEXEC = 2048, 524288 -- Linux open flags.
local EIO, EINVAL = 5, 22 -- Linux errno receipts.
local AT_EMPTY_PATH, STATX_TYPE, S_IFREG = 4096, 1, 32768 -- Linux descriptor/type query.
local AT_FDCWD, AT_SYMLINK_NOFOLLOW, STATX_INO = -100, 256, 256 -- Exclusive creation identity.

--- Opens without truncating and returns operations for this owned descriptor.
--- @param path string
--- @param mode string Buffered stream mode, "w", "a" or create-only "wx".
--- @return number|nil descriptor
--- @return table|string operations or failure detail
--- @return number|string|nil errno
local function native_open(path, mode)
	local flags = O_WRONLY + O_CREAT + O_NONBLOCK + O_CLOEXEC
	if mode == "a" then flags = flags + O_APPEND end
	if mode == "wx" then flags = flags + O_EXCL end
	local ok_uv, uv = pcall(require, "luv")
	if ok_uv and type(uv) == "table" and type(uv.fs_open) == "function"
		and type(uv.fs_fstat) == "function" and type(uv.fs_close) == "function" then
		if mode == "wx" and (type(uv.fs_lstat) ~= "function" or type(uv.fs_unlink) ~= "function") then
			return nil, "exclusive file cleanup unavailable", EIO
		end
		local lstat = uv.fs_lstat
		local fd, detail, code = uv.fs_open(path, flags, 438) -- 0666, subject to the process umask.
		if not fd then return nil, detail, code end
		local identity
		return fd, {
			regular = function() identity = uv.fs_fstat(fd); return identity and identity.type == "file" end,
			close = function() return uv.fs_close(fd) end,
			regular_path = function() local current = lstat(path); return current and current.type == "file" end,
			remove_owned = function()
				local current = uv.fs_lstat(path)
				-- Native IDs must be nonnegative exact integers, including LuaJIT doubles.
				if not identity or not current or current.type ~= "file" or type(identity.ino) ~= "number" or type(identity.dev) ~= "number"
					or identity.ino < 0 or identity.dev < 0 or identity.ino % 1 ~= 0 or identity.dev % 1 ~= 0
					or identity.ino >= 2 ^ 53 or identity.dev >= 2 ^ 53
					or current.ino ~= identity.ino or current.dev ~= identity.dev then return false end
				return uv.fs_unlink(path) == true
			end,
		}
	end
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or ffi.os ~= "Linux" then return nil, "native file write admission unavailable", EIO end
	-- Device adapters declare a two-argument open. A private symbol alias retains
	-- the creation-mode argument regardless of which adapter loaded its FFI first.
	pcall(ffi.cdef, [[
		int ergopti_write_open(const char *path, int flags, ...) __asm__("open");
		int close(int fd);
		int unlink(const char *path);
		int statx(int dirfd, const char *path, int flags, unsigned int mask, void *buffer);
		struct ergopti_write_statx {
			uint32_t mask, block_size;
			uint64_t attributes;
			uint32_t link_count, uid, gid;
			uint16_t mode;
			uint16_t padding;
			uint64_t inode;
			unsigned char timestamps_and_sizes[96];
			uint32_t dev_major, dev_minor;
			unsigned char remaining[112];
		};
	]])
	local has_statx, statx = pcall(function() return ffi.C.statx end)
	if not has_statx then return nil, "native descriptor metadata unavailable", EIO end
	local mask = mode == "wx" and STATX_TYPE + STATX_INO or STATX_TYPE
	local identity
	-- FFI varargs require the exact C integer type for the creation mode.
	local fd = ffi.C.ergopti_write_open(path, flags, ffi.new("unsigned int", 438))
	if fd < 0 then local errno = ffi.errno(); return nil, "native open refused", errno end
	return fd, {
		regular = function()
			local record = ffi.new("struct ergopti_write_statx")
			assert(ffi.sizeof(record) == 256 and ffi.offsetof("struct ergopti_write_statx", "mode") == 28,
				"unexpected native statx record layout")
			if statx(fd, "", AT_EMPTY_PATH, mask, record) ~= 0 or tonumber(record.mask) % 2 ~= 1 then return false end
			identity = record
			local mode_bits = tonumber(record.mode)
			return mode_bits - mode_bits % 4096 == S_IFREG
		end,
		close = function() return ffi.C.close(fd) == 0 end,
		regular_path = function()
			local record = ffi.new("struct ergopti_write_statx")
			if statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_TYPE, record) ~= 0 or tonumber(record.mask) % 2 ~= 1 then return false end
			local mode_bits = tonumber(record.mode)
			return mode_bits - mode_bits % 4096 == S_IFREG
		end,
		remove_owned = function()
			local current = ffi.new("struct ergopti_write_statx")
			if not identity or math.floor(tonumber(identity.mask) / STATX_INO) % 2 ~= 1
				or statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, mask, current) ~= 0
				or math.floor(tonumber(current.mask) / STATX_INO) % 2 ~= 1
				or current.inode ~= identity.inode or current.dev_major ~= identity.dev_major
				or current.dev_minor ~= identity.dev_minor then return false end
			return ffi.C.unlink(path) == 0
		end,
	}
end

--- Opens an already-pinned regular inode; special endpoints never reach stdio.
--- The admission descriptor is released on every classification/open receipt.
--- @param path string
--- @param mode string Buffered stream mode, "w", "a" or create-only "wx".
--- @return file*|nil stream
--- @return string|nil failure
--- @return number|string|nil errno
--- @return function|nil remove_owned Exclusive creation's identity-checked cleanup.
--- @return function|nil current_image Exclusive staging's regular-path byte proof.
function M.open(path, mode)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or (mode ~= "w" and mode ~= "a" and mode ~= "wx") then
		return nil, "invalid native write path or mode", EINVAL
	end
	local open_image
	if mode == "wx" then
		open_image = require("infra.regular_file_reader").open
		if type(open_image) ~= "function" then return nil, "native staging image reader unavailable", EIO end
	end
	local fd, operations, errno = native_open(path, mode)
	if not fd then return nil, operations, errno end
	local inspected, regular = pcall(operations.regular)
	local opened, stream, detail, open_errno = true, nil, "destination is not a regular file", EINVAL
	if inspected and regular == true then
		-- The alias addresses the admitted inode even after a competing rename.
		-- Only here may mode "w" truncate; mode "a" retains native append behavior.
		opened, stream, detail, open_errno = pcall(io.open, "/proc/self/fd/" .. tostring(fd), mode == "wx" and "w" or mode)
	end
	local close_ok, closed = pcall(operations.close)
	local function remove_owned()
		-- This fences observed succession; metadata plus unlink is not an OS CAS.
		local called, removed = pcall(operations.remove_owned)
		return called and removed == true
	end
	if mode == "wx" and (not inspected or not regular or not opened or not stream or not close_ok or not closed) then
		remove_owned()
	end
	if not close_ok or not closed then
		if stream then pcall(stream.close, stream) end
		return nil, "native write descriptor close failed", EIO
	end
	if not inspected then return nil, "native file classification failed", EIO end
	if not opened then return nil, "native stream open raised", EIO end
	if mode == "wx" and not stream then return nil, detail, open_errno end
	if mode == "wx" then
		local function current_image(expected_bytes)
			if type(expected_bytes) ~= "string" then return false end
			local inspected_path, regular_path = pcall(operations.regular_path)
			if not inspected_path or regular_path ~= true then return false end
			local acquired, image = pcall(open_image, path)
			if not acquired or not image then return false end
			local read_ok, bytes = pcall(image.read, image, "*a")
			local closed_ok, image_closed = pcall(image.close, image)
			-- Equal bytes in a replacement regular file are allowed; this is not an external CAS.
			return read_ok and bytes == expected_bytes and closed_ok and image_closed == true
		end
		return stream, detail, open_errno, remove_owned, current_image
	end
	return stream, detail, open_errno
end

return M
