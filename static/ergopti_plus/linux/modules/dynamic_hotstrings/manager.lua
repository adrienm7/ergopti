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

local LOG = "modules.dynamic_hotstrings.manager"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _trigger_char = "★"          -- active trigger character
local _enabled      = true         -- master enable/disable toggle
local _rules_count  = 0            -- how many rules were registered
local _info         = {}           -- parsed [info] table
local _letters      = {}           -- parsed [letters] map


-- =========================================
-- =========================================
-- ======= 2/ TOML Parser ==================
-- =========================================
-- =========================================

--- Parses a simple TOML file and extracts [info] key=value pairs and
--- [letters] key=value pairs. Falls back to the full toml_codec when available.
--- @param path string Absolute path to personal_info.toml.
--- @return table info, table letters
local function _parse_personal_info_toml(path)
	local fh = io.open(path, "r")
	if not fh then return {}, {} end
	local content = fh:read("*a")
	fh:close()

	-- Try the full toml_codec first (parses strings, not file paths).
	local ok_toml, toml_codec = pcall(require, "toml_codec")
	if ok_toml and toml_codec and type(toml_codec.parse) == "function" then
		local ok, parsed = pcall(toml_codec.parse, content)
		if ok and type(parsed) == "table" then
			local info = (type(parsed.info) == "table") and parsed.info or {}
			local letters = (type(parsed.letters) == "table") and parsed.letters or {}
			return info, letters
		end
	end

	-- Simple fallback parser.
	local info = {}
	local letters = {}
	local current_section = nil

	for line in content:gmatch("[^\n]+") do
		line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line == "" then goto continue end

		local section = line:match("^%[([^%]]+)%]$")
		if section then
			current_section = section
			goto continue
		end

		local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
		if k and v and current_section then
			v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"', ""):gsub('"$', "")
			if current_section == "info" then
				info[k] = v
			elseif current_section == "letters" then
				letters[k] = v
			end
		end
		::continue::
	end

	return info, letters
end


-- =========================================
-- =========================================
-- ======= 3/ Init & Rule Registration =====
-- =========================================
-- =========================================

--- Loads personal_info.toml and registers @-tag + date rules in the shared
--- dynamic_hotstrings engine.
--- @param opts table|nil { trigger_char?, personal_info_path? }
function M.init(opts)
	local options = type(opts) == "table" and opts or {}

	-- Resolve trigger character (default "★").
	if type(options.trigger_char) == "string" and options.trigger_char ~= "" then
		_trigger_char = options.trigger_char
	end

	-- Resolve personal_info.toml path.
	local home = os.getenv("HOME") or "~"
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

	-- Parse personal_info.toml.
	_info, _letters = _parse_personal_info_toml(info_path)

	-- Register @-tag letter shortcuts (e.g. "@p" → first_name).
	for letter, field in pairs(_letters) do
		if #letter == 1 and _info[field] then
			local value = _info[field]
			Engine.add_rule(
				"@" .. letter,                      -- suffix: "@p"
				"personal_info",                     -- section
				function() return value end          -- resolver
			)
			_rules_count = _rules_count + 1
		end
	end

	-- Register date rules (td, dt, date).
	Engine.register_date_rules(_trigger_char)
	_rules_count = _rules_count + 3  -- td, dt, date

	_enabled = _rules_count > 0
	Logger.info(LOG, "Dynamic hotstrings initialised: %d rule(s), trigger='%s', info=%d field(s).",
		_rules_count, _trigger_char, #_info)
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

--- Called by the daemon on every character. Checks the current typing buffer
--- against the shared engine and injects when a rule matches.
---
--- @param buffer string The current typing buffer (engine:current_buffer()).
--- @param trigger string The character that just triggered the check (the
---   magic key, typically "★" or "\\").
--- @return boolean True if a dynamic expansion was performed.
function M.on_trigger(buffer, trigger)
	if not _enabled then return false end
	if type(buffer) ~= "string" or buffer == "" then return false end

	-- Only fire on the configured trigger character.
	-- The shared engine matches the buffer suffix; we guard on the trigger.
	local t = trigger or _trigger_char
	if buffer:sub(-1) ~= t then return false end

	-- Injector loaded once at init; stored via closure below.
	local Engine = require("dynamic_hotstrings")
	if not Engine then return false end

	-- The shared engine matches the buffer SUFFIX (without the trigger char
	-- itself). Pass the buffer MINUS the last char (the trigger).
	local prefix = buffer:sub(1, -2)
	if prefix == "" then return false end

	local match = Engine.match_buffer(prefix, nil, nil)
	if not match then return false end

	-- Inject: erase the suffix + trigger, type the result.
	-- e.g. buffer "@p★" → backspace 3 chars → type "Adrien"
	local backspace_count = #(match.rule.suffix) + 1  -- suffix + trigger
	-- Injector is loaded once at require-time; the hotstrings injector module
	-- wraps ydotool and is always available on Linux.
	local ok_inj, injector = pcall(require, "modules.hotstrings.injector")
	if ok_inj and injector and type(injector.inject) == "function" then
		injector.inject(backspace_count, match.result)
		Logger.info(LOG, "Dynamic expansion: '%s' → '%s'.", match.rule.suffix, match.result)
		return true
	end

	Logger.warn(LOG, "Injector not available — expansion dropped: '%s'.", match.rule.suffix)
	return false
end

--- Returns the preview string for the current buffer (tooltip display).
--- @param buffer string The current typing buffer.
--- @return string|nil Preview text, or nil.
function M.preview(buffer)
	if not _enabled then return nil end
	if type(buffer) ~= "string" or buffer == "" then return nil end

	local ok_eng, Engine = pcall(require, "dynamic_hotstrings")
	if not ok_eng or not Engine then return nil end

	return Engine.preview(buffer:sub(1, -2), nil, nil)
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
--- @return number
function M.get_rules_count()
	return _rules_count
end

--- Returns a copy of the parsed personal info (for testing/diagnostics).
--- @return table
function M.get_info()
	local copy = {}
	for k, v in pairs(_info) do copy[k] = v end
	return copy
end

return M
