-- ui/menu/menu_llm/settings_manager.lua

-- ===========================================================================
-- LLM Settings Manager Sub-module.
--
-- Logic for handling numerical configurations via system dialogs.
-- Manages debounce delays, temperature, token limits, and context length.
-- Includes a dedicated menu builder for indentation preferences.
-- ===========================================================================

local keymap = require("modules.keymap")
local M = {}





-- ===================================
-- ===================================
-- ======= 1/ Dialog Helpers =========
-- ===================================
-- ===================================

--- Opens a standardized numeric input prompt and updates the state. Supports default fallbacks.
--- @param deps table Global dependencies
--- @param title string Dialog title
--- @param msg string Dialog informative text
--- @param key string The state key to update
--- @param factor number|nil Multiply factor for display (e.g. 1000 for ms)
--- @param hs_fn string|nil The keymap function name to sync the value
--- @param default_val number The fallback default value
--- @param min_val number|nil Minimum allowed value
--- @param max_val number|nil Maximum allowed value
local function generic_numeric_prompt(deps, title, msg, key, factor, hs_fn, default_val, min_val, max_val)
	local state = deps.state
	pcall(hs.focus)

	local current_val = tonumber(state[key])
	if current_val == nil then current_val = default_val end
	local display_val = factor and math.floor(current_val * factor) or current_val
	local display_def = factor and math.floor(default_val * factor) or default_val

	local full_msg = tostring(msg) .. "\n\n(Laissez vide pour réinitialiser : " .. tostring(display_def) .. ")"

	local ok_p, btn, raw = pcall(hs.dialog.textPrompt, 
		tostring(title), 
		full_msg, 
		tostring(display_val), 
		"OK", "Annuler"
	)

	if ok_p and btn == "OK" then
		local new_val
		if raw:match("^%s*$") then
			new_val = default_val
		else
			new_val = tonumber(raw)
		end
		
		if new_val then
			if min_val and new_val < min_val then new_val = min_val end
			if max_val and new_val > max_val then new_val = max_val end

			-- Reverse the factor if applied
			local final_val = factor and (new_val / factor) or new_val
			state[key] = final_val

			-- Sync with the keymap engine if a function is provided
			if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
				pcall(deps.keymap[hs_fn], final_val)
			end

			pcall(deps.save_prefs)
			pcall(deps.update_menu)
		end
	end
end

--- Resets a state key to its default value cleanly.
--- @param deps table Global dependencies
--- @param key string The state key to reset
--- @param default_val number The fallback default value
--- @param hs_fn string|nil The keymap function name to sync the value
local function reset_to_default(deps, key, default_val, hs_fn)
	deps.state[key] = default_val
	if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
		pcall(deps.keymap[hs_fn], default_val)
	end
	pcall(deps.save_prefs)
	pcall(deps.update_menu)
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

