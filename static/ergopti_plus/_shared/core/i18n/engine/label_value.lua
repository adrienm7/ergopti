--- _shared/core/i18n/engine/label_value.lua

--- ==============================================================================
--- MODULE: Label And Value
--- DESCRIPTION:
--- Joins a translated label to its value through common.label_value, the one
--- place the locale spells it: French puts a space before the colon, Chinese and
--- Japanese use a full-width colon, others a plain one. Windows has the same
--- rule in LabelValue (windows/infra/locale.ahk).
--- ==============================================================================

local M = {}

M.KEY = "common.label_value"

-- A lookup that answers with the key itself has no catalogue behind it: the
-- row keeps its value, and the lookup already reported the raw key. All 21
-- locales hold the key (tools/test/test-french-punctuation.cjs).
local NO_CATALOGUE_TEMPLATE = "{1}: {2}"

--- Fills the locale's template; both texts are literal data.
--- @param get function The i18n lookup, key to text.
--- @param label string The translated label.
--- @param value string|number The displayed value.
--- @return string
function M.compose(get, label, value)
	local template = get(M.KEY)
	if template == M.KEY then template = NO_CATALOGUE_TEMPLATE end
	if type(template) ~= "string" or not template:find("{1}", 1, true) or not template:find("{2}", 1, true) then
		error("locale key " .. M.KEY .. " does not hold {1} and {2}: " .. tostring(template), 2)
	end
	return (template:gsub("{([12])}", function(slot)
		return slot == "1" and tostring(label) or tostring(value)
	end))
end

return M
