--- lib/paths.lua

--- ==============================================================================
--- MODULE: Linux Path Resolver
--- DESCRIPTION:
--- Single source of truth for where the shared tree lives, mirroring the macOS
--- lib/paths.lua and windows/lib/boot.ahk.
---
--- WHY THIS EXISTS — TWO SHIPPED BUGS, SAME CAUSE:
--- Every Linux module used to derive `_shared` itself, from its own file's
--- location, with its own number of `..` steps. Twelve such expressions existed,
--- at four different depths, and two of them were wrong:
---
---   * lib/i18n.lua walked `../../` from the driver root to reach
---     `_shared/data/locales`. One level too high. `ls` on the missing directory
---     printed nothing, the scan collected zero codes, and the fallback list
---     `{"en", "fr"}` took over — so the language menu offered 2 locales out of
---     the 21 that ship. Nothing failed; the menu just quietly had two rows.
---
---   * modules/keylogger/sqlite_writer.lua walked `../../../` for
---     `_shared/data/db/schema.sql`. Two levels too high, with a bare relative
---     path as the fallback — which made schema loading depend on the process's
---     CURRENT DIRECTORY rather than on where the driver is installed.
---
--- Both are the same failure: a path derived per-file cannot be verified, and a
--- wrong one degrades silently instead of failing. This module derives the root
--- once, from its own location, and every caller asks it.
---
--- FEATURES & RATIONALE:
--- 1. Self-locating: the root comes from debug.getinfo on THIS file, so it is
---    correct wherever the driver is installed and independent of the CWD.
--- 2. Fails loudly: shared_root() returns nil when the tree is not found, and
---    shared() logs which path it looked for — a missing shared tree is a broken
---    install, not something to paper over with a fallback that half-works.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "paths"




-- =========================================
-- =========================================
-- ======= 1/ Root resolution ==============
-- =========================================
-- =========================================

--- The driver root (…/static/ergopti_plus/linux), derived from this file.
--- @return string Absolute path, forward slashes, no trailing slash.
local function driver_root()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	src = src:gsub("\\", "/")
	-- src is <driver root>/lib/paths.lua
	return src:match("^(.*)/lib/paths%.lua$") or "."
end

local _driver_root = driver_root()
local _shared_root = nil

--- Absolute path to the _shared tree, or nil when it cannot be found.
---
--- `_shared` is a SIBLING of the driver directory — one level up, never two.
--- The check is for a file that must exist rather than for the directory alone,
--- because a stale empty `_shared/` left by a partial install would otherwise
--- resolve and then fail at every read.
--- @return string|nil Absolute path with no trailing slash.
function M.shared_root()
	if _shared_root ~= nil then return _shared_root end
	local candidate = _driver_root .. "/../_shared"
	local probe = io.open(candidate .. "/data/locales/en.json", "r")
	if probe then
		probe:close()
		_shared_root = candidate
		return _shared_root
	end
	Logger.error(LOG, "Shared tree not found at %s — the install is incomplete.", candidate)
	return nil
end

--- Absolute path to a file or directory inside the shared tree.
--- @param rel string Path relative to _shared, e.g. "data/db/schema.sql".
--- @return string|nil Absolute path, or nil when the shared tree is missing.
function M.shared(rel)
	local root = M.shared_root()
	if not root then return nil end
	if type(rel) ~= "string" or rel == "" then return root end
	return (root .. "/" .. (rel:gsub("^/", "")))
end

--- The driver root, for callers that need a driver-relative path.
--- @return string Absolute path with no trailing slash.
function M.driver_root()
	return _driver_root
end

return M
