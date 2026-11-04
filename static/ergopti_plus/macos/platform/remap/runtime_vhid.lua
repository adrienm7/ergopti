--- platform/remap/runtime_vhid.lua

--- ==============================================================================
--- MODULE: Owned Runtime VirtualHIDDevice Compatibility
--- DESCRIPTION:
--- Reads the system extension listing and decides whether the one
--- Karabiner-DriverKit-VirtualHIDDevice installed on this Mac can serve the
--- owned runtime (ADR 011). Pure text analysis: it starts no process.
---
--- FEATURES & RATIONALE:
--- 1. One Version System-Wide: macOS keeps a single active copy of the driver,
---    shared with whatever Karabiner the user runs. The runtime's daemon speaks
---    one protocol version, so a different installed version is a refusal with
---    both versions named, never a guess that "close enough" works.
--- 2. Four Distinct Answers: absent (installable), waiting for approval (the
---    user must act), incompatible (a decision about another product's driver)
---    and unreadable (a listing this build cannot interpret). Each carries its
---    own reason, so the log and the field check say what to do.
--- 3. Publisher Pinned: an extension with the right identifier from another
---    team is incompatible, not a match.
--- ==============================================================================

local M = {}

--- Bundle identifier of the pqrs driver extension.
M.EXTENSION_ID = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"

--- Apple team identifier pqrs signs the driver with.
M.TEAM_ID = "G43BCU2T37"

--- Reasons a verdict can carry when it is not ok.
M.REASON_ABSENT = "virtual_hid_absent"
M.REASON_NOT_ACTIVE = "virtual_hid_not_active"
M.REASON_INCOMPATIBLE = "virtual_hid_incompatible"
M.REASON_UNREADABLE = "virtual_hid_unreadable"

local ACTIVE_STATE = "activated_enabled"
local EXTENSION_PATTERN = (M.EXTENSION_ID:gsub("%p", "%%%0"))





-- ====================================
-- ====================================
-- ======= 1/ Listing Analysis ========
-- ====================================
-- ====================================

--- Reads one listing line that names the extension.
--- @param line string One line of `systemextensionsctl list`.
--- @return table entry { team, version, state }; fields are nil when absent.
local function read_entry(line)
	local entry = {}
	entry.team = line:match("(%w+)%s+" .. EXTENSION_PATTERN)
	entry.version = line:match(EXTENSION_PATTERN .. "%s*%(([%d%.]+)")
	local state = line:match("%[([%a%s]+)%]%s*$")
	if state then entry.state = (state:gsub("%s+", "_")) end
	return entry
end

--- Summarises the driver as the system extension listing shows it.
--- @param output any Output of `systemextensionsctl list`.
--- @return table report { state = "absent"|"present"|"unreadable", team, version, activation }.
function M.parse(output)
	if type(output) ~= "string" then return { state = "unreadable" } end
	local entries = {}
	for line in output:gmatch("[^\r\n]+") do
		if line:find(M.EXTENSION_ID, 1, true) then entries[#entries + 1] = read_entry(line) end
	end
	if #entries == 0 then
		-- A listing that names no extension at all is a readable "absent" only
		-- when it looks like a listing: the tool always prints its header.
		if output:find("extension", 1, true) then return { state = "absent" } end
		return { state = "unreadable" }
	end
	-- Older copies stay listed as terminated until the next boot: the active one
	-- is the driver the system serves, whatever else remains.
	local chosen = entries[1]
	for _, entry in ipairs(entries) do
		if entry.state == ACTIVE_STATE then chosen = entry break end
	end
	if not chosen.version or not chosen.state then return { state = "unreadable" } end
	return { state = "present", team = chosen.team, version = chosen.version, activation = chosen.state }
end





-- ===========================
-- ===========================
-- ======= 2/ Verdict ========
-- ===========================
-- ===========================

--- Decides whether the installed driver can serve the owned runtime.
--- @param report table Result of M.parse.
--- @param required_version string Exact version the pinned runtime is built against.
--- @return table verdict { ok = true } or { ok = false, reason, explanation }.
function M.assess(report, required_version)
	assert(type(required_version) == "string" and required_version ~= "",
		"the pinned VirtualHIDDevice version is required")
	assert(type(report) == "table", "a VirtualHIDDevice report is required")
	if report.state == "unreadable" then
		return { ok = false, reason = M.REASON_UNREADABLE,
			explanation = "The system extension listing could not be interpreted, so the installed "
				.. "VirtualHIDDevice driver is unknown." }
	end
	if report.state == "absent" then
		return { ok = false, reason = M.REASON_ABSENT,
			explanation = "No VirtualHIDDevice driver is installed; the owned runtime installer provides version "
				.. required_version .. "." }
	end
	assert(report.state == "present", "unknown VirtualHIDDevice report state: " .. tostring(report.state))
	if report.team ~= M.TEAM_ID then
		return { ok = false, reason = M.REASON_INCOMPATIBLE,
			explanation = "The installed VirtualHIDDevice extension is signed by team "
				.. tostring(report.team) .. ", not by " .. M.TEAM_ID .. "." }
	end
	if report.version ~= required_version then
		return { ok = false, reason = M.REASON_INCOMPATIBLE,
			explanation = "VirtualHIDDevice " .. report.version .. " is installed but the owned runtime needs "
				.. required_version .. "; macOS keeps one version active system-wide, so replacing it "
				.. "(a driver-only update) needs the user's explicit confirmation and also affects any other "
				.. "Karabiner on this Mac." }
	end
	if report.activation ~= ACTIVE_STATE then
		return { ok = false, reason = M.REASON_NOT_ACTIVE,
			explanation = "VirtualHIDDevice " .. report.version .. " is installed but macOS reports it as "
				.. tostring(report.activation) .. "; it must be approved in System Settings." }
	end
	return { ok = true }
end

return M
