--- _shared/hotstrings/engine/personal_info/tags.lua

--- ==============================================================================
--- MODULE: Personal-Info Named Tags (shared)
--- DESCRIPTION:
--- The @-tags that name ONE personal_info field (`@iban★` types the IBAN and
--- nothing else). Pure data and one lookup: no OS calls and no state.
---
--- FEATURES & RATIONALE:
--- 1. A named tag wins over the letter aliases. Read letter by letter, `@iban★`
---    typed the IBAN, the BIC, the street and the surname, and `@ss★` the
---    social security number twice: more personal data than the user asked for
---    (HCD-3, decided by the agent on 2026-11-13, to review by the maintainer).
--- 2. One table for the three drivers. macOS and Linux read this module; the
---    Windows map (`PERSONAL_INFO_TAGS`, infra/personal_info_preview.ahk) is
---    pinned to it by tools/test/test-personal-info-tags-single-source.cjs.
--- 3. Case-insensitive, as the Windows hotstrings (no C flag) are.
--- ==============================================================================

local M = {}

local UnicodeCase = require("core.text.engine.unicode_case")

--- Tag (lower case, without « @ » and the trigger) → personal_info field.
M.FIELDS = {
	bic  = "bic",
	cb   = "credit_card",
	cc   = "credit_card",
	iban = "iban",
	rib  = "iban",
	ss   = "social_security_number",
	tel  = "phone_number",
	["tél"] = "phone_number",
}

--- The field a named tag types, or nil when the tag is not a named one.
--- @param tag string The tag without its « @ » and without the trigger.
--- @return string|nil field
function M.field(tag)
	if type(tag) ~= "string" or tag == "" then return nil end
	local ok, lower = pcall(UnicodeCase.lower, tag)
	if not ok or type(lower) ~= "string" then return nil end
	return M.FIELDS[lower]
end

return M
