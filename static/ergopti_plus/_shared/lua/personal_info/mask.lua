--- _shared/lua/personal_info/mask.lua

--- ==============================================================================
--- MODULE: Personal-Info Preview Masking (shared)
--- DESCRIPTION:
--- Turns a personal_info value into what the preview bubble may show. Pure: no
--- OS calls, no file reads of its own, no state. The caller supplies the policy
--- it read from _shared/modules/personal_info/fields.toml, so this module cannot
--- disagree with that file — it has no copy of it.
---
--- FEATURES & RATIONALE:
--- 1. Display only. Nothing here touches what gets TYPED. A masked value is a
---    string for a tooltip; the expansion is always the full value, and each
---    driver pins that at its own injection seam. If this module is ever reached
---    from an injection path, the bug is the call site, not the mask.
--- 2. Codepoint-aware, not byte-aware. An IBAN is ASCII, but a future field
---    need not be, and revealing "the last four bytes" of a UTF-8 string can cut
---    a character in half and produce a value that is both wrong and unreadable.
--- 3. Separators survive. Spaces in an IBAN, a card number and a French SSN are
---    decoration: they carry nothing, and masking them turns a recognisable
---    grouping into an unreadable run of dots. They also do not count toward the
---    revealed head and tail, so "FR76 3000 …" reveals two LETTERS, not "FR" and
---    then a space.
--- 4. Short values reveal nothing. Head 2 plus tail 4 applied to an eight-
---    character BIC shows six of them, which is not a mask — so below a declared
---    length the whole value is hidden.
--- ==============================================================================

local M = {}

-- The policy keys this module requires. Named so a caller that passes a
-- half-built table is told which key is missing rather than silently masking
-- with nil arithmetic.
local REQUIRED_POLICY = { "mask_char", "reveal_head", "reveal_tail", "min_length_to_reveal" }




-- =========================================
-- =========================================
-- ======= 1/ Codepoint helpers ============
-- =========================================
-- =========================================

