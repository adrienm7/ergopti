--- modules/keystats/studio_snapshot.lua

--- ==============================================================================
--- MODULE: Ergopti Studio Saved Read (Linux)
--- DESCRIPTION:
--- The file ports of Ergopti Studio's saved « My typing » read: the last
--- complete projection of metrics.sqlite, kept beside it in the XDG data
--- folder (_shared/metrics/engine/view/studio_ngrams.lua owns its format,
--- path and use).
---
--- FEATURES & RATIONALE:
--- 1. As private as the store: the counts come from what the user typed, so
---    the file is created 0600 by the store's own permission policy
---    (core/fs/engine/private_sqlite_file.lua) before a byte is written, even
---    when the selected folder is shared.
--- 2. Atomic: a private staging file, then a rename. A failed save leaves the
---    previous read whole.
--- 3. Classified reads: an unreadable file is a failure, never an absence, so
---    a broken saved read is logged rather than silently skipped.
--- 4. Retired by the metrics purge and the dashboard cache reset, through
---    retire(): the Studio never shows at once what the user deleted.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "keystats.studio_snapshot"





-- =============================
-- =============================
-- ======= 1/ File ports =======
-- =============================
-- =============================

--- Reads a saved read, its absence told apart from a failed read.
--- @param path string The saved read's file.
--- @return string|nil content
--- @return string status "ok", "absent" or a failure.
function M.read(path)
	local content, status = require("core.fs.adapters.file_system").read_with_status(path)
	return content, status
end

--- Saves a read atomically, private from its creation.
--- @param path string The saved read's file.
--- @param text string The saved read (studio_ngrams.encode_snapshot).
--- @return boolean written
function M.write(path, text)
	local FileSystem = require("core.fs.adapters.file_system")
	local temp = path .. ".tmp"
	local private, failure = require("core.fs.engine.private_sqlite_file").admit(temp)
	if not private then
		Logger.error(LOG, "The saved Ergopti Studio read has no private staging file: %s.", tostring(failure))
		return false
	end
	if FileSystem.write(temp, text) ~= true then
		FileSystem.delete(temp)
		return false
	end
	local called, renamed, err = pcall(os.rename, temp, path)
	if not called or renamed ~= true then
		FileSystem.delete(temp)
		Logger.error(LOG, "The saved Ergopti Studio read could not be published: %s.", tostring(called and err or renamed))
		return false
	end
	return true
end

--- The snapshot ports studio_ngrams.read takes.
--- @return table { read, write }.
function M.ports()
	return { read = M.read, write = M.write }
end

--- Removes the saved read of a store.
--- @param store_path string metrics.sqlite.
--- @return boolean retired True when no saved read remains.
function M.retire(store_path)
	return require("metrics.engine.view.studio_ngrams").retire_snapshot(store_path,
		require("core.fs.adapters.file_system").delete)
end

return M
