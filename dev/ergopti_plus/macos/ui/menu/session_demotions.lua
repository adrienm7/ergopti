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

--- Reads a whole preference or one independently editable child preference.
--- @param state table Complete preference snapshot.
--- @param entry table Demotion address.
--- @return any value
local function value_at(state, entry)
	if entry.subkey == nil then return state[entry.key] end
	local parent = state[entry.key]
	if type(parent) == "table" then return parent[entry.subkey] end
	return nil
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
	--- @param record table { feature, key, subkey?, persisted, demoted }.
	function registry.record(record)
		if type(record) ~= "table" or type(record.key) ~= "string" or record.key == ""
			or type(record.feature) ~= "string" or record.feature == "" then
			error("a session demotion needs a feature and a state key", 2)
		end
		if record.subkey ~= nil and (type(record.subkey) ~= "string" or record.subkey == "") then
			error("a child preference demotion needs a nonempty subkey", 2)
		end
		-- Length framing keeps a whole key distinct from every child address.
		local identity = #record.key .. ":" .. record.key
		if record.subkey ~= nil then identity = identity .. ":" .. record.subkey end
		-- Explicit branch: `existing and existing.persisted or ...` would drop a
		-- saved `false` and keep the later value instead.
		local persisted = clone(record.persisted)
		local existing = entries[identity]
		if existing then persisted = existing.persisted end
		entries[identity] = {
			key = record.key,
			subkey = record.subkey,
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
		local view
		for _, entry in pairs(entries) do
			if same_value(value_at(state, entry), entry.demoted) then
				view = view or clone(state)
				if entry.subkey == nil then
					view[entry.key] = clone(entry.persisted)
				else
					view[entry.key][entry.subkey] = clone(entry.persisted)
				end
			end
		end
		return view or state
	end

	--- Ends every demotion whose key the user changed, once a save has written
	--- that change to config.toml.
	--- @param state table Live menu state the committed save serialised.
	function registry.settle(state)
		if type(state) ~= "table" then error("settle needs the live state", 2) end
		for key, entry in pairs(entries) do
			if not same_value(value_at(state, entry), entry.demoted) then
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

	--- Detaches only the demotions owned by one explicitly published feature.
	--- @param feature string Exact synchronisation owner identity.
	--- @param keys table|nil Explicitly published state keys; omitted releases the whole feature.
	--- @return table released Entries retained for readopt on publication refusal.
	function registry.release_feature(feature, keys)
		assert(type(feature) == "string" and feature ~= "", "a demotion feature is required")
		local released = {}
		for key, entry in pairs(entries) do
			if entry.feature == feature and (keys == nil or keys[entry.key] == true) then
				released[key], entries[key] = entry, nil
			end
		end
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
		for _, entry in pairs(entries) do
			list[#list + 1] = {
				key = entry.key,
				subkey = entry.subkey,
				feature = entry.feature,
				persisted = clone(entry.persisted),
				demoted = clone(entry.demoted),
			}
		end
		table.sort(list, function(left, right)
			if left.key ~= right.key then return left.key < right.key end
			return (left.subkey or "") < (right.subkey or "")
		end)
		return list
	end

	return registry
end

return M
