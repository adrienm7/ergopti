--- _shared/lua/hotstrings/languages.lua

--- ==============================================================================
--- MODULE: Hotstring Language Packs (Shared)
--- DESCRIPTION:
--- The rules that turn _shared/modules/hotstrings/_index.toml [languages] into
--- the language packs both Lua drivers load and draw, and the default each
--- bundled section ships with.
---
--- WHY THIS IS SHARED AND PURE:
--- Hotstrings written for one natural language live in a sub-folder named after
--- it (french/autocorrection.toml) and load as their own group, "<folder>_<stem>".
--- That id is what config.toml, the feature manifest and the menu key on, so the
--- two Lua drivers must derive it identically. Parsing is left to each driver's
--- TOML reader; this module only interprets the already-decoded table, so it has
--- no I/O and no Hammerspoon dependency.
---
--- WHY DEFAULTS COME FROM THE MANIFEST:
--- Every bundled section ships disabled and the user opts in. The feature
--- manifest is the one place that says so; a driver that answered "enabled" for
--- a section it had never seen persisted would silently turn on the whole corpus.
--- ==============================================================================

local M = {}




-- ==================================
-- ==================================
-- ======= 1/ Language packs ========
-- ==================================
-- ==================================

--- The group id of one language pack's category file.
--- @param language string Folder name, e.g. "french".
--- @param stem string File stem, e.g. "autocorrection".
--- @return string
function M.group_id(language, stem)
	return language .. "_" .. stem
end

--- Interprets a decoded _index.toml into ordered language packs.
---
--- A declared language with no locale or no categories is a broken index and
--- raises: silently dropping it would hide a whole language from the menu.
--- @param index table The decoded index (root table with an optional `languages`).
--- @return table Array of { id, locale, categories = { stem, … } }.
function M.packs(index)
	if type(index) ~= "table" then
		error("[hotstrings.languages] the hotstring index is not a table")
	end
	local languages = index.languages
	if languages == nil then return {} end
	if type(languages) ~= "table" or type(languages.order) ~= "table" then
		error("[hotstrings.languages] [languages] must declare an `order` array")
	end
	local result = {}
	for _, id in ipairs(languages.order) do
		local pack = languages[id]
		if type(pack) ~= "table" or type(pack.locale) ~= "string" or pack.locale == ""
			or type(pack.categories_order) ~= "table" or #pack.categories_order == 0
		then
			error(string.format(
				"[hotstrings.languages] language '%s' needs a locale and a categories_order", tostring(id)))
		end
		local categories = {}
		for _, stem in ipairs(pack.categories_order) do categories[#categories + 1] = stem end
		result[#result + 1] = { id = id, locale = pack.locale, categories = categories }
	end
	return result
end

--- Every language group id, as a set.
--- @param packs table Result of M.packs().
--- @return table<string, table> group id → { language, stem, locale }.
function M.groups(packs)
	local set = {}
	for _, pack in ipairs(packs or {}) do
		for _, stem in ipairs(pack.categories) do
			set[M.group_id(pack.id, stem)] = { language = pack.id, stem = stem, locale = pack.locale }
		end
	end
	return set
end





-- ===================================
-- ===================================
-- ======= 2/ Section defaults =======
-- ===================================
-- ===================================

--- Removes underscores so the file-stem and manifest spellings of one category
--- compare equal ("distancesreduction" and "distances_reduction").
--- @param id string
--- @return string
local function flatten(id)
	return (tostring(id):gsub("_", ""))
end

--- The manifest's shipped `enabled` for one bundled section.
---
--- Answers nil when the manifest has no row for it — personal and extension
--- packs are user-owned and carry no manifest row, so the caller decides what an
--- undeclared section means rather than this module guessing.
--- @param features table The generated manifest's `features` array.
--- @param group string Hotstring group (file stem or language group id).
--- @param section string Section name.
--- @return boolean|nil
function M.section_default(features, group, section)
	local wanted = flatten(group)
	for _, entry in ipairs(features or {}) do
		local category = type(entry.section) == "string" and entry.section:match("^hotstrings%.(.+)$") or nil
		if category and entry.id == section and flatten(category) == wanted
			and type(entry.default) == "table" and type(entry.default.enabled) == "boolean"
		then
			return entry.default.enabled
		end
	end
	return nil
end

return M
