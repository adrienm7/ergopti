--- modules/dynamic_hotstrings/manager.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings Manager (Linux)
--- DESCRIPTION:
--- Loads personal_info.toml, registers @-tag letter-shortcut rules and date
--- expansion rules in the shared dynamic_hotstrings engine, and provides an
--- on_char hook for the daemon to match and inject dynamic expansions.
---
--- FEATURES & RATIONALE:
--- 1. TOML-driven: reads personal_info.toml from ~/.config/ergopti/ (or falls
---    back to shared defaults), parses [info] fields and [letters] mappings,
---    and registers one rule per letter shortcut (e.g. "@p" → first_name).
--- 2. Date rules: td → 2026_07_08, dt → 08/07/2026, date → long French.
--- 3. Shared engine: delegates all matching logic to the canonical
---    _shared/lua/dynamic_hotstrings/init.lua module — zero duplication.
--- 4. Trigger-agnostic: the caller supplies the trigger character (default
---    "★") so the engine matches regardless of which key the user configured.
--- 5. Injection: when a match fires, delegates to modules.hotstrings.injector
---    for ydotool-based text injection (same path as static hotstrings).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ManifestReader = require("infra.manifest_reader")

-- Shared TOML decoder — this module owns no bespoke parser.
local TomlCodec = require("toml_codec")

local LOG = "modules.dynamic_hotstrings.manager"

-- The category these rules belong to, as the menu and the delay cascade name it.
-- Passed to the shared engine's section guard, which takes (group, section).
local DYNAMIC_GROUP = "dynamichotstrings"

-- How many rules register_date_rules adds: td, dt and date. Named because the
-- rule total is also read back the other way — to work out how many @-tags there
-- are, which is everything that is not one of these three.
local DATE_RULE_COUNT = 3

-- U+21E5 RIGHTWARDS ARROW TO BAR, between two fields of a multi-field preview
-- row. The expansion types a real Tab keystroke there (the values land in
-- consecutive form fields) and a literal tab is invisible in a bubble, so the
-- glyph stands in for it. macOS shows the same character in the same place
-- (personal_info.lua) and so does Windows (PI_PREVIEW_FIELD_SEPARATOR); a row
-- that read differently on two machines is not the same check.
local PREVIEW_FIELD_SEPARATOR = " \226\135\165 "

-- The category a personal-information preview row resolves its colour, delay and
-- "show the bubble" toggle through. These rows carry the user's own data, so they
-- wear the personal colour on all three drivers — ui/tooltip/preview.lua keys its
-- PERSONAL_CATEGORY tint on exactly this string.
local PERSONAL_PREVIEW_GROUP = "personal"

-- The engine section every @-tag rule is registered under. Named because three
-- separate decisions read it — the per-family switch, the preview gate and the
-- privacy flag on a fired expansion — and a literal repeated at three sites is a
-- literal that can be corrected at two of them.
local PERSONAL_SECTION = "personal_info"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Active trigger character. Seeded from the shared manifest — the declaration
-- is the only place the default lives — and overridden by init() when the user
-- has chosen another one.
local _trigger_char = ManifestReader.default_for("hotstrings.trigger_char")
local _enabled      = true         -- master enable/disable toggle
local _rules_count  = 0            -- how many rules were registered
local _info         = {}           -- parsed [info] table
local _letters      = {}           -- parsed [letters] map

local native_utf8 = rawget(_G, "utf8")
local utf8_lib = (type(native_utf8) == "table" and native_utf8.len
	and native_utf8.codes and native_utf8.char)
	and native_utf8 or require("compat.utf8")

local function strict_codepoint_length(value)
	if type(value) ~= "string" then return nil end
	local ok, length = pcall(utf8_lib.len, value)
	if not ok or type(length) ~= "number" then return nil end
	return length
end

