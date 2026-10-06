--- ui/menu/shortcut_utils.lua

--- ==============================================================================
--- MODULE: Menu Shortcut Utils
--- DESCRIPTION:
--- Provides shared helpers to parse, normalize, display, and prompt keyboard
--- shortcuts from menu modules.
--- ============================================================================== 

local M = {}
local hs     = hs
local dialog = require("infra.dialog_util")
local i18n   = require("infra.i18n")
local Logger = require("infra.logger")
local SendInput = require("send_input")

local LOG = "menu.shortcut_utils"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local VALID_MODS = {
	cmd = true,
	alt = true,
	ctrl = true,
	shift = true,
}

local MOD_ORDER = {
	shift = 1,
	cmd = 2,
	alt = 3,
	ctrl = 4,
}

local function sort_modifiers(mods)
	table.sort(mods, function(a, b)
		local oa = MOD_ORDER[a] or 99
		local ob = MOD_ORDER[b] or 99
		if oa == ob then return a < b end
		return oa < ob
	end)
end





-- =======================================
-- =======================================
-- ======= 2/ Parsing & Formatting =======
-- =======================================
-- =======================================

--- Normalizes a shortcut definition into a validated table.
--- @param mods table|nil Modifier keys.
--- @param key string|nil Trigger key.
--- @param default_mods table|nil Default modifiers if none are provided.
--- @return table|nil Normalized shortcut table or nil when invalid.
function M.normalize_shortcut(mods, key, default_mods)
	if type(key) ~= "string" then return nil end
	local clean_key = key:match("^%s*(.-)%s*$")
	if clean_key == "" then return nil end

	local seen = {}
	local out_mods = {}
	for _, m in ipairs(type(mods) == "table" and mods or {}) do
		local mod = tostring(m):lower():match("^%s*(.-)%s*$")
		if mod == "option" then mod = "alt" end
		if mod == "control" then mod = "ctrl" end
		if VALID_MODS[mod] and not seen[mod] then
			seen[mod] = true
			table.insert(out_mods, mod)
		end
	end

	if #out_mods == 0 and type(default_mods) == "table" then
		for _, dm in ipairs(default_mods) do
			local m = tostring(dm):lower()
			if VALID_MODS[m] and not seen[m] then
				seen[m] = true
				table.insert(out_mods, m)
			end
		end
	end

	if #out_mods == 0 then return nil end
	sort_modifiers(out_mods)
	return { mods = out_mods, key = clean_key:lower() }
end

