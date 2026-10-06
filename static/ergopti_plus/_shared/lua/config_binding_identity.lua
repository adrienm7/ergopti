--- _shared/lua/config_binding_identity.lua

--- ==============================================================================
--- MODULE: Configuration Binding Identity (shared rule)
--- DESCRIPTION:
--- Judges supported binding families against complete catalogues published by
--- their native owners. Unavailable catalogues and other domains remain
--- unjudged; absent native identities in published catalogues are retired.
--- Readers warn and preserve that source until explicit cleanup, while ordinary
--- setters refuse to activate it. Publication admission belongs to native owners.
--- ==============================================================================

local M = {}

--- Detail shared by readers and cleanup for a retired gesture binding.
M.RETIRED_GESTURE = "no gesture slot of this build has this name"
M.RETIRED_SCRIPT = "no script chord slot of this build has this name"
M.RETIRED_TAP = "no number-row tap key of this build has this name"
M.RETIRED_KEYBOARD = "no keyboard shortcut slot of this build has this name"

--- Judges a binding only when its native gesture catalogue is published.
--- The owner supplies its actual complete slot ids, never an inferred empty
--- runtime inventory. A bare namespace belongs to the Lua gesture owners;
--- Windows publishes the same rule with its existing gesture__ prefix.
--- @param binding any Native binding id.
--- @param catalogue table|nil Published { prefix = string, slots = set }.
--- @return boolean|nil fits Nil means this rule cannot judge the binding.
function M.gesture_binding_fits(binding, catalogue)
	if catalogue == nil then return nil end
	assert(type(catalogue) == "table" and type(catalogue.prefix) == "string"
		and type(catalogue.slots) == "table", "config_binding_identity: invalid published catalogue")
	for slot, present in pairs(catalogue.slots) do
		assert(type(slot) == "string" and slot ~= "" and not slot:find("__", 1, true) and present == true,
			"config_binding_identity: invalid published slot set")
	end
	if type(binding) ~= "string" then return nil end
	local prefix = catalogue.prefix
	local slot
	if prefix == "" then
		if binding:find("__", 1, true) then return nil end
		slot = binding
	else
		if binding:sub(1, #prefix) ~= prefix then return nil end
		slot = binding:sub(#prefix + 1)
	end
	return catalogue.slots[slot] == true
end

--- Judges only the qualified script domain against an acknowledged native publication.
--- Missing publication remains unjudged; the reader never loads the catalogue.
--- @param binding any Native binding id.
--- @param catalogue table|nil Complete native publication.
--- @return boolean|nil fits
function M.script_binding_fits(binding, catalogue)
	if catalogue == nil then return nil end
	assert(type(catalogue) == "table" and catalogue.prefix == "script__",
		"config_binding_identity: invalid published script catalogue")
	assert(type(catalogue.slots) == "table" and next(catalogue.slots) ~= nil,
		"config_binding_identity: invalid published script catalogue")
	return M.gesture_binding_fits(binding, catalogue)
end

--- Builds the identity projection of the actual complete native tap-key source.
--- Native owners acknowledge their own read/close and platform keycodes first.
--- @param keys table Nonempty dense native array of key records.
--- @return table catalogue Detached qualified identity projection.
function M.tap_binding_catalogue(keys)
	assert(type(keys) == "table" and getmetatable(keys) == nil and next(keys) ~= nil,
		"config_binding_identity: invalid native tap-key catalogue")
	local slots, count = {}, 0
	for index, key in next, keys do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0
			and type(key) == "table" and getmetatable(key) == nil and type(key.id) == "string" and key.id ~= ""
			and not key.id:find("__", 1, true) and slots[key.id] == nil,
			"config_binding_identity: invalid native tap-key catalogue")
		slots[key.id], count = true, count + 1
	end
	for index = 1, count do
		assert(rawget(keys, index) ~= nil, "config_binding_identity: invalid native tap-key catalogue")
	end
	return { prefix = "tap_key__", slots = slots }
end

--- Judges only the tap-key domain after an acknowledged native publication.
--- @param binding any Native binding identity.
--- @param catalogue table|nil Complete native publication, never assignments.
--- @return boolean|nil fits
function M.tap_binding_fits(binding, catalogue)
	if catalogue == nil then return nil end
	assert(type(catalogue) == "table" and catalogue.prefix == "tap_key__"
		and type(catalogue.slots) == "table" and next(catalogue.slots) ~= nil,
		"config_binding_identity: invalid published tap-key catalogue")
	return M.gesture_binding_fits(binding, catalogue)
end

--- Builds a detached identity projection from the complete native shortcut inventory.
--- Native owners admit the actual group/key source and its read/close receipts first.
--- @param ids table Nonempty dense array of native slot ids, never active assignments.
--- @return table catalogue Detached qualified identity projection.
function M.keyboard_binding_catalogue(ids)
	assert(type(ids) == "table" and getmetatable(ids) == nil and next(ids) ~= nil,
		"config_binding_identity: invalid native keyboard catalogue")
	local slots, count = {}, 0
	for index, id in next, ids do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0
			and type(id) == "string" and id ~= "" and not id:find("__", 1, true) and slots[id] == nil,
			"config_binding_identity: invalid native keyboard catalogue")
		slots[id], count = true, count + 1
	end
	for index = 1, count do
		assert(rawget(ids, index) ~= nil, "config_binding_identity: invalid native keyboard catalogue")
	end
	return { prefix = "keyboard__", slots = slots }
end

--- Judges only keyboard bindings after an acknowledged complete native publication.
--- @param binding any Native binding identity.
--- @param catalogue table|nil Published catalogue, never menu rows or active assignments.
--- @return boolean|nil fits Missing or withdrawn publication remains unjudged.
function M.keyboard_binding_fits(binding, catalogue)
	if catalogue == nil then return nil end
	assert(type(catalogue) == "table" and catalogue.prefix == "keyboard__"
		and type(catalogue.slots) == "table" and next(catalogue.slots) ~= nil,
		"config_binding_identity: invalid published keyboard catalogue")
	return M.gesture_binding_fits(binding, catalogue)
end

return M
