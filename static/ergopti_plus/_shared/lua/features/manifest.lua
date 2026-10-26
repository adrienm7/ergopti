--- _shared/lua/features/manifest.lua

--- ==============================================================================
--- MODULE: Features Manifest Projection
--- DESCRIPTION:
--- Builds the features manifest one Lua driver loads from the table the macOS
--- and Linux drivers share (features.manifest_data, generated from
--- _shared/modules/features/manifest.toml). The two drivers' manifests shared
--- two thirds of their lines, so the generator writes the shared table once and
--- marks only what differs per driver; this module keeps the rows that name the
--- driver, resolves the per-driver default and recommendation, and lists the
--- others as unavailable with the reason the manifest gives.
---
--- FEATURES & RATIONALE:
--- 1. The projection is the table each driver's manifest used to be: same
---    fields, same order of rows, so manifest_reader and config_defaults read
---    it unchanged.
--- 2. Fresh tables: every call returns tables of its own, so a driver or a
---    test that edits its manifest never edits the shared data.
--- 3. Fail fast: an unknown driver, a row that names the driver without a full
---    entry, or a per-driver value missing for it raises instead of returning a
---    partial manifest.
--- ==============================================================================

local Data = require("features.manifest_data")
local TableUtil = require("table_util")

local M = {}

-- The drivers the shared data describes.
local PLATFORMS = { hs = true, linux = true }

-- Row fields that hold a value per driver, and the field each one resolves to.
local PER_DRIVER = { default_by = "default", recommended_by = "recommended" }





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Whether a row names the driver among the ones that keep it.
--- @param row table Shared row with a `platforms` list.
--- @param platform string Driver key.
--- @return boolean
local function keeps(row, platform)
	for _, name in ipairs(row.platforms) do
		if name == platform then return true end
	end
	return false
end






-- =============================
-- =============================
-- ======= 2/ Projection =======
-- =============================
-- =============================

--- The manifest one driver loads.
--- @param platform string Driver key, "hs" or "linux".
--- @return table manifest { version, section_order, scopes, sections, features, unavailable }
function M.for_platform(platform)
	if not PLATFORMS[platform] then
		error("features.manifest: unknown driver " .. tostring(platform), 2)
	end
	local manifest = {
		version = Data.version,
		section_order = TableUtil.deep_copy(Data.section_order),
		scopes = TableUtil.deep_copy(Data.scopes),
		sections = TableUtil.deep_copy(Data.sections),
		features = {},
		unavailable = {},
	}
	for _, row in ipairs(Data.features) do
		if keeps(row, platform) then
			if row.id == nil then
				error("features.manifest: " .. tostring(row.path) .. " names " .. platform
					.. " but has no entry", 2)
			end
			local entry = {}
			for field, value in pairs(row) do
				local resolved = PER_DRIVER[field]
				if resolved then
					if value[platform] == nil then
						error("features.manifest: " .. row.path .. " has no " .. field .. " for " .. platform, 2)
					end
					entry[resolved] = TableUtil.deep_copy(value[platform])
				elseif field ~= "reason_key" then
					entry[field] = TableUtil.deep_copy(value)
				end
			end
			manifest.features[#manifest.features + 1] = entry
		else
			manifest.unavailable[#manifest.unavailable + 1] = {
				path = row.path,
				section = row.section,
				reason_key = row.reason_key or "",
				platforms = TableUtil.deep_copy(row.platforms),
			}
		end
	end
	return manifest
end

return M
