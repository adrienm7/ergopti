--- _shared/settings/engine/value_check.lua

--- ==============================================================================
--- MODULE: User Value Check (Lua port)
--- DESCRIPTION:
--- Lua port of _shared/settings/data/value_schema/value_check.js for the macOS
--- and Linux drivers: checks one user-entered or stored setting value against
--- its declaration in value_schema.json. Both ports replay
--- value_check_vectors.json (_shared/tests/lua/value_check_contract.lua), so a
--- value refused on one OS is refused on every OS for the same reason.
---
--- FEATURES & RATIONALE:
--- 1. Three places, one rule: parse_entry() reads typed text, check_value()
---    reads a loaded value, require_value() guards the consuming boundary and
---    raises. Callers log and localize; this module stays pure.
--- 2. Special values (0 = no time limit, -1 = never) are declared per setting
---    and admitted outside min..max.
--- 3. Lengths count UTF-8 characters, not bytes, as the JS port counts code
---    points, so a one-character trigger such as « ★ » is one character.
--- ==============================================================================

local NumberPolicy = require("core.text.engine.number_policy")

local M = {}

--- Every refusal reason; the localized message is `dialog.value_check.<reason>`.
M.REASONS = {
	"empty", "wrong_type", "not_finite", "not_integer",
	"below_minimum", "above_maximum", "not_allowed", "too_long", "not_url",
}

local TYPES = { integer = true, decimal = true, boolean = true, enum = true, string = true, path = true, url = true }

