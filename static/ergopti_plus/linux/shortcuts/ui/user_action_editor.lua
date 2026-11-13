--- shortcuts/ui/user_action_editor.lua

--- ==============================================================================
--- MODULE: Command and Path Parameter Editors (Linux)
--- DESCRIPTION:
--- Asks the tray's native dialogs for the parameter of run_command (the
--- command typed, then how it runs and what its output does) and of open_path
--- (a file or folder chosen in Ergopti's own picker). Every binding
--- editor of the driver (the shortcuts menu, the menu dialogs and the physical
--- shortcuts window) calls ask() for these kinds.
---
--- FEATURES & RATIONALE:
--- 1. One editor per kind, so the three menus cannot disagree.
--- 2. A command that does not validate is returned as typed: the caller's
---    validator refuses it with the parameter's own error.
--- 3. The pickers cannot offer files and folders at once, so the user says
---    which first; ui/app_chooser opens them through ui/modal like every tray
---    dialog, which hands the grabbed keyboard to the desktop while they are open.
--- 4. Cancel at any step is a cancellation: nothing is returned.
--- ==============================================================================

local M = {}

local ChoicePrompt = require("core.ui.ui.choice_prompt")
local TextPrompt = require("core.ui.ui.text_prompt")
local I18n = require("core.i18n.engine.i18n")
local Parameter = require("shortcuts.engine.user_action_parameter")
local Logger = require("core.logger.engine.shim")

local LOG = "shortcuts.ui.user_action_editor"

--- The kinds this module edits.
M.KINDS = { command = true, path = true }

-- Escapes text for a dialog's --text, which is Pango markup.
local markup_plain = require("core.ui.ui.native_dialog").plain_markup

--- The choices of a closed option set, labelled through the locale.
--- @param options table Array of { value, key }.
--- @return table choices Array of { value, label }.
local function labelled(options)
	local choices = {}
	for index, option in ipairs(options) do choices[index] = { value = option.value, label = I18n.get(option.key) } end
	return choices
end

-- The output choices of run_command.
local OUTPUT_OPTIONS = {
	{ value = "none", key = "dialog.gestures.param_output_none" },
	{ value = "type", key = "dialog.gestures.param_output_type" },
	{ value = "copy", key = "dialog.gestures.param_output_copy" },
}

--- Asks for a run_command value.
--- @param title string Window title.
--- @param prompt string The kind's prompt (plain text).
--- @param prior string|nil The stored value.
--- @param deps table|nil { pick, ask } (tests).
--- @return string|nil value
function M.ask_command(title, prompt, prior, deps)
	deps = deps or {}
	local pick, ask = deps.pick or ChoicePrompt.pick, deps.ask or TextPrompt.ask
	local stored = Parameter.parse("command", prior) or {}
	local command = ask(title, markup_plain(prompt), stored.command or "")
	if command == nil then return nil end
	local mode = pick(title, I18n.get("dialog.gestures.param_command_mode"), labelled({
		{ value = "hidden", key = "dialog.gestures.param_command_mode_hidden" },
		{ value = "terminal", key = "dialog.gestures.param_command_mode_terminal" },
	}), stored.mode)
	if mode == nil then return nil end
	local output = "none"
	if mode == "hidden" then
		output = pick(title, I18n.get("dialog.gestures.param_output"), labelled(OUTPUT_OPTIONS), stored.output)
		if output == nil then return nil end
	end
	local fields = { command = command, mode = mode, output = output }
	return Parameter.encode("command", fields) or Parameter.spell("command", fields)
end

--- Asks for an open_path value: a file or a folder, then the picker.
--- @param title string Window title.
--- @param prompt string The kind's prompt (plain text).
--- @param prior string|nil The stored value.
--- @param deps table|nil { pick, shell, modal } (tests).
--- @return string|nil value
function M.ask_path(title, prompt, prior, deps)
	deps = deps or {}
	local pick = deps.pick or ChoicePrompt.pick
	local shell = deps.shell or require("core.process.adapters.shell_runner")
	local stored = Parameter.parse("path", prior)
	local kind = pick(title, prompt, labelled({
		{ value = "file", key = "dialog.gestures.param_path_kind_file" },
		{ value = "folder", key = "dialog.gestures.param_path_kind_folder" },
	}), nil)
	if kind == nil then return nil end
	local start = stored and stored.path or (require("settings.engine.paths").home() .. "/")
	local chosen, why = require("apps.ui.chooser").pick_path(shell, title, kind == "folder", start, deps.modal)
	if not chosen then Logger.info(LOG, "No path chosen: %s.", tostring(why)) end
	return chosen
end

--- Asks for a value of one of KINDS.
--- @param spec string command or path.
--- @param title string Window title.
--- @param prompt string The kind's prompt (plain text).
--- @param prior string|nil The stored value.
--- @return string|nil value
function M.ask(spec, title, prompt, prior)
	if spec == "command" then return M.ask_command(title, prompt, prior) end
	if spec == "path" then return M.ask_path(title, prompt, prior) end
	error("user_action_editor: no editor for parameter kind '" .. tostring(spec) .. "'", 2)
end

return M
