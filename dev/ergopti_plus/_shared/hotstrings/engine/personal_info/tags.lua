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
---    Windows map (`PERSONAL_INFO_TAGS`, hotstrings/engine/catalogue/personal_info_preview.ahk) is
---    pinned to it by tools/test/test-personal-info-tags-single-source.cjs.
--- 3. A named tag is case-insensitive; a letter tag follows the typed case
---    (cased_value, HCD-5).
--- ==============================================================================

local M = {}

local UnicodeCase = require("core.text.engine.unicode_case")

--- The dynamic family section every @-tag belongs to: its switch, its preview
--- gate and its expansion delay (HCD-4) are read under this name.
M.SECTION = "personal_info"

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

--- Whether a typed tag letter asks for capitals: it is a cased letter typed in
--- its upper form. A letter with no case (a digit, an uncased script) asks for
--- the value as stored.
--- @param letter string One typed codepoint of the tag.
--- @return boolean
function M.letter_is_upper(letter)
	if type(letter) ~= "string" or letter == "" then return false end
	local ok_upper, upper = pcall(UnicodeCase.upper, letter)
	local ok_lower, lower = pcall(UnicodeCase.lower, letter)
	return ok_upper and ok_lower and upper == letter and lower ~= letter
end

--- The value a letter alias types, cased as the letter was typed (maintainer
--- decision HCD-5, 2026-11-21). A personal tag follows the typed case the way
--- a word hotstring does for mot / Mot / MOT, one field per letter: a lower
--- letter types its field as stored, an upper letter types it in capitals.
--- `@np` types « Nom Prénom », `@Np` « NOM Prénom », `@NP` « NOM PRÉNOM ». A named
--- tag (`@iban`, `@IBAN`) names a field, not a letter: it types the value as
--- stored whatever its case. Pinned on the three OS by
--- _shared/tests/corpus/personal_info/tag_case_vectors.json.
--- @param letter string The typed tag letter.
--- @param value string The field's stored value.
--- @return string
function M.cased_value(letter, value)
	if M.letter_is_upper(letter) then return UnicodeCase.upper(value) end
	return value
end

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
