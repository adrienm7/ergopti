--- infra/personal_file_adoption.lua

--- ==============================================================================
--- MODULE: Native Personal File Adoption
--- DESCRIPTION:
--- Supplies physical Linux source observations to the shared adoption policy.
--- Missing native identity support refuses ownership instead of using filenames.
--- ==============================================================================

local M = {}
local Core = require("hotstrings.personal_adoption")
M.plan_gates, M.plan_selection = Core.plan_gates, Core.plan_selection
local FileSystem = require("adapters.file_system")
local available, FileAttributes = pcall(require, "lfs")

--- Returns an exact no-follow physical identity for a regular source file.
--- @param path string
--- @return string|nil identity
local function physical_identity(path)
	if not available then return nil end
	local attributes = FileAttributes.symlinkattributes(path)
	if type(attributes) ~= "table" or attributes.mode ~= "file"
		or attributes.dev == nil or attributes.ino == nil then return nil end
	return tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
end

--- Captures classified bytes only while both physical observations agree.
--- @param path string
--- @return table|nil evidence
local function capture(path)
	local identity = physical_identity(path)
	if not identity then return nil end
	local content, status = FileSystem.read_with_status(path)
	if status ~= "ok" or type(content) ~= "string" or physical_identity(path) ~= identity then return nil end
	return { physical = identity, content = content }
end

--- Follows only the primary route to exclude its target from additional owners.
--- @param path string
--- @return string|nil identity
--- @return string|nil status
local function primary_physical(path)
	if not available then return nil, "unavailable" end
	local before, _, error_code = FileAttributes.symlinkattributes(path)
	if not before then return nil, error_code == 2 and "absent" or "unavailable" end
	local function followed()
		local attributes = FileAttributes.attributes(path)
		if type(attributes) ~= "table" or attributes.mode ~= "file"
			or attributes.dev == nil or attributes.ino == nil then return nil end
		return tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
	end
	local first, second = followed(), followed()
	local after = FileAttributes.symlinkattributes(path)
	if not first or first ~= second or type(after) ~= "table" or before.mode ~= after.mode
		or before.dev == nil or before.ino == nil or before.dev ~= after.dev or before.ino ~= after.ino then
		return nil, "unavailable"
	end
	return first
end

local ports = { physical = physical_identity, primary_physical = primary_physical, capture = capture }

--- Captures one native catalogue cohort.
--- @param records table
--- @param choices table
--- @param primary_path string
--- @return table|nil inventory
--- @return string|nil reason
function M.stage(records, choices, primary_path)
	return Core.stage(records, choices, primary_path, ports)
end

--- Rechecks a held catalogue cohort before calling its existing writer.
--- @param inventory table
--- @param selected table
--- @return boolean
function M.current(inventory, selected)
	return Core.current(inventory, selected, ports)
end

function M.advance(inventory, selected, content)
	return Core.advance(inventory, selected, content, ports)
end

M.preferences = Core.preferences

return M