--- Parses a raw input string to a normalized shortcut definition.
--- @param raw string Raw value from text prompt.
--- @param default_mods table|nil Default modifiers if none are provided.
--- @return table|nil Parsed shortcut.
function M.parse_shortcut_input(raw, default_mods)
	if type(raw) ~= "string" then return nil end
	local normalized = raw:match("^%s*(.-)%s*$"):lower()
	if normalized == "" then return nil end

	local parts = {}
	for part in normalized:gmatch("[^+]+") do
		table.insert(parts, part)
	end
	if #parts < 1 then return nil end

	local key = parts[#parts]
	local mods = {}
	for i = 1, #parts - 1 do table.insert(mods, parts[i]) end
	return M.normalize_shortcut(mods, key, default_mods)
end

--- Converts a shortcut table to a config-friendly string.
--- @param sc table|nil Shortcut definition.
--- @return string String representation for input fields.
function M.shortcut_to_config_string(sc)
	if type(sc) ~= "table" then return "" end
	local mods = type(sc.mods) == "table" and table.concat(sc.mods, "+") or ""
	local key = type(sc.key) == "string" and sc.key or ""
	if mods ~= "" and key ~= "" then return mods .. "+" .. key end
	if key ~= "" then return key end
	return ""
end

--- Converts a shortcut table to a readable label for menu entries.
--- @param sc table|nil Shortcut definition.
--- @param none_label string|nil Label when shortcut is disabled.
--- @return string Display label.
function M.shortcut_to_label(sc, none_label)
	-- `common.none`, not a French word written here: this is a menu label, and the
	-- other two drivers already read that key for the same row (Windows in
	-- menu_settings.ahk, Linux in menu_builder.lua). A literal is a translation of
	-- exactly one of the twenty-one languages the menu is drawn in.
	if type(sc) ~= "table" then return none_label or i18n.get("common.none") end
	local ordered_mods = {}
	for _, m in ipairs(sc.mods or {}) do table.insert(ordered_mods, m) end
	sort_modifiers(ordered_mods)

	local mods_cap = {}
	for _, m in ipairs(ordered_mods) do
		table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
	end

	local mods_str = table.concat(mods_cap, " + ")
	local key_str = string.upper(sc.key or "")
	if key_str == "" then return none_label or i18n.get("common.none") end
	return (mods_str ~= "" and (mods_str .. " + ") or "") .. key_str
end





-- ==================================
-- ==================================
-- ======= 3/ Prompt Helpers ========
-- ==================================
-- ==================================

--- Invokes a shortcut mutation and reports only literal committed success.
--- @param callback function Shortcut transaction callback.
--- @param ... any Callback arguments.
--- @return boolean committed
local function apply_prompt_update(callback, ...)
	local ok, result = xpcall(callback, debug.traceback, ...)
	if not ok then
		Logger.error(LOG, "Shortcut prompt update raised: %s.", tostring(result))
		return false
	end
	if result ~= true then
		Logger.error(LOG, "Shortcut prompt update did not commit: %s.", tostring(result))
		return false
	end
	return true
end

--- Delegates a program edit to the session's existing writer-fenced owner.
--- @param gestures table Gestures facade.
--- @param binding string Canonical binding identifier.
--- @param action string Action identifier.
--- @param value string Validated parameter scalar.
--- @param mutation table Assignment read, apply and restore ports.
--- @param transaction function Session program transaction entry point.
--- @return boolean committed
function M.commit_action_parameter(gestures, binding, action, value, mutation, transaction)
	if type(transaction) ~= "function" then
		Logger.error(LOG, "Private program edit refused because its transaction owner is unavailable.")
		return false
	end
	local called, committed = pcall(transaction, binding, action, value, mutation)
	if not called or committed ~= true then
		Logger.error(LOG, "Private program edit was not acknowledged.")
		return false
	end
	return true
end

--- Opens a standard shortcut prompt and returns parsed output via callback.
--- @param opts table Prompt options.
--- @return boolean True only when the update callback committed.
function M.prompt_shortcut(opts)
	if type(opts) ~= "table" or type(opts.on_apply) ~= "function" then return false end

	local title = type(opts.title) == "string" and opts.title or i18n.get("shortcuts.shortcut_label")
	local message = type(opts.message) == "string"
		and opts.message
		or i18n.get("shortcuts.shortcut_format_hint")

	local current = M.shortcut_to_config_string(opts.current_shortcut)
	local ok_prompt, button, raw = pcall(dialog.text_prompt, title, message, current, "OK", i18n.get("common.cancel"))
	if not ok_prompt or button ~= "OK" or type(raw) ~= "string" then return false end

	local cleaned = raw:match("^%s*(.-)%s*$")
	if cleaned == "" then
		return apply_prompt_update(opts.on_apply, nil, nil)
	end

	local parsed = M.parse_shortcut_input(cleaned, opts.default_mods)
	if parsed then
		return apply_prompt_update(opts.on_apply, parsed.mods, parsed.key)
	end

	pcall(dialog.alert, i18n.get("shortcut_utils.format_invalid"), i18n.get("shortcut_utils.format_hint"))
	return false
end





-- ==============================================
-- ==============================================
-- ======= 5/ Parameterized Action Prompt =======
-- ==============================================
-- ==============================================

--- Builds the "Configure <action>" dialog title from its translated template.
---
--- The substitution is done on plain indices rather than with gsub: an action
--- label may contain a `%`, which gsub reads as a capture reference in the
--- REPLACEMENT string and would raise "invalid use of '%'".
--- @param label string The human-readable action label.
--- @return string The localised title.
function M.action_parameter_title(label)
	local template = i18n.get("dialog.gestures.param_title")
	local at = template:find("{1}", 1, true)
	if not at then return template .. " " .. tostring(label) end
	return template:sub(1, at - 1) .. tostring(label) .. template:sub(at + 3)
end

--- Asks for one parameter value the way its kind is chosen: an application is
--- picked in the /Applications chooser, every other kind is typed.
--- @param gestures table The gestures facade.
--- @param action string The action being configured.
--- @param spec string Its parameter kind.
--- @param title string The prompt's title.
--- @param prior string The value shown first.
--- @return string|nil value Nil when the user cancelled.
function M.ask_parameter_value(gestures, action, spec, title, prior)
	local prompt = gestures.parameter_prompt(action)
	if spec == "app" then
		return dialog.choose_application(prompt, title)
	end
	local save_btn = i18n.get("button.save")
	local prompt_ok, button, typed = pcall(dialog.text_prompt,
		title, prompt, prior, save_btn, i18n.get("button.cancel"))
	if not prompt_ok or button ~= save_btn then return nil end
	return typed
end

--- Prompts for an action's required parameter and stores it against `binding`.
---
--- Some actions (open_url, search_web) carry no useful behaviour without a value:
--- their handlers read get_action_parameter(binding, action) and silently do
--- nothing when it is empty. Any menu that can assign such an action must collect
--- the value first, or it hands the user a binding that looks configured and does
--- nothing when pressed.
---
--- Parameters are keyed by (binding, action), so `binding` can be a gesture slot
--- or a script-control key name — the storage does not care which.
---
--- @param gestures table The gestures actions module (parameter storage owner).
--- @param binding string The binding the parameter belongs to.
--- @param action string The action being configured.
--- @param spec string The parameter spec ("search_url" or a plain link).
--- @param picked string|nil A value the action picker's own editor collected: it
---   is stored without a prompt when it validates, and prefills the prompt when
---   it does not.
--- @param mutation table|nil Program assignment ports for the session transaction.
--- @param transaction function|nil Session program transaction entry point.
--- @return boolean True when a valid value was stored and the optional transaction committed.
local function prompt_action_parameter(gestures, binding, action, spec, picked, mutation, transaction)
	if type(gestures) ~= "table" or type(spec) ~= "string" then return false end

	local label  = (type(gestures.get_action_label) == "function" and gestures.get_action_label(action)) or action
	local prior  = (type(gestures.get_action_parameter) == "function" and gestures.get_action_parameter(binding, action)) or ""

	-- Loop until the value validates or the user cancels: accepting an invalid one
	-- would store a parameter the action's own validator later rejects, which is
	-- the silent no-op this prompt exists to prevent. The prompt and its refusal
	-- text belong to the parameter kind; the gestures module owns them.
	local title    = M.action_parameter_title(label)
	local value    = type(picked) == "string" and picked or nil

	while true do
		if value == nil then
			value = M.ask_parameter_value(gestures, action, spec, title, prior)
			if value == nil then return false end
		end
		if type(gestures.validate_action_parameter) == "function"
			and gestures.validate_action_parameter(action, value) then
			if spec == "program" then
				return M.commit_action_parameter(gestures, binding, action, value, mutation, transaction)
			end
			return apply_prompt_update(gestures.set_action_parameter,
				binding, action, value)
		end
		pcall(dialog.block_alert, i18n.get("dialog.gestures.param_error_title"),
			gestures.parameter_error(action), "OK", nil, "warning")
		prior = value or prior
		value = nil
	end
end

--- Prompts and contains private program provider failures without logging values.
--- @param gestures table Gestures facade.
--- @param binding string Canonical binding identifier.
--- @param action string Action identifier.
--- @param spec string Parameter kind.
--- @param picked string|nil Picker editor value.
--- @param mutation table|nil Program assignment ports.
--- @param transaction function|nil Session program transaction entry point.
--- @return boolean committed
function M.prompt_action_parameter(gestures, binding, action, spec, picked, mutation, transaction)
	if spec ~= "program" then return prompt_action_parameter(gestures, binding, action, spec, picked, mutation, transaction) end
	local called, committed = pcall(prompt_action_parameter, gestures, binding, action, spec, picked, mutation, transaction)
	if not called then
		Logger.error(LOG, "Private program parameter prompt was refused by its provider.")
		return false
	end
	return committed == true
end

-- What picker_parameter_fields reads from the gestures facade.
local PICKER_EDITOR_FACADE = {
	"get_action_parameter_spec", "get_action_parameter", "parameter_prompt", "parameter_error", "send_vocabulary",
	"llm_prompt_choices", "llm_prompt_default_count", "llm_vision_choices", "llm_language_choices",
}

--- Readies picker items for the picker's own parameter editor: each action with
--- a parameter is marked with its kind and the value `binding` holds for it, so
--- the page can reopen the current one ("edit the current action"). The page
--- edits a text, a key, a shortcut, a prompt choice, a vision backend and a
--- target language itself; for any other kind it confirms without a value and
--- the native prompt asks for it. The returned fields give the page the
--- send-input vocabulary, the prompt profiles, the AI menu's prediction count,
--- the vision backends, the target languages and the same prompts and refusals
--- as the native prompt.
--- @param gestures table The gestures facade.
--- @param items table Picker items, marked in place.
--- @param binding string|nil The binding the pick is for; nil marks no value.
--- @return table { send_vocabulary, parameter_strings, prompt_choices, default_count,
---   vision_choices, language_choices, edit_current_label }, the options ActionPicker.open reads; empty, with an error
---   logged, when the facade lacks what the editor needs, and every value is then
---   asked by the native prompt.
function M.picker_parameter_fields(gestures, items, binding)
	for _, name in ipairs(PICKER_EDITOR_FACADE) do
		if type(gestures) ~= "table" or type(gestures[name]) ~= "function" then
			Logger.error(LOG, "The gestures facade has no %s — the picker cannot edit a value.", name)
			return {}
		end
	end
	local prompts, errors = {}, {}
	for _, item in ipairs(items) do
		local kind = item.type == "action" and gestures.get_action_parameter_spec(item.id) or nil
		if kind then
			if kind == "program" then
				local ready_ok, ready = pcall(function()
					return require("modules.gestures.actions_aux_owner").program_available() == true
						and type(gestures.program_admission_available) == "function"
						and gestures.program_admission_available() == true
						and type(gestures.program_binding_supported) == "function"
						and gestures.program_binding_supported(binding) == true
				end)
				if not ready_ok or ready ~= true then
					item.disabled = true
					item.hint = i18n.get("platform_reason.program_runner_unavailable")
				end
			end
			item.parameter = kind
			item.parameterValue = binding and gestures.get_action_parameter(binding, item.id) or ""
			if SendInput.KINDS[kind] or kind == "llm_prompt" or kind == "llm_vision" or kind == "llm_language" or kind == "program" then
				prompts[kind] = gestures.parameter_prompt(item.id)
				errors[kind] = gestures.parameter_error(item.id)
			end
		end
	end
	return {
		send_vocabulary = gestures.send_vocabulary(),
		prompt_choices = gestures.llm_prompt_choices(),
		default_count = gestures.llm_prompt_default_count(),
		vision_choices = gestures.llm_vision_choices(),
		language_choices = gestures.llm_language_choices(),
		edit_current_label = i18n.get("dialog.action_picker.edit_current"),
		parameter_strings = {
			save = i18n.get("button.save"),
			back = i18n.get("dialog.action_picker.back"),
			captureKey = i18n.get("dialog.action_picker.capture_key"),
			captureShortcut = i18n.get("dialog.action_picker.capture_shortcut"),
			promptLabel = i18n.get("dialog.action_picker.prompt_label"),
			countLabel = i18n.get("dialog.action_picker.count_label"),
			-- Raw: the page substitutes {1} with the count it shows
			countDefault = i18n.get("dialog.action_picker.count_default"),
			visionProviderLabel = i18n.get("dialog.action_picker.vision_provider_label"),
			visionModelLabel = i18n.get("dialog.action_picker.vision_model_label"),
			-- Raw: the page substitutes {1} with the backend's default model
			visionModelDefault = i18n.get("dialog.action_picker.vision_model_default"),
			visionModelRequired = i18n.get("dialog.action_picker.vision_model_required"),
			languageLabel = i18n.get("dialog.action_picker.language_label"),
			programExecutableLabel = i18n.get("dialog.action_picker.program_executable"),
			programArgumentsLabel = i18n.get("dialog.action_picker.program_arguments"),
			programAddLabel = i18n.get("dialog.action_picker.program_add_argument"),
			programRemoveLabel = i18n.get("dialog.action_picker.program_remove_argument"),
			prompts = prompts,
			errors = errors,
		},
	}
end

return M
