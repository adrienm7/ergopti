--- ui/menu/menu_llm/settings_manager.lua

--- ==============================================================================
--- MODULE: LLM Settings Manager
--- DESCRIPTION:
--- Logic for handling numerical configurations via system dialogs.
--- Manages debounce delays, temperature, token limits, and context length.
--- Includes a dedicated menu builder for indentation preferences.
--- ==============================================================================

local M = {}

local hs      = hs
local llm_mod = require("modules.llm")
local Logger  = require("infra.logger")
local i18n    = require("infra.i18n")
local dialog  = require("infra.dialog_util")

local LOG = "menu_llm.settings"

--- Invokes one optional injected dependency with visible, exact settlement.
--- @param label string Operation-specific callback label.
--- @param fn function|nil Injected dependency.
--- @param ... any Arguments forwarded to fn.
--- @return boolean settled True when absent or completed without refusal.
local function invoke_optional(label, fn, ...)
	if type(fn) ~= "function" then return true end
	local ok, result = Logger.callback(LOG, label, fn, ...)
	return ok == true and result ~= false
end

--- Rebuilds the menu through the required injected owner.
--- @param deps table Global dependencies.
--- @param label string Operation-specific callback label.
--- @return boolean settled True only when the rebuild callback completed.
local function refresh_menu(deps, label)
	if type(deps.update_menu) ~= "function" then
		Logger.error(LOG, "%s refused because update_menu is unavailable.", tostring(label))
		return false
	end
	return invoke_optional(label, deps.update_menu)
end

--- Persists preferences through the required injected owner.
--- @param deps table Global dependencies.
--- @param label string Operation-specific callback label.
--- @return boolean settled True only after an explicit persistence commit.
local function save_prefs(deps, label)
	if type(deps.save_prefs) ~= "function" then
		Logger.error(LOG, "%s refused because save_prefs is unavailable.", tostring(label))
		return false
	end
	local ok, saved = Logger.callback(LOG, label, deps.save_prefs)
	return ok == true and saved == true
end

--- Reads pause state through the injected lifecycle owner and fails closed.
--- @param deps table Global dependencies.
--- @param label string Operation-specific callback label.
--- @return boolean paused
local function is_paused(deps, label)
	local script_control = deps.script_control
	if not script_control or type(script_control.is_paused) ~= "function" then return false end
	local ok, paused = Logger.callback(LOG, label, script_control.is_paused)
	if not ok then return true end
	return paused == true
end





-- =================================
-- =================================
-- ======= 1/ Dialog Helpers =======
-- =================================
-- =================================

--- Opens a standardized numeric input prompt and updates the state.
--- @param deps table Global dependencies.
--- @param title string Dialog title.
--- @param msg string Dialog informative text.
--- @param key string The state key to update.
--- @param factor number|nil Multiply factor for display (e.g. 1000 for ms).
--- @param hs_fn string|nil The keymap function name to sync the value.
--- @param default_val number|string|nil The fallback default value.
--- @param min_val number|nil Minimum allowed value.
--- @param max_val number|nil Maximum allowed value.
local function generic_numeric_prompt(deps, title, msg, key, factor, hs_fn, default_val, min_val, max_val)
	local state = deps.state

	local current_val = tonumber(state[key])
	if current_val == nil then current_val = tonumber(default_val) or 0 end
	local display_val = factor and math.floor(current_val * factor) or current_val
	local display_def = (factor and tonumber(default_val)) and math.floor(tonumber(default_val) * factor) or default_val

	local full_msg = tostring(msg) .. string.format(i18n.get("menu.settings.reset_instruction"), tostring(display_def))

	Logger.debug(LOG, string.format("Opening numeric prompt for %s…", key))
	local ok_p, btn, raw = pcall(dialog.text_prompt,
		tostring(title),
		full_msg,
		tostring(display_val),
		i18n.get("button.ok"), i18n.get("common.cancel")
	)

	if ok_p and btn == i18n.get("button.ok") then
		local new_val
		if raw:match("^%s*$") then
			new_val = tonumber(default_val) or 0
		else
			new_val = tonumber(raw)
		end
		
		if new_val then
			if min_val and new_val < min_val then new_val = min_val end
			if max_val and new_val > max_val then new_val = max_val end

            -- Reverse the factor if applied
			local final_val = factor and (new_val / factor) or new_val
			state[key] = final_val
			hs.settings.set(key, final_val)

			-- Sync with the keymap engine if a function is provided
			if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
				if not invoke_optional("Numeric setting runtime sync", deps.keymap[hs_fn], final_val) then
					return false
				end
			end

			if not save_prefs(deps, "Numeric setting preference save") then return false end
			if not refresh_menu(deps, "Numeric setting menu refresh") then return false end
			Logger.info(LOG, string.format("Value for %s updated successfully.", key))
			return true
		else
			Logger.warn(LOG, "Invalid numeric input provided.")
		end
	end
