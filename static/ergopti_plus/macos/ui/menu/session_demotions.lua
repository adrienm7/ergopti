--- ui/menu/session_demotions.lua

--- ==============================================================================
--- MODULE: Session Feature Demotions
--- DESCRIPTION:
--- Remembers the features whose runtime refused the saved preference during this
--- session. Their live state shows the real (demoted) posture, while every save
--- keeps the value config.toml already holds, so a runtime refusal never rewrites
--- the user's file. A demotion ends once a save commits a user change of that
--- value, or when a global action publishes an explicit value for every feature.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG = "menu"





-- ================================
-- ================================
-- ======= 1/ Value Helpers =======
-- ================================
-- ================================

--- Deep-copies plain Lua data so a recorded value cannot alias live state.
--- @param value any Value to copy.
--- @return any copy
local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[clone(key)] = clone(child) end
	return copy
end

--- Compares two plain Lua values structurally.
--- @param left any First value.
--- @param right any Second value.
--- @return boolean equal
local function same_value(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not same_value(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end





-- ====================================
-- ====================================
-- ======= 2/ Demotion Registry =======
-- ====================================
-- ====================================

--- Creates one session registry. Each menu session owns exactly one.
--- @return table registry record, persisted_view, settle, release_all, readopt, list.
function M.new()
	local entries = {}
	local registry = {}

	--- Records one demotion reported by the preference synchronisation.
	--- The first recorded saved value wins: a later demotion of the same key
	--- must not replace the user's file value with an earlier demoted one.
	--- @param record table { feature, key, persisted, demoted }.
	function registry.record(record)
		if type(record) ~= "table" or type(record.key) ~= "string" or record.key == ""
			or type(record.feature) ~= "string" or record.feature == "" then
			error("a session demotion needs a feature and a state key", 2)
		end
		-- Explicit branch: `existing and existing.persisted or ...` would drop a
		-- saved `false` and keep the later value instead.
		local persisted = clone(record.persisted)
		local existing = entries[record.key]
		if existing then persisted = existing.persisted end
		entries[record.key] = {
			feature = record.feature,
			persisted = persisted,
			demoted = clone(record.demoted),
		}
		Logger.info(LOG,
			"Feature '%s' is demoted for this session; config.toml keeps its saved '%s'.",
			record.feature, record.key)
	end

	--- Returns the state a save must serialise: the live state, with the saved
	--- value restored for every key that still holds its demoted posture. It
	--- never ends a demotion: the save may still fail and roll the key back to
	--- its demoted posture, so only settle() ends one, after the commit.
	--- @param state table Live menu state.
	--- @return table view The live table itself when no demotion applies.
	function registry.persisted_view(state)
		if type(state) ~= "table" then error("persisted_view needs the live state", 2) end
		local overrides = nil
		for key, entry in pairs(entries) do
			if same_value(state[key], entry.demoted) then
				overrides = overrides or {}
				overrides[key] = clone(entry.persisted)
			end
		end
		if not overrides then return state end
		local view = {}
		for key, value in pairs(state) do view[key] = value end
		for key, value in pairs(overrides) do view[key] = value end
		return view
	end

	--- Ends every demotion whose key the user changed, once a save has written
	--- that change to config.toml.
	--- @param state table Live menu state the committed save serialised.
	function registry.settle(state)
		if type(state) ~= "table" then error("settle needs the live state", 2) end
		for key, entry in pairs(entries) do
			if not same_value(state[key], entry.demoted) then
				entries[key] = nil
				Logger.info(LOG, "Feature '%s' was changed; its session demotion ended.",
					entry.feature)
			end
		end
	end

	--- Detaches every demotion before a save that sets every feature explicitly.
	--- @return table released Detached entries for readopt() if that save fails.
	function registry.release_all()
		local released = entries
		entries = {}
		return released
	end

	--- Restores entries detached by release_all() when the explicit save they
	--- made way for is reversed. Idempotent, so a retried inverse may call it again.
	--- @param released table Entries returned by release_all().
	--- @return boolean committed Always true; malformed input raises.
	function registry.readopt(released)
		if type(released) ~= "table" then error("readopt needs released entries", 2) end
		for key, entry in pairs(released) do
			if entries[key] == nil then entries[key] = entry end
		end
		return true
	end

	--- Lists the active demotions for diagnostics and tests.
	--- @return table list Sorted { key, feature, persisted, demoted } records.
	function registry.list()
		local list = {}
		for key, entry in pairs(entries) do
			list[#list + 1] = {
				key = key,
				feature = entry.feature,
				persisted = clone(entry.persisted),
				demoted = clone(entry.demoted),
			}
		end
		table.sort(list, function(left, right) return left.key < right.key end)
		return list
	end

	return registry
end

return M
