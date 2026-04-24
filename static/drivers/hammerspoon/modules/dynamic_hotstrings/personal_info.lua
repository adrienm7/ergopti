--- modules/dynamic_hotstrings/personal_info.lua

--- ==============================================================================
--- MODULE: Personal Info Tracker
--- DESCRIPTION:
--- Monitors typed characters and expands  @<letters><trigger>  into
--- tab-separated personal-information values.
---
--- FEATURES & RATIONALE:
--- 1. Single Tap Integration: Registers an interceptor directly inside keymap's keyDown tap.
--- 2. Conflict Avoidance: Runs BEFORE backspace, escape, and hotstring matching.
--- ==============================================================================

local M = {}

local hs       = hs
local eventtap = hs.eventtap
local timer    = hs.timer
local Logger   = require("lib.logger")
local LOG      = "personal_info"

-- Safely require the UI editor module to prevent crashes
local ok_editor, ui_editor = pcall(require, "ui.personal_info_editor")
if not ok_editor then ui_editor = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local STATE_IDLE       = "idle"
local STATE_COLLECTING = "collecting"

local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""

local _trigger         = "★"
local _info            = {}
local _letters         = {}
local _base_dir        = ""
local _info_toml_path  = ""

local _keymap    = nil

local DEFAULT_CONFIG = {
	trigger_char = "★",
	info = {
		FirstName            = "Prénom",
		LastName             = "Nom",
		DateOfBirth          = "01/01/1990",
		EmailAddress         = "prenom.nom@exemple.fr",
		WorkEmailAddress     = "prenom.nom@entreprise.fr",
		PhoneNumber          = "0600000000",
		PhoneNumberFormatted = "06 00 00 00 00",
		StreetAddress        = "1 Rue de la Paix",
		City                 = "Paris",
		Country              = "France",
		PostalCode           = "75001",
		IBAN                 = "FR00 0000 0000 0000 0000 0000 000",
		BIC                  = "ABCDFRPP",
		CreditCard           = "0000 0000 0000 0000",
		SocialSecurityNumber = "0 00 00 00 000 000 00",
	},
	letters = {
		a = "StreetAddress",
		b = "BIC",
		c = "CreditCard",
		d = "DateOfBirth",
		e = "EmailAddress",
		f = "PhoneNumberFormatted",
		i = "IBAN",
		m = "EmailAddress",
		n = "LastName",
		p = "FirstName",
		s = "SocialSecurityNumber",
		t = "PhoneNumber",
		w = "WorkEmailAddress",
	},
}





-- ===========================================
-- ===========================================
-- ======= 2/ Configuration Management =======
-- ===========================================
-- ===========================================

--- Parses a simple key = "value" TOML section block into a table.
--- @param content string Full file content.
--- @param section string Section name (without brackets).
--- @return table
local function parse_toml_section(content, section)
	local result = {}
	-- Find the section header, then collect lines until the next header
	local in_section = false
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		line = line:match("^%s*(.-)%s*$")
		if line:match("^%[") then
			in_section = (line == "[" .. section .. "]")
		elseif in_section then
			local key, val = line:match('^(%w+)%s*=%s*"(.*)"$')
			if key then
				-- Unescape basic TOML sequences
				val = val:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
				result[key] = val
			end
		end
	end
	return result
end

--- Escapes a string for a TOML double-quoted value.
--- @param s string
--- @return string
local function escape_toml(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"',  '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\t", "\\t")
	return s
end

--- Reads personal_info.toml and returns a config table compatible with DEFAULT_CONFIG.
--- @param toml_path string Absolute path to personal_info.toml.
--- @return table The loaded or default configuration.
local function load_config(toml_path)
	Logger.debug(LOG, "Loading personal info from '%s'…", toml_path)
	local fh = io.open(toml_path, "r")
	if not fh then
		Logger.info(LOG, "personal_info.toml not found — using default values.")
		return DEFAULT_CONFIG
	end
	local content = fh:read("*a")
	fh:close()

	local info    = parse_toml_section(content, "info")
	local letters = parse_toml_section(content, "letters")

	-- Fall back to defaults for any missing field
	local merged_info    = {}
	local merged_letters = {}
	for k, v in pairs(DEFAULT_CONFIG.info)    do merged_info[k]    = info[k]    or v end
	for k, v in pairs(DEFAULT_CONFIG.letters) do merged_letters[k] = letters[k] or v end

	Logger.info(LOG, "Personal info configuration loaded successfully.")
	return {
		trigger_char = DEFAULT_CONFIG.trigger_char,
		info         = merged_info,
		letters      = merged_letters,
	}