--- A web address: a lowercase http or https scheme, then at least one
--- character and no ASCII space or control character anywhere (the JS and AHK
--- ports' [^\x00-\x20\x7f]; %c is exactly 0-31 and 127 in the C locale).
--- @param value string Candidate.
--- @return boolean
local function is_url(value)
	local rest = value:match("^https?://(.*)$")
	return rest ~= nil and rest ~= "" and value:find("[%c ]") == nil
end





-- ================================
-- ================================
-- ======= 1/ Schema Lookup =======
-- ================================
-- ================================

--- Splits a dotted path into its segments.
--- @param key string Dotted path.
--- @return table segments
local function split(key)
	local segments = {}
	for part in (key .. "."):gmatch("([^.]*)%.") do segments[#segments + 1] = part end
	return segments
end

--- The declaration of one setting, raising on an unknown name. A pattern key
--- may use `*` for one path segment.
--- @param schema table Decoded value_schema.json.
--- @param key string Dotted setting path.
--- @return table entry
function M.entry_for(schema, key)
	local settings = type(schema) == "table" and schema.settings
	if type(settings) ~= "table" then error("value_check: the value schema has no settings", 2) end
	if type(key) ~= "string" then error("value_check: a setting key must be a string", 2) end
	if settings[key] ~= nil then return settings[key] end
	local segments = split(key)
	for name, entry in pairs(settings) do
		if name:find("*", 1, true) then
			local pattern = split(name)
			if #pattern == #segments then
				local matched = true
				for index, part in ipairs(pattern) do
					if part ~= "*" and part ~= segments[index] then matched = false; break end
				end
				if matched then return entry end
			end
		end
	end
	error("value_check: the value schema declares no setting " .. key, 2)
end





-- =========================
-- =========================
-- ======= 2/ Checks =======
-- =========================
-- =========================

--- A refusal carrying the declared bounds for the localized message.
--- @param reason string One of M.REASONS.
--- @param entry table Declaration.
--- @return table result
local function refusal(reason, entry)
	return { ok = false, reason = reason, min = entry.min, max = entry.max }
end

--- Whether a value is one of the declaration's special values.
--- @param entry table Declaration.
--- @param value any Candidate.
--- @return boolean
local function is_special(entry, value)
	if type(entry.special) ~= "table" then return false end
	for _, item in ipairs(entry.special) do
		if item.value == value then return true end
	end
	return false
end

--- Checks a numeric candidate.
--- @param entry table Declaration.
--- @param value any Candidate.
--- @return table result
local function check_number(entry, value)
	if type(value) ~= "number" then return refusal("wrong_type", entry) end
	if not NumberPolicy.is_finite(value) then return refusal("not_finite", entry) end
	if is_special(entry, value) then return { ok = true, value = value } end
	if entry.type == "integer" and value % 1 ~= 0 then return refusal("not_integer", entry) end
	if entry.min ~= nil and value < entry.min then return refusal("below_minimum", entry) end
	if entry.max ~= nil and value > entry.max then return refusal("above_maximum", entry) end
	return { ok = true, value = value }
end

--- Number of UTF-8 characters of a string.
--- @param text string
--- @return integer
local function char_count(text)
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

--- Checks a value as loaded from a file or received from a host bridge.
--- @param entry table Declaration from entry_for().
--- @param value any Candidate value.
--- @return table result { ok, value } or { ok = false, reason, min, max }.
function M.check_value(entry, value)
	if type(entry) ~= "table" or not TYPES[entry.type] then
		error("value_check: a check needs a declared type", 2)
	end
	local kind = entry.type
	if kind == "integer" or kind == "decimal" then return check_number(entry, value) end
	if kind == "boolean" then
		if type(value) == "boolean" then return { ok = true, value = value } end
		return refusal("wrong_type", entry)
	end
	if kind == "enum" then
		if type(value) ~= "string" and type(value) ~= "boolean" then return refusal("wrong_type", entry) end
		for _, allowed in ipairs(entry.values) do
			if allowed == value then return { ok = true, value = value } end
		end
		return refusal("not_allowed", entry)
	end
	if type(value) ~= "string" then return refusal("wrong_type", entry) end
	if value == "" and entry.allow_empty ~= true then return refusal("empty", entry) end
	if entry.max_length ~= nil and char_count(value) > entry.max_length then return refusal("too_long", entry) end
	if kind == "url" and not is_url(value) then return refusal("not_url", entry) end
	return { ok = true, value = value }
end

--- Rounds a bound scaled to the typed unit to the microunit, so 0.001 * 1000
--- reads 1, not 1.0000000000000002.
--- @param bound number Bound in the stored unit.
--- @param scale number Typed units per stored unit.
--- @return number
local function scaled(bound, scale)
	local value = bound * scale * 1e6
	value = value >= 0 and math.floor(value + 0.5) or -math.floor(-value + 0.5)
	return value / 1e6
end

--- A refusal of typed text, its bounds given in the typed unit.
--- @param reason string One of M.REASONS.
--- @param entry table Declaration.
--- @return table result
local function entry_refusal(reason, entry)
	local result = refusal(reason, entry)
	local scale = entry.entry_scale or 1
	if result.min ~= nil then result.min = scaled(result.min, scale) end
	if result.max ~= nil then result.max = scaled(result.max, scale) end
	return result
end

--- Reads what a person typed in an entry box. A declaration with
--- `entry_scale` is typed in another unit than it is stored (milliseconds
--- typed, seconds stored: scale 1000) and `entry_type` says whether the typed
--- number may carry decimals; a refusal's bounds are in the typed unit.
--- @param entry table Declaration from entry_for().
--- @param text any Raw text of the box.
--- @return table result
function M.parse_entry(entry, text)
	if type(text) ~= "string" then return entry_refusal("wrong_type", entry) end
	if entry.type == "string" or entry.type == "path" then return M.check_value(entry, text) end
	local trimmed = require("core.text.engine.utils_core").trim(text)
	if trimmed == "" then return entry_refusal("empty", entry) end
	if entry.type == "integer" or entry.type == "decimal" then
		local integral = trimmed:match("^[+-]?%d+$")
		local decimal = integral or trimmed:match("^[+-]?%d+[.,]%d+$")
		if not decimal then return entry_refusal("wrong_type", entry) end
		if (entry.entry_type or entry.type) == "integer" and not integral then
			return entry_refusal("not_integer", entry)
		end
		-- tonumber() refuses a leading « + »; the sign is applied by hand.
		local sign, digits = trimmed:match("^([+-]?)(.*)$")
		local typed = tonumber((digits:gsub(",", ".")))
		if sign == "-" then typed = -typed end
		local scale = entry.entry_scale or 1
		local result = check_number(entry, scale == 1 and typed or typed / scale)
		if result.ok then return result end
		return entry_refusal(result.reason, entry)
	end
	if entry.type == "boolean" then
		if trimmed == "true" then return { ok = true, value = true } end
		if trimmed == "false" then return { ok = true, value = false } end
		return refusal("wrong_type", entry)
	end
	return M.check_value(entry, trimmed)
end

--- The localized message of a refusal, as i18n keys with their arguments, for
--- the driver to translate and join: the sentence naming what is accepted,
--- then one sentence per special value. An argument { key = ... } is itself an
--- i18n key to translate before it is inserted.
--- @param entry table Declaration.
--- @param result table A refusal from parse_entry() or check_value().
--- @return table parts Array of { key = string, args = table }.
function M.message_parts(entry, result)
	local parts = {}
	if entry.type == "integer" or entry.type == "decimal" then
		local base = "dialog.value_check.range_" .. (entry.entry_type or entry.type)
		local unit = entry.entry_unit or entry.unit
		if unit then
			parts[1] = { key = base .. "_unit", args = { result.min, result.max, { key = "value_check.unit." .. unit } } }
		else
			parts[1] = { key = base, args = { result.min, result.max } }
		end
		for _, item in ipairs(entry.special or {}) do
			parts[#parts + 1] = { key = "dialog.value_check.special",
				args = { scaled(item.value, entry.entry_scale or 1), { key = item.label_key } } }
		end
	elseif result.reason == "too_long" then
		parts[1] = { key = "dialog.value_check.too_long", args = { entry.max_length } }
	elseif result.reason == "not_allowed" then
		parts[1] = { key = "dialog.value_check.not_allowed", args = {} }
	elseif result.reason == "not_url" then
		parts[1] = { key = "dialog.value_check.not_url", args = {} }
	else
		parts[1] = { key = "dialog.value_check.empty", args = {} }
	end
	return parts
end

--- Writes a bound as the JS port writes it: no « .0 » on a whole number
--- (Lua 5.4 writes 1.0 for a float), at most 15 significant digits otherwise.
--- @param value number
--- @return string
function M.format_number(value)
	if value % 1 == 0 and math.abs(value) < 2 ^ 53 then return string.format("%.0f", value) end
	return (string.format("%.15g", value))
end

--- Translates message_parts() with the driver's i18n accessor, fills the
--- positional {1}, {2}… placeholders and joins the sentences with a space, so
--- every driver shows the same refusal text.
--- @param parts table From message_parts().
--- @param translate function i18n accessor: translate(key) -> template with {1}, {2}…
--- @return string message
function M.render_message(parts, translate)
	local sentences = {}
	for index, part in ipairs(parts) do
		local args = {}
		for position, arg in ipairs(part.args) do
			if type(arg) == "table" then
				args[position] = translate(arg.key)
			elseif type(arg) == "number" then
				args[position] = M.format_number(arg)
			else
				args[position] = tostring(arg)
			end
		end
		local template = translate(part.key)
		if type(template) ~= "string" then error("value_check: no text for " .. part.key, 2) end
		-- Plain replacement: a translated unit or label may hold « % ».
		sentences[index] = (template:gsub("{(%d+)}", function(position)
			return args[tonumber(position)] or ("{" .. position .. "}")
		end))
	end
	return table.concat(sentences, " ")
end

--- The declared keys by constant name (TAP_HOLD_TIME_ACTIVATION_SECONDS, a `*`
--- segment spelled ANY), generated from the schema; an unknown name raises,
--- since a misspelt key would read as nil.
M.KEY = setmetatable({}, {
	__index = function(_, name)
		local key = require("settings.engine.value_schema_data").keys[name]
		if key == nil then error("value_check: no declared key named " .. tostring(name), 2) end
		return key
	end,
	__newindex = function() error("value_check: the key table is read-only", 2) end,
})

--- The generated declarations (value_schema_data.lua), required on first use.
--- @return table schema
function M.schema()
	return require("settings.engine.value_schema_data")
end

--- The declaration of a setting of the shared schema.
--- @param key string Dotted setting path.
--- @return table entry
function M.declaration(key)
	return M.entry_for(M.schema(), key)
end

--- The localized refusal text of a setting of the shared schema.
--- @param key string Dotted setting path.
--- @param result table A refusal from parse_entry() or check_value().
--- @param translate function i18n accessor returning a template.
--- @return string message
function M.refusal_text(key, result, translate)
	return M.render_message(M.message_parts(M.declaration(key), result), translate)
end

--- Checks a value a driver holds in another unit than its declaration (the
--- macOS remap model holds whole milliseconds for a delay the files store in
--- seconds): it must be a finite whole number and pass the declaration once
--- multiplied by `scale`. A string or a fraction never reaches the engine.
--- @param key string Dotted setting path of the shared schema.
--- @param value any Candidate in the driver's unit.
--- @param scale number Declared units per driver unit.
--- @return boolean admitted
--- @return string|nil reason One of M.REASONS when refused.
function M.check_whole_scaled(key, value, scale)
	if type(value) ~= "number" then return false, "wrong_type" end
	if not NumberPolicy.is_finite(value) then return false, "not_finite" end
	if value % 1 ~= 0 then return false, "not_integer" end
	local checked = M.check_value(M.declaration(key), value * scale)
	return checked.ok, checked.reason
end

--- Guards a consuming boundary: returns the value, or raises an error naming
--- the setting, the reason and the value for the caller to log.
--- @param schema table|nil Decoded value_schema.json; the generated one when nil.
--- @param key string Dotted setting path.
--- @param value any Value about to reach the engine.
--- @return any value
function M.require_value(schema, key, value)
	local result = M.check_value(M.entry_for(schema or M.schema(), key), value)
	if not result.ok then
		error(string.format("value_check: %s refused (%s): %s", key, result.reason, tostring(value)), 2)
	end
	return result.value
end

return M
