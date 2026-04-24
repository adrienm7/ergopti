--- modules/dynamic_hotstrings/rules_engine.lua

--- ==============================================================================
--- MODULE: Rules Engine
--- DESCRIPTION:
--- Manages interceptor rules (like date injection) and registers dynamic
--- auto-completing hotstrings (like phone numbers) using the keymap module.
---
--- FEATURES & RATIONALE:
--- 1. Data Parsing: Automatically maps personal info properties to functional prefixes.
--- 2. Instant Resolution: Uses the keymap interceptor for low-latency replacements.
--- ==============================================================================

local M = {}

local hs = hs
local ok_utils, km_utils = pcall(require, "modules.keymap.utils")
if not ok_utils then km_utils = nil end

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local Logger = require("lib.logger")
local LOG    = "dynamic_hotstrings.rules"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local GROUP_NAME = "dynamichotstrings"

local _km             = nil
local _trigger        = "\u{2605}"
local _is_injecting   = false
local _rules          = {}
local _personal_data  = nil
-- Mutable section list kept as an upvalue so register_prefix_entries can
-- update the real counts after personal data is injected.
local _sections       = nil





-- =========================================
-- =========================================
-- ======= 2/ Key Interceptor Engine =======
-- =========================================
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

	for _, rule in ipairs(_rules) do
		if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, rule.section) then
			local suf = rule.suffix
			
			if type(km_buffer) == "string" and #suf > 0 and km_buffer:sub(-(#suf)) == suf then
				
				local ok, result = pcall(rule.resolver)
				
				if ok and type(result) == "string" and result ~= "" then
					Logger.debug(LOG, string.format("Injecting dynamic rule for suffix %s…", suf))
					local n_back = #suf

					if keylogger and type(keylogger.log_hotstring) == "function" then
						pcall(keylogger.log_hotstring, suf .. _trigger, result)
					end
					
					hs.timer.doAfter(0, function()
						_is_injecting = true
						
						-- Delete the suffix characters
						for _ = 1, n_back do
							hs.eventtap.keyStroke({}, "delete", 0)
						end
						
						-- Emit the actual result
						if km_utils and type(km_utils.emit_text) == "function" then
							km_utils.emit_text(result)
						else
							hs.eventtap.keyStrokes(result)
						end
						
						hs.timer.doAfter(0.15, function()
							_is_injecting = false
							Logger.info(LOG, "Dynamic rule injection completed.")
						end)
					end)
					
					return "consume"
				end
			end
		end
	end

	return nil
end





-- ============================================
-- ============================================
-- ======= 3/ Data-Dependent Expansions =======
-- ============================================
-- ============================================

--- Returns the shortest prefix of a spaced string containing exactly raw_count non-space characters.
--- Used to build the "with spaces" trigger that expands to the formatted value.
--- @param spaced string The full string containing decorative spaces.
--- @param raw_count number The number of non-space characters to collect.
--- @return string The prefix ending after the raw_count-th non-space character.
local function spaced_prefix(spaced, raw_count)
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
--- Mirrors the exact threshold logic used in AHK hotstrings.ahk section 5.2.
local function compute_prefix_counts(phone, fphone, ssn_raw, iban_raw)
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

--- Generates and registers all prefix-based hotstrings based on the user’s personal data.
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
	local counts = compute_prefix_counts(phone, fphone, ssn_raw, iban_raw)
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
			local ssn_spaced_pfx = spaced_prefix(ssn, 5)
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
			local iban_spaced_pfx = spaced_prefix(iban, 6)
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
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Adds a custom interceptor rule for runtime evaluation.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
function M.add_rule(suffix, section, resolver)
	if type(suffix) ~= "string" or type(section) ~= "string" or type(resolver) ~= "function" then return end
	table.insert(_rules, { suffix = suffix, section = section, resolver = resolver })
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

	M.add_rule("td", "date",   function() return os.date("%Y_%m_%d") end)
	M.add_rule("dt", "datefr", function() return os.date("%d/%m/%Y") end)

	-- Descriptions show today's date so the user can immediately see the expected output.
	local date_iso = os.date("%Y_%m_%d")
	local date_fr  = os.date("%d/%m/%Y")

	-- Sections ordered identically to the AHK DynamicHotstrings feature map.
	-- Prefix section counts start at 0; register_prefix_entries updates them with
	-- the real values once personal data is injected.
	_sections = {
		{ name = "datefr",        description = "dt" .. _trigger .. " insère la date courante (" .. date_fr  .. ")", count = 1 },
		{ name = "date",          description = "td" .. _trigger .. " insère la date courante (" .. date_iso .. ")", count = 1 },
		{ name = "phoneprefixes", description = "Saisir les premiers chiffres du numéro de téléphone le complète automatiquement", count = 0 },
		{ name = "ssnprefixes",   description = "Saisir les premiers chiffres du numéro de sécurité sociale le complète automatiquement", count = 0 },
		{ name = "ibanprefixes",  description = "Saisir les premiers caractères de l'IBAN le complète automatiquement", count = 0 },
	}

	if _km.register_lua_group then
		_km.register_lua_group(GROUP_NAME, "Hotstrings dynamiques", _sections)
	end

	if _km.set_post_load_hook then
		_km.set_post_load_hook(GROUP_NAME, function()
			register_prefix_entries()
		end)
	end

	if _km.register_interceptor then
		_km.register_interceptor(interceptor)
	end

	-- Register preview provider for UI feedback
	if type(_km.register_preview_provider) == "function" then
		_km.register_preview_provider(function(buf)
			if type(buf) ~= "string" then return nil end
			for _, rule in ipairs(_rules) do
				if _km and _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, rule.section) then
					local suf = rule.suffix
					if #suf > 0 and buf:sub(-(#suf)) == suf then
						local ok, res = pcall(rule.resolver)
						if ok and type(res) == "string" then return res end
					end
				end
			end
			return nil
		end)
	end
	Logger.info(LOG, "Dynamic rules engine started successfully.")
end

return M
