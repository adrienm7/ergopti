--- _shared/apps/engine/secure_apps.lua

--- ==============================================================================
--- MODULE: Secure Applications (shared rule)
--- DESCRIPTION:
--- The one list of password managers and vaults whose whole application is a
--- secure field (_shared/data/secure_apps.json, projected into
--- secure_apps_data.lua by tools/codegen/codegen-secure-apps.cjs), and how each
--- driver matches its own application identity against it. macOS and Linux
--- read it here; Windows reads the same file's `windows` entries.
---
--- FEATURES & RATIONALE:
--- 1. One list for three drivers: the macOS, Linux and Windows lists had
---    drifted apart (ADD-1, decided by the maintainer on 2026-11-11).
--- 2. One matching rule per identity kind: macOS display names are exact,
---    Windows process names ignore case, Linux identities are lowercased and
---    matched by fragment, so `keepassxc` covers the X11 class `keepassxc` and
---    the Wayland app_id `org.keepassxc.KeePassXC` alike.
--- 3. No file work on the focus path: the list is generated Lua data, read
---    with require. A malformed list raises, so a driver never runs a privacy
---    gate with no list behind it.
--- ==============================================================================

local M = {}

local Data = require("apps.engine.secure_apps_data")

-- The identity kinds the list declares for each application.
M.PLATFORMS = { "windows", "macos", "linux" }





-- ======================================
-- ======================================
-- ======= 1/ Validation and rule =======
-- ======================================
-- ======================================

--- Validates the decoded secure_apps.json and builds one platform's matcher.
--- @param document table Decoded secure_apps.json.
--- @param platform string "windows", "macos" or "linux".
--- @return function matches(identity): boolean
function M.matcher(document, platform)
	assert(platform == "windows" or platform == "macos" or platform == "linux",
		"secure apps: unknown platform " .. tostring(platform))
	assert(type(document) == "table" and type(document.apps) == "table" and #document.apps > 0,
		"secure apps: the list declares no application")
	local exact, fragments, seen = {}, {}, {}
	for _, app in ipairs(document.apps) do
		assert(type(app) == "table" and type(app.id) == "string" and app.id ~= "" and not seen[app.id],
			"secure apps: an application lacks a unique id")
		seen[app.id] = true
		for _, name in ipairs(M.PLATFORMS) do
			assert(type(app[name]) == "table", "secure apps: " .. app.id .. " lacks its " .. name .. " list")
		end
		for _, identity in ipairs(app[platform]) do
			assert(type(identity) == "string" and identity ~= "", "secure apps: " .. app.id .. " holds an empty identity")
			if platform == "linux" then
				assert(identity == identity:lower(), "secure apps: Linux fragment " .. identity .. " is not lowercase")
				fragments[#fragments + 1] = identity
			elseif platform == "windows" then
				exact[identity:lower()] = true
			else
				exact[identity] = true
			end
		end
	end
	return function(identity)
		if type(identity) ~= "string" or identity == "" then return false end
		if platform == "macos" then return exact[identity] == true end
		local lower = identity:lower()
		if platform == "windows" then return exact[lower] == true end
		for _, fragment in ipairs(fragments) do
			if lower:find(fragment, 1, true) then return true end
		end
		return false
	end
end

-- One validated matcher per platform over the generated data, built once.
local _matchers = {}

--- Whether an application identity is a secure application on a platform.
--- @param platform string "windows", "macos" or "linux".
--- @param identity string|nil The driver's application identity.
--- @return boolean
function M.is_secure_app(platform, identity)
	local matches = _matchers[platform]
	if not matches then
		matches = M.matcher(Data, platform)
		_matchers[platform] = matches
	end
	return matches(identity)
end

--- The Linux fragments in list order, for the metrics' secure-app list.
--- @param document table|nil Decoded secure_apps.json; the generated data when nil.
--- @return table fragments
function M.linux_fragments(document)
	document = document or Data
	M.matcher(document, "linux")
	local out = {}
	for _, app in ipairs(document.apps) do
		for _, identity in ipairs(app.linux) do out[#out + 1] = identity end
	end
	return out
end

return M
