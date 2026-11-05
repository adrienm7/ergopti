--- _shared/lua/dynamic_hotstrings/init.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings Rules Engine (shared)
--- DESCRIPTION:
--- Pure-Lua rules engine for dynamic hotstring matching. Contains all matching
--- logic, rule evaluation, prefix-count computation, and date-resolver helpers
--- with zero hs.* dependencies. Canonical implementation shared by all
--- Lua-based drivers (Hammerspoon, Linux LuaJIT daemon, and any future driver).
---
--- FEATURES & RATIONALE:
--- 1. Zero OS dependencies: no hs.*, no eventtap, no timer — runs standalone
---    in any LuaJIT or Lua 5.3+ environment without modification.
--- 2. Pure matching API: callers supply the current buffer and an optional
---    section-guard predicate; the engine returns matching rule and resolved
---    value without performing any injection — injection is left to the driver.
--- 3. Prefix utilities: spaced_prefix and compute_prefix_counts expose the
---    shared phone/SSN/IBAN prefix logic so both HS and Linux drivers produce
---    identical hotstring sets from the same personal-data table.
--- 4. Rule registration: add_rule lets callers extend the engine at runtime
---    with arbitrary suffix/resolver pairs — used for date expansions and any
---    future driver-specific rules.
--- 5. Logger shim: works without lib.logger present (standalone daemon outside
---    Hammerspoon); falls back to plain print() transparently.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TextUtils = require("text_utils")
local utf8_lib = (type(utf8) == "table" and utf8.len)
	and utf8 or require("compat.utf8")

local LOG = "dynamic_hotstrings.shared"





-- =====================================
-- =====================================
-- ======= 1/ Module-Level State =======
-- =====================================
-- =====================================

--- @type table[] List of registered rules: {suffix, section, resolver}.
local _rules = {}
--- @type function|nil Platform reporter: (rule, failure) -> strict boolean.
local _resolver_error_reporter = nil





-- ===============================================
-- ===============================================
-- ======= 2/ Prefix Computation Utilities =======
-- ===============================================
-- ===============================================

--- Removes the spacing commonly found in pasted personal identifiers.
--- @param value string
--- @return string
function M.strip_prefix_spacing(value)
	return (value:gsub("%s+", ""):gsub("\194\160", ""):gsub("\226\128\175", ""))
end

--- Returns the shortest prefix containing raw_count non-space characters.
--- Mirrors the helper in the Windows dynamic hotstrings driver.
--- @param spaced string
--- @param raw_count number
--- @return string
function M.spaced_prefix(spaced, raw_count)
	local seen = 0
	local i = 1
	while i <= #spaced do
		local char = spaced:match("^[%z\1-\127\194-\244][\128-\191]*", i) or spaced:sub(i, i)
		if M.strip_prefix_spacing(char) ~= "" then seen = seen + 1 end
		i = i + #char
		if seen >= raw_count then return spaced:sub(1, i - 1) end
	end
	return spaced
end


--- Computes the real hotstring count for each prefix section given personal data.
--- Returns a table keyed by section name with integer counts.
--- Mirrors the exact threshold logic used in AHK hotstrings.ahk section 5.2,
--- so both drivers expose the same section counts in their respective UIs.
--- @param phone string Raw phone number string (digits only, no spaces).
--- @param fphone string Formatted phone number (may contain spaces).
--- @param ssn_raw string SSN with spaces stripped.
--- @param iban_raw string IBAN with spaces stripped.
--- @return table Counts per section: {phoneprefixes, ssnprefixes, ibanprefixes}.
function M.compute_prefix_counts(phone, fphone, ssn_raw, iban_raw)
	local phone_n = 0
	if TextUtils.utf8_len(phone) >= 2 then phone_n = phone_n + 2 end  -- phone[1:2]+★ and +33+phone[1:2]
	if TextUtils.utf8_len(phone) >= 4 then phone_n = phone_n + 2 end  -- phone[1:4] and +33+phone[2:4]
	if TextUtils.utf8_len(phone) >= 6 then phone_n = phone_n + 1 end  -- phone[2:5]
	if TextUtils.utf8_len(fphone) >= 5 then phone_n = phone_n + 1 end -- fphone[1:5]

	-- No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
	local ssn_n = (TextUtils.utf8_len(ssn_raw) >= 5) and 2 or 0

	-- 6 raw chars (no-space, case-insensitive) and 7-char spaced trigger
	local iban_n = (TextUtils.utf8_len(iban_raw) >= 6) and 2 or 0

	return { phoneprefixes = phone_n, ssnprefixes = ssn_n, ibanprefixes = iban_n }