end

--- Resets a state key to its default value cleanly.
--- @param deps table Global dependencies.
--- @param key string The state key to reset.
--- @param default_val number|string|nil The fallback default value.
--- @param hs_fn string|nil The keymap function name to sync the value.
local function reset_to_default(deps, key, default_val, hs_fn)
	Logger.debug(LOG, string.format("Resetting %s to default value…", key))
	deps.state[key] = default_val
	hs.settings.set(key, default_val)
	if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
		if not invoke_optional("Default setting runtime sync", deps.keymap[hs_fn], default_val) then
			return false
		end
	end
	if not save_prefs(deps, "Default setting preference save") then return false end
	if not refresh_menu(deps, "Default setting menu refresh") then return false end
	Logger.info(LOG, string.format("Key %s reset successfully.", key))
	return true
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Instantiates the settings manager.
--- @param deps table Global dependencies.
--- @return table The settings manager instance.
function M.new(deps)
	local obj = { deps = deps }

	--- Sets the idle delay before triggering the LLM.
	function obj.set_debounce()
		local state = deps.state

		local current_val = tonumber(state.llm_debounce)
		if current_val == nil then current_val = llm_mod.DEFAULT_STATE.llm_debounce end
		local display_val = current_val < 0 and i18n.get("menu.settings.never") or math.floor(current_val * 1000)
		local display_def = math.floor(llm_mod.DEFAULT_STATE.llm_debounce * 1000)

		local full_msg = string.format(i18n.get("menu.settings.delay_prompt"), display_def)

		local ok_p, btn, raw = pcall(dialog.text_prompt, i18n.get("menu.settings.delay_title"), full_msg, tostring(display_val), i18n.get("button.ok"), i18n.get("common.cancel"))

		if ok_p and btn == i18n.get("button.ok") then
			local new_val
			if raw:match("^%s*$") then
				new_val = llm_mod.DEFAULT_STATE.llm_debounce
			elseif raw:lower() == string.lower(i18n.get("menu.settings.never")) then
				new_val = -1
			else
				new_val = tonumber(raw)
				if new_val and new_val >= 0 then new_val = new_val / 1000 end
			end
			
			if new_val then
				state.llm_debounce = new_val
				hs.settings.set("llm_debounce", new_val)
				if deps.keymap and type(deps.keymap.set_llm_debounce) == "function" then
					if not invoke_optional("Debounce runtime sync", deps.keymap.set_llm_debounce, new_val) then
						return false
					end
				end
				if not save_prefs(deps, "Debounce preference save") then return false end
				if not refresh_menu(deps, "Debounce menu refresh") then return false end
				Logger.info(LOG, "Debounce delay updated successfully.")
				return true
			end
		end
	end
	
	function obj.reset_debounce() 
		reset_to_default(deps, "llm_debounce", llm_mod.DEFAULT_STATE.llm_debounce, "set_llm_debounce") 
	end

	--- Sets the maximum number of words kept per prediction.
	function obj.set_max_words()
		local state = deps.state

		local current_val = tonumber(state.llm_max_words)
		local display_val = (current_val and current_val > 0) and tostring(current_val) or "0"

		local full_msg = i18n.get("menu.settings.max_words_prompt")

		local ok_p, btn, raw = pcall(dialog.text_prompt, i18n.get("menu.settings.max_words_title"), full_msg, display_val, i18n.get("button.ok"), i18n.get("common.cancel"))

		if ok_p and btn == i18n.get("button.ok") then
			local digits = raw:match("^%s*(%d+)%s*$")
			if not digits then return end
			local new_val = tonumber(digits) or 0
			
			state.llm_max_words = new_val
			hs.settings.set("llm_max_words", new_val)
			if deps.keymap and type(deps.keymap.set_llm_max_words) == "function" then
				if not invoke_optional("Maximum-words runtime sync", deps.keymap.set_llm_max_words, new_val) then
					return false
				end
			end
			if not save_prefs(deps, "Maximum-words preference save") then return false end
			if not refresh_menu(deps, "Maximum-words menu refresh") then return false end
			Logger.info(LOG, "Max words updated successfully.")
			return true
		end
	end
	
	function obj.reset_max_words() 
		reset_to_default(deps, "llm_max_words", llm_mod.DEFAULT_STATE.llm_max_words, "set_llm_max_words")
	end

	--- Sets the minimum number of words generated per prediction.
	function obj.set_min_words()
		local state = deps.state

		local current_val = tonumber(state.llm_min_words)
		local display_val = (current_val and current_val > 0) and tostring(current_val) or "1"

		local full_msg = i18n.get("menu.llm.min_words_prompt")

		local ok_p, btn, raw = pcall(dialog.text_prompt, i18n.get("menu.settings.min_words_title"), full_msg, display_val, i18n.get("button.ok"), i18n.get("common.cancel"))

		if ok_p and btn == i18n.get("button.ok") then
			local digits = raw:match("^%s*(%d+)%s*$")
			if not digits then return end
			local new_val = tonumber(digits) or 1
			
			state.llm_min_words = new_val
			hs.settings.set("llm_min_words", new_val)
			if deps.keymap and type(deps.keymap.set_llm_min_words) == "function" then
				if not invoke_optional("Minimum-words runtime sync", deps.keymap.set_llm_min_words, new_val) then
					return false
				end
			end
			if not save_prefs(deps, "Minimum-words preference save") then return false end
			if not refresh_menu(deps, "Minimum-words menu refresh") then return false end
			Logger.info(LOG, "Min words updated successfully.")
			return true
		end
	end
	
	function obj.reset_min_words() 
		reset_to_default(deps, "llm_min_words", llm_mod.DEFAULT_STATE.llm_min_words, "set_llm_min_words") 
	end

	--- Sets the AI temperature (creativity vs stability).
	function obj.set_temperature()
		generic_numeric_prompt(deps, 
			i18n.get("menu.settings.temperature_title"), 
			i18n.get("menu.settings.temperature_prompt"), 
			"llm_temperature", nil, "set_llm_temperature", llm_mod.DEFAULT_STATE.llm_temperature, 0.0, 1.0
		)
	end
	
	function obj.reset_temperature() 
		reset_to_default(deps, "llm_temperature", llm_mod.DEFAULT_STATE.llm_temperature, "set_llm_temperature") 
	end

	--- Sets the size of the text buffer sent as context to the AI.
	function obj.set_context_length()
		generic_numeric_prompt(deps, 
			i18n.get("menu.settings.context_length_title"), 
			i18n.get("menu.llm.context_length_prompt"), 
			"llm_context_length", nil, "set_llm_context_length", llm_mod.DEFAULT_STATE.llm_context_length
		)
	end
	
	function obj.reset_context_length()
		reset_to_default(deps, "llm_context_length", llm_mod.DEFAULT_STATE.llm_context_length, "set_llm_context_length")
	end

	--- Prompts for the local MLX server port and applies it. The port lives in
	--- api_mlx (persisted to hs.settings), NOT in the LLM state table, because it is
	--- a property of Ergopti's own MLX server — the one we launch with `--port` — and
	--- is read by the launcher, the health probe, and the boot cleanup. On a valid
	--- change we persist + rebuild the server URL via api_mlx.set_port, then invoke
	--- on_applied so the caller can relaunch the server on the new port.
	--- @param on_applied function|nil Called after a successful change (e.g. restart).
	function obj.set_mlx_port(on_applied)
		local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
		if not ok_api or type(ApiMlx.set_port) ~= "function" then
			Logger.warn(LOG, "set_mlx_port: api_mlx unavailable — cannot change the port.")
			return
		end
		local current      = ApiMlx.get_port()
		local default_port = ApiMlx.get_default_port()
		local lo, hi       = ApiMlx.get_port_bounds()

		local full_msg = string.format(i18n.get("menu.llm.mlx_port_prompt"), tostring(default_port))
		local ok_p, btn, raw = pcall(dialog.text_prompt,
			i18n.get("menu.llm.mlx_port_title"), full_msg, tostring(current),
			i18n.get("button.ok"), i18n.get("common.cancel"))
		if not (ok_p and btn == i18n.get("button.ok")) then return end

		local new_port
		if raw:match("^%s*$") then
			new_port = default_port  -- empty input resets to the dedicated default
		else
			new_port = tonumber(raw:match("^%s*(%d+)%s*$"))
		end
		if not new_port or new_port < lo or new_port > hi then
			Logger.warn(LOG, "set_mlx_port: invalid input '%s' (expected an integer %d-%d).",
				tostring(raw), lo, hi)
			return
		end
		if not ApiMlx.set_port(new_port) then return end
		Logger.info(LOG, "MLX server port set to %d via menu.", new_port)
		local applied = invoke_optional("MLX port apply", on_applied)
		local refreshed = refresh_menu(deps, "MLX port menu refresh")
		return applied and refreshed
	end

	--- Resets the MLX server port to its dedicated default and applies it.
	--- @param on_applied function|nil Called after the reset (e.g. restart).
	function obj.reset_mlx_port(on_applied)
		local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
		if not ok_api or type(ApiMlx.set_port) ~= "function" then return end
		if ApiMlx.set_port(ApiMlx.get_default_port()) then
			Logger.info(LOG, "MLX server port reset to default %d.", ApiMlx.get_default_port())
			local applied = invoke_optional("MLX port reset apply", on_applied)
			local refreshed = refresh_menu(deps, "MLX port reset menu refresh")
			return applied and refreshed
		end
		return false
	end

	--- Builds the indentation selection submenu.
	--- @return table The Hammerspoon menu structure.
	function obj.build_indent_menu()
		local menu = {}
		local default_val = llm_mod.DEFAULT_STATE.llm_pred_indent
		local current = math.floor(tonumber(deps.state.llm_pred_indent) or default_val)
		local paused = is_paused(deps, "Indentation menu pause-state read")

		for i = -7, 7 do
			local title_str = ((i == -1 or i == 0 or i == 1) and i18n.get("menu.settings.indent_space")) or (i .. i18n.get("menu.settings.indent_spaces"))
			if i == default_val then title_str = title_str .. " " .. i18n.get("menu.settings.default_indicator") end
			
			table.insert(menu, {
				title   = title_str,
				checked = (i == current) or nil,
				fn      = not paused and function()
					deps.state.llm_pred_indent = i
					hs.settings.set("llm_pred_indent", i)
					if deps.keymap and type(deps.keymap.set_llm_pred_indent) == "function" then
						if not invoke_optional("Indentation runtime sync",
							deps.keymap.set_llm_pred_indent, i) then return false end
					end
					if not save_prefs(deps, "Indentation preference save") then return false end
					return refresh_menu(deps, "Indentation menu refresh")
				end or nil,
			})
		end
		return menu
	end

	--- Dynamic builder for modifier menus.
	local function build_modifier_menu(key, default_mods, hs_fn)
		local current_mods = hs.settings.get(key)
		-- Fail closed on a non-table (corrupt/AHK-migrated plist): table.concat on a
		-- string would raise and blank the submenu (same class as format_shortcut_title).
		if type(current_mods) ~= "table" then current_mods = default_mods end
		local current_str = table.concat(current_mods, "+")
		local paused = is_paused(deps, "Modifier menu pause-state read")

        local opts = {
            {title = i18n.get("menu.settings.disabled"), mods = {"none"}},
            {title = i18n.get("menu.settings.no_modifier"), mods = {}},
            {title = "⇧ Shift", mods = {"shift"}}, 
            {title = "⌘ Cmd", mods = {"cmd"}},
            {title = "⌥ Option", mods = {"alt"}}, 
            {title = "⌃ Ctrl", mods = {"ctrl"}},
            {title = "⇧⌘ Shift + Cmd", mods = {"shift", "cmd"}},
            {title = "⇧⌥ Shift + Option", mods = {"shift", "alt"}}
        }
        
        local menu = {}
        for _, opt in ipairs(opts) do
            table.insert(menu, {
                title = opt.title,
                checked = (table.concat(opt.mods, "+") == current_str) or nil,
                fn = not paused and function()
                    hs.settings.set(key, opt.mods)
					deps.state[key] = opt.mods
					if deps.keymap and type(deps.keymap[hs_fn]) == "function" then
						if not invoke_optional("Modifier runtime sync",
							deps.keymap[hs_fn], opt.mods) then return false end
					end
					if not save_prefs(deps, "Modifier preference save") then return false end
					return refresh_menu(deps, "Modifier menu refresh")
                end or nil
            })
        end
        return menu
    end

	function obj.build_nav_modifier_menu()
		return build_modifier_menu("llm_nav_modifiers", llm_mod.DEFAULT_STATE.llm_nav_modifiers, "set_llm_nav_modifiers")
	end

	function obj.build_val_modifier_menu()
		return build_modifier_menu("llm_val_modifiers", llm_mod.DEFAULT_STATE.llm_val_modifiers, "set_llm_val_modifiers")
	end

	return obj
end

return M
