--- _shared/lua/tap_hold/combination_labels.lua

--- ==============================================================================
--- MODULE: Canonical Physical Combination Labels
--- DESCRIPTION:
--- Resolves ordered physical key identities through the shared tap-hold
--- catalogue. Display names never decide grouping or native binding identity.
--- ==============================================================================

local M = {}

--- Resolves one ordered pair without mutating the catalogue or native matrix.
--- @param catalogue table Driver entries returned by tap_hold.key_catalog.
--- @param first_id string Native identity of the key pressed first.
--- @param second_id string Native identity of the key pressed second.
--- @param translate function Active locale's key-label accessor.
--- @return table Labels and the first physical identity used for grouping.
function M.resolve(catalogue, first_id, second_id, translate)
	local first, second
	for _, key in ipairs(catalogue) do
		if key.id == first_id then first = key end
		if key.id == second_id then second = key end
	end
	if first == nil or second == nil then
		error("combination labels require two catalogued physical keys", 2)
	end
	local first_label, second_label = translate(first.label_key), translate(second.label_key)
	if type(first_label) ~= "string" or first_label == ""
		or type(second_label) ~= "string" or second_label == "" then
		error("combination labels require two non-empty translated key names", 2)
	end
	return { group_id = first.id, group_label = first_label,
		label = first_label .. " + " .. second_label, hand = first.hand }
end

return M
