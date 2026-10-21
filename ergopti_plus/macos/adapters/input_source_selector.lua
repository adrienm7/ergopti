--- adapters/input_source_selector.lua

--- ==============================================================================
--- MODULE: Native Input-source Commands
--- DESCRIPTION:
--- Resolves the bundle-owned launcher and builds typed selection or upgrade argv.
--- Carbon's AppleScript bridge crashes before returning a native status on both
--- macOS architectures; the signed launcher calls the C API directly instead.
--- The input-source module retains ownership of process and deadline settlement.
--- ==============================================================================

local M = {}
local LauncherHelper = require("platform.remap.lease_helper")
local SELECT_FLAG = "--select-input-source"
local SELECT_BY_NAME_FLAG = "--select-input-source-by-name"
local UPGRADE_FLAG = "--upgrade-input-sources"
local MAX_SOURCE_BYTES = 1024


--- Rejects identifiers that cannot cross the native argv protocol.
--- @param identifier any Stable TIS source identifier.
--- @return boolean valid
local function valid_identifier(identifier)
	return type(identifier) == "string" and identifier ~= "" and #identifier <= MAX_SOURCE_BYTES
		and not identifier:find("\0", 1, true)
end


--- Resolves the exact bundled executable before returning a private argv vector.
--- @param arguments table Command arguments.
--- @return string|nil executable Exact native launcher.
--- @return table|nil arguments Independent argv values, never shell source.
--- @return table|nil environment Verified launcher file identity.
--- @return string|nil reason Failure detail.
local function resolve(arguments)
	local ok, executable, detail, environment = xpcall(LauncherHelper.resolve, debug.traceback)
	if not ok then return nil, nil, nil, "helper_resolution_failed" end
	if type(executable) ~= "string" or executable == "" or type(environment) ~= "table" then
		return nil, nil, nil, detail or "helper_unavailable"
	end
	return executable, arguments, environment, nil
end


--- Builds one selection invocation with a stable identifier as literal argv.
--- @param identifier string Stable TIS source identifier.
--- @return string|nil executable
--- @return table|nil arguments
--- @return table|nil environment
--- @return string|nil reason
function M.command(identifier)
	if not valid_identifier(identifier) then return nil, nil, nil, "invalid_source" end
	return resolve({ SELECT_FLAG, identifier })
end


--- Resolves a unique localized name and an exact candidate in one native inventory.
--- @param localised_name string Native localized source name.
--- @param identifier string Exact ID candidate, never a guessed prefix.
--- @return string|nil executable
--- @return table|nil arguments
--- @return table|nil environment
--- @return string|nil reason
function M.command_named(localised_name, identifier)
	if not valid_identifier(localised_name) or not valid_identifier(identifier) then
		return nil, nil, nil, "invalid_source"
	end
	return resolve({ SELECT_BY_NAME_FLAG, localised_name, identifier })
end


--- Copies every replacement into one preflighted native transaction.
--- @param replacements table Dense list of {old_id, new_id} records.
--- @return string|nil executable
--- @return table|nil arguments
--- @return table|nil environment
--- @return string|nil reason
function M.upgrade(replacements)
	if type(replacements) ~= "table" or #replacements == 0 then
		return nil, nil, nil, "invalid_entries"
	end
	local count = 0
	for index, replacement in pairs(replacements) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #replacements
			or type(replacement) ~= "table" or not valid_identifier(replacement.old_id)
			or not valid_identifier(replacement.new_id) then
			return nil, nil, nil, "invalid_entries"
		end
		count = count + 1
	end
	if count ~= #replacements then return nil, nil, nil, "invalid_entries" end
	local arguments = { UPGRADE_FLAG }
	for _, replacement in ipairs(replacements) do
		arguments[#arguments + 1] = replacement.old_id
		arguments[#arguments + 1] = replacement.new_id
	end
	return resolve(arguments)
end

return M
