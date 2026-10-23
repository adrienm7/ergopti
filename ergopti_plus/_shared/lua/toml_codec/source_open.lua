--- _shared/lua/toml_codec/source_open.lua

--- ==============================================================================
--- MODULE: TOML Source Stream Admission (shared)
--- DESCRIPTION:
--- Opens a TOML source for reading through the driver's pinned regular-file
--- admission when the driver ships one. Opening a FIFO with stdio waits for a
--- writer, so a special file at a configuration path froze the reading caller.
---
--- FEATURES & RATIONALE:
--- 1. The Linux driver owns the native admission (`infra.regular_file_reader`):
---    a nonblocking descriptor is classified before any stream exists, and a
---    FIFO, socket or directory is refused with a non-ENOENT receipt, so it is
---    never mistaken for an absent file that a writer may create.
--- 2. A driver without that module (macOS, build scripts) keeps the stdio
---    stream. The lookup runs on the module path, not through a protected
---    require, so a Linux reader that fails to load raises instead of silently
---    falling back to the blocking stream.
--- ==============================================================================

local M = {}

-- The one module name a driver publishes to own descriptor admission.
local NATIVE_READER = "infra.regular_file_reader"

-- Resolved once: package.path is fixed before the codec loads.
local has_native_reader = package.searchpath(NATIVE_READER, package.path) ~= nil

--- Opens a TOML source for reading.
--- @param path string Source path.
--- @return file*|nil stream Readable stream, or nil on refusal.
--- @return string|nil detail Failure detail.
--- @return number|string|nil errno Native errno; 2 proves absence.
function M.open(path)
	if has_native_reader then return require(NATIVE_READER).open_source(path) end
	return io.open(path, "r")
end

return M
