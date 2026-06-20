--- drivers/_shared/lua/dynamic_hotstrings/init.lua

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

local LOG = "dynamic_hotstrings.shared"




-- ===================================
-- ===================================
-- ======= 1/ Module-Level State =======
-- ===================================
-- ===================================

--- @type table[] List of registered rules: {suffix, section, resolver}.
local _rules = {}




-- =============================================
-- =============================================
-- ======= 2/ Prefix Computation Utilities =======
-- =============================================
-- =============================================

--- Returns the shortest prefix of a spaced string containing exactly raw_count
--- non-space characters.
--- Used to build the "with spaces" trigger that expands to the formatted value.
--- Mirrors the identical helper in AHK hotstrings.ahk section 5.2.
--- @param spaced string The full string containing decorative spaces.
--- @param raw_count number The number of non-space characters to collect.
--- @return string The prefix ending after the raw_count-th non-space character.
function M.spaced_prefix(spaced, raw_count)
	local seen = 0
	for i = 1, #spaced do
		if spaced:sub(i, i) ~= " " then
			seen = seen + 1
		end
		if seen >= raw_count then
			return spaced:sub(1, i)
		end
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
	if #phone >= 2 then phone_n = phone_n + 2 end  -- phone[1:2]+★ and +33+phone[1:2]
	if #phone >= 4 then phone_n = phone_n + 2 end  -- phone[1:4] and +33+phone[2:4]
	if #phone >= 6 then phone_n = phone_n + 1 end  -- phone[2:5]
	if #fphone >= 5 then phone_n = phone_n + 1 end -- fphone[1:5]

	-- No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
	local ssn_n = (#ssn_raw >= 5) and 2 or 0

	-- 6 raw chars (no-space, case-insensitive) and 7-char spaced trigger
	local iban_n = (#iban_raw >= 6) and 2 or 0

	return { phoneprefixes = phone_n, ssnprefixes = ssn_n, ibanprefixes = iban_n }
end




-- =================================
-- =================================
-- ======= 3/ Rule Management =======
-- =================================
-- =================================

--- Registers a suffix/resolver pair.
--- The resolver is called at match time and must return a non-empty string.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
function M.add_rule(suffix, section, resolver)
	if type(suffix) ~= "string" or type(section) ~= "string" or type(resolver) ~= "function" then
		Logger.warn(LOG, "add_rule: invalid arguments — skipped.")
		return
	end
	table.insert(_rules, { suffix = suffix, section = section, resolver = resolver })
	Logger.debug(LOG, "Rule registered: suffix='%s' section='%s'.", suffix, section)
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




-- =======================================================
-- =======================================================
-- ======= 4/ Buffer Matching & Preview Pure Logic =======
-- =======================================================
-- =======================================================

--- Checks whether any registered rule matches the tail of the given buffer,
--- subject to the optional section-guard predicate.
--- Returns a match descriptor or nil — does NOT perform any text injection.
--- @param buffer string The current typing buffer.
--- @param group_name string The keymap group name passed to is_section_enabled.
--- @param is_section_enabled_fn function|nil Predicate: (group, section) → boolean.
--- @return table|nil Match descriptor {rule, result} or nil if no match.
function M.match_buffer(buffer, group_name, is_section_enabled_fn)
	if type(buffer) ~= "string" then return nil end
	for _, rule in ipairs(_rules) do
		-- Apply section guard when provided; skip disabled sections
		if is_section_enabled_fn == nil
				or is_section_enabled_fn(group_name, rule.section) then
			local suf = rule.suffix
			if #suf > 0 and buffer:sub(-(#suf)) == suf then
				local ok, result = pcall(rule.resolver)
				if ok and type(result) == "string" and result ~= "" then
					Logger.debug(LOG, "Buffer match: suffix='%s' → result='%s'.", suf, result)
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
function M.preview(buffer, group_name, is_section_enabled_fn)
	if type(buffer) ~= "string" then return nil end
	local match = M.match_buffer(buffer, group_name, is_section_enabled_fn)
	if match then return match.result end
	return nil
end




-- =========================================
-- =========================================
-- ======= 5/ Built-In Date Resolvers =======
-- =========================================
-- =========================================

--- Registers the three standard date rules (ISO, French short, French long).
--- Called by each driver's start() function after the engine is initialized.
--- @param trigger string The trigger character (e.g. "★") — used only for logging.
function M.register_date_rules(trigger)
	local t = trigger or "★"

	M.add_rule("td", "date", function() return os.date("%Y_%m_%d") end)
	M.add_rule("dt", "datefr", function() return os.date("%d/%m/%Y") end)
	M.add_rule("date", "datelongfr", function()
		local days   = { "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" }
		local months = { "janvier", "février", "mars", "avril", "mai", "juin",
		                 "juillet", "août", "septembre", "octobre", "novembre", "décembre" }
		local wday = tonumber(os.date("%w")) + 1  -- os.date %w: 0 = Sunday
		local mday = tonumber(os.date("%d"))
		local mon  = tonumber(os.date("%m"))
		local year = os.date("%Y")
		return days[wday] .. " " .. mday .. " " .. months[mon] .. " " .. year
	end)

	Logger.info(LOG, "Date rules registered (trigger='%s').", t)
end


--- Resolves today's date strings for section descriptions.
--- Returns a table with iso, fr, and long_fr fields so callers can embed
--- live date previews in UI section labels without reimplementing os.date logic.
--- @return table {iso, fr, long_fr}
function M.today_date_strings()
	local days   = { "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" }
	local months = { "janvier", "février", "mars", "avril", "mai", "juin",
	                 "juillet", "août", "septembre", "octobre", "novembre", "décembre" }
	local wday   = tonumber(os.date("%w")) + 1
	local mday   = tonumber(os.date("%d"))
	local mon    = tonumber(os.date("%m"))
	local year   = os.date("%Y")
	return {
		iso     = os.date("%Y_%m_%d"),
		fr      = os.date("%d/%m/%Y"),
		long_fr = days[wday] .. " " .. mday .. " " .. months[mon] .. " " .. year,
	}
end

return M
