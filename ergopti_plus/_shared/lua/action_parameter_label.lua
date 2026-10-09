--- _shared/lua/action_parameter_label.lua

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

--- Formats the value owned by one binding when that registry exposes parameters.
--- @param label string Translated action label.
--- @param registry table Action registry provided by the host.
--- @param binding string|nil The dispatch owner's binding id.
--- @param action string Action identifier.
--- @return string
function M.for_binding(label, registry, binding, action)
	if action == "none" or binding == nil or type(registry.get_action_parameter) ~= "function" then return label end
	return M.format(label, registry.get_action_parameter(binding, action))
end

return M
