--- infra/fs_dir.lua

--- ==============================================================================
--- MODULE: Filesystem Directory Listing
--- DESCRIPTION:
--- One blessed wrapper around hs.fs.dir() that honours its two traps in exactly
--- one place, shared by every consumer (boot-time hotstring discovery, the
--- hotstrings config window, …) so the contract can never drift between copies.
---
--- FEATURES & RATIONALE:
--- 1. Throw-safe: hs.fs.dir() THROWS on a missing / permission-denied directory.
---    The iteration runs INSIDE a pcall so an inaccessible folder is logged, not
---    fatal (init-fsdir-pcall).
--- 2. State-safe: hs.fs.dir() returns TWO values — the iterator AND a directory
---    state object the iterator REQUIRES as its first argument. Iterating INSIDE
---    the pcall keeps both; capturing only the iterator
---    (`local ok, it = pcall(hs.fs.dir, dir)`) drops the state and real Hammerspoon
---    aborts with "directory metatable expected, got nil" on the first step — the
---    boot crash a lenient test stub once masked (init-fsdir-drops-state).
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "fs_dir"





-- ====================================
-- ====================================
-- ======= 1/ Directory Listing =======
-- ====================================
-- ====================================

--- Lists the entry names of a directory, surviving an unreadable folder.
--- @param dir string Absolute directory path.
--- @return table Array of entry names; empty when the directory is unreadable.
function M.entries(dir)
	local names = {}
	if type(dir) ~= "string" or dir == "" then return names end
	local ok, err = pcall(function()
		for name in hs.fs.dir(dir) do
			names[#names + 1] = name
		end
	end)
	if not ok then
		Logger.error(LOG, "Cannot iterate directory '%s' — %s.", tostring(dir), tostring(err))
		return {}
	end
	return names
end

return M
