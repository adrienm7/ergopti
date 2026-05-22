--- lib/paths.lua

--- ==============================================================================
--- MODULE: Paths
--- DESCRIPTION:
--- Utility helpers for resolving file-system paths relative to hs.configdir.
---
--- FEATURES & RATIONALE:
--- 1. Resilient Discovery: Walks up the directory tree to find a target path
---    rather than relying on brittle suffix-strip patterns. This is necessary
---    because hs.configdir can differ between dev (repo checkout) and packaged
---    .app builds where macOS resolves symlinks or adds path prefixes at runtime.
--- 2. Single Source of Truth: All hs.configdir-relative path resolution goes
---    through this module so a future change to the repo layout only needs to
---    be fixed here.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local LOG    = "paths"




-- =========================================
--- ==========================================
-- ======= 1/ Directory-walk resolver =======
--- ==========================================
-- =========================================

--- Walks up the directory tree from ``base_dir`` looking for a file or directory
--- whose path relative to the current level matches ``relative_target``.
--- Returns the first matching absolute path, or nil if not found within
--- ``max_steps`` levels.
---
--- Example — find ``static/locales`` starting from hs.configdir:
---   M.find_upward(hs.configdir, "static/locales")
---
--- @param base_dir string Starting directory (trailing slash optional).
--- @param relative_target string Relative path to look for at each level, e.g. ``"static/locales"``.
--- @param max_steps number|nil Maximum levels to climb (default: 8).
--- @return string|nil Absolute path to the match, or nil.
function M.find_upward(base_dir, relative_target, max_steps)
	max_steps = max_steps or 8
	local current = (base_dir or ""):gsub("[/\\]+$", "")
	for _ = 1, max_steps do
		local candidate = current .. "/" .. relative_target
		local ok, attr = pcall(hs.fs.attributes, candidate)
		if ok and type(attr) == "table" then
			Logger.debug(LOG, "find_upward('%s'): found at '%s'.", relative_target, candidate)
			return candidate
		end
		local parent = current:match("^(.*)[/\\][^/\\]+$")
		if not parent or parent == current then break end
		current = parent
	end
	Logger.warn(LOG, "find_upward('%s'): not found within %d levels of '%s'.", relative_target, max_steps, base_dir)
	return nil
end

--- Convenience wrapper: walks up from hs.configdir looking for ``relative_target``.
--- Returns the absolute path to the match, or nil.
--- @param relative_target string Relative path to look for, e.g. ``"static/locales"``.
--- @param max_steps number|nil Maximum levels to climb (default: 8).
--- @return string|nil
function M.find_from_configdir(relative_target, max_steps)
	return M.find_upward(hs.configdir or "", relative_target, max_steps)
end

return M
