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

--- Generates and registers all prefix-based hotstrings based on the user's personal data.
local function register_prefix_entries()
	if not _km or type(_personal_data) ~= "table" then return end
	Logger.debug(LOG, "Registering prefix-based dynamic hotstrings…")

	local opts = { is_word = false, auto_expand = true, is_case_sensitive = true }
	
	local phone  = type(_personal_data.PhoneNumber) == "string" and _personal_data.PhoneNumber or tostring(_personal_data.PhoneNumber or "")
	local fphone = type(_personal_data.PhoneNumberFormatted) == "string" and _personal_data.PhoneNumberFormatted or tostring(_personal_data.PhoneNumberFormatted or "")
	local ssn    = type(_personal_data.SocialSecurityNumber) == "string" and _personal_data.SocialSecurityNumber or tostring(_personal_data.SocialSecurityNumber or "")

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

	-- Register SSN prefixes
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
		if #ssn >= 5 then
			_km.add(ssn:sub(1, 5), ssn, opts)
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

	M.add_rule("dt", "date", function() return os.date("%d/%m/%Y") end)

	-- Define French UI strings for the menu
	local sections = {
		{ name = "date",          description = "dt" .. _trigger .. " insère la date courante (jj/mm/aaaa)" },
		{ name = "phoneprefixes", description = "Saisir les premiers chiffres du numéro de téléphone le complète automatiquement" },
		{ name = "ssnprefixes",   description = "Saisir les premiers chiffres du numéro de sécurité sociale le complète automatiquement" },
	}
	
	if _km.register_lua_group then
		_km.register_lua_group(GROUP_NAME, "Hotstrings dynamiques", sections)
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
