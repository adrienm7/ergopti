--- infra/personal_file_adoption.lua

--- ==============================================================================
--- MODULE: Native Personal File Adoption
--- DESCRIPTION:
--- Supplies classified macOS file observations to the shared adoption policy.
--- ==============================================================================

local M = {}
local Core = require("hotstrings.personal_adoption")
local FileSystem = require("adapters.file_system")

--- Reads the exact regular-file identity; links never gain mutation authority.
--- @param path string
--- @return string|nil identity
local function physical_identity(path)
	local status, attributes = FileSystem.path_status(path)
	if status ~= "present" or type(attributes) ~= "table" or attributes.mode ~= "file"
		or attributes.dev == nil or attributes.ino == nil then return nil end
	return tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
end

--- Captures exact classified bytes under an unchanged physical identity.
--- @param path string
--- @return table|nil evidence
local function capture(path)
	local physical = physical_identity(path)
	if not physical then return nil end
	local content, read_status = FileSystem.read_with_status(path)
	if read_status ~= "ok" or type(content) ~= "string" or physical_identity(path) ~= physical then return nil end
	return { physical = physical, content = content }
end

--- Excludes the primary target without granting any linked extra source authority.
--- @param path string Independently owned primary source route.
--- @return string|nil identity
--- @return string|nil status
local function primary_physical(path)
	local status, before = FileSystem.path_status(path)
	if status == "absent" then return nil, "absent" end
	if status ~= "present" or type(before) ~= "table" then return nil, "unavailable" end
	local first, second
	if before.mode == "file" then
		first, second = physical_identity(path), physical_identity(path)
	elseif before.mode == "link" and hs and hs.fs and type(hs.fs.attributes) == "function" then
		local function followed()
			local ok, attributes = pcall(hs.fs.attributes, path)
			if not ok or type(attributes) ~= "table" or attributes.mode ~= "file"
				or attributes.dev == nil or attributes.ino == nil then return nil end
			return tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
		end
		first, second = followed(), followed()
	end
	local after_status, after = FileSystem.path_status(path)
	if not first or first ~= second or after_status ~= "present" or type(after) ~= "table"
		or before.mode ~= after.mode or before.dev == nil or before.ino == nil
		or before.dev ~= after.dev or before.ino ~= after.ino or before.target ~= after.target then
		return nil, "unavailable"
	end
	return first
end

local ports = { physical = physical_identity, primary_physical = primary_physical, capture = capture }

--- Normalizes the native flat reader without changing any stored preference.
--- @param saved table
--- @return table choices
local function choices(saved)
	return { groups = saved.hotstrings, modules = saved.section_states }
end

--- Captures a cohort before registry publication.
--- @param records table Dense source records.
--- @param saved table Native canonical flat preferences.
--- @param primary_path string Independently owned primary source.
--- @return table|nil inventory
--- @return string|nil reason
function M.stage(records, saved, primary_path)
	if type(saved) ~= "table" then return nil, "invalid-preferences" end
	return Core.stage(records, choices(saved), primary_path, ports)
end

--- Rechecks a held cohort before its acknowledged native writer is called.
--- @param inventory table
--- @param selected table
--- @return boolean
function M.current(inventory, selected)
	return Core.current(inventory, selected, ports)
end

--- Supplies read-only published-cohort evidence to a native receipt consumer.
--- @param inventory table Original source cohort.
--- @param selected table Original admitted binding.
--- @param content string Exact invocation-owned candidate.
--- @return boolean current
function M.published_current(inventory, selected, content)
	return Core.published_current(inventory, selected, content, ports)
end

function M.advance(inventory, selected, content)
	return Core.advance(inventory, selected, content, ports)
end

--- Projects explicit canonical or unambiguous legacy choices for one file.
--- @param record table
--- @param saved table
--- @return boolean enabled
--- @return table sections
function M.preferences(record, saved)
	return Core.preferences(record, choices(saved))
end

return M
