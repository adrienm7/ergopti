--- modules/dynamic_hotstrings/rules_engine.lua

--- ==============================================================================
--- MODULE: Rules Engine (Hammerspoon shim)
--- DESCRIPTION:
--- Hammerspoon-specific shim that wires the shared pure-Lua dynamic hotstrings
--- rules engine into the HS keymap module. Handles hs.eventtap injection and
--- hs.timer scheduling — the matching logic itself lives in the shared module at
--- drivers/_shared/lua/dynamic_hotstrings/init.lua.
---
--- FEATURES & RATIONALE:
--- 1. Thin shim: all suffix-matching and rule-registration logic is delegated to
---    the shared engine; this file only adds HS-specific injection mechanics.
--- 2. Instant Resolution: uses the keymap interceptor for low-latency replacements.
--- ==============================================================================

local M = {}

local hs = hs
local ok_utils, km_utils = pcall(require, "modules.keymap.utils")
if not ok_utils then km_utils = nil end

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local SharedEngine = require("dynamic_hotstrings")

local Logger = require("lib.logger")
local LOG    = "dynamic_hotstrings.rules"

local ok_locale, locale = pcall(require, "lib.locale")
if not ok_locale then locale = nil end




-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

local GROUP_NAME = "dynamichotstrings"

local _km             = nil
local _trigger        = "\u{2605}"
local _is_injecting   = false
local _personal_data  = nil
-- Mutable section list kept as an upvalue so register_prefix_entries can
-- update the real counts after personal data is injected.
local _sections       = nil




-- =========================================
--- =========================================
-- ======= 2/ Key Interceptor Engine =======
--- =========================================
-- =========================================

--- Intercepts keystrokes to detect suffix + trigger combinations for dynamic resolution.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or nil to pass it through.
local function interceptor(event, km_buffer)
	if _is_injecting or not _km then return nil end

	local flags = event:getFlags()
	if flags.cmd or flags.ctrl then return nil end

	local char = event:getCharacters(false) or ""
	if char ~= _trigger then return nil end

	local is_sec_enabled = _km.is_section_enabled
	local guard = is_sec_enabled
		and function(grp, sec) return is_sec_enabled(grp, sec) end
		or nil

	local match = SharedEngine.match_buffer(km_buffer or "", GROUP_NAME, guard)
	if not match then return nil end

	local rule   = match.rule
	local result = match.result
	local n_back = #rule.suffix

	Logger.debug(LOG, "Injecting dynamic rule for suffix '%s'…", rule.suffix)

	if keylogger and type(keylogger.log_hotstring) == "function" then
		pcall(keylogger.log_hotstring, rule.suffix .. _trigger, result)
	end

	hs.timer.doAfter(0, function()
		_is_injecting = true

		local ok, err = pcall(function()
			-- Delete the suffix characters typed so far
			for _ = 1, n_back do
				hs.eventtap.keyStroke({}, "delete", 0)
			end

			-- Emit the actual result
			if km_utils and type(km_utils.emit_text) == "function" then
				km_utils.emit_text(result)
			else
				hs.eventtap.keyStrokes(result)
			end
		end)

		if not ok then
			Logger.error(LOG, "Dynamic rule injection failed: %s.", tostring(err))
		end

		-- Always release the flag, even on error, so future injections are not blocked.
		hs.timer.doAfter(0.15, function()
			_is_injecting = false
			if ok then
				Logger.info(LOG, "Dynamic rule injection completed.")
			end
		end)
	end)

	return "consume"
end




-- ============================================
--- ============================================
-- ======= 3/ Data-Dependent Expansions =======
--- ============================================
-- ============================================

