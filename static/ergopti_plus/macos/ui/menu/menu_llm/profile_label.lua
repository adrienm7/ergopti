--- ui/menu/menu_llm/profile_label.lua

--- ==============================================================================
--- MODULE: LLM Profile Label Formatter
--- DESCRIPTION:
--- Single source of truth for turning a raw profile label (as stored in the
--- shared locale files) into the string shown in the menu. Profile labels carry
--- two brace placeholders that depend on the live prediction count:
---   - "{n}" → the number of predictions currently configured.
---   - "{s}" → the plural marker ("s" when n > 1, "" otherwise).
---
--- WHY THIS EXISTS:
--- The label used to be formatted two different ways: profiles_manager substituted
--- "{n}"/"{s}" while model_switcher used string.format with "%d"/"%s". The locale
--- strings could only match one convention, so the other consumer leaked a literal
--- "%d prédiction%s" (or "{n} prédiction{s}") straight into the menu. Routing every
--- consumer through this one helper makes that whole class of bug impossible: there
--- is exactly one placeholder convention and one substitution. It mirrors the AHK
--- twin LLM_Menu_GetProfileLabel, which performs the same "{n}"/"{s}" replacement.
--- ==============================================================================

local M = {}
local text_utils = require("lib.text_utils")

-- The canonical default prediction count lives in the LLM module's DEFAULT_STATE
-- (single source of truth — CLAUDE.md §5.2). Resolving the fallback here means no
-- consumer has to re-derive it.
local llm_mod = require("modules.llm")





-- ===========================================
-- ===========================================
-- ======= 1/ Placeholder Substitution =======
-- ===========================================
-- ===========================================

--- Replaces the "{n}" / "{s}" placeholders in a profile label.
--- @param label string Raw label, typically straight from i18n.get().
--- @param num_preds number|string|nil Configured prediction count; falls back to
---        the canonical DEFAULT_STATE.llm_num_predictions when absent or invalid.
--- @return string The display-ready label ("" when label is not a string).
function M.format(label, num_preds)
	if type(label) ~= "string" then return "" end
	-- Fall back to the configured default (never a hardcoded literal) so the count
	-- always reflects the user's real setting — CLAUDE.md §5.4.
	local default_n = (llm_mod and llm_mod.DEFAULT_STATE and llm_mod.DEFAULT_STATE.llm_num_predictions) or 1
	local n = tonumber(num_preds) or default_n
	local s = (n > 1) and "s" or ""
	-- Parenthesised so only the substituted string escapes (gsub also returns a count).
	return (label:gsub("{n}", text_utils.escape_gsub_replacement(tostring(n))):gsub("{s}", text_utils.escape_gsub_replacement(s)))
end

return M
