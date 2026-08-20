--- modules/dynamic_hotstrings/prefix_rules.lua

--- ==============================================================================
--- MODULE: Prefix Expansions Built From personal_info.toml (Linux)
--- DESCRIPTION:
--- Turns the user's phone number, social-security number and IBAN into hotstring
--- mappings that complete themselves: typing the first few characters of any of
--- them expands to the whole value.
---
--- WHY THESE ARE MAPPINGS AND NOT DYNAMIC RULES:
--- The three date families and the @-tags fire on the magic key — the user types
--- `td★` and the engine resolves it. A prefix has no trigger character: typing
--- `0750` IS the trigger. So these belong to the ordinary hotstring matcher,
--- registered as auto-expanding mappings, not to the dynamic engine's rule list.
--- Windows and macOS both do it this way (`_km.add` with `auto_expand`), and the
--- thresholds below are theirs, read from the shared engine rather than
--- re-derived, so a change to one moves all three.
---
--- WHY EVERY MAPPING IS PRIVATE:
--- The replacement IS the secret, and so is the trigger — the first six
--- characters of an IBAN identify the account as surely as all twenty-seven. The
--- `is_private` flag keeps both out of the metrics database and the 14-day log;
--- see modules/keylogger/keylogger.lua, which is where it is honoured.
---
--- WHY THE GATE IS READ AT BUILD TIME:
--- A prefix mapping is matched by the ordinary engine, which knows nothing about
--- dynamic families. Switching a family off therefore has to remove its
--- mappings rather than filter them at match time, so the caller rebuilds. That
--- is also why this module is pure: given the same info and the same gate it
--- returns the same list, and the rebuild is the only moving part.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Engine = require("dynamic_hotstrings")

local LOG = "modules.dynamic_hotstrings.prefix_rules"

-- The category these mappings belong to, matching the group the dynamic rules
-- use so the menu counts them under one heading.
local GROUP = "dynamichotstrings"

-- The French international dialling prefix. A phone number stored as "0750…"
-- is also wanted as "+3375…", which is the form every non-French form expects.
local FRANCE_DIAL_PREFIX = "+33"

-- How many characters of each value are enough to identify it. Below these, a
-- prefix is short enough to collide with ordinary typing — three digits of a
-- phone number would fire inside any date.
local PHONE_MIN_FOR_SHORT   = 2   -- "07" + the magic key, an explicit request
local PHONE_MIN_FOR_PLAIN   = 4   -- "0750", unambiguous on its own
local PHONE_MIN_FOR_INNER   = 6   -- an inner slice, for the "+33" forms
local PHONE_FORMATTED_CHARS = 5   -- "07 50", the spaced form's own prefix
local SSN_PREFIX_CHARS      = 5
local IBAN_PREFIX_CHARS     = 6

-- Every mapping this module builds carries the same flags. auto_expand because
-- there is no terminator to wait for; is_private because both halves are secret.
local BASE_OPTS = {
	is_word           = false,
	auto_expand       = true,
	is_case_sensitive = true,
	is_private        = true,
	final_result      = false,
}




-- =========================================
-- =========================================
-- ======= 1/ Helpers ======================
-- =========================================
-- =========================================

--- Reads one [info] field as a string, treating anything else as absent.
--- @param info table
--- @param field string
--- @return string
local function field(info, field_name)
	local value = type(info) == "table" and info[field_name] or nil
	return type(value) == "string" and value or ""
end

