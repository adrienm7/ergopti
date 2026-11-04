--- infra/private_sqlite_file.lua
--- ==============================================================================
--- MODULE: Private SQLite File Admission
--- DESCRIPTION:
--- Creates and tightens sensitive SQLite inodes through retained descriptors.
--- Directory policy stays with the user's selected configuration location.
--- ==============================================================================

local M = {}
local Policy = require("infra.sqlite_privacy_policy")
local PRIVATE_MODE = Policy.file_mode
local OPEN_FLAGS = 2 + 2048 + 524288 + 131072 -- O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW.
local O_CREAT = 64
local close_debt = nil

M.creation_mask = Policy.creation_mask

--- Selects actual descriptor primitives without importing an unavailable runtime.
--- LuaJIT's FFI preserves the public synchronous SQLite reader without luv.
local function native_backend()
	local loaded, uv = pcall(require, "luv")
	local names = { "fs_open", "fs_fstat", "fs_lstat", "fs_stat", "fs_fchmod", "fs_close", "fs_realpath" }
	if loaded and type(uv) == "table" then
		local operations, complete = {}, true
		for _, name in ipairs(names) do operations[name] = uv[name]; complete = complete and type(uv[name]) == "function" end
		if complete then return operations end
	end
	local available, ffi = pcall(require, "ffi")
	if not available or ffi.os ~= "Linux" then return nil end
	pcall(ffi.cdef, [[
		int ergopti_private_open(const char *path, int flags, ...) __asm__("open");
		int ergopti_private_fchmod(int fd, unsigned int mode) __asm__("fchmod");
		int ergopti_private_close(int fd) __asm__("close");
		char *ergopti_private_realpath(const char *path, char *resolved) __asm__("realpath");
		int ergopti_private_statx_query(int dirfd, const char *path, int flags, unsigned int mask, void *buffer) __asm__("statx");
		struct ergopti_private_statx {
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
	local supported, statx = pcall(function() return ffi.C.ergopti_private_statx_query end)
	if not supported then return nil end
	local AT_FDCWD, AT_EMPTY_PATH, AT_SYMLINK_NOFOLLOW = -100, 4096, 256
	local STATX_TYPE, STATX_INO, S_IFREG = 1, 256, 32768
	local function failure()
		local errno = ffi.errno()
		return nil, "private SQLite native operation refused", errno == 2 and "ENOENT" or errno
	end
	local function metadata(descriptor, path, flags)
		local record = ffi.new("struct ergopti_private_statx")
		assert(ffi.sizeof(record) == 256 and ffi.offsetof("struct ergopti_private_statx", "mode") == 28,
			"unexpected private SQLite statx layout")
		if statx(descriptor, path, flags, STATX_TYPE + STATX_INO, record) ~= 0 then return failure() end
		local mask, mode = tonumber(record.mask), tonumber(record.mode)
		if mask % 2 ~= 1 or math.floor(mask / STATX_INO) % 2 ~= 1 then return nil end
		return { type = mode - mode % 4096 == S_IFREG and "file" or "other", mode = mode,
			ino = tostring(record.inode), dev = tostring(record.dev_major) .. ":" .. tostring(record.dev_minor) }
	end
	return {
		fs_open = function(path, flags, mode)
			local descriptor = ffi.C.ergopti_private_open(path, flags, ffi.new("unsigned int", mode))
			if descriptor < 0 then return failure() end
			return tonumber(descriptor)
		end,
		fs_fstat = function(descriptor) return metadata(descriptor, "", AT_EMPTY_PATH) end,
		fs_lstat = function(path) return metadata(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW) end,
		fs_stat = function(path) return metadata(AT_FDCWD, path, 0) end,
		fs_fchmod = function(descriptor, mode) if ffi.C.ergopti_private_fchmod(descriptor, mode) == 0 then return true end; return failure() end,
		fs_close = function(descriptor) if ffi.C.ergopti_private_close(descriptor) == 0 then return true end; return failure() end,
		fs_realpath = function(path)
			local buffer = ffi.new("char[4096]") -- Linux PATH_MAX, including the terminator.
			if ffi.C.ergopti_private_realpath(path, buffer) == nil then return failure() end
			return ffi.string(buffer)
		end,
	}
end

--- Rejects rounded native inode identifiers instead of accepting false equality.
--- Both adjacent differences must stay exact: doubles lose unit spacing at
--- their precision boundary, while native integers retain it even across wrap.
local function exact_identity(stat)
	for _, value in ipairs({ stat.dev, stat.ino }) do
		if type(value) ~= "string" and (type(value) ~= "number" or value < 0 or value % 1 ~= 0
			or (value + 1) - value ~= 1 or value - (value - 1) ~= 1) then return false end
	end
	return stat.dev ~= nil and stat.ino ~= nil
end

--- Admits one regular inode without truncation or following a final symlink.
--- @param path string Exact SQLite filename.
--- @param create boolean Whether this database inode may be created.
--- @return boolean admitted
--- @return string|nil failure
local function admit_file(Native, path, create)
	local close = Native.fs_close
	local descriptor, _, code = Native.fs_open(path, OPEN_FLAGS + (create and O_CREAT or 0), PRIVATE_MODE)
	if not descriptor then
		if not create and code == "ENOENT" then return true end
		return false, "private SQLite open refused"
	end
	local inspected, admitted = pcall(function()
		local before = Native.fs_fstat(descriptor)
		if not before or before.type ~= "file" or not exact_identity(before) then return false end
		local current = Native.fs_lstat(path)
		if not current or current.type ~= "file" or current.dev ~= before.dev or current.ino ~= before.ino then return false end
		if before.mode % 4096 ~= PRIVATE_MODE and Native.fs_fchmod(descriptor, PRIVATE_MODE) ~= true then return false end
		local after = Native.fs_fstat(descriptor)
		current = Native.fs_lstat(path)
		if after and after.type == "file" and after.mode % 4096 == PRIVATE_MODE
			and after.dev == before.dev and after.ino == before.ino and current and current.type == "file"
			and current.dev == before.dev and current.ino == before.ino and current.mode % 4096 == PRIVATE_MODE then return before end
		return false
	end)
	local close_ok, closed = pcall(close, descriptor)
	if not close_ok or closed ~= true then
		-- An ambiguous close cannot be retried against a possibly reused FD.
		-- Retain its exact authority and refuse further acquisitions until exit.
		close_debt = { descriptor = descriptor, close = close }
		return false, "private SQLite descriptor close refused"
	end
	if not inspected or not admitted then return false, "private SQLite permissions admission refused" end
	return true, nil, admitted
end

--- Admits the database and every already-existing sensitive companion inode.
--- @param database string Filesystem path, never a SQLite URI.
--- @return boolean admitted
--- @return string|nil failure
function M.admit(database)
	if close_debt then return false, "private SQLite descriptor ownership unresolved" end
	if type(database) ~= "string" or database == "" or database:find("\0", 1, true) then return false, "invalid private SQLite path" end
	local Native = native_backend()
	if not Native then return false, "private SQLite descriptor API unavailable" end
	-- SQLite resolves existing database file links to their regular target.
	-- Pin that target without following a racing final link, then recheck the
	-- original alias; companion names belong to the resolved SQLite namespace.
	local resolved, _, code = Native.fs_realpath(database)
	if not resolved and code ~= "ENOENT" then return false, "private SQLite resolution refused" end
	local target = resolved or database
	local identity
	for _, suffix in ipairs({ "", "-journal", "-wal", "-shm" }) do
		local admitted, failure, captured = admit_file(Native, target .. suffix, suffix == "")
		if not admitted then return false, failure end
		if suffix == "" then identity = captured end
	end
	local current = Native.fs_stat(database)
	if not current or current.type ~= "file" or current.mode % 4096 ~= PRIVATE_MODE
		or current.dev ~= identity.dev or current.ino ~= identity.ino then return false, "private SQLite identity changed during admission" end
	if resolved and Native.fs_realpath(database) ~= resolved then return false, "private SQLite alias changed during admission" end
	return true
end

--- Reports physical closure without inventing an ACK for a retained descriptor.
--- @return boolean settled
function M.is_settled() return close_debt == nil end

return M
