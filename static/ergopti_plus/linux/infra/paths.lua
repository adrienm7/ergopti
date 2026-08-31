--- infra/paths.lua

--- ==============================================================================
--- MODULE: Linux Path Resolver
--- DESCRIPTION:
--- Single source of truth for where the shared tree lives, mirroring the macOS
--- infra/paths.lua and windows/infra/boot.ahk.
---
--- WHY THIS EXISTS — TWO SHIPPED BUGS, SAME CAUSE:
--- Every Linux module used to derive `_shared` itself, from its own file's
--- location, with its own number of `..` steps. Twelve such expressions existed,
--- at four different depths, and two of them were wrong:
---
---   * infra/i18n.lua walked `../../` from the driver root to reach
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
--- 3. Layout-tolerant, not layout-guessing: the two layouts that actually ship
---    are both probed, in a fixed order, and nothing else is. See shared_root().
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "paths"

-- The file a candidate directory must carry to BE the shared tree. Probing a
-- file rather than the directory keeps a stale empty `_shared/` left by a
-- partial install from resolving and then failing at every subsequent read.
local SHARED_PROBE_FILE = "data/locales/en.json"




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
	-- src is <driver root>/infra/paths.lua
	return src:match("^(.*)/infra/paths%.lua$") or "."
end

local _driver_root = driver_root()
local _shared_root = nil

local function shared_probe(path)
	local handle = io.open(path, "r")
	if not handle then return false end
	handle:close()
	return true
end

--- Resolves the shared tree beside or inside an explicit driver root.
--- This is the non-memoised seam used to validate a staged update before it
--- replaces the running tree; it deliberately applies the same probe and
--- precedence as shared_root().
--- @param root string Absolute driver root.
--- @param probe function|nil Predicate receiving the complete probe-file path.
--- @return string|nil Absolute shared root with no trailing slash.
function M.shared_root_from(root, probe)
	if type(root) ~= "string" or root == "" then return nil end
	local exists = type(probe) == "function" and probe or shared_probe
	local sibling = root .. "/../_shared"
	local child = root .. "/_shared"
	for _, candidate in ipairs({ sibling, child }) do
		if exists(candidate .. "/" .. SHARED_PROBE_FILE) then return candidate end
	end
	return nil
end

--- Absolute path to the _shared tree, or nil when it cannot be found.
---
--- TWO LAYOUTS SHIP, AND BOTH ARE REAL:
---
---   * SIBLING — `<driver root>/../_shared`. The checkout
---     (static/ergopti_plus/{linux,_shared}) and the release tarball, which
---     unpacks `linux/` and `_shared/` next to each other.
---
---   * CHILD — `<driver root>/_shared`. The system packages. build-linux-deb.sh,
---     build-linux-rpm.sh and PKGBUILD all stage the driver flat into
---     /usr/lib/ergopti and nest the shared tree inside it, because a sibling
---     would put it at /usr/lib/_shared — a directory no package may own.
---
--- Resolving the sibling ONLY is the defect this ordering replaced. On an
--- installed .deb the probe addressed /usr/lib/_shared/data/locales/en.json and
--- shared_root() returned nil — taking with it every locale, keycode table,
--- hotstring pack, tooltip config and defaults file the driver reads. The
--- wrapper's LUA_PATH hides how broad that is: it rescues `require`, so the
--- daemon starts and only the DATA reads fail.
---
--- The sibling is probed first because it is the layout every developer, test
--- and CI run uses, so the common case still costs a single io.open.
--- @return string|nil Absolute path with no trailing slash.
function M.shared_root()
	if _shared_root ~= nil then return _shared_root end
	local sibling = _driver_root .. "/../_shared"
	local child   = _driver_root .. "/_shared"
	_shared_root = M.shared_root_from(_driver_root)
	if _shared_root then return _shared_root end
	-- Both candidates are named because the next reader's first question is which
	-- layout was assumed, and a message carrying one path answers half of it.
	Logger.error(LOG, "Shared tree not found: neither %s nor %s carries %s — the install is incomplete.",
		sibling, child, SHARED_PROBE_FILE)
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

--- The directories extension packs are installed into, in precedence order.
---
--- The bundled root is a SIBLING of _shared and of this driver, not a child of
--- either: extensions are shipped to all three drivers from one place, which is
--- why the Windows driver's `_ExtensionsDir` points at the same directory. The
--- user root comes second so an extension installed by the user overrides a
--- bundled one of the same id — the overlay rule the hotstring packs already use.
--- @return table Array of absolute paths; may be empty when neither exists.
function M.extension_roots()
	local roots = {}
	local shared = M.shared_root()
	if shared then
		-- _shared/../extensions — resolved from the shared root because that is the
		-- one anchor already probed for existence above.
		roots[#roots + 1] = shared .. "/../extensions"
	end
	local ok_cfg, ConfigPaths = pcall(require, "infra.config_paths")
	if ok_cfg and type(ConfigPaths.home) == "function" then
		roots[#roots + 1] = ConfigPaths.home() .. "/.config/ergopti/extensions"
	end
	return roots
end

return M