end





-- ==================================
-- ==================================
-- ======= 3/ Rule Management =======
-- ==================================
-- ==================================

--- Registers a suffix/resolver pair.
--- The resolver is called at match time and must return a non-empty string.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
--- @param require_word_boundary boolean|nil Builtin word-start policy; absent preserves custom-rule semantics.
--- @return boolean committed
function M.add_rule(suffix, section, resolver, require_word_boundary)
	if type(suffix) ~= "string" or type(section) ~= "string" or type(resolver) ~= "function"
		or (require_word_boundary ~= nil and type(require_word_boundary) ~= "boolean") then
		Logger.warn(LOG, "add_rule: invalid arguments — skipped.")
		return false
	end
	local valid_utf8, suffix_len = pcall(utf8_lib.len, suffix)
	if not valid_utf8 or type(suffix_len) ~= "number" or suffix_len < 1 then
		Logger.warn(LOG, "add_rule: suffix must be non-empty valid UTF-8 — skipped.")
		return false
	end
	table.insert(_rules, { suffix = suffix, section = section, resolver = resolver,
		require_word_boundary = require_word_boundary })
	Logger.debug(LOG, "Rule registered: suffix='%s' section='%s'.", suffix, section)
	return true
end


--- Installs the platform reporter used when a rule resolver raises.
--- A nil reporter restores the portable direct-logger fallback.
--- @param reporter function|nil Reporter returning true only after ownership.
--- @return boolean committed
function M.set_resolver_error_reporter(reporter)
	if reporter ~= nil and type(reporter) ~= "function" then
		Logger.error(LOG, "set_resolver_error_reporter: expected function or nil, got %s.",
			type(reporter))
		return false
	end
	_resolver_error_reporter = reporter
	Logger.debug(LOG, "Resolver error reporter: %s.", reporter and "installed" or "direct logger")
	return true
end


--- Returns the full list of registered rules (read-only reference).
--- @return table[]
function M.get_rules()
	return _rules
end


--- Clears all registered rules.
--- Used by tests and by re-initialization paths.
function M.reset_rules()
	_rules = {}
	Logger.debug(LOG, "All rules cleared.")
end


