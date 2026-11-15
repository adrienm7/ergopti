--- _shared/ai/engine/policy/app_identity.lua

--- ==============================================================================
--- MODULE: Application Identity For AI Settings (Shared Lua)
--- DESCRIPTION:
--- The one key an application is stored and compared under by the AI settings
--- that name applications: the per-application profile overrides
--- (llm.app_profile_overrides) and the applications the automatic trigger never
--- runs in (llm.trigger.disabled_apps). Windows applies the same rule in its
--- engine; macOS and Linux share this module (vectors in
--- _shared/tests/corpus/llm/app_profile_overrides_vectors.json, section normalize).
---
--- FEATURES & RATIONALE:
--- 1. The durable key uses the historical byte-oriented lowercase and strips
---    a trailing ".exe". A Unicode lowercase fallback compares valid UTF-8
---    without rewriting those keys; it is not full Unicode case folding.
--- 2. Empty, over-long and control-character identifiers have no key: they are
---    refused rather than stored.
--- 3. PURE Lua (LuaJIT and 5.4): no driver imports, no io.
--- ==============================================================================

local M = {}
local TextUtils = require("core.text.engine.utils_core")

-- The longest identifier a setting may hold
M.MAX_CHARS = 256
local MAX_INDEXED_EXCLUSIONS = 200

--- The key an application is stored and looked up under.
--- @param app any The identifier a driver reports, or a user typed.
--- @return string|nil key Lower-cased, trimmed, without ".exe"; nil when unusable.
function M.normalize(app)
	if type(app) ~= "string" then return nil end
	local key = TextUtils.trim(app):lower():gsub("%.exe$", "")
	if key == "" or #key > M.MAX_CHARS or key:find("%c") then return nil end
	return key
end

--- Unicode comparison is a lookup fallback, not a new storage format. Invalid
--- UTF-8 remains eligible for the historical byte-exact comparison only.
--- @param app any
--- @return string|nil
function M.comparison_key(app)
	local key = M.normalize(app)
	if not key or require("core.lifecycle.engine.compat.utf8").len(key) == nil then return nil end
	return require("core.text.engine.unicode_case").lower(key)
end

--- Compare without changing or migrating either stored application key.
--- @param left any
--- @param right any
--- @return boolean
function M.matches(left, right)
	local first, second = M.normalize(left), M.normalize(right)
	if not first or not second then return false end
	if first == second then return true end
	-- The historical ASCII lowercasing already compared these two keys.
	if not first:find("[\128-\255]") and not second:find("[\128-\255]") then return false end
	local folded = M.comparison_key(first)
	return folded ~= nil and folded == M.comparison_key(second)
end

--- Builds a bounded lookup from a published list, without retaining queries.
--- @param apps table
--- @return table
function M.exclusion_index(apps)
	local index = { exact = {}, unicode = {}, overflow = false }
	for position, app in ipairs(apps) do
		if position > MAX_INDEXED_EXCLUSIONS then index.overflow = true; break end
		local key = M.normalize(app)
		if key then
			index.exact[key] = true
			local comparison = M.comparison_key(key)
			if comparison then index.unicode[comparison] = true end
		end
	end
	return index
end

--- Consults only this list's indexed keys; no application query is retained.
--- @param index table
--- @param app any
--- @param apps table The currently published list, used only for an overflow.
--- @return boolean
function M.exclusion_contains(index, app, apps)
	local key = M.normalize(app)
	if not key then return false end
	if index.exact[key] then return true end
	local comparison = M.comparison_key(key)
	if comparison ~= nil and index.unicode[comparison] == true then return true end
	if index.overflow then
		local position = MAX_INDEXED_EXCLUSIONS + 1
		while apps[position] ~= nil do
			if M.matches(apps[position], key) then return true end
			position = position + 1
		end
	end
	return false
end

return M
