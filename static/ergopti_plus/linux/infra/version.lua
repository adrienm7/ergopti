--- infra/version.lua

--- ==============================================================================
--- MODULE: Driver Version (Linux)
--- DESCRIPTION:
--- Single owner of the Linux driver's version string. Every surface that shows a
--- version — the tray menu header, the healthcheck, the boot snapshot, the crash
--- dump, the updater — reads M.VERSION from here.
---
--- FEATURES & RATIONALE:
--- 1. The release build stamps it. The version used to be a "3.0.0" literal that
---    no build rewrote, while releases are published as 0.0.0-dev.N and N.N.N:
---    every installed driver showed a version that never existed, and the
---    updater compared releases against it. tools/build/write_build_stamp.sh now
---    writes `version=` next to `commit=` in the shared tree's build stamp,
---    from the version the workflow's release job resolved.
--- 2. A source run has no stamp and reports M.LOCAL, the token the macOS driver
---    and the Linux updater already use for "running from a checkout".
--- 3. A package without a usable version (a CI test build, a broken stamp)
---    reports M.UNKNOWN with the reason logged, never a guessed number.
--- 4. Semver build metadata is dropped by the shared parser, so "+<build>" is
---    never shown.
--- ==============================================================================

local M = {}

local Logger   = require("logger.shim")
local Snapshot = require("diagnostics.snapshot")
local Paths    = require("infra.paths")

local LOG = "Version"

-- Version reported by a source checkout, which carries no build stamp.
M.LOCAL = "local"

-- Version reported by a package whose stamp holds no usable version.
M.UNKNOWN = Snapshot.UNKNOWN

-- Where M.VERSION came from.
M.SOURCE_BUILD = "build"
M.SOURCE_LOCAL = "local"
M.SOURCE_UNKNOWN = "unknown"

--- Reads a whole file, nil when it cannot be opened.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Resolves the driver version from the shared tree's build stamp.
--- @param opts table|nil { fs = { read = fn(path) }, shared_root = string } overrides for tests.
--- @return string version Release version, M.LOCAL or M.UNKNOWN.
--- @return string source One of the M.SOURCE_* values.
function M.resolve(opts)
	opts = opts or {}
	local shared_root = opts.shared_root
	if shared_root == nil then shared_root = Paths.shared_root() end
	local version, reason, stamped = Snapshot.build_version(opts.fs or { read = read_file }, shared_root)
	if version then return version, M.SOURCE_BUILD end
	if not stamped and reason == nil then return M.LOCAL, M.SOURCE_LOCAL end
	Logger.warn(LOG, "Driver version unknown: %s.", tostring(reason))
	return M.UNKNOWN, M.SOURCE_UNKNOWN
end

-- Resolved once: the stamp cannot change under a running daemon, and the menu
-- header reads it on every rebuild.
M.VERSION, M.SOURCE = M.resolve()

return M