function M.new(deps)
	local obj = { deps = deps }

	--- Sets the idle delay before triggering the LLM
	function obj.set_debounce()
		generic_numeric_prompt(deps, 
			"Temps d’attente", 
			"Délai de pause requis lors de la frappe (en ms) avant de solliciter l’IA :", 
			"llm_debounce", 1000, "set_llm_debounce", keymap.LLM_DEBOUNCE_DEFAULT
		)
	end
	function obj.reset_debounce() reset_to_default(deps, "llm_debounce", keymap.LLM_DEBOUNCE_DEFAULT, "set_llm_debounce") end

	--- Sets the maximum number of tokens generated per prediction
	function obj.set_max_predict()
		generic_numeric_prompt(deps, 
			"Tokens max", 
			"Nombre maximum de tokens à générer par suggestion :", 
			"llm_max_predict", nil, "set_llm_max_predict", keymap.LLM_MAX_PREDICT_DEFAULT
		)
	end
	function obj.reset_max_predict() reset_to_default(deps, "llm_max_predict", keymap.LLM_MAX_PREDICT_DEFAULT, "set_llm_max_predict") end

	--- Sets the maximum number of words kept per prediction
	function obj.set_max_words()
		generic_numeric_prompt(deps, 
			"Mots max par suggestion", 
			"Nombre maximum de mots à conserver (0 = illimité) :", 
			"llm_max_words", nil, "set_llm_max_words", keymap.LLM_MAX_WORDS_DEFAULT
		)
	end
	function obj.reset_max_words() reset_to_default(deps, "llm_max_words", keymap.LLM_MAX_WORDS_DEFAULT, "set_llm_max_words") end

	--- Sets the AI temperature (creativity vs stability)
	function obj.set_temperature()
		generic_numeric_prompt(deps, 
			"Température", 
			"Niveau de créativité (de 0.0 à 1.0) :", 
			"llm_temperature", nil, "set_llm_temperature", keymap.LLM_TEMPERATURE_DEFAULT, 0.0, 1.0
		)
	end
	function obj.reset_temperature() reset_to_default(deps, "llm_temperature", keymap.LLM_TEMPERATURE_DEFAULT, "set_llm_temperature") end

	--- Sets the size of the text buffer sent as context to the AI
	function obj.set_context_length()
		generic_numeric_prompt(deps, 
			"Taille du contexte", 
			"Nombre de caractères précédents à analyser :", 
			"llm_context_length", nil, "set_llm_context_length", keymap.LLM_CONTEXT_LENGTH_DEFAULT
		)
	end
	function obj.reset_context_length() reset_to_default(deps, "llm_context_length", keymap.LLM_CONTEXT_LENGTH_DEFAULT, "set_llm_context_length") end

	--- Builds the indentation selection submenu
	--- @return table The Hammerspoon menu structure
	function obj.build_indent_menu()
		local menu = {}
		local default_val = keymap.LLM_PRED_INDENT_DEFAULT
		local current = math.floor(tonumber(deps.state.llm_pred_indent) or default_val)
		local paused  = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false

		for i = -7, 7 do
			local title_str = ((i == -1 or i == 0 or i == 1) and i .. " espace") or (i .. " espaces")
			if i == default_val then title_str = title_str .. " (défaut)" end
			
			table.insert(menu, {
				title   = title_str,
				checked = (i == current) or nil,
				fn      = not paused and function()
					deps.state.llm_pred_indent = i
					if deps.keymap and type(deps.keymap.set_llm_pred_indent) == "function" then
						pcall(deps.keymap.set_llm_pred_indent, i)
					end
					pcall(deps.save_prefs)
					pcall(deps.update_menu)
				end or nil,
			})
		end
		return menu
	end

	--- Dynamic builder for modifier menus
	local function build_modifier_menu(key, default_mods, hs_fn)
		local current_mods = hs.settings.get(key)
		if current_mods == nil then current_mods = default_mods end
		local current_str = table.concat(current_mods, "+")
		local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false

		local opts = {
			{title = "Désactivé", mods = {"none"}}, 
			{title = "Aucun modificateur", mods = {}},
			{title = "⇧ Shift", mods = {"shift"}}, 
			{title = "⌘ Cmd", mods = {"cmd"}},
			{title = "⌥ Option", mods = {"alt"}}, 
			{title = "⌃ Ctrl", mods = {"ctrl"}},
			{title = "⌘⇧ Cmd + Shift", mods = {"cmd", "shift"}},
			{title = "⌥⇧ Option + Shift", mods = {"alt", "shift"}}
		}
		
		local menu = {}
		for _, opt in ipairs(opts) do
			table.insert(menu, {
				title = opt.title,
				checked = (table.concat(opt.mods, "+") == current_str) or nil,
				fn = not paused and function()
					hs.settings.set(key, opt.mods)
					if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
						pcall(deps.keymap[hs_fn], opt.mods)
					end
					pcall(deps.save_prefs)
					pcall(deps.update_menu)
				end or nil
			})
		end
		return menu
	end

	function obj.build_nav_modifier_menu()
		return build_modifier_menu("llm_nav_modifiers", keymap.LLM_NAV_MODIFIERS_DEFAULT, "set_llm_nav_modifiers")
	end

	function obj.build_val_modifier_menu()
		return build_modifier_menu("llm_val_modifiers", keymap.LLM_VAL_MODIFIERS_DEFAULT, "set_llm_val_modifiers")
    end

	return obj
end

return M