end

--- Persists updated info fields into personal_info.toml.
--- @param new_info table The updated fields to save.
function M.save_info(new_info)
	if type(new_info) ~= "table" then return end
	Logger.debug(LOG, "Saving personal info to '%s'…", _info_toml_path)

	-- Merge the new values into the current info
	for k, v in pairs(new_info) do
		_info[k] = v
	end

	local lines = { "[info]" }
	for k, v in pairs(_info) do
		lines[#lines + 1] = k .. ' = "' .. escape_toml(tostring(v)) .. '"'
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "[letters]"
	for k, v in pairs(_letters) do
		lines[#lines + 1] = k .. ' = "' .. escape_toml(tostring(v)) .. '"'
	end
	lines[#lines + 1] = ""

	local fh = io.open(_info_toml_path, "w")
	if not fh then
		Logger.error(LOG, "Cannot open personal_info.toml for writing.")
		return
	end
	fh:write(table.concat(lines, "\n"))
	fh:close()

	Logger.info(LOG, "Personal info configuration saved successfully.")
end





-- ====================================
-- ====================================
-- ======= 3/ Engine Operations =======
-- ====================================
-- ====================================

--- Resolves accumulated letters into actual mapped strings.
--- @param combo string Sequence of typed letters.
--- @return table List of strings resolved from the letters.
local function resolve_combo(combo)
	local parts = {}
	if type(combo) ~= "string" then return parts end
	
	for i = 1, #combo do
		local letter = combo:sub(i, i)
		local key    = _letters[letter]
		if key and _info[key] then
			table.insert(parts, _info[key])
		end
	end
	return parts
end

--- Performs the actual injection of the requested data.
--- @param combo string Sequence of typed letters corresponding to the data.
local function do_expand(combo)
	Logger.debug(LOG, "Injecting personal data…")
	local n_back = 1 + #combo
	local parts  = resolve_combo(combo)

	_replacing = true

	-- Suppress keymap rescan to avoid interference during injection
	if _keymap and type(_keymap.suppress_rescan) == "function" then
		_keymap.suppress_rescan()
	end

	-- Delete the typed combo characters
	for _ = 1, n_back do
		eventtap.keyStroke({}, "delete", 0)
	end
	
	-- Insert the resolved strings with tabs in between
	for i, value in ipairs(parts) do
		eventtap.keyStrokes(value)
		if i < #parts then
			eventtap.keyStroke({}, "tab", 0)
		end
	end

	timer.doAfter(0.15, function()
		_replacing = false
		Logger.info(LOG, "Personal data injection completed.")
	end)
end





-- =========================================
-- =========================================
-- ======= 4/ Key Interceptor Engine =======
-- =========================================
-- =========================================

--- Intercepts keystrokes to detect prefix + trigger combinations for dynamic resolution.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param _km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or "suppress" to block hotstrings.
local function interceptor(event, _km_buffer)
	if not _enabled then return nil end
	if _replacing then return nil end

	local flags = event:getFlags()
	
	-- Reset state on command or control modifiers
	if flags.cmd or flags.ctrl then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	local kc = event:getKeyCode()

	-- Reset state on escape, return, or navigation keys
	if kc == 53 or kc == 36 or kc == 76 or (kc >= 123 and kc <= 126) then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	-- Handle backspace during collection
	if kc == 51 then
		if _state == STATE_COLLECTING then
			if #_combo > 0 then
				_combo = _combo:sub(1, -2)
			else
				_state = STATE_IDLE
			end
		end
		return nil
	end

	local char = event:getCharacters(false) or ""
	if char == "" then return nil end

	if _state == STATE_IDLE then
		if char == "@" then
			local full_trigger = (_km_buffer or "") .. "@"
			if _keymap then
				local exact = (_keymap.has_exact_trigger and _keymap.has_exact_trigger(full_trigger)) or false
				local pref  = (_keymap.has_trigger_prefix and _keymap.has_trigger_prefix(full_trigger)) or false
				local suff  = (_keymap.has_trigger_suffix and _keymap.has_trigger_suffix(full_trigger)) or false
				
				if exact or pref or suff then
					return nil
				end
			end

			_state = STATE_COLLECTING
			_combo = ""
			return nil
		end
		return nil
	end

	if _state == STATE_COLLECTING then
		if char == _trigger then
			if #_combo > 0 and #resolve_combo(_combo) > 0 then
				local combo = _combo
				
				local full_trigger = "@" .. combo .. _trigger
				if _keymap and _keymap.has_exact_trigger
						and _keymap.has_exact_trigger(full_trigger)
						and full_trigger:sub(1, 1) == "@" then
					_state = STATE_IDLE
					_combo = ""
					return nil
				end
				
				_state = STATE_IDLE
				_combo = ""
				
				timer.doAfter(0, function() do_expand(combo) end)
				return "consume"
			end
			
			_state = STATE_IDLE
			_combo = ""
			return nil
		end

		-- Collect lowercase letters for the combo
		if char:match("^[a-z]$") then
			_combo = _combo .. char
			return nil
		end

		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	return nil
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

--- Retrieves the current personal info table.
--- @return table The info table.
function M.get_info()         return _info    end

--- Retrieves the configured trigger character.
--- @return string The trigger character.
function M.get_trigger_char() return _trigger end

--- Opens the browser-based HTML form using the extracted UI module.
function M.open_editor()
	Logger.debug(LOG, "Opening personal info editor UI…")
	if ui_editor and type(ui_editor.open) == "function" then
		ui_editor.open(_info, M.save_info)
	else
		Logger.error(LOG, "The editor UI module is not available.")
	end
end

--- Initializes the module, wiring it into the keymap engine.
--- @param base_dir string Base configuration directory.
--- @param keymap_module table The active keymap module reference.
--- @param info_toml_path string|nil Absolute path to personal_info.toml (optional override).
function M.start(base_dir, keymap_module, info_toml_path)
	Logger.debug(LOG, "Starting personal info tracker…")
	if type(base_dir) == "string" then _base_dir = base_dir end

	-- Resolve the TOML path: explicit override > default relative to base_dir
	if type(info_toml_path) == "string" and info_toml_path ~= "" then
		_info_toml_path = info_toml_path
	else
		_info_toml_path = _base_dir .. "../hotstrings/personal_info.toml"
	end

	local config = load_config(_info_toml_path)
	if type(config) ~= "table" then
		Logger.warn(LOG, "Module disabled because configuration is missing or invalid.")
		return
	end

	_trigger = tostring(config.trigger_char or "★")
	_info    = type(config.info) == "table" and config.info or {}
	_letters = type(config.letters) == "table" and config.letters or {}

	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
	_enabled   = true
	
	if type(keymap_module) == "table" then
		_keymap = keymap_module
	end

	-- Register the keystroke interceptor
	if _keymap and type(_keymap.register_interceptor) == "function" then
		_keymap.register_interceptor(interceptor)
	end

	-- Register the preview provider for UI feedback
	if _keymap and type(_keymap.register_preview_provider) == "function" then
		_keymap.register_preview_provider(function(buf)
			if not _enabled or type(buf) ~= "string" then return nil end
			
			local match = buf:match("@([a-z]+)$")
			if match then
				local parts = resolve_combo(match)
				if #parts > 0 then
					return table.concat(parts, " ⇥ ")
				end
			end
			return nil
		end)
	end
	Logger.info(LOG, "Personal info tracker started successfully.")
end

--- Enables the engine tracking.
function M.enable()
	Logger.debug(LOG, "Enabling personal info tracking…")
	_enabled = true; _state = STATE_IDLE; _combo = ""
	Logger.info(LOG, "Personal info tracking enabled.")
end

--- Disables the engine tracking.
function M.disable()
	Logger.debug(LOG, "Disabling personal info tracking…")
	_enabled = false; _state = STATE_IDLE; _combo = ""
	Logger.info(LOG, "Personal info tracking disabled.")
end

return M
