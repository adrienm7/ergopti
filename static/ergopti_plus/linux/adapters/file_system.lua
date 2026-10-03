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
--- 4. exists() via lfs: LuaFileSystem (lfs) is the idiomatic way to stat a
---    path on Linux; the adapter falls back to io.open when lfs is absent.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.file_system"

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


-- ========================================
-- ========================================
-- ======= 1/ Adapter Methods =============
-- ========================================
-- ========================================

--- Reads the entire contents of a file as a string.
--- @param path string Absolute path to the file.
--- @return string|nil File contents, or nil on any error.
function M.read(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "read(): path must be a non-empty string.")
		return nil
	end

	local ok, result = pcall(function()
		local fh, err = io.open(path, "r")
		if not fh then
			Logger.debug(LOG, "read(): cannot open '%s' — %s", path, tostring(err))
			return nil
		end
		local content = fh:read("*a")
		fh:close()
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
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "write(): path must be a non-empty string.")
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
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "append(): path must be a non-empty string.")
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
	if type(path) ~= "string" or path == "" then return false end

	-- Prefer lfs.attributes which performs a stat() syscall directly.
	if lfs then
		local ok, attrs = pcall(lfs.attributes, path)
		return ok and attrs ~= nil
	end

	-- Fallback: attempt to open the path as a regular file.
	local ok, fh = pcall(io.open, path, "r")
	if ok and fh then
		fh:close()
		return true
	end
	return false
end

--- Deletes a file. Returns true if the file was deleted or was already absent.
--- @param path string Absolute path to the file to delete.
--- @return boolean true on success or file-not-found, false on any other error.
function M.delete(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "delete(): path must be a non-empty string.")
		return false
	end

	-- Already absent — contract says this is a no-op success.
	if not M.exists(path) then return true end

	local ok, result = pcall(os.remove, path)
	if not ok or not result then
		Logger.error(LOG, "delete(): os.remove failed for '%s' — %s", path, tostring(result))
		return false
	end
	return true
end

return M
