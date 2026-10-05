--- _shared/lua/config_binding_identity.lua

--- ==============================================================================
--- MODULE: Configuration Binding Identity (shared rule)
--- DESCRIPTION:
--- Judges only gesture bindings against a complete catalogue published by their
--- native owner. An unavailable catalogue or another binding domain remains
--- unjudged; a missing gesture in a published catalogue is retired. Readers
--- warn and preserve that source until explicit cleanup, while ordinary setters
--- refuse to activate it.
--- ==============================================================================

local M = {}

--- Detail shared by readers and cleanup for a retired gesture binding.
M.RETIRED_GESTURE = "no gesture slot of this build has this name"

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

return M