--- Reports one resolver failure without preventing later sibling rules.
--- @param rule table Failing rule record.
--- @param failure any Error object returned by pcall.
local function report_resolver_failure(rule, failure)
	if rule.resolver_error_reported then return end
	if _resolver_error_reporter then
		local reporter_ok, reported = pcall(_resolver_error_reporter, rule, failure)
		if reporter_ok and reported == true then
			rule.resolver_error_reported = true
			return
		end
		Logger.error(LOG, "Resolver error reporter failed for section '%s' (details withheld).",
			tostring(rule.section))
	end
	-- An error object may define a throwing or expensive __tostring metamethod.
	-- The fallback needs only a privacy-safe size hint, so never execute foreign
	-- code while reporting the resolver that already failed.
	local failure_size = type(failure) == "string" and #failure or 0
	Logger.error(LOG, "Dynamic resolver failed in section '%s' "
		.. "(%d-byte suffix; %d-byte failure content withheld).",
		tostring(rule.section), #rule.suffix, failure_size)
	rule.resolver_error_reported = true
end





-- =======================================================
-- =======================================================
-- ======= 4/ Buffer Matching & Preview Pure Logic =======
-- =======================================================
-- =======================================================

--- Admits the beginning of a bare builtin trigger under the ordinary word policy.
--- Explicit @ tags retain their back-to-back command contract.
--- @param buffer string Exact text preceding the magic key.
--- @param suffix string Registered builtin trigger.
--- @param start_is_boundary boolean|nil The input owner's buffer-start state.
--- @return boolean admitted
function M.word_boundary_allows(buffer, suffix, start_is_boundary)
	if type(buffer) ~= "string" or type(suffix) ~= "string" or suffix == ""
		or buffer:sub(-#suffix) ~= suffix then return false end
	if suffix:sub(1, 1) == "@" then return true end
	local before = buffer:sub(1, #buffer - #suffix)
	if before == "" then return start_is_boundary == true end
	local valid, offset = pcall(utf8_lib.offset, before, -1)
	if not valid or type(offset) ~= "number" then return false end
	return not TextUtils.is_hotstring_word_char(before:sub(offset))
end


--- Checks whether any registered rule matches the tail of the given buffer,
--- subject to the optional section-guard predicate.
--- Returns a match descriptor or nil — does NOT perform any text injection.
--- @param buffer string The current typing buffer.
--- @param group_name string The keymap group name passed to is_section_enabled.
--- @param is_section_enabled_fn function|nil Predicate: (group, section) → boolean.
--- @return table|nil Match descriptor {rule, result} or nil if no match.
--- @param start_is_boundary boolean|nil The exact input owner's rolling-buffer start state.
function M.match_buffer(buffer, group_name, is_section_enabled_fn, start_is_boundary)
	if type(buffer) ~= "string" then return nil end
	local length = #buffer
	for _, rule in ipairs(_rules) do
		local suf = rule.suffix
		local at = length - #suf + 1
		-- The suffix test comes first: it is pure and allocates nothing, while the
		-- section guard reads the settings store (a native read on macOS). Asking
		-- the guard of every rule on every keystroke made the preview providers
		-- cost 1.7 ms per key on average in the 2026-10-30 macOS field report.
		if #suf > 0 and at >= 1 and buffer:find(suf, at, true) == at
			and (is_section_enabled_fn == nil or is_section_enabled_fn(group_name, rule.section)) then
			if rule.require_word_boundary ~= true
					or M.word_boundary_allows(buffer, suf, start_is_boundary) then
				local ok, result = pcall(rule.resolver)
				if not ok then report_resolver_failure(rule, result) end
				if ok and type(result) == "string" and result ~= "" then
					-- `result` is whatever the resolver produced, and the resolvers
					-- registered against this engine include every @-tag: for "@i" it
					-- is the user's IBAN. This printed it in full — and DEBUG is not
					-- the safeguard it looks like here, because the shared logger's
					-- default minimum level is 10, i.e. debug included. So the value
					-- reached the log on every expansion, on every driver using this
					-- engine, with nothing switched on.
					--
					-- The length is kept because it is the diagnostic that matters
					-- when a rule misfires (which field answered), and it is what the
					-- other two drivers keep at their equivalent sites.
					Logger.debug(LOG, "Buffer match: suffix='%s' → %d char(s) (content withheld).",
						suf, #result)
					return { rule = rule, result = result }
				end
			end
		end
	end
	return nil
end


--- Returns a preview string for the tooltip given the current buffer.
--- Identical filtering logic to match_buffer but intended for read-only display.
--- @param buffer string The current typing buffer.
--- @param group_name string The keymap group name passed to is_section_enabled.
--- @param is_section_enabled_fn function|nil Predicate: (group, section) → boolean.
--- @return string|nil The preview string, or nil if no rule matches.
--- @param start_is_boundary boolean|nil The exact input owner's rolling-buffer start state.
function M.preview(buffer, group_name, is_section_enabled_fn, start_is_boundary)
	if type(buffer) ~= "string" then return nil end
	local match = M.match_buffer(buffer, group_name, is_section_enabled_fn, start_is_boundary)
	if match then return match.result end
	return nil
end





-- ==========================================
-- ==========================================
-- ======= 5/ Built-In Date Resolvers =======
-- ==========================================
-- ==========================================

-- Capture one local-calendar snapshot for all components. Separate os.date
-- calls can cross midnight and combine a weekday with another calendar day.
local function date_strings()
	local day = os.date("*t")
	local days = { "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" }
	local months = { "janvier", "février", "mars", "avril", "mai", "juin",
		"juillet", "août", "septembre", "octobre", "novembre", "décembre" }
	return {
		iso = string.format("%04d_%02d_%02d", day.year, day.month, day.day),
		fr = string.format("%02d/%02d/%04d", day.day, day.month, day.year),
		long_fr = days[day.wday] .. " " .. day.day .. " " .. months[day.month] .. " " .. day.year,
	}
end

--- Registers the three standard date rules (ISO, French short, French long).
--- @param trigger string The trigger character, used only for logging.
function M.register_date_rules(trigger)
	local t = trigger or "★"
	M.add_rule("td", "date", function() return os.date("%Y_%m_%d") end, true)
	M.add_rule("dt", "datefr", function() return os.date("%d/%m/%Y") end, true)
	M.add_rule("date", "datelongfr", function() return date_strings().long_fr end, true)
	Logger.info(LOG, "Date rules registered (trigger='%s').", t)
end

--- Resolves all section date previews from one local-calendar snapshot.
--- @return table {iso, fr, long_fr}
function M.today_date_strings()
	return date_strings()
end

return M
