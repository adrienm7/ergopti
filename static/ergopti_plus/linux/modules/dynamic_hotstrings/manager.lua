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
	if type(options.trigger_char) == "string" and options.trigger_char ~= "" then
		_trigger_char = options.trigger_char
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

	-- The parsed [info] table is string-keyed, so the length operator (#) always
	-- reports 0; count its keys explicitly to log the real field total
	local info_field_count = 0
	for _ in pairs(_info) do info_field_count = info_field_count + 1 end

	_enabled = _rules_count > 0
	Logger.info(LOG, "Dynamic hotstrings initialised: %d rule(s), trigger='%s', info=%d field(s).",
		_rules_count, _trigger_char, info_field_count)
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
--- @return table|nil Canonical event details for a successful expansion.
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

	local match = Engine.match_buffer(prefix, DYNAMIC_GROUP, M.is_rule_enabled)
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
		return true, {
			trigger = match.rule.suffix .. t,
			replacement = match.result,
			h_type = "dynamic",
			backspace_count = backspace_count,
		}
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

	-- The same guard as the match path. A preview that offers what the engine
	-- will refuse is worse than no preview: the user sees a rule they switched
	-- off and concludes the toggle does nothing.
	return Engine.preview(buffer:sub(1, -2), DYNAMIC_GROUP, M.is_rule_enabled)
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
--- The three prefix families (iban, phone, ssn) are declared in the manifest,
--- rendered by the other two drivers, and registered by no Linux code at all, so
--- they are absent here rather than listed and inert: a switch for a rule that
--- does not exist is a worse lie than a missing switch. Implementing them is its
--- own item, tracked as a parity gap in the Linux plan.
local RULE_FAMILIES = {
	{ id = "date_long_fr",                        section = "datelongfr" },
	{ id = "date_fr",                             section = "datefr" },
	{ id = "date",                                section = "date" },
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
--- @return table Array of { id, section, enabled, label } and { separator = true }.
function M.rule_families()
	local out = {}
	for _, family in ipairs(RULE_FAMILIES) do
		if family.separator then
			out[#out + 1] = { separator = true }
		else
			out[#out + 1] = {
				id      = family.id,
				section = family.section,
				enabled = M.is_rule_enabled(nil, family.section),
				label   = _family_label(family),
			}
		end
	end
	return out
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
	if enabled then
		Storage.delete(RULE_PREF_PREFIX .. section)
	else
		Storage.set(RULE_PREF_PREFIX .. section, false)
	end
	Logger.debug(LOG, "Dynamic rule family %s: %s.", section, enabled and "on" or "off")
	return true
end

return M