--- Splits a UTF-8 string into an array of single-character strings.
---
--- Hand-rolled rather than using the standard library's codepoint iterator:
--- LuaJIT is 5.1-based and ships no such library, the Linux driver installs a
--- shim whose exact shape this module must not depend on, and the pattern below
--- is the one the rest of this repository already uses for the same job.
---
--- Named indirectly on purpose — tools/test/test-luajit-52-isms.cjs scans shared
--- Lua for that identifier and cannot tell a comment from a call, which is the
--- right trade for a check whose whole job is catching a name that resolves to
--- nil at runtime.
--- @param text string
--- @return table Array of characters.
local function characters(text)
	local out = {}
	for char in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		out[#out + 1] = char
	end
	return out
end

--- Whether a character is decoration rather than content.
--- @param char string One character.
--- @return boolean
local function is_separator(char)
	return char == " " or char == "-" or char == "\194\160"  -- space, hyphen, NBSP
end




-- =========================================
-- =========================================
-- ======= 2/ Masking ======================
-- =========================================
-- =========================================

--- Whether a policy table is safe for display masking.
--- @param policy table|nil
--- @return boolean ok, string|nil invalid_field
function M.validate_policy(policy)
	if type(policy) ~= "table" then return false, "policy" end
	for _, key in ipairs(REQUIRED_POLICY) do
		if policy[key] == nil then return false, key end
	end
	if type(policy.mask_char) ~= "string" or policy.mask_char == "" then
		return false, "mask_char"
	end
	for _, key in ipairs({ "reveal_head", "reveal_tail", "min_length_to_reveal" }) do
		local value = policy[key]
		if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
			return false, key
		end
	end
	if type(policy.preserve_separators) ~= "boolean" then
		return false, "preserve_separators"
	end
	if policy.reveal_head + policy.reveal_tail >= policy.min_length_to_reveal then
		return false, "reveal_window"
	end
	return true
end

--- Masks a value for display.
---
--- @param value string The full value, as it would be typed.
--- @param policy table From fields.toml [policy]: mask_char, reveal_head,
---   reveal_tail, min_length_to_reveal, preserve_separators.
--- @return string What the preview may show. The input unchanged when it is not
---   a string; an all-masked string when the value is too short to reveal.
function M.mask(value, policy)
	if type(value) ~= "string" or value == "" then return value end
	local ok = M.validate_policy(policy)
	-- Fail CLOSED. A caller with a broken policy gets everything hidden rather
	-- than everything shown: the whole point of this module is that a mistake
	-- must not end in a secret on screen.
	if not ok then
		local chars = characters(value)
		local out = {}
		for index = 1, #chars do out[index] = "•" end
		return table.concat(out)
	end

	local chars = characters(value)
	local preserve = policy.preserve_separators ~= false

	-- Content length, not string length: the thresholds are about how much of the
	-- SECRET is revealed, and the spaces in "FR76 3000 4000" are not secret.
	local content = 0
	for _, char in ipairs(chars) do
		if not (preserve and is_separator(char)) then content = content + 1 end
	end

	local head, tail = policy.reveal_head, policy.reveal_tail
	if content < policy.min_length_to_reveal then
		head, tail = 0, 0
	end

	local out = {}
	local seen = 0
	for _, char in ipairs(chars) do
		if preserve and is_separator(char) then
			out[#out + 1] = char
		else
			seen = seen + 1
			if seen <= head or seen > content - tail then
				out[#out + 1] = char
			else
				out[#out + 1] = policy.mask_char
			end
		end
	end
	return table.concat(out)
end

--- Masks a value only when its field is declared masked.
---
--- The entry point a preview row should call: it takes the field NAME, so the
--- decision and the masking cannot drift apart in a caller that remembers one
--- and forgets the other.
---
--- An unknown field is masked. A field that is not in fields.toml is a field
--- nobody classified, and the safe answer for something nobody classified is to
--- hide it — the opposite default reveals whatever a future edit forgets to
--- declare.
--- @param value string
--- @param field string|nil The personal_info.toml field name the value came from.
--- @param declaration table The parsed fields.toml: { policy = …, fields = … }.
--- @return string
function M.mask_field(value, field, declaration)
	if type(value) ~= "string" or value == "" then return value end
	if type(declaration) ~= "table" then return M.mask(value, nil) end

	local fields = type(declaration.fields) == "table" and declaration.fields or {}
	-- No field name at all means the value's provenance was lost on the way here,
	-- which is exactly the condition under which it must not be assumed public.
	local entry = (type(field) == "string") and fields[field] or nil
	if entry ~= nil and entry.masked == false then return value end

	return M.mask(value, declaration.policy)
end




-- =========================================
-- =========================================
-- ======= 3/ Redaction for the log ========
-- =========================================
-- =========================================

--- What a LOG LINE may keep of a private value.
---
--- The masking above reveals a head and a tail so the user can recognise their
--- own value on their own screen. A log has no such reader: it is written to
--- disk, rotated, and on this project replicated to the user's other machines.
--- So the only safe answer there is that none of the content survives.
---
--- The LENGTH does survive — one mask character per character — because the
--- arithmetic downstream is computed from it and dropping it would trade a
--- privacy bug for a metrics bug. This is the same contract as the Linux
--- keylogger's `recorded_char` and the Windows `PersonalInfoRedactForLog`; it
--- lives here so the three drivers cannot answer it differently.
---
--- @param value string The complete value, as it would be typed.
--- @param policy table|nil From fields.toml [policy]; only `mask_char` is read.
--- @return string A run of mask characters of the same length; the input
---   unchanged when it is not a non-empty string.
function M.redact_for_log(value, policy)
	if type(value) ~= "string" or value == "" then return value end
	-- Fail closed on a missing policy exactly as M.mask does: a broken policy
	-- must not become a reason to print the value.
	local mask_char = (type(policy) == "table" and type(policy.mask_char) == "string"
		and policy.mask_char ~= "") and policy.mask_char or "\226\128\162"  -- U+2022
	local out = {}
	for index = 1, #characters(value) do
		out[index] = mask_char
	end
	return table.concat(out)
end

return M