--- Appends one mapping, unless its trigger is already taken.
---
--- A duplicate trigger would be dropped by the loader's dedup pass with a
--- warning naming a value that must not be logged, so it is refused here where
--- the refusal can stay quiet about which value it was.
--- @param out table
--- @param seen table
--- @param section string
--- @param trigger string
--- @param replacement string
--- @param case_sensitive boolean
--- @param field string The personal_info.toml field this value came from. It
---   travels to the preview row, which asks fields.toml whether the value may be
---   shown in full — so a mapping built without it is a mapping the bubble has to
---   assume is a secret.
local function add(out, seen, section, trigger, replacement, case_sensitive, field)
	if trigger == "" or replacement == "" or seen[trigger] then return end
	seen[trigger] = true

	local mapping = {
		trigger     = trigger,
		replacement = replacement,
		group       = GROUP,
		section     = section,
		field       = field,
	}
	for key, value in pairs(BASE_OPTS) do mapping[key] = value end
	mapping.is_case_sensitive = case_sensitive
	out[#out + 1] = mapping
end




-- =========================================
-- =========================================
-- ======= 2/ Building =====================
-- =========================================
-- =========================================

--- Builds every prefix mapping the user's data and their toggles allow.
---
--- @param info table The parsed [info] table from personal_info.toml.
--- @param is_section_enabled function|nil Predicate (group, section) → boolean.
---   Absent means every section is on, matching the shared engine's convention
---   for the same argument.
--- @return table Array of mapping tables, ready for the hotstring engine.
function M.build(info, is_section_enabled)
	local out, seen = {}, {}
	if type(info) ~= "table" then return out end

	local function enabled(section)
		if type(is_section_enabled) ~= "function" then return true end
		return is_section_enabled(GROUP, section) and true or false
	end

	local phone  = field(info, "phone_number")
	local fphone = field(info, "phone_number_clean")
	local ssn    = field(info, "social_security_number")
	local iban   = field(info, "iban")

	-- The decorative spaces are what the user wants typed BACK, but they must not
	-- be part of what the prefix matches against.
	local ssn_raw  = ssn:gsub("%s+", "")
	local iban_raw = iban:gsub("%s+", "")

	if enabled("phoneprefixes") then
		if #phone >= PHONE_MIN_FOR_SHORT then
			add(out, seen, "phoneprefixes", phone:sub(1, PHONE_MIN_FOR_SHORT), phone, true, "phone_number")
			add(out, seen, "phoneprefixes",
				FRANCE_DIAL_PREFIX .. phone:sub(1, PHONE_MIN_FOR_SHORT),
				FRANCE_DIAL_PREFIX .. phone, true, "phone_number")
		end
		if #phone >= PHONE_MIN_FOR_PLAIN then
			add(out, seen, "phoneprefixes", phone:sub(1, PHONE_MIN_FOR_PLAIN), phone, true, "phone_number")
			add(out, seen, "phoneprefixes",
				FRANCE_DIAL_PREFIX .. phone:sub(2, PHONE_MIN_FOR_PLAIN),
				FRANCE_DIAL_PREFIX .. phone, true, "phone_number")
		end
		if #phone >= PHONE_MIN_FOR_INNER then
			add(out, seen, "phoneprefixes", phone:sub(2, 5), phone, true, "phone_number")
		end
		if #fphone >= PHONE_FORMATTED_CHARS then
			add(out, seen, "phoneprefixes", fphone:sub(1, PHONE_FORMATTED_CHARS), fphone, true, "phone_number_clean")
		end
	end

	if enabled("ssnprefixes") then
		if #ssn_raw >= SSN_PREFIX_CHARS then
			local raw_prefix    = ssn_raw:sub(1, SSN_PREFIX_CHARS)
			local spaced_prefix = Engine.spaced_prefix(ssn, SSN_PREFIX_CHARS)
			-- The no-space trigger gives back the no-space value and the spaced one
			-- gives back the spaced value, so the user gets the form they started
			-- typing rather than the one that happens to be stored.
			add(out, seen, "ssnprefixes", raw_prefix, ssn_raw, true, "social_security_number")
			if spaced_prefix ~= raw_prefix then
				add(out, seen, "ssnprefixes", spaced_prefix, ssn, true, "social_security_number")
			end
		end
	end

	if enabled("ibanprefixes") then
		if #iban_raw >= IBAN_PREFIX_CHARS then
			local raw_prefix    = iban_raw:sub(1, IBAN_PREFIX_CHARS)
			local spaced_prefix = Engine.spaced_prefix(iban, IBAN_PREFIX_CHARS)
			-- Case-INsensitive, alone among the three: an IBAN is conventionally
			-- written in capitals and typed in whatever the user's hands produce.
			add(out, seen, "ibanprefixes", raw_prefix, iban_raw, false, "iban")
			if spaced_prefix ~= raw_prefix then
				add(out, seen, "ibanprefixes", spaced_prefix, iban, false, "iban")
			end
		end
	end

	Logger.debug(LOG, "Built %d prefix mapping(s).", #out)
	return out
end

--- How many mappings each section would contribute, for the menu's counts.
---
--- Delegates the arithmetic to the shared engine, which is the same source the
--- other two drivers count from — a count computed here would be a second
--- implementation of the thresholds above and would drift from them.
--- @param info table The parsed [info] table.
--- @return table { phoneprefixes, ssnprefixes, ibanprefixes }
function M.counts(info)
	if type(info) ~= "table" then
		return { phoneprefixes = 0, ssnprefixes = 0, ibanprefixes = 0 }
	end
	return Engine.compute_prefix_counts(
		field(info, "phone_number"),
		field(info, "phone_number_clean"),
		(field(info, "social_security_number"):gsub("%s+", "")),
		(field(info, "iban"):gsub("%s+", ""))
	)
end

return M
