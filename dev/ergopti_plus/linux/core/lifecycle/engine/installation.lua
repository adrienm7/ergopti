--- core/lifecycle/engine/installation.lua

--- ==============================================================================
--- MODULE: Installed Build Or Source Run (Linux)
--- DESCRIPTION:
--- The one answer to « is this daemon an installed ErgoptiPlus, or a local
--- version run from a source checkout? ». The About menu's Uninstall and
--- Update rows, the uninstall action and the Versions window's install
--- buttons all ask here. They had three answers: the uninstall action matched
--- the install layout itself, the Versions window read the missing build
--- stamp, and the Update row asked neither.
---
--- FEATURES & RATIONALE:
--- 1. An install layout is an installed build. The system packages stage the
---    driver flat under /usr/lib/ergopti; install.sh puts it at
---    <prefix>/lib/ergopti/linux. install.sh stamps a checkout copy only with
---    its commit (source=checkout, no release version), so that tree is still
---    a local version, installed.
--- 2. A build stamp is a build, wherever it runs from: the release packages and
---    bundles carry the stamp tools/build/write_build_stamp.sh writes.
--- 3. Anything else is a source run: an unstamped tree outside every install
---    layout, which is what a checkout is.
--- ==============================================================================

local M = {}

local Paths   = require("core.fs.engine.paths")
local Version = require("infra.version")

-- The flat driver folder a package stages under its install prefix.
local PACKAGED_DIR = "/lib/ergopti"
-- Where the system packages (.deb, .rpm, PKGBUILD) stage the driver.
M.SYSTEM_ROOT = "/usr" .. PACKAGED_DIR





-- ==============================
-- ==============================
-- ======= 1/ The Answers =======
-- ==============================
-- ==============================

--- Where a driver root sits among the install layouts.
--- @param root string Absolute driver root.
--- @return table layout { system = boolean, prefix = string|nil }: system for
---   the system packages' root, prefix for install.sh's --prefix.
function M.layout(root)
	if root == M.SYSTEM_ROOT then return { system = true } end
	local prefix = type(root) == "string" and root:match("^(.*)/lib/ergopti/linux$") or nil
	return { system = false, prefix = prefix }
end

--- The flat driver root a package stages under one install prefix: /usr for
--- the system packages, the host deployment of a Flatpak's /app.
--- @param prefix string Absolute install prefix.
--- @return string root
function M.packaged_root(prefix)
	assert(type(prefix) == "string" and prefix:sub(1, 1) == "/", "an absolute install prefix")
	return prefix .. PACKAGED_DIR
end

--- Whether this daemon is a local version run from source.
--- @param root string|nil Driver root; the running one when nil.
--- @param version_source string|nil A Version.SOURCE_* value; the running one when nil.
--- @return boolean source_run
function M.is_source_run(root, version_source)
	local layout = M.layout(root or Paths.driver_root())
	if layout.system or layout.prefix then return false end
	return (version_source or Version.SOURCE) == Version.SOURCE_LOCAL
end

return M
