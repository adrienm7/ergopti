--- _shared/lua/config_keyboard_publication.lua

--- ==============================================================================
--- MODULE: Native Keyboard Catalogue Publication
--- DESCRIPTION:
--- Projects the native owner's complete key and modifier inventories. The pure
--- receipt withdraws when their identities or consumed fields change; native
--- owners alone acknowledge source reads and expose the registered accessor.
--- ==============================================================================

local M = {}
local Identity = require("config_binding_identity")
local Publication = require("config_binding_publication")
local NATIVE_OWNER = "modules.shortcuts.keyboard_shortcuts"

--- Registers the native module's genuine accessor exactly once, without IO.
--- A new instance can initialize after require has withdrawn its predecessor;
--- an attempted registration cannot displace the current native module.
--- @param owner table Native module being constructed.
--- @param getter function Its genuine source-bound accessor.
function M.register(owner, getter)
	Publication.register("keyboard", NATIVE_OWNER, owner, getter)
end

--- Allows the genuine accessor to withdraw when its public ownership changes.
--- @param owner table Native module instance.
--- @return boolean current
function M.owner_is_current(owner)
	return Publication.owner_is_current("keyboard", NATIVE_OWNER, owner)
end

--- Reads only a genuine registered current accessor, never a public replacement.
--- @param owner table|nil Currently loaded native module.
--- @return table|nil catalogue Source-unavailable and withdrawn owners are unjudged.
function M.current(owner)
	return Publication.current("keyboard", NATIVE_OWNER, owner)
end

--- Reads a plain nonempty dense source array without invoking metamethods.
--- @param value table Actual native source array.
--- @return number count
local function dense_count(value)
	assert(type(value) == "table" and getmetatable(value) == nil and next(value) ~= nil,
		"config_keyboard_publication: invalid native inventory")
	local count = 0
	for index in next, value do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0,
			"config_keyboard_publication: invalid native inventory")
		count = count + 1
	end
	for index = 1, count do
		assert(rawget(value, index) ~= nil, "config_keyboard_publication: invalid native inventory")
	end
	return count
end

--- Captures the exact native fields that determine slot identities and chords.
--- @param keys table Native key records.
--- @param groups table Native pairs of prefix and modifier array.
--- @param contextual string Actual contextual slot owner.
--- @return table ids Dense slot identities.
--- @return table census Consumed source identities and values.
local function project(keys, groups, contextual)
	assert(type(contextual) == "string" and contextual ~= "" and not contextual:find("__", 1, true),
		"config_keyboard_publication: invalid contextual owner")
	local key_count, group_count = dense_count(keys), dense_count(groups)
	local ids, census, key_ids, prefixes = { contextual }, {}, {}, {}
	local function capture(value) census[#census + 1] = value end
	capture(keys); capture(groups); capture(contextual); capture(key_count); capture(group_count)
	for index = 1, key_count do
		local key = rawget(keys, index)
		assert(type(key) == "table" and getmetatable(key) == nil,
			"config_keyboard_publication: invalid native key")
		local id, chord_key = rawget(key, "id"), rawget(key, "chord_key")
		assert(type(id) == "string" and id ~= "" and not id:find("__", 1, true) and not key_ids[id]
			and (chord_key == nil or type(chord_key) == "string" and chord_key ~= ""),
			"config_keyboard_publication: invalid native key")
		key_ids[id] = true
		capture(key); capture(id); capture(chord_key ~= nil and chord_key or false)
	end
	for index = 1, group_count do
		local group = rawget(groups, index)
		assert(type(group) == "table" and getmetatable(group) == nil and dense_count(group) == 2,
			"config_keyboard_publication: invalid native modifier group")
		local prefix, modifiers = rawget(group, 1), rawget(group, 2)
		assert(type(prefix) == "string" and prefix:match("^[a-z0-9_]+_$")
			and not prefix:find("__", 1, true) and not prefixes[prefix],
			"config_keyboard_publication: invalid native modifier group")
		prefixes[prefix] = true
		local modifier_count, seen = dense_count(modifiers), {}
		capture(group); capture(prefix); capture(modifiers); capture(modifier_count)
		for offset = 1, modifier_count do
			local modifier = rawget(modifiers, offset)
			assert(type(modifier) == "string" and modifier ~= "" and not seen[modifier],
				"config_keyboard_publication: invalid native modifier")
			seen[modifier] = true; capture(modifier)
		end
		for offset = 1, key_count do ids[#ids + 1] = prefix .. rawget(rawget(keys, offset), "id") end
	end
	return ids, census
end

--- Publishes an admitted native source without loading or registering input.
--- @param keys table Complete native key records.
--- @param groups table Complete private native modifier groups.
--- @param contextual string Actual contextual slot owner.
--- @return function accessor Pure source-identity and semantic-census check.
function M.publish(keys, groups, contextual)
	local ids, source = project(keys, groups, contextual)
	Identity.keyboard_binding_catalogue(ids)
	return function(current_keys, current_groups, current_contextual)
		if not rawequal(keys, current_keys) or not rawequal(groups, current_groups)
			or contextual ~= current_contextual then return nil end
		local okay, current_ids, current = pcall(project, current_keys, current_groups, current_contextual)
		if not okay or #current ~= #source then return nil end
		for index, value in ipairs(source) do
			if not rawequal(value, current[index]) then return nil end
		end
		return Identity.keyboard_binding_catalogue(current_ids)
	end
end

return M
