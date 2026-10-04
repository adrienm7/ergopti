--- adapters/file_system.lua

--- ==============================================================================
--- MODULE: FileSystem Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the FileSystem port contract defined in
--- static/ergopti_plus/_shared/core/ports/FileSystem.spec.js. Wraps Lua's standard
--- io.open behind the five canonical methods (read, write, append, exists,
--- delete) so domain modules perform file I/O without coupling to OS APIs.
---
--- FEATURES & RATIONALE:
--- 1. UTF-8 everywhere: all reads and writes use the "r"/"w"/"a" modes which
---    pass raw bytes through. LuaJIT on Linux runs in a UTF-8 locale by default
---    so string content is already UTF-8.
--- 2. Fail-safe returns: read() returns nil on any error; write/append/delete
---    return false. No exceptions propagate to the caller.
--- 3. Defensive pcall: every io.open call is wrapped in pcall because
---    permission errors and locked files can panic the Lua runtime.
--- 4. exists() uses metadata only: LuaFileSystem, libuv or native libc, then the
---    shell's test builtin on plain Lua. No readable stream is required.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.file_system"
local ENOENT = 2 -- Native Linux errno: a failed unlink proves absence only here.

--- Rejects paths that a native C-string API would silently truncate.
--- @param path any
--- @return boolean
local function valid_native_path(path)
	return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
end

--- Reads exact bytes while distinguishing absence from a failed read.
--- @param path string Source path.
--- @return string|nil content
--- @return string status
--- @return string|nil detail
function M.read_with_status(path)
	return require("toml_codec.writer").read_classified(path)
end

--- Publishes through the shared atomic writer after its exact source check.
--- This synchronous port completes before the daemon dispatches another callback.
--- @param path string Destination path.
--- @param content string Complete replacement bytes.
--- @param expected table Classified source precondition.
--- @return boolean committed
--- @return string|nil detail
function M.write_if_unchanged(path, content, expected)
	return require("toml_codec.writer").publish_if_unchanged(path, content, nil, expected)
end

-- LuaFileSystem is optional — present on most LuaJIT installations.
-- TODO(linux): declare lfs in vendor/ so it is always available.
local ok_lfs, lfs = pcall(require, "lfs")
if not ok_lfs then lfs = nil end

local native_stat = lfs and type(lfs.attributes) == "function" and lfs.attributes or nil
if not native_stat then
	local ok_uv, uv = pcall(require, "luv")
	if ok_uv and type(uv) == "table" and type(uv.fs_stat) == "function" then native_stat = uv.fs_stat end
end

-- LuaJIT always has FFI, even when its optional C-module path omits luv/lfs.
-- Keep daemon reload metadata in-process on that normal runtime as well.
local native_exists
if not native_stat then
	local ok_ffi, ffi = pcall(require, "ffi")
	if ok_ffi and type(ffi) == "table" and pcall(ffi.cdef, "int faccessat(int fd, const char *path, int mode, int flags);") then
		local ok_symbol, call = pcall(function() return ffi.C.faccessat end)
		if ok_symbol then
			local AT_FDCWD, F_OK, AT_EACCESS = -100, 0, 512 -- Linux libc ABI.
			native_exists = function(path) return call(AT_FDCWD, path, F_OK, AT_EACCESS) == 0 end
		end
	end
end


-- ========================================
-- ========================================
-- ======= 1/ Adapter Methods =============
-- ========================================
-- ========================================

--- Reads the entire contents of a regular file as a string.
--- Native descriptor admission rejects FIFO/socket sources before stdio can wait.
--- @param path string Absolute path to the file.
--- @return string|nil File contents, or nil on any error.
function M.read(path)
	if not valid_native_path(path) then
		Logger.error(LOG, "read(): path must be a non-empty string without NUL.")
		return nil
	end

	local ok, result = pcall(function()
		local fh, err = require("infra.regular_file_reader").open(path)
		if not fh then
			Logger.debug(LOG, "read(): cannot open '%s' — %s", path, tostring(err))
			return nil
		end
		-- A read exception still leaves an owned stream to close. Publish bytes
		-- only after both operations returned successful native receipts.
		local read_ok, content, read_err = pcall(fh.read, fh, "*a")
		local close_ok, closed, close_err = pcall(fh.close, fh)
		if not read_ok or type(content) ~= "string" then
			Logger.error(LOG, "read(): native read failed for '%s' — %s", path,
				tostring(read_ok and read_err or content))
			return nil
		end
		if not close_ok or closed ~= true then
			Logger.error(LOG, "read(): native close failed for '%s' — %s", path,
				tostring(close_ok and close_err or closed))
			return nil
		end
		return content
	end)

	if not ok then
		Logger.error(LOG, "read(): unexpected error on '%s' — %s", path, tostring(result))
		return nil
	end
	return result
