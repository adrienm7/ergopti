--- _shared/lua/remap/system_extension_observation.lua

--- ==============================================================================
--- MODULE: System Extension Observation
--- DESCRIPTION:
--- Parses a bounded systemextensionsctl list observation for the official pqrs
--- extension. Text approval is not signing, live driver readiness, installed
--- package identity, or VirtualHID protocol compatibility.
--- ==============================================================================

local M = {}
local TEAM_ID = "G43BCU2T37"
local BUNDLE_ID = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
-- A large or truncated listing cannot provide an unambiguous bounded observation.
local MAX_OUTPUT_BYTES = 65536
local MAX_VERSION_BYTES = 64

--- Returns a fresh unknown observation without retaining command output.
--- @return table observation No approval or compatibility authority.
local function unknown()
	return { state = "unknown", approved = false }
end

--- Checks only the displayed numeric version grammar, never its compatibility.
--- @param version string Displayed version component.
--- @return boolean valid Whether this component has bounded numeric grammar.
local function version_valid(version)
	return #version <= MAX_VERSION_BYTES and version:match("^%d[%d%.]*$") ~= nil
		and version:sub(-1) ~= "." and not version:find("..", 1, true)
end

--- Tests the only horizontal separators accepted in a CLI row.
--- @param byte integer|nil Candidate byte.
--- @return boolean space Whether this byte separates columns.
local function horizontal_space(byte)
	return byte == 32 or byte == 9
end

--- Recognizes exact identity boundaries independently of valid row formatting.
--- A glued '(' is malformed same-ID evidence; a '.other' sibling is a different ID.
--- @param line string Bounded CLI line.
--- @return boolean target Whether the exact identifier occurs at a token boundary.
local function target_identity(line)
	local at = 1
	while true do
		local first, last = line:find(BUNDLE_ID, at, true)
		if first == nil then return false end
		local before = first > 1 and line:sub(first - 1, first - 1) or ""
		local after = line:sub(last + 1, last + 1)
		if not before:find("[A-Za-z0-9_.%-]") and not after:find("[A-Za-z0-9_.%-]") then return true end
		at = last + 1
	end
end

--- Parses one row with index scans and bounded version patterns.
--- @param line string One target-bearing CLI line.
--- @return table observation Approval and literal versions, or unknown.
local function observe_row(line)
	local first, last = 1, #line
	while first <= last and horizontal_space(line:byte(first)) do first = first + 1 end
	while last >= first and horizontal_space(line:byte(last)) do last = last - 1 end
	if line:byte(last) ~= 93 then return unknown() end
	local opening = last - 1
	while opening >= first and line:byte(opening) ~= 91 do opening = opening - 1 end
	if opening < first or not horizontal_space(line:byte(opening - 1)) then return unknown() end
	local state = line:sub(opening + 1, last - 1)
	if state ~= "activated enabled" and state ~= "waiting for user" then return unknown() end
	local fields = {}
	for token in line:sub(first, opening - 1):gmatch("[^ \t]+") do fields[#fields + 1] = token end
	if #fields < 6 or fields[3] ~= TEAM_ID or fields[4] ~= BUNDLE_ID
		or (fields[1] ~= "*" and fields[1] ~= "-")
		or (fields[2] ~= "*" and fields[2] ~= "-") then return unknown() end
	-- Bound the tuple before any pattern; separating slash/parentheses cannot
	-- backtrack across unbounded display-name or whitespace fields.
	if #fields[5] > 2 * MAX_VERSION_BYTES + 3 then return unknown() end
	local version, build = fields[5]:match("^%(([^/]+)/([^/]+)%)$")
	if version == nil or not version_valid(version) or not version_valid(build) then return unknown() end
	for index = 6, #fields do
		if fields[index]:find("[%[%]]") then return unknown() end
	end
	local approved = fields[1] == "*" and fields[2] == "*" and state == "activated enabled"
	return {
		state = approved and "approved" or "not_approved",
		approved = approved,
		displayed_version = version,
		displayed_build = build,
	}
end

--- Observes one exact official extension row without querying or changing macOS.
--- @param output any Completed systemextensionsctl list output.
--- @return table observation State, approval, and literal displayed version/build.
function M.observe(output)
	if type(output) ~= "string" or #output == 0 or #output > MAX_OUTPUT_BYTES then return unknown() end
	output = output:gsub("\r\n", "\n")
	if output:find("[%z\1-\8\11-\31\127]") then return unknown() end
	local observation = nil
	for line in output:gmatch("[^\n]+") do
		if target_identity(line) then
			-- A preferred or first successful row cannot resolve an update/conflict.
			if observation ~= nil then return unknown() end
			observation = observe_row(line)
			if observation.state == "unknown" then return observation end
		end
	end
	return observation or unknown()
end

return M
