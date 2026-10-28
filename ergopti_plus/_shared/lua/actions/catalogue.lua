--- _shared/lua/actions/catalogue.lua

--- ==============================================================================
--- MODULE: Action Catalogue Projection
--- DESCRIPTION:
--- Builds the action catalogue one Lua driver loads from the data the macOS
--- and Linux drivers share (actions.catalogue_data, generated from
--- _shared/modules/actions/actions.toml). The generator already decided, per
--- driver, which picker items, axes and actions it keeps; this module only
--- keeps the entries that name the driver and adds what the driver alone
--- declares (Karabiner aliases on macOS, the gesture slot-space on Linux).
---
--- FEATURES & RATIONALE:
--- 1. One copy of the shared table: the two drivers' catalogues shared four
---    lines in five, so the generator writes them once.
--- 2. Fresh tables: every call returns tables of its own, so a driver or a
---    test that edits its catalogue never edits the shared data.
--- 3. Fail fast: an unknown driver or an extra that would replace a shared
---    field raises instead of returning a partial catalogue.
--- ==============================================================================

local Data = require("actions.catalogue_data")

local M = {}

-- The drivers the shared data describes.
local PLATFORMS = { hs = true, linux = true }

-- The fields of the shared data a driver extra may not replace.
local OWNED_FIELDS = { platform = true, sg_items = true, ax_items = true, actions = true }





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Whether an entry names the driver among the ones that keep it.
--- @param entry table Shared entry with a `platforms` list.
--- @param platform string Driver key.
--- @return boolean
local function keeps(entry, platform)
	for _, name in ipairs(entry.platforms) do
		if name == platform then return true end
	end
	return false
end

--- A copy of a list of strings.
--- @param values table
--- @return table
local function copy_list(values)
	local copy = {}
	for index, value in ipairs(values) do copy[index] = value end
	return copy
end





-- =============================
-- =============================
-- ======= 2/ Projection =======
-- =============================
-- =============================

--- The catalogue one driver loads.
--- @param platform string Driver key, "hs" or "linux".
--- @param extras table|nil Fields only this driver declares.
--- @return table catalogue { platform, sg_items, ax_items, actions, ...extras }
function M.for_platform(platform, extras)
	if not PLATFORMS[platform] then
		error("actions.catalogue: unknown driver " .. tostring(platform), 2)
	end
	local catalogue = { platform = platform, sg_items = {}, ax_items = {}, actions = {} }
	for _, item in ipairs(Data.sg_items) do
		if keeps(item, platform) then
			local copy = {}
			for field, value in pairs(item) do
				if field ~= "platforms" then copy[field] = value end
			end
			catalogue.sg_items[#catalogue.sg_items + 1] = copy
		end
	end
	for _, axis in ipairs(Data.ax_items) do
		if keeps(axis, platform) then catalogue.ax_items[#catalogue.ax_items + 1] = axis.id end
	end
	for id, action in pairs(Data.actions) do
		if keeps(action, platform) then
			local copy = { family = action.family, label_key = action.label_key,
				parameter = action.parameter, confirm = action.confirm }
			if action.requires and action.requires[platform] then
				copy.requires = copy_list(action.requires[platform])
			end
			catalogue.actions[id] = copy
		end
	end
	for field, value in pairs(extras or {}) do
		if OWNED_FIELDS[field] then
			error("actions.catalogue: a driver extra may not replace " .. tostring(field), 2)
		end
		catalogue[field] = value
	end
	return catalogue
end

return M
