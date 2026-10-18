--- adapters/input_source_selector.lua

--- ==============================================================================
--- MODULE: Native Input-source Selection Command
--- DESCRIPTION:
--- Resolves the bundle-owned launcher and builds one typed selection invocation.
--- Carbon's AppleScript bridge crashes before returning a native status on both
--- macOS architectures; the signed launcher calls the C API directly instead.
--- The input-source module retains ownership of process and deadline settlement.
--- ==============================================================================

local M = {}
local LauncherHelper = require("platform.remap.lease_helper")
local SELECT_FLAG = "--select-input-source"
local MAX_SOURCE_BYTES = 1024


--- Builds an argv command only after proving the exact bundled executable.
--- @param identifier string Stable TIS source identifier.
--- @return string|nil executable Exact native launcher.
--- @return table|nil arguments Independent argv values, never shell source.
--- @return table|nil environment Verified launcher file identity.
--- @return string|nil reason Failure detail.
function M.command(identifier)
	if type(identifier) ~= "string" or identifier == "" or #identifier > MAX_SOURCE_BYTES
		or identifier:find("\0", 1, true) then
		return nil, nil, nil, "invalid_source"
	end
	local ok, executable, detail, environment = xpcall(LauncherHelper.resolve, debug.traceback)
	if not ok then return nil, nil, nil, "helper_resolution_failed" end
	if type(executable) ~= "string" or executable == "" or type(environment) ~= "table" then
		return nil, nil, nil, detail or "helper_unavailable"
	end
	return executable, { SELECT_FLAG, identifier }, environment, nil
end

return M
