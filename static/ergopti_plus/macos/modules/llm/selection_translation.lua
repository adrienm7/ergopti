--- modules/llm/selection_translation.lua

--- ==============================================================================
--- MODULE: Translation of the Selection
--- DESCRIPTION:
--- Runs the llm_translate_selection action: the selection is translated by the
--- AI menu's current text backend into the binding's language and offered as
--- one candidate of the prediction tooltip. Accepting it replaces the selection
--- with the translation, which stays selected; Escape, a dismissal or typing
--- leave the text untouched.
---
--- FEATURES & RATIONALE:
--- 1. Refusals first: a paused script, the AI switched off or a text backend
---    that is not ready refuse before the selection is read, with the notices
---    of llm_generate_prediction.
--- 2. The selection is read and replaced through the clipboard pipeline of the
---    tone actions (modules/shortcuts/actions/text.lua), so Electron apps,
---    which expose no AXSelectedText, work too. The translation replaces the
---    selection only while it is still the text that was translated, in the
---    window it was read from.
--- 3. One plain chat request (modules/llm/init.lua fetch_raw_text): the
---    translate.json prompt as system, the selection as user turn, no
---    streaming. Neither the selection nor the translation is ever logged.
--- 4. One translation at a time: a new trigger supersedes the previous one,
---    whose late answer is dropped by generation.
---
--- The pure logic (binding parameter, target language, prompt, answer reading)
--- is shared: _shared/lua/llm/translate.lua, configured by
--- _shared/modules/llm/translate.json.
--- ==============================================================================

local M = {}

local Translate  = require("llm.translate")
local Logger     = require("infra.logger")
local i18n       = require("infra.i18n")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")
local WindowInfo = require("adapters.window_info")

local LOG = "llm.selection_translation"

-- What the engine's shared answer seams log this flow as
local LABEL = "Selection translation"

-- The decoded translate.json, locale_names.json and locale_order.json, read on first use
local _config = nil
local _names = nil
local _order = nil

-- Generation of the current translation; a callback of an older one is stale
local _generation = 0




-- =====================================
-- =====================================
-- ======= 1/ Configuration ============
-- =====================================
-- =====================================

--- Decodes a shared JSON file. A missing or malformed file is a broken install
--- and raises.
--- @param path string|nil Absolute path.
--- @param name string Shared-relative name, for the error.
--- @return table decoded
local function read_shared_json(path, name)
	local raw = path and FileSystem.read(path) or nil
	if type(raw) ~= "string" then error("selection_translation: _shared/" .. name .. " is unreadable") end
	local decoded, decode_error = JsonCodec.decode(raw)
	if type(decoded) ~= "table" then
		error("selection_translation: _shared/" .. name .. " is not valid JSON: " .. tostring(decode_error))
	end
	return decoded
end

--- Returns the decoded _shared/modules/llm/translate.json, read once.
--- @return table config
function M.config()
	if _config then return _config end
	local config = read_shared_json(Paths.shared_llm_path("translate.json"), "modules/llm/translate.json")
	for _, key in ipairs({ "ui_value", "tag", "user_prefix", "prompt", "prediction_prompt" }) do
		if type(config[key]) ~= "string" or config[key] == "" then
			error("selection_translation: translate.json field '" .. key .. "' must be a non-empty string")
		end
	end
	if type(config.max_tokens) ~= "number" or config.max_tokens <= 0 then
		error("selection_translation: translate.json field 'max_tokens' must be a positive number")
	end
	if type(config.max_language_bytes) ~= "number" or config.max_language_bytes < 1
		or config.max_language_bytes % 1 ~= 0 then error("translate.json has no language byte limit") end
	_config = config
	return _config
end

--- Returns the decoded _shared/data/locale_names.json, read once.
--- @return table names
function M.locale_names()
	if _names then return _names end
	local names = read_shared_json(Paths.shared("data/locale_names.json"), "data/locale_names.json")
	if type(names.locales) ~= "table" then
		error("selection_translation: locale_names.json holds no 'locales' table")
	end
	_names = names
	return _names
