--- modules/llm/translation.lua

--- ==============================================================================
--- MODULE: Selection Translation Data (Linux)
--- DESCRIPTION:
--- Loads what the llm_translate_selection action and its llm_language parameter
--- need from the shared tree: _shared/modules/llm/translate.json (prompt, tag,
--- token budget) and the shipped locales (_shared/data/locale_names.json,
--- locale_order.json). The logic itself is the shared _shared/lua/llm/translate.lua;
--- this module only reads the files and hands them to it.
---
--- FEATURES & RATIONALE:
--- 1. The three files are read once and validated as a whole: a missing or
---    malformed one is an installation fault, logged once, and the action and
---    its parameter refuse to run rather than half-work.
--- 2. The binding editors (the zenity prompt and the picker page) get the same
---    choices from choices(), so both offer the one closed list.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Translate = require("llm.translate")

local LOG = "modules.llm.translation"

-- The shared files this module reads, relative to _shared/
local CONFIG_FILE = "modules/llm/translate.json"
local NAMES_FILE = "data/locale_names.json"
local ORDER_FILE = "data/locale_order.json"

-- The decoded files, loaded once: { config, names, order }
local _data = nil




-- =========================================
-- =========================================
-- ======= 1/ Loading ======================
-- =========================================
-- =========================================

--- Parses the three files. Exposed for tests.
--- @param config_text string|nil translate.json's content.
--- @param names_text string|nil locale_names.json's content.
--- @param order_text string|nil locale_order.json's content.
--- @return table|nil data { config, names, order }, string|nil reason
function M.parse(config_text, names_text, order_text)
	local config = type(config_text) == "string" and Json.decode(config_text) or nil
	if type(config) ~= "table" then return nil, "translate.json is missing or not JSON" end
	for _, key in ipairs({ "ui_value", "tag", "user_prefix", "prompt", "prediction_prompt" }) do
		if type(config[key]) ~= "string" or config[key] == "" then return nil, "translate.json has no " .. key end
	end
	if type(config.max_tokens) ~= "number" or config.max_tokens < 1 or config.max_tokens % 1 ~= 0 then
		return nil, "translate.json max_tokens is not a positive integer"
	end
	if type(config.max_language_bytes) ~= "number" or config.max_language_bytes < 1
		or config.max_language_bytes % 1 ~= 0 then return nil, "translate.json has no language byte limit" end
	local names = type(names_text) == "string" and Json.decode(names_text) or nil
	if type(names) ~= "table" or type(names.locales) ~= "table" then
		return nil, "locale_names.json is missing or has no locales"
	end
	local order = type(order_text) == "string" and Json.decode(order_text) or nil
	if type(order) ~= "table" or type(order.order) ~= "table" or #order.order == 0 then
		return nil, "locale_order.json is missing or has no order"
	end
	for _, code in ipairs(order.order) do
		local entry = names.locales[code]
		if type(entry) ~= "table" or type(entry.name) ~= "string" or type(entry.flag) ~= "string" then
			return nil, "locale_names.json has no name or flag for " .. tostring(code)
		end
	end
	return { config = config, names = names, order = order }, nil
end

--- Reads one shared file.
--- @param relative string Path under _shared/.
--- @return string|nil text
local function read_shared(relative)
	local path = require("infra.paths").shared(relative)
	local fh = path and io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- The shipped files, decoded. A missing or malformed one is an installation
--- fault: the action refuses to run and the reason is logged.
--- @return table|nil data { config, names, order }
function M.data()
	if _data then return _data end
	local data, reason = M.parse(read_shared(CONFIG_FILE), read_shared(NAMES_FILE), read_shared(ORDER_FILE))
	if not data then
		Logger.error(LOG, "Selection translation unavailable: %s.", tostring(reason))
		return nil
	end
	_data = data
	return _data
end




-- =========================================
-- =========================================
-- ======= 2/ The llm_language parameter ===
-- =========================================
-- =========================================

--- Reports whether a binding value names a target language.
--- @param value string The stored parameter.
--- @return boolean
function M.is_valid(value)
	local data = M.data()
	return data ~= nil and Translate.is_valid(value, data.config, data.names)
end

--- The target languages a binding may name, in display order: the interface
--- language first, labelled with its current native name, then every locale.
--- @return table Array of { value, label }.
function M.choices()
	local data = M.data()
	if not data then error("the translation choices are unavailable: the shared files did not load") end
	local i18n = require("infra.i18n")
	local current = Translate.language_name(i18n.get_locale(), data.names)
	if not current then error("the interface locale '" .. tostring(i18n.get_locale()) .. "' has no native name") end
	local template = i18n.get("llm.translate.ui_language")
	-- Plain indices, never gsub: a name is data, not a pattern replacement.
	local at = template:find("{1}", 1, true)
	local label = at and (template:sub(1, at - 1) .. current .. template:sub(at + 3)) or template
	return Translate.choices(data.names, data.order, data.config, label)
end

--- Forgets the loaded files (tests).
function M._reset_for_test()
	_data = nil
end

return M
