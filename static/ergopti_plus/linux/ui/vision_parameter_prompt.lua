--- ui/vision_parameter_prompt.lua

--- ==============================================================================
--- MODULE: Screen Action Vision Parameter Prompt (Linux)
--- DESCRIPTION:
--- Asks the tray's native dialogs for the `llm_vision` parameter of a screen
--- action ("<backend>" or "<backend>|<model>") the way the action picker page
--- asks it: the backend picked from a list, then the optional model typed with
--- the backend's default shown. It replaces a free-text entry whose prompt
--- printed every backend on its own line, about forty with the API catalogue.
---
--- FEATURES & RATIONALE:
--- 1. The backends come from vision_request.backend_choices(), the list the
---    page offers, so the two editors cannot disagree.
--- 2. An empty model keeps the backend's default (the stored value is then the
---    bare backend); a backend with no default needs one, and the caller's
---    validation refuses the value without it.
--- 3. Cancel at either step is a cancellation: nothing is returned.
--- ==============================================================================

local M = {}

local ChoicePrompt = require("ui.choice_prompt")
local I18n = require("infra.i18n")
local TextPrompt = require("ui.text_prompt")
local Vision = require("llm.vision")

--- Escapes text for zenity's --text, which is Pango markup.
--- @param text string
--- @return string
local function markup_plain(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Asks for the vision parameter of one binding.
--- @param title string Window title (the action being configured).
--- @param prior string|nil The stored value, offered first.
--- @param deps table|nil { choices = function() -> backend choices, pick, ask } (tests).
--- @return string|nil value "<backend>" or "<backend>|<model>", nil when cancelled.
function M.ask(title, prior, deps)
	deps = deps or {}
	local choices = (deps.choices or require("modules.llm.vision_request").backend_choices)()
	local pick = deps.pick or ChoicePrompt.pick
	local ask = deps.ask or TextPrompt.ask
	local parsed = type(prior) == "string" and Vision.parse(prior) or nil
	local backend = pick(title, I18n.get("dialog.action_picker.vision_provider_label"), choices,
		parsed and parsed.backend or nil)
	if backend == nil then return nil end
	local chosen
	for _, choice in ipairs(choices) do
		if choice.value == backend then chosen = choice end
	end
	local default_model = chosen and chosen.defaultModel or ""
	local hint = default_model ~= ""
		and I18n.get("dialog.action_picker.vision_model_default"):gsub("{1}", function() return default_model end)
		or I18n.get("dialog.action_picker.vision_model_required")
	local initial = parsed and parsed.backend == backend and parsed.model or ""
	local model = ask(title, markup_plain(I18n.get("dialog.action_picker.vision_model_label") .. "\n" .. hint), initial)
	if model == nil then return nil end
	return Vision.compose_parameter(backend, model, default_model)
end

return M
