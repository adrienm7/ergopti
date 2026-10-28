--- infra/hotstring_choice_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Choice Catalogue (macOS owner)
--- DESCRIPTION:
--- Holds the one fact the preferences reader cannot know while it loads: which
--- hotstring categories and sections this build ships. Boot publishes it once,
--- after the bundled sources finished loading, and the configuration cleanup
--- then judges explicit choices against it with the rule the Lua drivers share
--- (_shared/lua/hotstrings/choice_catalogue.lua).
---
--- FEATURES & RATIONALE:
--- 1. Explicit initialization: `publish` takes the judging lookup once and
---    refuses a second owner, so two boots can never disagree on the catalogue.
--- 2. Unpublished means unjudged: the preferences reader runs before the
---    hotstring sources load, and an unpublished catalogue retires nothing.
--- 3. Only bundled identities are judged: the lookup answers `unjudged` for a
---    personal file, an extension pack or a dynamic group, whose absence may be
---    temporary and whose choices must never be offered for deletion.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Catalogue = require("hotstrings.choice_catalogue")

local LOG = "infra.hotstring_choice_catalogue"

local _lookup = nil

--- Publishes the catalogue lookup once boot loaded every bundled source.
--- @param lookup function lookup(id) -> nil | { unjudged = true } | { sections = set|nil }.
--- @return boolean published
function M.publish(lookup)
	if type(lookup) ~= "function" then
		Logger.error(LOG, "Hotstring catalogue publication refused: the lookup is not a function.")
		return false
	end
	if _lookup ~= nil then
		Logger.error(LOG, "Hotstring catalogue publication refused: a catalogue is already published.")
		return false
	end
	_lookup = lookup
	Logger.success(LOG, "Hotstring choice catalogue published.")
	return true
end

--- Whether an explicit choice names a category or section the catalogue proves retired.
--- @param id string Category id.
--- @param section string|nil Section name, for a section choice.
--- @return boolean retired
function M.retired(id, section)
	return Catalogue.is_retired(_lookup ~= nil, _lookup, id, section)
end

--- Forgets the published catalogue, for tests only.
function M.reset_for_tests()
	_lookup = nil
end

return M
