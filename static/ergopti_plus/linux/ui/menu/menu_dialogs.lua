--- ui/menu/menu_dialogs.lua

--- ==============================================================================
--- MODULE: Linux Menu Dialogs
--- DESCRIPTION:
--- The zenity dialogs, prompts and binding helpers the tray's section builders
--- share: placeholder filling, shell quoting, exit-status normalisation, text
--- prompts, error and information messages, the yes/no question, and the action
--- picker and slot-binding rows.
--- ==============================================================================

local M = {}

local WindowTitles = require("window_titles")
local Logger = require("logger.shim")
local Modal = require("ui.modal")
local TextPrompt = require("ui.text_prompt")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_dialogs"

--- Substitutes a single placeholder in a translated template.
---
--- Plain indices rather than gsub: a release tag or an interval code is data,
--- and a "%" in it would be read as a capture reference in gsub's REPLACEMENT
--- string and raise "invalid use of '%'".
--- @param template string The translated string, containing `placeholder`.
--- @param placeholder string The literal token to replace, e.g. "{tag}".
--- @param value any The value to substitute.
--- @return string The filled template.
local function _fill(template, placeholder, value)
	local at = template:find(placeholder, 1, true)
	if not at then return template .. " " .. tostring(value) end
	return template:sub(1, at - 1) .. tostring(value) .. template:sub(at + #placeholder)
end

local function shell_quote(value)
	return require("text_utils").shell_quote(value or "")
end

--- Normalises a child-process exit status across interpreters.
---
--- Production runs LuaJIT (Lua 5.1 semantics): os.execute and pipe:close
--- return a NUMBER, 0 for success. From Lua 5.2 the same success reads as
--- `true`. A bare `if not status` is therefore never true on LuaJIT — not
--- even for a failure — so Cancel and "binary absent" both read as success.
--- Every zenity site below goes through this helper.
--- @param status any
--- @return boolean
local function succeeded(status)
	return status == true or status == 0
end

--- Asks the user for a line of text (ui/text_prompt.lua, shared with the AI
--- agent's command dialog).
---
--- Declared here, above every closure that calls it: a `local` declared after a
--- closure that uses it is captured as a nil GLOBAL, and the call fails at click
--- time rather than at load time — which is the shape of three bugs already fixed
--- in this driver.
--- @param title string Window title.
--- @param prompt string The question.
--- @param initial string|nil Pre-filled value.
--- @param hidden boolean|nil Mask the typed text (an API key).
--- @return string|nil The entered text, or nil when the dialog was cancelled.
local function prompt_text(title, prompt, initial, hidden)
	return TextPrompt.ask(title, prompt, initial, hidden)
end

--- Shows a message the user must acknowledge.
--- @param message string Already-localised text.
--- @param title string|nil Already-localised window title.
local function show_error(message, title)
	local command = "zenity --error"
		.. " --title=" .. shell_quote(WindowTitles.compose(title == nil and i18n_safe("common.error_title") or title))
		.. " --text=" .. shell_quote(message) .. " 2>/dev/null"
	if not succeeded(Modal.run(function() return os.execute(command) end)) then
		-- Zenity absent: the refusal still has to reach someone, and a silent
		-- rejection reads as a menu row that does nothing when clicked.
		Logger.error(LOG, "%s", tostring(message))
	end
end

--- Shows an informational message the user must acknowledge.
--- @param title string Already-localised window title.
--- @param message string Already-localised text.
local function show_info(title, message)
	local command = "zenity --info --title=" .. shell_quote(WindowTitles.compose(title))
		.. " --text=" .. shell_quote(message) .. " 2>/dev/null"
	if not succeeded(Modal.run(function() return os.execute(command) end)) then
		-- Zenity absent: the outcome is still recorded where a user can find it.
		Logger.info(LOG, "%s", tostring(message))
	end
end

--- Escapes text for zenity's --text, which is Pango markup: a config value
--- holding "<" or "&" would otherwise blank the dialog.
--- @param text string
--- @return string
local function zenity_plain(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Prompts and persists the parameter required by one action before binding it.
--- @param ctx table Menu context with an optional prompt test boundary.
--- @param gestures table Shared action catalogue and parameter store.
--- @param binding string Exact binding identity used during dispatch.
--- @param action string Action identifier.
--- @param assign function Publishes the binding only after its parameter is durable.
--- @param picked string|nil A value the action picker's own editor collected: it
---   is validated and stored without a prompt.
--- @return boolean assigned True only when the whole user-visible assignment succeeded.
local function assign_parameterized_action(ctx, gestures, binding, action, assign, picked)
	local spec = type(gestures.get_action_parameter_spec) == "function"
		and gestures.get_action_parameter_spec(action) or nil
	local bindings = package.loaded["infra.program_binding_transaction"]
	if spec ~= "program" and type(bindings) == "table" and bindings.pending() then
		Logger.error(LOG, "Binding edit refused while private user program compensation remains pending.")
		return false
	end
	if not spec then return assign() == true end

	local prior = type(gestures.get_action_parameter) == "function"
		and gestures.get_action_parameter(binding, action) or ""
	local value
	if type(picked) == "string" then
		value = picked
	elseif type(ctx.prompt_action_parameter) == "function" then
		value = ctx.prompt_action_parameter(binding, action, spec, prior)
	elseif spec == "app" then
		-- An application is picked among the desktop entries, never typed.
		local chosen, why = require("ui.app_chooser").pick(require("adapters.shell_runner"),
			gestures.get_action_parameter_prompt(action))
		if not chosen then Logger.info(LOG, "No application chosen for '%s': %s.", tostring(binding), tostring(why)) end
		value = chosen
	else
		local label = type(gestures.get_action_label) == "function"
			and gestures.get_action_label(action) or action
		local title = _fill(i18n_safe("dialog.gestures.param_title"), "{1}", label)
		if spec == "llm_vision" then
			-- A backend is picked from a list, as on the action picker page.
			value = require("ui.vision_parameter_prompt").ask(title, prior)
		else
			-- The prompt belongs to the parameter kind (the gestures manager owns it).
			-- Escaped: a wrap-pair sample such as <…> would be read as Pango markup.
			value = prompt_text(title, zenity_plain(gestures.get_action_parameter_prompt(action)), prior)
		end
	end
	if value == nil or (spec == "llm_language" and value == "") then return false end
	if type(gestures.validate_action_parameter) ~= "function"
		or not gestures.validate_action_parameter(action, value)
	then
		Logger.warn(LOG, "Invalid parameter for binding '%s' action '%s'.",
			tostring(binding), tostring(action))
		show_error(zenity_plain(gestures.get_action_parameter_error(action)))
		return false
	end
	-- A rejected assignment cannot leave its parameter durably changed.
	return require("infra.program_binding_transaction").apply(binding, value, ctx.is_paused, action)
end

--- Opens the shared searchable action catalogue for one current assignment.
--- @param title string Already-localised target label.
--- @param current string Current action id.
--- @param binding string The binding the pick is for: the picker's own editor
---   starts from the value it holds for a send_* action.
--- @param on_confirm function Transactional assignment callback, given the action
---   id and the value the picker's editor collected, if any.
--- @return boolean opened
local function open_action_picker(title, current, binding, on_confirm, selected_items)
	local ok_picker, Picker = pcall(require, "ui.action_picker.bridge")
	local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
	if not ok_picker or type(Picker.open) ~= "function" or not ok_gestures then
		Logger.error(LOG, "Action picker is unavailable for '%s'.", tostring(title))
		return false
	end
	local Paths = require("infra.config_paths")
	local path = Paths.config("config.toml")
	local items = type(selected_items) == "table" and selected_items or Gestures.get_picker_items()
	local editor = Gestures.get_picker_parameter_fields(items, binding)
	return Picker.open({
		title = title,
		current = current or "none",
		items = items,
		send_vocabulary = editor.send_vocabulary,
		parameter_strings = editor.parameter_strings,
		prompt_choices = editor.prompt_choices,
		vision_choices = editor.vision_choices,
		language_choices = editor.language_choices,
		default_count = editor.default_count,
		edit_current_label = editor.edit_current_label,
	}, function(option, _state, picked)
		if Paths.config("config.toml") ~= path then
			Logger.warn(LOG, "Action picker confirmation refused after its configuration folder changed.")
			return false
		end
		return on_confirm(option, picked)
	end)
end

--- The rows under one bindable slot: the searchable picker and, when the slot
--- is bound, a row that clears it.
---
--- The whole catalogue used to be inlined here, about 640 rows per slot — for
--- each of the 39 gesture slots and every keyboard slot — which no tray menu
--- can present usably and which the picker, with its headings and search,
--- already offers.
--- @param slot_label string Already-localised target label.
--- @param bound string The action currently bound ("none" when unbound).
--- @param binding string The binding the slot dispatches its action under.
--- @param assign function(option, picked) Transactional assignment; true on commit.
--- @return table Provider rows.
local function slot_binding_rows(slot_label, bound, binding, assign)
	if not ManifestMenu then return {} end
	local function pick() open_action_picker(slot_label, bound, binding, assign) end
	local function clear() assign("none") end
	local rows = ManifestMenu.template_rows("slot_binding_frame", {
		[require("config_keys").COMMAND.SLOT_BINDING_PICK] = pick,
		[require("config_keys").COMMAND.SLOT_BINDING_CLEAR] = clear,
	}, {
		["slot_binding_has_action"] = function() return bound ~= "none" end,
	}, {})
	-- A missing late declaration must withdraw the entire slot submenu. The
	-- renderer may already have translated earlier rows; no picker or write runs.
	if type(rows) ~= "table" or #rows ~= (bound ~= "none" and 2 or 1) then return {} end
	return rows
end

--- Asks a yes/no question.
---
--- Returns nil rather than false when the dialog could not be shown at all, so a
--- caller can tell "the user said no" from "there was nobody to ask" — the second
--- must not be recorded as a choice.
--- @param title string Already-translated.
--- @param text string Already-translated.
--- @param ok_label string Already-translated.
--- @param cancel_label string Already-translated.
--- @return boolean|nil
local function ask_yes_no(title, text, ok_label, cancel_label, default_cancel)
	-- os.execute returns a number on LuaJIT (5.1) and true on 5.2+: the
	-- module-level succeeded() above normalises both spellings.
	local command = "zenity --question --title=" .. shell_quote(WindowTitles.compose(title))
		.. " --text=" .. shell_quote(text)
		.. " --ok-label=" .. shell_quote(ok_label)
		.. " --cancel-label=" .. shell_quote(cancel_label)
		.. (default_cancel and " --default-cancel" or "")
		.. " 2>/dev/null"

	-- Probed rather than assumed, because the exit code alone cannot distinguish
	-- "the user pressed Cancel" from "no such binary" — both are non-zero, and
	-- treating the second as a No would silently record a choice nobody made.
	if not succeeded(os.execute("command -v zenity >/dev/null 2>&1")) then
		Logger.error(LOG, "Zenity is unavailable: cannot ask '%s'.", tostring(title))
		return nil
	end
	-- zenity exits 0 for the OK button and 1 for cancel.
	return succeeded(Modal.run(function() return os.execute(command) end))
end

M._fill = _fill
M.shell_quote = shell_quote
M.succeeded = succeeded
M.prompt_text = prompt_text
M.show_error = show_error
M.show_info = show_info
M.zenity_plain = zenity_plain
M.assign_parameterized_action = assign_parameterized_action
M.open_action_picker = open_action_picker
M.slot_binding_rows = slot_binding_rows
M.ask_yes_no = ask_yes_no

return M
