--- adapters/file_system.lua

--- ==============================================================================
--- MODULE: FileSystem Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the FileSystem port contract defined in
--- static/ergopti_plus/_shared/core/ports/FileSystem.spec.js. Wraps Lua's io.open and
--- hs.fs behind the five canonical methods (read, write, append, exists, delete)
--- so domain modules perform file I/O without coupling to OS-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. UTF-8 everywhere: all reads and writes use the "r"/"w"/"a" modes which
---    pass raw bytes through. Hammerspoon on macOS runs in a UTF-8 locale so
---    string content is already UTF-8 by default.
--- 2. Fail-safe returns: read() returns nil on any error; write/append/delete
---    return false. No exceptions propagate to the caller.
--- 3. Defensive pcall: every io.open / hs.fs call is wrapped in pcall because
---    permission errors and locked files can panic the Lua runtime.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.file_system"




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
		-- Inner pcall ensures fh:close() always runs even when read() panics
		-- (e.g. an I/O error mid-read on a file that was truncated after open)
		local read_ok, content = pcall(function() return fh:read("*a") end)
		fh:close()
		if not read_ok then return nil end
		return content
	end)

	if not ok then
		Logger.error(LOG, "read(): unexpected error on '%s' — %s", path, tostring(result))
		return nil
	end
	return result
end

--- Ensures all intermediate directories on the path exist.
--- Walks up the directory chain and creates any missing nodes via hs.fs.mkdir.
--- Silently succeeds when the full chain already exists.
--- @param dir string Absolute directory path to create.
local function ensure_dir(dir)
	if not dir or dir == "" or dir == "/" then return end
	-- Skip if the directory already exists
	if hs.fs.attributes(dir, "mode") == "directory" then return end
	-- Recursively ensure the parent exists first
	local parent = dir:match("^(.+)/[^/]+$")
	if parent and parent ~= dir then ensure_dir(parent) end
	pcall(function() hs.fs.mkdir(dir) end)
end

--- Writes content to a file atomically (temp file + rename), overwriting any
--- existing content. Creates parent directories when they do not exist.
--- A crash or process kill mid-write can never leave a torn/truncated file at
--- `path` — a reader (e.g. Karabiner-Elements' own FSEvents watcher on
--- karabiner.json) either sees the old complete content or the new complete
--- content, never a partial write (filesystem-adapter-nonatomic-write).
--- Symlink-safe: if `path` is (or resolves through) a symlink, the temp file
--- is written and renamed at the RESOLVED real target, so the symlink itself
--- is left untouched — renaming directly over a symlink path would otherwise
--- replace the symlink with a plain file, breaking the documented
--- "deploy_string works for regular paths and Unix symlinks" contract.
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
		-- Guarantee parent directories exist; io.open("w") fails silently on a
		-- fresh machine where the containing folder has never been created
		-- (filesystem-adapter-missing-mkdir).
		local dir = path:match("^(.+)/[^/]+$")
		if dir then ensure_dir(dir) end

		-- Resolve `path` to its real target BEFORE writing, so a rename lands on
		-- the file a symlink points to rather than replacing the symlink itself.
		-- pathToAbsolute returns nil when nothing exists yet at `path` — in that
		-- case there is no symlink to preserve, so fall back to `path` verbatim.
		local real_path = path
		if hs and hs.fs and type(hs.fs.pathToAbsolute) == "function" then
			local ok_abs, abs = pcall(hs.fs.pathToAbsolute, path)
			if ok_abs and type(abs) == "string" and abs ~= "" then
				real_path = abs
			end
		end

		local tmp_path = real_path .. ".tmp"
		local fh, err  = io.open(tmp_path, "w")
		if not fh then
			Logger.error(LOG, "write(): cannot open '%s' for writing — %s", tmp_path, tostring(err))
			return false
		end
		local write_ok, write_err = pcall(function() fh:write(content) end)
		fh:close()
		if not write_ok then
			Logger.error(LOG, "write(): write failed for '%s' — %s", tmp_path, tostring(write_err))
			pcall(os.remove, tmp_path)
			return false
		end

		local rename_ok, rename_err = os.rename(tmp_path, real_path)
		if not rename_ok then
			-- POSIX rename() atomically replaces an existing destination; some
			-- non-POSIX os.rename implementations instead fail with "File exists"
			-- when the destination is already present. Retry once after removing
			-- the stale destination so the adapter behaves consistently across
			-- test/dev environments — production (macOS/Hammerspoon) never needs
			-- this fallback since its os.rename is already atomic-replace.
			pcall(os.remove, real_path)
			rename_ok, rename_err = os.rename(tmp_path, real_path)
		end
		if not rename_ok then
			Logger.error(LOG, "write(): rename '%s' -> '%s' failed — %s", tmp_path, real_path, tostring(rename_err))
			pcall(os.remove, tmp_path)
			return false
		end
		return true
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
		local write_ok, write_err = pcall(function() fh:write(content) end)
		fh:close()
		if not write_ok then
			Logger.error(LOG, "append(): write failed for '%s' — %s", path, tostring(write_err))
			return false
		end
		return true
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

	-- hs.fs.attributes returns a table on success, nil on failure
	if hs and hs.fs and type(hs.fs.attributes) == "function" then
		local ok, attrs = pcall(hs.fs.attributes, path)
		return ok and attrs ~= nil
	end

	-- Fallback: try to open as a file
	local ok, fh = pcall(io.open, path, "r")
	if ok and fh then
		fh:close()
		return true
	end
	return false
end

--- Expands a path that may begin with "~" to an absolute path.
--- Delegates to hs.fs.pathToAbsolute so the result follows macOS symlink
--- resolution (important for ~/.config which may be a symlink on some setups).
--- Falls back to naive HOME substitution when hs.fs is unavailable (unit tests).
--- @param path string Path to expand (may start with "~").
--- @return string Expanded absolute path.
function M.expand_path(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "expand_path(): path must be a non-empty string.")
		return path or ""
	end

	if hs and hs.fs and type(hs.fs.pathToAbsolute) == "function" then
		local ok, abs = pcall(hs.fs.pathToAbsolute, path)
		if ok and type(abs) == "string" and abs ~= "" then
			return abs
		end
		-- pathToAbsolute returns nil when the path does not exist yet — fall
		-- through to naive expansion so callers can still build paths for files
		-- that have not been created yet.
	end

	-- Naive fallback: replace leading "~" with HOME env var
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end


--- Deletes a file. Returns true if the file was deleted or was already absent.
--- @param path string Absolute path to the file to delete.
--- @return boolean true on success or file-not-found, false on any other error.
function M.delete(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "delete(): path must be a non-empty string.")
		return false
	end

	-- Already absent — contract says this is a no-op success
	if not M.exists(path) then return true end

	local ok, result = pcall(os.remove, path)
	if not ok or not result then
		Logger.error(LOG, "delete(): os.remove failed for '%s' — %s", path, tostring(result))
		return false
	end
	return true
end

return M