local function strict_codepoints(value)
	local expected_length = strict_codepoint_length(value)
	if expected_length == nil then return nil end

	local codepoints = {}
	local ok = pcall(function()
		for _, codepoint in utf8_lib.codes(value) do
			codepoints[#codepoints + 1] = utf8_lib.char(codepoint)
		end
	end)
	if not ok or #codepoints ~= expected_length then return nil end
	return codepoints
end


-- =========================================
-- =========================================
-- ======= 2/ TOML Parser ==================
-- =========================================
-- =========================================

--- Decodes personal_info.toml via the shared toml_codec and returns the [info]
--- and [letters] tables. All TOML parsing is delegated to the shared codec —
--- this module owns no bespoke parser.
--- @param path string Absolute path to personal_info.toml.
--- @return table info, table letters
local function _parse_personal_info_toml(path)
	local fh = io.open(path, "r")
	if not fh then return {}, {} end
	local content = fh:read("*a")
	fh:close()

	-- Delegate all TOML parsing to the shared codec; decode returns nil on a
	-- spec violation.
	local parsed = TomlCodec.decode(content)
	if type(parsed) ~= "table" then
		Logger.error(LOG, "personal_info.toml at '%s' is malformed — @-tag shortcuts disabled.", path)
		return {}, {}
	end

	local info    = (type(parsed.info) == "table") and parsed.info or {}
	local letters = (type(parsed.letters) == "table") and parsed.letters or {}
	return info, letters
end





-- ===========================================
-- ===========================================
-- ======= 3/ Init & Rule Registration =======
-- ===========================================
-- ===========================================

--- Loads personal_info.toml and registers @-tag + date rules in the shared
--- dynamic_hotstrings engine.
--- @param opts table|nil { trigger_char?, personal_info_path? }
function M.init(opts)
	local options = type(opts) == "table" and opts or {}

	-- Resolve trigger character (default "★").
	if options.trigger_char ~= nil then
		if strict_codepoint_length(options.trigger_char) ~= 1 then
			Logger.error(LOG, "Dynamic hotstring trigger must be exactly one valid UTF-8 codepoint.")
			_enabled = false
			return false
		end
		_trigger_char = options.trigger_char
	end
	if strict_codepoint_length(_trigger_char) ~= 1 then
		Logger.error(LOG, "Dynamic hotstring trigger must be exactly one valid UTF-8 codepoint.")
		_enabled = false
		return false
	end

	-- Resolve personal_info.toml path.
	local home = require("infra.config_paths").home()
	local default_path = home .. "/.config/ergopti/personal_info.toml"
	local info_path = options.personal_info_path or default_path

	-- Load shared engine.
	local ok_eng, Engine = pcall(require, "dynamic_hotstrings")
	if not ok_eng or not Engine then
		Logger.warn(LOG, "Shared dynamic_hotstrings engine not available — disabled.")
		_enabled = false
		return
	end

	-- Reset any previously registered rules.
	Engine.reset_rules()

	-- Stage parsed state and the count locally. Re-initialisation is synchronous,
	-- but readers must never observe a cumulative count left over from the
	-- previous rule set while the engine itself has already been reset.
	local staged_info, staged_letters = _parse_personal_info_toml(info_path)

	-- Register @-tag letter shortcuts (e.g. "@p" → first_name).
	for letter, field in pairs(staged_letters) do
		local alias_length = strict_codepoint_length(letter)
		-- Alias keys are exact codepoints. Precomposed aliases such as NFC "é"
		-- are accepted; decomposed multi-codepoint spellings are rejected rather
		-- than normalized, which avoids silently merging two user-owned mappings.
		if alias_length == 1 and staged_info[field] then
			local value = staged_info[field]
			Engine.add_rule(
				"@" .. letter,                      -- suffix: "@p"
				PERSONAL_SECTION,                    -- section
				function() return value end          -- resolver
			)
		elseif alias_length == nil then
			Logger.error(LOG, "Personal alias rejected: key is not valid UTF-8.")
		elseif alias_length ~= 1 then
			Logger.error(LOG,
				"Personal alias rejected: key must be exactly one codepoint; normalization is not applied (got %d).",
				alias_length)
		end
	end

	-- Register date rules (td, dt, date).
	Engine.register_date_rules(_trigger_char)
	local registered_rules = Engine.get_rules()
	if type(registered_rules) ~= "table" then
		Logger.error(LOG, "Dynamic rule registration returned no readable rule set.")
		_enabled = false
		return false
	end
	local staged_rules_count = #registered_rules

	-- Publish the staged snapshot only after registration completed. This keeps
	-- the reported count identical to the engine after every reload or magic-key
	-- change instead of accumulating the previous initialisation's total.
	_info = staged_info
	_letters = staged_letters
	_rules_count = staged_rules_count

	-- The parsed [info] table is string-keyed, so the length operator (#) always
	-- reports 0; count its keys explicitly to log the real field total
	local info_field_count = 0
	for _ in pairs(_info) do info_field_count = info_field_count + 1 end

	_enabled = _rules_count > 0
	Logger.info(LOG, "Dynamic hotstrings initialised: %d rule(s), trigger='%s', info=%d field(s).",
		_rules_count, _trigger_char, info_field_count)
	return true
end

--- The personal_info fields an @-tag expands to, in the order they are typed.
---
--- THE SINGLE SOURCE for what "@np" means: the fire path and the preview bubble
--- both call this, so the two cannot answer differently. Windows learned that the
--- expensive way — its bubble and its engine each had their own idea of which
--- combos existed, and the bubble stayed silent for a family that expanded fine.
---
--- Multi-letter combos are NOT registered as rules. With thirteen alias letters
--- the space is 169 combinations at length two and 28 561 at length four, so
--- pre-registering is not an option and a hand-written selection of them is worse
--- than none (Windows shipped thirty-one and was missing @npdt and @nt). Resolving
--- at use time makes every combination work at flat cost, and makes the ORDER
--- significant for free: @np and @pn walk the same letters in different sequence.
---
--- An unknown letter, or a letter aliasing a field the user left blank, declines
--- the WHOLE tag rather than skipping that field. A partial expansion in a form
--- shifts every later value up by one box, which is silently wrong; nothing
--- happening is merely visibly wrong. Note this differs from macOS's
--- `resolve_combo`, which skips what it cannot resolve — see PROJECT_MEMORY.
--- @param tag string The tag WITHOUT its leading "@" and without the trigger.
--- @return table Array of personal_info field names; empty when the tag resolves to none.
function M.resolve_combo(tag)
	local fields = {}
	if type(tag) ~= "string" or tag == "" then return fields end
	local letters = strict_codepoints(tag)
	if not letters then return fields end

	-- Lower-cased because the single-letter rules are registered lower-cased and
	-- typing "@NP" must mean what "@np" means.
	for _, raw_letter in ipairs(letters) do
		local letter = raw_letter:lower()
		local field = _letters[letter]
		if not field then return {} end
		local value = _info[field]
		if type(value) ~= "string" or value == "" then return {} end
		fields[#fields + 1] = field
	end
	return fields
end

--- The values an @-tag expands to, in order.
--- @param tag string The tag without its "@" and without the trigger.
--- @return table Array of strings; empty when the tag resolves to nothing.
function M.resolve_combo_values(tag)
	local values = {}
	for _, field in ipairs(M.resolve_combo(tag)) do
		values[#values + 1] = _info[field]
	end
	return values
end

--- The @-tag the buffer ends with, or "" when it does not end with one.
---
--- Walks backwards over letters to the "@" rather than matching a pattern: Lua's
--- `%a` class is byte-oriented and would stop at the first byte of an accented
--- letter, and an accented alias is a thing a user can put in [letters].
--- @param buffer string The typing buffer, WITHOUT the trigger character.
--- @return string The tag without its "@", or "".
function M.trailing_tag(buffer)
	if type(buffer) ~= "string" or buffer == "" then return "" end
	local at = buffer:find("@[^@]*$")
	if not at then return "" end
	local tag = buffer:sub(at + 1)
	-- "@" with nothing after it is not a tag yet.
	if tag == "" then return "" end
	-- Anything that is not a letter ends the tag — and since a separator can only
	-- appear INSIDE what we just cut, its presence means the "@" belongs to an
	-- earlier word (an email address, most often) rather than to a tag.
	if tag:find("[%s%p%d]") then return "" end
	return tag
end

--- Returns true when the module has been initialised and has active rules.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Enables/disables the module at runtime.
--- @param state boolean
function M.set_enabled(state)
	_enabled = state and true or false
end


-- =========================================
-- =========================================
-- ======= 4/ Match & Inject ===============
-- =========================================
-- =========================================

--- Expands a multi-letter @-combo, the fallback when no registered rule matched.
---
--- Gated on the SAME switch as the single-letter tags: a combo is a concatenation
--- of the very fields those tags expand to, so a user who turned the personal-info
--- family off has turned this off too. Reading the switch here rather than at
--- registration is what makes the toggle live — there is nothing registered to
--- remove when it flips.
--- @param prefix string The buffer without the trigger character.
--- @param trigger string The trigger character that fired.
--- @return boolean fired
--- @return table|nil event Canonical event details when it fired.
local function _fire_combo(prefix, trigger)
	if not M.is_rule_enabled(DYNAMIC_GROUP, PERSONAL_SECTION) then return false end

	local tag = M.trailing_tag(prefix)
	if tag == "" then return false end

	local values = M.resolve_combo_values(tag)
	-- A single-letter tag that resolves here is one the registered rule already
	-- declined — its section is off, or the engine holds no rule for it — so
	-- expanding it now would route around a decision that was already taken.
	if #values < 2 then return false end
	local tag_length = strict_codepoint_length(tag)
	if tag_length == nil then
		Logger.error(LOG, "@-combo contains invalid UTF-8; expansion refused.")
		return false
	end

	local ok_inj, injector = pcall(require, "modules.hotstrings.injector")
	if not ok_inj or not injector or type(injector.inject_fields) ~= "function" then
		Logger.warn(LOG, "Injector not available — @-combo dropped: '@%s'.", tag)
		return false
	end

	-- "@" + the letters + the trigger: everything the user typed for this.
	local backspace_count = tag_length + 2
	-- is_private is not optional: every value here comes out of personal_info.toml,
	-- so the payload is the user's own data by construction.
	local delivery = injector.inject_fields(backspace_count, values, true)
	if type(delivery) ~= "table" or delivery.ok ~= true then
		Logger.error(LOG, "@-combo output did not commit: '@%s'.", tag)
		return false
	end

	local total = 0
	for _, value in ipairs(values) do total = total + #value end
	Logger.info(LOG, "@-combo expansion: '@%s' → %d field(s), %d char(s) (content withheld).",
		tag, #values, total)

	return true, {
		trigger = "@" .. tag .. trigger,
		-- The LOGICAL text: values only, no tab. A Tab moves focus and inserts
		-- nothing on screen, so this is what the buffer and the keylogger's record
		-- must hold — the same split macOS documents at its own injection seam.
		replacement = table.concat(values),
		h_type = "dynamic",
		backspace_count = backspace_count,
		is_private = true,
	}
end

--- Called by the daemon on every character. Checks the current typing buffer
--- against the shared engine and injects when a rule matches.
---
--- @param buffer string The current typing buffer (engine:current_buffer()).
--- @param trigger string The character that just triggered the check (the
---   magic key, typically "★" or "\\").
--- @return boolean True if a dynamic expansion was performed.
--- @return table|nil Canonical event details for a successful expansion.
function M.on_trigger(buffer, trigger)
	if not _enabled then return false end
	if type(buffer) ~= "string" or buffer == "" then return false end

	-- Only fire on the configured trigger character.
	-- The daemon calls this for every character, so accepting the current one as
	-- the trigger makes the guard tautological and lets `tdx` fire the `td` rule.
	if trigger ~= _trigger_char then return false end
	local t = _trigger_char
	if strict_codepoint_length(t) ~= 1 or buffer:sub(-#t) ~= t then return false end

	-- Injector loaded once at init; stored via closure below.
	local Engine = require("dynamic_hotstrings")
	if not Engine then return false end

	-- The shared engine matches the buffer SUFFIX (without the trigger char
	-- itself). Pass the buffer MINUS the last char (the trigger).
	local prefix = buffer:sub(1, -(#t + 1))
	if prefix == "" then return false end

	local match = Engine.match_buffer(prefix, DYNAMIC_GROUP, M.is_rule_enabled)
	if not match then
		-- Nothing registered claimed the sequence. Only now try the multi-letter
		-- @-combo, so a registered tag always wins: "@dt" spells two valid alias
		-- letters AND is the short-date rule, and the registration is what decides.
		return _fire_combo(prefix, t)
	end

	-- Inject: erase the suffix + trigger, type the result.
	-- e.g. buffer "@p★" → backspace 3 chars → type "Adrien"
	local suffix_length = strict_codepoint_length(match.rule.suffix)
	if not suffix_length then
		Logger.error(LOG, "Dynamic rule output is invalid UTF-8 (%d-byte resolved content withheld); expansion refused.",
			#match.result)
		return false
	end
	local backspace_count = suffix_length + 1  -- suffix + trigger
	-- Injector is loaded once at require-time; the hotstrings injector module
	-- wraps ydotool and is always available on Linux.
	local ok_inj, injector = pcall(require, "modules.hotstrings.injector")
	if ok_inj and injector and type(injector.inject) == "function" then
		local delivery = injector.inject(backspace_count, match.result,
			match.rule.section == PERSONAL_SECTION)
		if type(delivery) ~= "table" or delivery.ok ~= true then
			Logger.error(LOG, "Dynamic expansion output did not commit: '%s'.",
				match.rule.suffix)
			return false
		end
		-- `match.result` is the RESOLVED value: for "@i★" it is the user's IBAN,
		-- for "@t★" their phone number. This line used to print it in full, at
		-- INFO, with the shared logger's default level at 10 — so it reached the
		-- driver's log unconditionally, no opt-in, on every expansion. Windows
		-- redacts the equivalent site and macOS has no such line at all; Linux was
		-- the only driver still writing it.
		--
		-- Redacted rather than dropped: the length is what tells you WHICH field
		-- expanded when a rule misfires, and it is the only diagnostic this line
		-- carried that is worth keeping. The date rules take the same path, and
		-- a date is not a secret — but the group cannot be told apart here without
		-- re-deriving what the resolver already decided, and printing a date is
		-- not worth a branch that could get the answer wrong.
		Logger.info(LOG, "Dynamic expansion: '%s' → %d char(s) (content withheld).",
			match.rule.suffix, #match.result)
		return true, {
			trigger = match.rule.suffix .. t,
			replacement = match.result,
			h_type = "dynamic",
			backspace_count = backspace_count,
			-- The SECTION decides, and it is the only thing here that can: the
			-- resolver has already run and its output is just a string. Everything
			-- registered under "personal_info" resolves a field of the user's own
			-- personal_info.toml; the three date rules resolve a date, which is not
			-- a secret and must stay legible in the metrics.
			is_private = (match.rule.section == PERSONAL_SECTION),
		}
	end

	Logger.warn(LOG, "Injector not available — expansion dropped: '%s'.", match.rule.suffix)
	return false
end

--- Preview rows for the @-family, in the shape `engine:candidates()` returns.
---
--- WHY THE BUBBLE NEEDED A SECOND SOURCE: the daemon builds its preview from
--- `engine:candidates()`, which reads the static hotstring matcher's buckets. The
--- @-tags live in a DIFFERENT engine (the dynamic one) and the multi-letter
--- combos are not registered anywhere at all, so no key beginning with "@" could
--- ever appear there. The whole family expanded correctly and previewed nothing —
--- the same gap Windows had, for the same reason, and fixed the same way.
---
--- `parts` and `fields` are parallel arrays rather than one joined string: each
--- value has to be masked against ITS OWN classification, so an IBAN is hidden
--- while the phone number beside it is not. Joining first would force one verdict
--- on the whole row.
--- @param buffer string The typing buffer, WITHOUT the trigger character.
--- @return table Array of candidate records; empty when nothing is offered.
function M.preview_candidates(buffer)
	local rows = {}
	if not _enabled then return rows end
	if not M.is_rule_enabled(DYNAMIC_GROUP, PERSONAL_SECTION) then return rows end

	local tag = M.trailing_tag(buffer)
	if tag == "" then return rows end

	local fields = M.resolve_combo(tag)
	if #fields == 0 then return rows end

	-- A single-letter tag is a registered rule and reaches the bubble through the
	-- ordinary path; offering it here too would draw the same row twice.
	if #fields < 2 then return rows end

	local parts = {}
	for index, field in ipairs(fields) do parts[index] = _info[field] end

	rows[#rows + 1] = {
		trigger  = "@" .. tag .. _trigger_char,
		-- `replacement` is what a consumer that knows nothing about `parts` would
		-- show. It stays UNMASKED here for the same reason the fire path holds the
		-- real values: masking is the display layer's job, and doing it twice or in
		-- the wrong place is how a masked value once reached an injector.
		replacement = table.concat(parts, PREVIEW_FIELD_SEPARATOR),
		parts    = parts,
		fields   = fields,
		group    = PERSONAL_PREVIEW_GROUP,
		section  = PERSONAL_SECTION,
		fires    = true,
	}
	return rows
end

--- Returns the preview string for the current buffer (tooltip display).
--- @param buffer string The current typing buffer.
--- @return string|nil Preview text, or nil.
function M.preview(buffer)
	if not _enabled then return nil end
	if type(buffer) ~= "string" or buffer == "" then return nil end

	local ok_eng, Engine = pcall(require, "dynamic_hotstrings")
	if not ok_eng or not Engine then return nil end

	-- The same guard as the match path. A preview that offers what the engine
	-- will refuse is worse than no preview: the user sees a rule they switched
	-- off and concludes the toggle does nothing.
	if strict_codepoint_length(_trigger_char) ~= 1 or buffer:sub(-#_trigger_char) ~= _trigger_char then
		return nil
	end
	return Engine.preview(buffer:sub(1, -(#_trigger_char + 1)), DYNAMIC_GROUP, M.is_rule_enabled)
end


-- =========================================
-- =========================================
-- ======= 5/ Accessors ====================
-- =========================================
-- =========================================

--- Returns the active trigger character.
--- @return string
function M.get_trigger_char()
	return _trigger_char
end

--- Returns the number of registered rules.
---
--- The RULES only — the @-tags and the three dates. The prefix expansions are
--- mappings held by the ordinary matcher and are not registered here, so the
--- menu asks `active_count()` instead; this stays what its name says for the
--- boot log, which reports what the dynamic engine took.
--- @return number
function M.get_rules_count()
	return _rules_count
end

--- How many expansions this category currently offers, switches accounted for.
---
--- What the other two drivers show beside the category name: the sum over
--- ENABLED families, so the number tracks what is live rather than what would
--- come back. Windows computes it the same way in `_HS_CategoriesDynamic`.
--- @return number
function M.active_count()
	local total = 0

	-- One rule each, and the engine registers them as a batch, so the count is
	-- the number of enabled date families rather than anything it can be asked.
	for _, section in ipairs({ "date", "datefr", "datelongfr" }) do
		if M.is_rule_enabled(nil, section) then total = total + 1 end
	end

	-- The @-tags: whatever [letters] mapped to a field that exists.
	if M.is_rule_enabled(nil, "personal_info") then
		total = total + math.max(0, _rules_count - DATE_RULE_COUNT)
	end

	local ok, Prefix = pcall(require, "modules.dynamic_hotstrings.prefix_rules")
	if ok and Prefix then
		local counts = Prefix.counts(_info)
		for _, section in ipairs({ "phoneprefixes", "ssnprefixes", "ibanprefixes" }) do
			if M.is_rule_enabled(nil, section) then total = total + (counts[section] or 0) end
		end
	end

	return total
end

--- Returns a copy of the parsed personal info (for testing/diagnostics).
--- @return table
function M.get_info()
	local copy = {}
	for k, v in pairs(_info) do copy[k] = v end
	return copy
end




-- =========================================
-- =========================================
-- ======= 6/ Per-rule switches ============
-- =========================================
-- =========================================

--- The rule families the manifest declares, in the order Windows and macOS
--- render them (`_DYNAMIC_HOTSTRINGS_ORDER` in tray_menu.ahk, `_sections` in
--- macos/modules/dynamic_hotstrings/rules_engine.lua — the two already agree).
---
--- `id` is the manifest id under `hotstrings.dynamic`; `section` is what the
--- shared engine registers the rule under, and the two differ because the locale
--- catalogue folds underscores away. `_shared/modules/features/manifest.toml`
--- and `_shared/data/locales/*.json` are those two spellings' sources.
---
--- Windows and macOS offer one toggle per family; Linux offered only the
--- category gate, and the plan recorded the blocker as "the shared engine
--- registers the date rules as a batch with no identifier". That was wrong —
--- `add_rule(suffix, section, resolver)` has carried a section all along, and
--- `match_buffer` has always taken a predicate to filter on it. The gap was that
--- this driver passed nil for it.
---
--- The three prefix families are not dynamic RULES: a prefix has no trigger
--- character, so they are ordinary auto-expanding mappings assembled by
--- prefix_rules.lua and handed to the hotstring matcher. Their switches live
--- here all the same, because a user does not care which matcher answers them —
--- they care that the dynamic-hotstrings submenu has one line per family, as it
--- does on the other two drivers.
local RULE_FAMILIES = {
	{ id = "date_long_fr",                        section = "datelongfr" },
	{ id = "date_fr",                             section = "datefr" },
	{ id = "date",                                section = "date" },
	{ id = "phone_prefixes",                      section = "phoneprefixes",  is_prefix = true },
	{ id = "ssn_prefixes",                        section = "ssnprefixes",    is_prefix = true },
	{ id = "iban_prefixes",                       section = "ibanprefixes",   is_prefix = true },
	{ separator = true },
	{ id = "text_expansion_personal_information", section = "personal_info",
	  label_key = "dynamichotstrings.textexpansionpersonalinformation" },
}

-- Where a family's OFF state lives, matching the `hotstrings.dynamic.<key>`
-- path macOS stores under (infra/preferences.lua). Only the OFF state is
-- written: every family ships enabled, so persisting the default would freeze
-- today's default for anyone who had already run the driver once.
local RULE_PREF_PREFIX = "hotstrings.dynamic."

-- Which live date each label's "{date}" placeholder stands for. The label
-- promises what the rule inserts, so it must be resolved from the same engine
-- that inserts it rather than re-derived here.
local DATE_FIELD_FOR_SECTION = {
	date        = "iso",
	datefr      = "fr",
	datelongfr  = "long_fr",
}

M.RULE_FAMILIES = RULE_FAMILIES

--- Resolves one family's menu label, with today's date substituted in.
--- @param family table An entry of RULE_FAMILIES.
--- @return string
local function _family_label(family)
	local key = family.label_key or ("dynamichotstrings." .. family.section)
	local ok_i18n, i18n = pcall(require, "infra.i18n")
	local label = ok_i18n and i18n and i18n.get(key) or key

	local field = DATE_FIELD_FOR_SECTION[family.section]
	if not field or not label:find("{date}", 1, true) then return label end

	local ok_eng, Engine = pcall(require, "dynamic_hotstrings")
	if not ok_eng or not Engine then return label end
	local today = Engine.today_date_strings()
	local value = today and today[field]
	if type(value) ~= "string" then return label end

	-- "%" is the escape in a gsub REPLACEMENT. No date format in use produces
	-- one, but a future format that did would corrupt the label rather than fail.
	return (label:gsub("{date}", (value:gsub("%%", "%%%%"))))
end

--- The families, for a menu, in render order.
---
--- A prefix family carries its `count`, which the other two drivers show beside
--- the label and which is 0 until the user fills in that field of
--- personal_info.toml — a switch with nothing behind it, and the count is the
--- only thing that says so.
--- @return table Array of { id, section, enabled, label, count? } and { separator = true }.
function M.rule_families()
	local counts = nil
	local out = {}
	for _, family in ipairs(RULE_FAMILIES) do
		if family.separator then
			out[#out + 1] = { separator = true }
		else
			local entry = {
				id      = family.id,
				section = family.section,
				enabled = M.is_rule_enabled(nil, family.section),
				label   = _family_label(family),
			}
			if family.is_prefix then
				-- Resolved once for the whole list rather than per family: the shared
				-- helper answers all three at a time.
				if not counts then
					local ok, Prefix = pcall(require, "modules.dynamic_hotstrings.prefix_rules")
					counts = (ok and Prefix) and Prefix.counts(_info) or {}
				end
				entry.count = counts[family.section] or 0
			end
			out[#out + 1] = entry
		end
	end
	return out
end

--- The prefix expansions the user's data and their toggles currently allow.
---
--- Handed to `hotstrings_config.set_extra_mappings_provider` by the daemon, and
--- called again on every load — which is what makes a toggle take effect, since
--- the ordinary matcher these mappings live in has no notion of a dynamic family
--- to filter on.
--- @return table Array of mapping tables.
function M.prefix_mappings()
	if not _enabled then return {} end
	local ok, Prefix = pcall(require, "modules.dynamic_hotstrings.prefix_rules")
	if not ok or not Prefix then
		Logger.error(LOG, "prefix_rules module unavailable — no prefix expansion is registered.")
		return {}
	end
	return Prefix.build(_info, M.is_rule_enabled)
end

--- Whether one engine section may fire.
---
--- Shaped as the predicate `match_buffer` expects — (group, section) — so it can
--- be handed straight to the shared engine rather than wrapped at each call site.
--- @param _group string|nil Unused: this driver has a single dynamic group.
--- @param section string
--- @return boolean
function M.is_rule_enabled(_group, section)
	if type(section) ~= "string" then return true end
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then return true end
	return Storage.get(RULE_PREF_PREFIX .. section, nil) ~= false
end

--- Turns one family on or off, persisting the choice.
--- @param section string
--- @param enabled boolean
--- @return boolean True when the choice was recorded.
function M.set_rule_enabled(section, enabled)
	local known = false
	for _, family in ipairs(RULE_FAMILIES) do
		if family.section == section then known = true ; break end
	end
	if not known then
		Logger.error(LOG, "set_rule_enabled(): '%s' is not a rule family.", tostring(section))
		return false
	end

	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then
		Logger.error(LOG, "set_rule_enabled(): no storage adapter — '%s' not persisted.", section)
		return false
	end
	local persisted
	if enabled then
		persisted = Storage.delete(RULE_PREF_PREFIX .. section)
	else
		persisted = Storage.set(RULE_PREF_PREFIX .. section, false)
	end
	if not persisted then
		Logger.error(LOG, "set_rule_enabled(): could not persist '%s'.", section)
		return false
	end
	Logger.debug(LOG, "Dynamic rule family %s: %s.", section, enabled and "on" or "off")
	return true
end

return M
