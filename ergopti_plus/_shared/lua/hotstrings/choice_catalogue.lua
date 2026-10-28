--- _shared/lua/hotstrings/choice_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Choice Catalogue Judgement
--- DESCRIPTION:
--- Decides whether an explicit hotstring category or section choice names
--- something the loaded catalogue can prove retired. The Lua drivers keep their
--- own registry; this is the one rule they share, so a choice for a removed
--- category is ignored at runtime and offered by the configuration cleanup the
--- same way on Linux and macOS.
---
--- FEATURES & RATIONALE:
--- 1. Nothing is retired before a catalogue was published: a boot that has not
---    finished loading must not call any choice retired.
--- 2. A category the lookup does not know is retired; a category the lookup
---    cannot judge (a personal file, an extension pack) answers `unjudged`.
--- 3. A section is retired only when its category lists its sections as the
---    build's own: a user override holds that file's sections only, and removing
---    the override brings the bundled section back.
--- ==============================================================================

local M = {}

--- Judges one explicit choice.
--- @param published boolean Whether a complete catalogue was published.
--- @param lookup function lookup(id) -> nil (unknown), or a record
---   `{ unjudged = true }` or `{ sections = set|nil }`; a nil `sections` means the
---   category's sections are not the build's and cannot prove a section retired.
--- @param id string Category id.
--- @param section string|nil Section name, for a section choice.
--- @return boolean retired
function M.is_retired(published, lookup, id, section)
	if published ~= true then return false end
	assert(type(lookup) == "function", "the catalogue lookup is required")
	local category = lookup(id)
	if category == nil then return true end
	if category.unjudged == true then return false end
	if section == nil or category.sections == nil then return false end
	return category.sections[section] == nil
end

return M