--- Generates and registers all prefix-based hotstrings based on the user's personal data.
local function register_prefix_entries()
	if not _km or type(_personal_data) ~= "table" then return end
	Logger.debug(LOG, "Registering prefix-based dynamic hotstrings…")

	local opts = { is_word = false, auto_expand = true, is_case_sensitive = true }

	local phone  = type(_personal_data.PhoneNumber) == "string" and _personal_data.PhoneNumber or tostring(_personal_data.PhoneNumber or "")
	local fphone = type(_personal_data.PhoneNumberFormatted) == "string" and _personal_data.PhoneNumberFormatted or tostring(_personal_data.PhoneNumberFormatted or "")
	local ssn    = type(_personal_data.SocialSecurityNumber) == "string" and _personal_data.SocialSecurityNumber or tostring(_personal_data.SocialSecurityNumber or "")
	local iban   = type(_personal_data.IBAN) == "string" and _personal_data.IBAN or tostring(_personal_data.IBAN or "")

	-- Strip decorative spaces for prefix matching (SSN and IBAN contain spaces)
	local ssn_raw  = ssn:gsub("%s+", "")
	local iban_raw = iban:gsub("%s+", "")

	-- Update section counts in the registry so build_groups shows accurate totals.
	local counts = SharedEngine.compute_prefix_counts(phone, fphone, ssn_raw, iban_raw)
	if type(_sections) == "table" then
		for _, sec in ipairs(_sections) do
			if type(sec) == "table" and counts[sec.name] ~= nil then
				sec.count = counts[sec.name]
			end
		end
	end

	if _km.set_group_context then _km.set_group_context(GROUP_NAME) end

	-- Register phone prefixes
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "phoneprefixes") then
		if #phone >= 2 then
			_km.add(phone:sub(1, 2) .. _trigger, phone, opts)
			_km.add("+33" .. phone:sub(1, 2), "+33" .. phone, opts)
		end
		if #phone >= 4 then
			_km.add(phone:sub(1, 4), phone, opts)
			_km.add("+33" .. phone:sub(2, 4), "+33" .. phone, opts)
		end
		if #phone >= 6 then
			_km.add(phone:sub(2, 5), phone, opts)
		end
		if #fphone >= 5 then
			_km.add(fphone:sub(1, 5), fphone, opts)
		end
	end

	-- Register SSN prefixes: no-space trigger → SSN without spaces; spaced → SSN with spaces
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
		if #ssn_raw >= 5 then
			local ssn_raw_pfx    = ssn_raw:sub(1, 5)
			local ssn_spaced_pfx = SharedEngine.spaced_prefix(ssn, 5)
			_km.add(ssn_raw_pfx, ssn_raw, opts)
			if ssn_spaced_pfx ~= ssn_raw_pfx then
				_km.add(ssn_spaced_pfx, ssn, opts)
			end
		end
	end

	-- Register IBAN prefixes: 6 raw chars (case-insensitive) → IBAN without spaces;
	-- 7-char spaced trigger (e.g. "FR76 XX") → IBAN with spaces.
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ibanprefixes") then
		if #iban_raw >= 6 then
			local iban_raw_pfx    = iban_raw:sub(1, 6)
			local iban_spaced_pfx = SharedEngine.spaced_prefix(iban, 6)
			local opts_ci = { is_word = false, auto_expand = true, is_case_sensitive = false }
			_km.add(iban_raw_pfx,    iban:gsub("%s+", ""), opts_ci)
			if iban_spaced_pfx ~= iban_raw_pfx then
				_km.add(iban_spaced_pfx, iban, opts_ci)
			end
		end
	end

	if _km.set_group_context then _km.set_group_context(nil) end
	if _km.sort_mappings then _km.sort_mappings() end
	Logger.info(LOG, "Prefix-based dynamic hotstrings registered.")
end




-- =============================
--- =============================
-- ======= 4/ Public API =======
--- =============================
-- =============================

--- Adds a custom interceptor rule — delegated to the shared engine.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
function M.add_rule(suffix, section, resolver)
	SharedEngine.add_rule(suffix, section, resolver)
end

