--- modules/keystats/studio_snapshot.lua

--- ==============================================================================
--- MODULE: Ergopti Studio Saved Read (macOS)
--- DESCRIPTION:
--- The file ports of Ergopti Studio's saved « My typing » read: the last
--- complete projection of db.sqlite, kept beside it in the keystats cache
--- folder (_shared/metrics/engine/view/studio_ngrams.lua owns its format,
--- path and use).
---
--- FEATURES & RATIONALE:
--- 1. Atomic: the FileSystem port publishes a staged copy, so a failed save
---    leaves the previous read whole.
--- 2. Classified reads: an unreadable file is a failure, never an absence, so
---    a broken saved read is logged rather than silently skipped.
--- 3. Retired by the metrics purge and the dashboard cache reset, through
---    retire(): the Studio never shows at once what the user deleted.
--- ==============================================================================

local M = {}

local FileSystem = require("core.fs.adapters.file_system")

--- The snapshot ports studio_ngrams.read takes.
--- @return table { read = function(path) -> content, status, write = function(path, text) -> boolean }.
function M.ports()
	return {
		read = function(path)
			local content, status = FileSystem.read_with_status(path)
			return content, status
		end,
		write = function(path, text) return FileSystem.write(path, text) == true end,
	}
end

--- Removes the saved read of a store.
--- @param store_path string|nil db.sqlite; nil while keystats never started (nothing saved).
--- @return boolean retired True when no saved read remains.
function M.retire(store_path)
	if store_path == nil then return true end
	return require("metrics.engine.view.studio_ngrams").retire_snapshot(store_path, FileSystem.delete)
end

return M
