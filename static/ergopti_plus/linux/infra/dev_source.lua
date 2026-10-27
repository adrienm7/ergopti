--- infra/dev_source.lua

--- ==============================================================================
--- MODULE: Developer Source Mode (Linux)
--- DESCRIPTION:
--- Answers whether this daemon is a developer run of a repository clone
--- (bash tools/dev/run-linux-dev.sh), and resolves what such a run needs that
--- an installed daemon finds in its install layout: the launcher that starts
--- it again on Reload, and the source trees whose saved .lua edits restart it.
---
--- FEATURES & RATIONALE:
--- 1. Launcher authority: only the developer launcher exports the clone root
---    (Identifiers.dev_source.environment, the variable the macOS developer app
---    uses), so an installed daemon never sees one.
--- 2. Exact match: the root must name the clone this very driver runs from. A
---    root naming another tree is an invalid state and raises, instead of
---    restarting or watching a tree that is not the one running.
--- 3. Same restart path: a checkout has no install-layout wrapper, so the
---    daemon restart relays the developer launcher itself, which starts the
---    same install/launch.sh entry point as the packages.
--- 4. Pure resolution: the environment reader and the driver root are
---    parameters, so every branch is tested without a daemon.
--- ==============================================================================

local Identifiers = require("identifiers")

local M = {}

--- Environment variable naming the clone root, set only by the developer launcher.
M.ENVIRONMENT = Identifiers.dev_source.environment
--- The driver folder inside a clone.
M.DRIVER_SUBPATH = "/static/ergopti_plus/linux"
--- The shared Lua tree inside a clone, reloaded like the driver's own sources.
M.SHARED_LUA_SUBPATH = "/static/ergopti_plus/_shared/lua"
--- The developer launcher inside a clone, relayed by a Reload.
M.LAUNCHER_SUBPATH = "/tools/dev/run-linux-dev.sh"

-- Cached root of this process; false once resolved as "not a developer run".
local _resolved = nil





-- ==================================
-- ==================================
-- ======= 1/ Mode Resolution =======
-- ==================================
-- ==================================

--- Resolves the clone root of a developer run.
--- @param getenv function Environment reader.
--- @param driver_root string|nil Absolute folder of the running driver.
--- @return string|nil root Clone root, or nil for an ordinary daemon.
function M.resolve(getenv, driver_root)
	local root = getenv(M.ENVIRONMENT)
	if root == nil or root == "" then return nil end
	if type(root) ~= "string" or root:sub(1, 1) ~= "/" or root:sub(-1) == "/" then
		error(M.ENVIRONMENT .. " is not a plain absolute clone path", 0)
	end
	if driver_root ~= root .. M.DRIVER_SUBPATH then
		error(string.format("%s names the clone %s, but this driver runs from %s",
			M.ENVIRONMENT, root, tostring(driver_root)), 0)
	end
	return root
end

--- Returns the clone root of this process, or nil when it is not a developer run.
--- Raises when the launcher's root does not name the running driver.
--- @return string|nil root
function M.root()
	if _resolved == nil then
		_resolved = M.resolve(os.getenv, require("infra.paths").driver_root()) or false
	end
	return _resolved or nil
end

--- Reports whether this process is a developer run.
--- @return boolean
function M.is_active()
	return M.root() ~= nil
end





-- ======================================
-- ======================================
-- ======= 2/ Developer Resources =======
-- ======================================
-- ======================================

--- The installation context a Reload relays in a developer run, shaped as
--- modules/updater/installer.resolve() answers for a standalone installation.
--- @param root string|nil Clone root; the running one when nil.
--- @return table|nil context { kind = "standalone", wrapper = string }, nil outside a developer run.
function M.restart_context(root)
	root = root or M.root()
	if not root then return nil end
	return { kind = "standalone", wrapper = root .. M.LAUNCHER_SUBPATH, reason = "developer source run" }
end

--- The source trees whose saved .lua edits restart a developer run.
--- @param root string|nil Clone root; the running one when nil.
--- @return table|nil dirs Absolute folders, nil outside a developer run.
function M.source_dirs(root)
	root = root or M.root()
	if not root then return nil end
	return { root .. M.DRIVER_SUBPATH, root .. M.SHARED_LUA_SUBPATH }
end

--- Test seam: forgets the cached resolution.
function M._reset_for_test()
	_resolved = nil
end

return M