end

--- Returns the decoded _shared/data/locale_order.json, read once.
--- @return table order
local function locale_order()
	if _order then return _order end
	local order = read_shared_json(Paths.shared("data/locale_order.json"), "data/locale_order.json")
	if type(order.order) ~= "table" then
		error("selection_translation: locale_order.json holds no 'order' list")
	end
	_order = order
	return _order
end

--- The interface locale code, the one "ui" follows.
--- @return string code
local function interface_locale()
	return require("modules.llm.profiles").prompt_language()
end




-- =====================================
-- =====================================
-- ======= 2/ Internal Helpers =========
-- =====================================
-- =====================================

--- Shows a notice explaining why a translation did nothing.
--- @param key string Locale key of the notice.
local function show_notice(key)
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local ok_show, shown = false, nil
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.show) == "function" then
		ok_show, shown = pcall(tooltip.show, i18n.get(key), true, true)
	end
	if not ok_show or shown ~= true then
		Logger.warn(LOG, "Translation notice '%s' was not shown: %s.", key, tostring(shown))
	end
end

--- Loads a module the translation calls at dispatch time.
--- @param name string Module name.
--- @param method string Function the module must expose.
--- @return table|nil module The module, or nil after logging why it is unavailable.
local function dependency(name, method)
	local ok, module = pcall(require, name)
	if not ok or type(module) ~= "table" or type(module[method]) ~= "function" then
		Logger.error(LOG, "Translation impossible: '%s.%s' is unavailable (%s).", name, method, tostring(module))
		return nil
	end
	return module
end

--- Tells whether a callback still belongs to the current translation.
--- @param generation number The translation the callback belongs to.
--- @param stage string What the callback delivers, for the log.
--- @return boolean current
local function is_current(generation, stage)
	if generation == _generation then return true end
	Logger.info(LOG, "Translation %s dropped: a newer translation superseded it.", stage)
	return false
end