--- Internal method used by init.lua to inject personal data into the engine.
--- @param personal_data table Dictionary containing personal information.
--- @param trigger_char string The global trigger character to apply.
function M.inject_data(personal_data, trigger_char)
	_personal_data = type(personal_data) == "table" and personal_data or {}
	if type(trigger_char) == "string" and trigger_char ~= "" then _trigger = trigger_char end
	register_prefix_entries()
end

--- Initializes the engine, wiring it into the keymap engine.
--- @param keymap_module table The active keymap module reference.
function M.start(keymap_module)
	Logger.debug(LOG, "Starting dynamic rules engine…")
	if type(keymap_module) ~= "table" then
		Logger.error(LOG, "Keymap module missing, rules engine aborted.")
		return
	end
	_km = keymap_module

	-- Register date rules via shared engine so both HS and Linux produce identical expansions
	SharedEngine.register_date_rules(_trigger)

	local dates = SharedEngine.today_date_strings()

	-- Descriptions show today's date so the user can immediately see the expected output.
	local function loc(key) return locale and locale.get(key) or "" end
	local desc_datefr = loc("dynamichotstrings.datefr")
	if desc_datefr == "" then desc_datefr = "dt" .. _trigger .. " inserts current date ({date})" end
	desc_datefr = desc_datefr:gsub("{date}", dates.fr)
	local desc_datelongfr = loc("dynamichotstrings.datelongfr")
	if desc_datelongfr == "" then desc_datelongfr = "date" .. _trigger .. " inserts long date ({date})" end
	desc_datelongfr = desc_datelongfr:gsub("{date}", dates.long_fr)
	local desc_date = loc("dynamichotstrings.date")
	if desc_date == "" then desc_date = "td" .. _trigger .. " inserts current date ({date})" end
	desc_date = desc_date:gsub("{date}", dates.iso)

	-- Sections ordered identically to the AHK DynamicHotstrings feature map.
	-- Prefix section counts start at 0; register_prefix_entries updates them with
	-- the real values once personal data is injected.
	-- textexpansionpersonalinformation is a module placeholder — resolved by the menu via _index.toml.
	-- textexpansionpersonalinformation is last, separated — mirrors AHK DynamicHotstrings layout.
	-- Descriptions come from lib.locale (static/locales/fr.json) so the JSON
	-- is the single source of truth shared with the AHK driver.
	_sections = {
		{ name = "datelongfr",    description = desc_datelongfr,                            count = 1 },
		{ name = "datefr",        description = desc_datefr,                                count = 1 },
		{ name = "date",          description = desc_date,                                  count = 1 },
		{ name = "phoneprefixes", description = loc("dynamichotstrings.phoneprefixes"),     count = 0 },
		{ name = "ssnprefixes",   description = loc("dynamichotstrings.ssnprefixes"),       count = 0 },
		{ name = "ibanprefixes",  description = loc("dynamichotstrings.ibanprefixes"),      count = 0 },
		{ name = "-" },
		{ name = "textexpansionpersonalinformation", count = 0, is_module_placeholder = true },
	}

	if _km.register_lua_group then
		_km.register_lua_group(GROUP_NAME, loc("dynamichotstrings.group_label"), _sections)
	end

	if _km.set_post_load_hook then
		_km.set_post_load_hook(GROUP_NAME, function()
			register_prefix_entries()
		end)
	end

	if _km.register_interceptor then
		_km.register_interceptor(interceptor)
	end

	-- Register preview provider — delegates matching to the shared engine
	if type(_km.register_preview_provider) == "function" then
		local is_sec_enabled = _km.is_section_enabled
		local guard = is_sec_enabled
			and function(grp, sec) return is_sec_enabled(grp, sec) end
			or nil
		_km.register_preview_provider(function(buf)
			return SharedEngine.preview(buf, GROUP_NAME, guard)
		end)
	end

	Logger.info(LOG, "Dynamic rules engine started successfully.")
end

return M
