--- tests/support/script_chord_sequence.lua

--- ==============================================================================
--- MODULE: Script Chord Sequence In A Deployed Graph
--- DESCRIPTION:
--- A running script chord is right Option pressed, then its key, with no key
--- between (platform/remap/script_chord_rules.lua, apply_sequence): every
--- deployed key manipulator lowers the sequence variable first at its
--- key-down, and a last rule lowers it for the keys no earlier rule takes.
--- Tests about another feature's manipulators read the graph without both.
--- ==============================================================================

local M = {}

local ScriptChordRules = require("platform.remap.script_chord_rules")
local LeaseContract    = require("platform.remap.lease_contract")

-- The logical name of the sequence variable, before the lease scopes it.
local SEQUENCE_LOGICAL = ScriptChordRules.sequence_var("ke_held_" .. ScriptChordRules.HOLDER_KEY)

--- Whether a deployed rule is the last one, which ends the sequence.
--- @param rule table Deployed Karabiner rule.
--- @return boolean
function M.is_sequence_rule(rule)
	return type(rule.description) == "string"
		and rule.description:find(ScriptChordRules.SEQUENCE_RULE_DESCRIPTION, 1, true) ~= nil
end

--- Whether a Karabiner event writes the sequence variable.
--- @param event table Karabiner event.
--- @return boolean
function M.is_sequence_event(event)
	local set = type(event) == "table" and event.set_variable
	if type(set) ~= "table" then return false end
	return LeaseContract.parse_runtime_variable_name(set.name) == SEQUENCE_LOGICAL
end

--- The events of a list but those writing the sequence variable.
--- @param events table|nil Karabiner events.
--- @return table events A new list.
function M.without_sequence(events)
	local kept = {}
	for _, event in ipairs(events or {}) do
		if not M.is_sequence_event(event) then kept[#kept + 1] = event end
	end
	return kept
end

return M