--- Replaces the selection with the accepted translation, only in the window it
--- was read from and while the selection is still the translated text.
--- @param selection string The translated selection.
--- @param translation string The accepted translation.
--- @param focus string The focused window identity when the selection was read.
--- @param parent string|nil Stable action parent.
--- @return boolean started True when the replacement is under way.
local function replace_selection(selection, translation, focus, parent)
	local current_focus = WindowInfo.focused_identity()
	if current_focus == nil or current_focus ~= focus then
		Logger.info(LOG, "Translation not typed: the focus moved to another window (%s → %s).",
			tostring(focus), tostring(current_focus))
		return false
	end
	local Text = dependency("modules.shortcuts.actions.text", "replace_copied_selection")
	if not Text then return false end
	local started = Text.replace_copied_selection(selection, translation, parent, function(matched)
		if not matched then
			Logger.info(LOG, "Translation not typed: the selection changed since it was read.")
			return
		end
		Logger.info(LOG, "Selection replaced by its translation (%d byte(s)).", #translation)
	end)
	if not started then
		Logger.warn(LOG, "Translation not typed: another text action still owns the clipboard.")
	end
	return started == true
end

--- Requests the translation once the selection was read.
--- @param generation number The translation.
--- @param language string Native name of the target language.
--- @param selection string The selected text.
--- @param parent string|nil Stable action parent.
local function request_translation(generation, language, selection, parent)
	if not is_current(generation, "selection") then return end
	local focus = WindowInfo.focused_identity()
	if focus == nil then
		Logger.warn(LOG, "Translation refused: the focused window cannot be identified.")
		return
	end
	local engine = dependency("modules.llm.prediction_engine", "open_answer_surface")
	if not engine then return end
	local session = engine.open_answer_surface(LABEL)
	if not session then
		Logger.warn(LOG, "Translation stopped: the prediction tooltip could not be opened.")
		return
	end
	local config = M.config()

	--- Ends a translation that produced nothing.
	--- @param reason string Why, for the log.
	local function fail(reason)
		Logger.warn(LOG, "Translation failed: %s.", reason)
		engine.close_answer_surface(session)
		show_notice("llm.translate.failed")
	end
	local function on_raw(raw)
		if not is_current(generation, "answer") then return end
		local translation = Translate.extract(config, raw)
		if not translation then
			fail(string.format("the answer holds no %s block (%d char(s))", config.tag, #tostring(raw)))
			return
		end
		local shown = engine.show_answers(session, { translation }, 1, function(accepted)
			return replace_selection(selection, accepted, focus, parent)
		end)
		if not shown then
			Logger.info(LOG, "Translation dropped: its tooltip was dismissed or replaced.")
			return
		end
		Logger.info(LOG, "Translation offered (%d byte(s)).", #translation)
	end
	local function on_fail(detail)
		if not is_current(generation, "answer") then return end
		fail("the model gave no answer (" .. tostring(detail) .. ")")
	end
	local sent = engine.request_chat_answer(LABEL, Translate.system_prompt(config, language),
		Translate.user_text(config, selection), config.max_tokens, on_raw, on_fail)
	if not sent then
		fail("the request could not be sent")
		return
	end
	Logger.info(LOG, "Translation %d requested into %s (%d byte(s)).", generation, language, #selection)
end




-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Reports whether a llm_language binding value is valid.
--- @param value string The stored parameter.
--- @return boolean
function M.is_valid(value)
	return Translate.is_valid(value, M.config(), M.locale_names())
end

--- The target languages a binding may name: the interface language first
--- (labelled with its current native name), then every shipped locale in the
--- language menu's order.
--- @return table Array of { value, label }.
function M.choices()
	local names = M.locale_names()
	local current = Translate.language_name(interface_locale(), names)
	if not current then
		error("selection_translation: the interface locale '" .. tostring(interface_locale())
			.. "' has no native name in locale_names.json")
	end
	return Translate.choices(names, locale_order(), M.config(), i18n.format("llm.translate.ui_language", current))
end

--- Translates the selection and offers the translation in the prediction
--- tooltip.
--- @param value string The binding's parameter: "ui" or a locale code.
--- @param parent string|nil Stable action parent of the text actions.
--- @return boolean started True when the selection is being read.
function M.run(value, parent)
	local engine = dependency("modules.llm.prediction_engine", "admit_answer_request")
	if not engine or not engine.admit_answer_request(LABEL) then return false end
	local config, names = M.config(), M.locale_names()
	local target = Translate.parse(value, config, names)
	if not target then
		Logger.warn(LOG, "Translation refused: invalid language parameter '%s'.", tostring(value))
		return false
	end
	local code = Translate.target_locale(target, config, interface_locale())
	local language = Translate.resolve_language(target, config, names, interface_locale())
	if not language then
		Logger.error(LOG, "Translation refused: locale '%s' has no native name.", tostring(code))
		return false
	end
	local Text = dependency("modules.shortcuts.actions.text", "read_copied_selection")
	if not Text then return false end
	local previous = _generation
	_generation = previous + 1
	local generation = _generation
	local started = Text.read_copied_selection(parent, function(selection)
		if type(selection) ~= "string" or selection:match("^%s*$") then
			if not is_current(generation, "selection") then return end
			Logger.info(LOG, "Translation refused: the selection holds no text.")
			show_notice("llm.translate.no_selection")
			return
		end
		request_translation(generation, language, selection, parent)
	end, function()
		if not is_current(generation, "selection") then return end
		Logger.info(LOG, "Translation refused: nothing is selected.")
		show_notice("llm.translate.no_selection")
	end)
	if not started then
		-- Nothing was read: the translation in flight, if any, stays the current one
		if _generation == generation then _generation = previous end
		Logger.info(LOG, "Translation ignored: the selection cannot be read now.")
		return false
	end
	Logger.info(LOG, "Translation %d started (target '%s').", generation, code)
	return true
end

--- Drops every translation in flight and the decoded files, for tests and a
--- fresh start.
function M.reset()
	_generation = _generation + 1
	_config, _names, _order = nil, nil, nil
	Logger.debug(LOG, "Translation generation advanced to %d.", _generation)
end

return M
