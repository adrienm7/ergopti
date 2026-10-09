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

--- Collects entry names while preserving whether enumeration succeeded.
--- @param dir string Absolute directory path.
--- @return table names Array of entry names.
--- @return boolean listed Whether the whole directory was enumerated.
--- @return string|nil error_message
local function collect_entries(dir)
	local names = {}
	if type(dir) ~= "string" or dir == "" then return names, false, "invalid directory path" end
	local ok, err = pcall(function()
		for name in hs.fs.dir(dir) do
			names[#names + 1] = name
		end
	end)
	if not ok then
		Logger.error(LOG, "Cannot iterate directory '%s' — %s.", tostring(dir), tostring(err))
		return {}, false, tostring(err)
	end
	return names, true
end

--- Lists the entry names of a directory, surviving an unreadable folder.
--- @param dir string Absolute directory path.
--- @return table Array of entry names; empty when the directory is unreadable.
function M.entries(dir)
	local names = collect_entries(dir)
	return names
end

--- Lists a directory and reports whether an empty result is authoritative.
--- Callers making safety decisions must use this form so an unreadable parent
--- cannot be confused with a successfully listed empty directory.
--- @param dir string Absolute directory path.
--- @return table names Array of entry names.
--- @return boolean listed Whether the whole directory was enumerated.
--- @return string|nil error_message
function M.try_entries(dir)
	return collect_entries(dir)
end

--- Collects bounded private names without logging native pathname or error text.
--- The bundled Lua 5.4 directory factory supplies its fourth closing value;
--- generic-for closes that exact state on exhaustion, early break and errors.
--- This observes the public API close, not an unavailable closedir errno receipt.
--- @param dir string Absolute directory path.
--- @param limit number Maximum retained entry count.
--- @return table|nil listing Dense names and an explicit truncation flag.
--- @return string|nil reason Closed failure category.
function M.collect_private(dir, limit)
	if type(dir) ~= "string" or dir:sub(1, 1) ~= "/" or dir:find("\0", 1, true)
		or type(limit) ~= "number" or limit < 1 or limit > 256 or limit % 1 ~= 0 then
		return nil, "listing_refused"
	end
	local listing = { names = {}, truncated = false }
	local ok = pcall(function()
		for name in hs.fs.dir(dir) do
			if type(name) ~= "string" or name == "" or #name > 4096
				or name:find("\0", 1, true) or name:find("/", 1, true) then
				error("listing_refused", 0)
			end
			if name ~= "." and name ~= ".." then
				if #listing.names == limit then listing.truncated = true; break end
				listing.names[#listing.names + 1] = name
			end
		end
	end)
	if not ok then return nil, "listing_refused" end
	return listing
end

return M