end

--- Writes and closes a native file, preserving both failure receipts.
--- A successful write alone does not guarantee that buffered bytes were flushed.
--- LuaJIT can return true from write; stock Lua returns the file handle instead.
--- @param fh userdata Open native file.
--- @param content string Bytes to write.
--- @param path string Destination for diagnostics.
--- @param operation string Adapter operation.
--- @return boolean
local function write_and_close(fh, content, path, operation)
	local write_ok, written, write_err = pcall(fh.write, fh, content)
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not write_ok or not written then
		Logger.error(LOG, "%s(): write failed for '%s' — %s", operation, path,
			tostring(write_ok and write_err or written))
		return false
	end
	if not close_ok or not closed then
		Logger.error(LOG, "%s(): close failed for '%s' — %s", operation, path,
			tostring(close_ok and close_err or closed))
		return false
	end
	return true
end

--- Writes content to a file, overwriting any existing content.
--- @param path    string Absolute path to the file.
--- @param content string UTF-8 content to write.
--- @return boolean true on success, false on any error.
function M.write(path, content)
	if not valid_native_path(path) then
		Logger.error(LOG, "write(): path must be a non-empty string without NUL.")
		return false
	end
	content = type(content) == "string" and content or ""

	local ok, result = pcall(function()
		local fh, err = io.open(path, "w")
		if not fh then
			Logger.error(LOG, "write(): cannot open '%s' for writing — %s", path, tostring(err))
			return false
		end
		return write_and_close(fh, content, path, "write")
	end)

	if not ok then
		Logger.error(LOG, "write(): unexpected error on '%s' — %s", path, tostring(result))
		return false
	end
	return result == true
end

--- Appends content to a file, creating it if it does not exist.
--- @param path    string Absolute path to the file.
--- @param content string UTF-8 content to append.
--- @return boolean true on success, false on any error.
function M.append(path, content)
	if not valid_native_path(path) then
		Logger.error(LOG, "append(): path must be a non-empty string without NUL.")
		return false
	end
	content = type(content) == "string" and content or ""

	local ok, result = pcall(function()
		local fh, err = io.open(path, "a")
		if not fh then
			Logger.error(LOG, "append(): cannot open '%s' for appending — %s", path, tostring(err))
			return false
		end
		return write_and_close(fh, content, path, "append")
	end)

	if not ok then
		Logger.error(LOG, "append(): unexpected error on '%s' — %s", path, tostring(result))
		return false
	end
	return result == true
end

--- Returns true if a file or directory exists at the given path.
--- @param path string Absolute path to test.
--- @return boolean true if the path exists, false otherwise.
function M.exists(path)
	if not valid_native_path(path) then return false end

	-- Metadata does not need read permission and never waits on a FIFO/socket.
	if native_stat then
		local ok, attrs = pcall(native_stat, path)
		return ok and attrs ~= nil
	end
	if native_exists then
		local ok, present = pcall(native_exists, path)
		return ok and present == true
	end

	-- Minimal Lua installations still have the POSIX shell's metadata builtin.
	-- Opening the path here mistook unreadability for absence and blocked FIFOs.
	local ok, present = pcall(function()
		local Shell = require("adapters.shell_runner")
		return Shell.run("test -e " .. Shell.quote(path) .. " 2>/dev/null")
	end)
	return ok and present == true
end

--- Deletes a file. Returns true if the file was deleted or was already absent.
--- @param path string Absolute path to the file to delete.
--- @return boolean true on success or file-not-found, false on any other error.
function M.delete(path)
	if not valid_native_path(path) then
		Logger.error(LOG, "delete(): path must be a non-empty string without NUL.")
		return false
	end

	-- A stat/open refusal is ambiguous and follows symlinks. Delete the path
	-- itself and classify the native receipt instead of racing an existence probe.
	local ok, removed, detail, errno = pcall(os.remove, path)
	if ok and (removed == true or errno == ENOENT) then return true end
	Logger.error(LOG, "delete(): os.remove failed for '%s' — %s", path,
		tostring(ok and detail or removed))
	return false
end

return M
