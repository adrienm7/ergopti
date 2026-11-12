--- _shared/shortcuts/engine/action_parameter_label.lua

--- Replaces the localized configurable marker with a binding's literal value.
local M = {}

--- Formats an assigned action without keeping its unconfigured marker.
--- @param label string Translated action label ending in a bracketed marker.
--- @param value string|nil Value configured for this binding.
--- @return string
function M.format(label, value)
	if value == nil or value == "" then return label end
	local first = label:find("%[[^%[%]]*%]$")
	assert(first, "parameterized action label has no configurable marker")
	return label:sub(1, first - 1) .. "[" .. value .. "]"
end

--- Formats a value of a known parameter kind: a user action's value shows only
--- its safe summary (_shared/shortcuts/engine/user_action_parameter.lua label_value), a
--- program none, every other kind its literal value.
--- @param label string Translated action label.
--- @param spec string|nil The action's parameter kind.
--- @param value string|nil Value configured for this binding.
--- @return string
function M.for_spec(label, spec, value)
	if spec == "program" then return label end
	local UserActionParameter = require("shortcuts.engine.user_action_parameter")
	if UserActionParameter.KINDS[spec] then return M.format(label, UserActionParameter.label_value(spec, value)) end
	return M.format(label, value)
end

--- Formats the value owned by one binding when that registry exposes parameters.
--- @param label string Translated action label.
--- @param registry table Action registry provided by the host.
--- @param binding string|nil The dispatch owner's binding id.
--- @param action string Action identifier.
--- @return string
function M.for_binding(label, registry, binding, action)
	if action == "none" or binding == nil or type(registry.get_action_parameter) ~= "function" then return label end
	local spec = type(registry.get_action_parameter_spec) == "function" and registry.get_action_parameter_spec(action) or nil
	return M.for_spec(label, spec, registry.get_action_parameter(binding, action))
end

return M
