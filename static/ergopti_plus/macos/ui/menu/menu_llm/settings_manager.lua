--- ui/menu/menu_llm/settings_manager.lua

--- ==============================================================================
--- MODULE: LLM Settings Manager
--- DESCRIPTION:
--- Logic for handling numerical configurations via system dialogs.
--- Manages debounce delays, temperature, token limits, and context length.
--- Includes a dedicated menu builder for indentation preferences.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local Logger  = require("infra.logger")
local Storage = require("adapters.storage")
local i18n    = require("infra.i18n")
local dialog  = require("infra.dialog_util")

local LOG = "menu_llm.settings"

--- Creates a detached value snapshot for rollback.
--- @param value any Value to clone.
--- @return any clone
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[clone_value(key)] = clone_value(child) end
	return clone
end

--- Reports whether a numeric candidate can be safely published and persisted.
--- @param value any Candidate value.
--- @return boolean finite True for non-numbers and finite numbers only.
local function is_finite_number(value)
	return type(value) ~= "number"
		or (value == value and value ~= math.huge and value ~= -math.huge)
end

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

--- Invokes one required dependency with visible, exact settlement.
--- @param label string Operation-specific callback label.
--- @param fn function|nil Required dependency.
--- @param ... any Arguments forwarded to fn.
--- @return boolean settled True when the callback completed without refusal.
local function invoke_required(label, fn, ...)
	if type(fn) ~= "function" then
		Logger.error(LOG, "%s refused because its callback is unavailable.", tostring(label))
		return false
	end
	local ok, result = Logger.callback(LOG, label, fn, ...)
	return ok == true and result ~= false
end

--- Reads one native setting through the logger-aware ownership boundary.
--- @param key string Native settings key.
--- @return boolean settled
--- @return any value Detached current value when settled.
local function read_native_setting(key)
	local ok, value = Storage.read_exact(key)
	if not ok then return false, nil end
	return true, clone_value(value)
end

--- Writes or clears one native setting through an exact boundary.
--- @param key string Native settings key.
--- @param value any Value to write; nil restores absence.
--- @param label string Operation-specific callback label.
--- @return boolean settled
local function write_native_setting(key, value, label)
	if value == nil then
		return Storage.delete_exact(key) == true
	end
	return Storage.set(key, clone_value(value)) == true
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
--- @param apply_setting_transaction function Transaction owner.
--- @param title string Dialog title.
--- @param msg string Dialog informative text.
--- @param key string The state key to update.
--- @param factor number|nil Multiply factor for display (e.g. 1000 for ms).
--- @param hs_fn string|nil The keymap function name to sync the value.
--- @param default_val number|string|nil The fallback default value.
--- @param min_val number|nil Minimum allowed value.
--- @param max_val number|nil Maximum allowed value.
local function generic_numeric_prompt(
	deps,
	apply_setting_transaction,
	title,
	msg,
	key,
	factor,
	hs_fn,
	default_val,
	min_val,
	max_val
)
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
			return apply_setting_transaction({
				key = key,
				value = final_val,
				runtime_fn = hs_fn,
				publish_setting = true,
			})
		else
			Logger.warn(LOG, "Invalid numeric input provided.")
		end
	end
end

--- Resets a state key to its default value cleanly.
--- @param apply_setting_transaction function Transaction owner.
--- @param key string The state key to reset.
--- @param default_val number|string|nil The fallback default value.
--- @param hs_fn string|nil The keymap function name to sync the value.
local function reset_to_default(apply_setting_transaction, key, default_val, hs_fn)
	Logger.debug(LOG, string.format("Resetting %s to default value…", key))
	return apply_setting_transaction({
		key = key,
		value = default_val,
		runtime_fn = hs_fn,
		publish_setting = true,
	})
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
	local setting_recovery_debt = nil

	--- Restores every boundary reached by a rejected setting transition.
	--- @param debt table Mutable per-boundary compensation ledger.
	--- @return boolean settled True only when every compensation commits.
	local function restore_setting_transaction(debt)
		local snapshot = debt.snapshot
		deps.state[snapshot.key] = clone_value(snapshot.state_value)

		local failures = {}
		if debt.menu then
			if refresh_menu(deps, "LLM setting menu rollback") then
				debt.menu = false
			else
				failures[#failures + 1] = "menu rollback"
			end
		end
		if debt.persist then
			local persisted = save_prefs(deps, "LLM setting preference rollback")
			-- The outer preference owner may restore its last committed candidate
			-- when this compensating write refuses, so reclaim this key immediately
			deps.state[snapshot.key] = clone_value(snapshot.state_value)
			if persisted then
				debt.persist = false
			else
				failures[#failures + 1] = "preference rollback"
			end
		end
		if debt.setting then
			if write_native_setting(snapshot.key, snapshot.setting_value,
				"LLM native-setting rollback") then
				-- PreferencesTransaction may republish its last committed candidate
				-- whenever rollback persistence refuses. Keep this reassertion as debt
				-- until that owner settles, then perform it once more on the retry.
				if not debt.persist then debt.setting = false end
			else
				failures[#failures + 1] = "native-setting rollback"
			end
		end
		if debt.runtime then
			if invoke_required("LLM setting runtime rollback", debt.runtime_callback,
				clone_value(snapshot.runtime_value)) then
				debt.runtime = false
			else
				failures[#failures + 1] = "runtime rollback"
			end
		end

		if #failures > 0 then
			setting_recovery_debt = debt
			Logger.error(LOG,
				"LLM setting '%s' rollback remains unsettled at: %s.",
				tostring(snapshot.key), table.concat(failures, ", "))
			return false
		end
		setting_recovery_debt = nil
		return true
	end

	--- Retries retained compensation before accepting another setting action.
	--- @return boolean settled True when no setting recovery remains.
	local function settle_setting_recovery_debt()
		if not setting_recovery_debt then return true end
		Logger.warn(LOG, "Retrying retained LLM setting rollback before a new action.")
		return restore_setting_transaction(setting_recovery_debt)
	end

	--- Applies one state/runtime/persistence/native-setting/menu transaction.
	--- Void runtime and native setters commit on a non-throwing nil return; literal
	--- false is an operational refusal. Preference persistence alone requires true.
	--- @param options table Transaction fields: key, value, runtime_fn, publish_setting.
	--- @return boolean committed True only when every boundary commits.
	function obj.apply_setting_transaction(options)
		if type(options) ~= "table" or type(options.key) ~= "string"
			or options.key == "" or type(options.runtime_fn) ~= "string" then
			Logger.error(LOG, "LLM setting transaction refused invalid options.")
			return false
		end
		if not is_finite_number(options.value) then
			Logger.error(LOG, "LLM setting '%s' refused a non-finite numeric value.",
				tostring(options.key))
			return false
		end
		if type(deps.state) ~= "table" then
			Logger.error(LOG, "LLM setting '%s' refused because state is unavailable.",
				tostring(options.key))
			return false
		end
		if not settle_setting_recovery_debt() then return false end

		local runtime_callback = deps.keymap and deps.keymap[options.runtime_fn]
		if type(runtime_callback) ~= "function" then
			Logger.error(LOG,
				"LLM setting '%s' refused because runtime setter '%s' is unavailable.",
				tostring(options.key), tostring(options.runtime_fn))
			return false
		end
		local runtime_getter = deps.keymap and deps.keymap.get_llm_runtime_setting
		if type(runtime_getter) ~= "function" then
			Logger.error(LOG,
				"LLM setting '%s' refused because its runtime getter is unavailable.",
				tostring(options.key))
			return false
		end
		local runtime_ok, runtime_found, runtime_value = Logger.callback(LOG,
			"LLM setting runtime snapshot", runtime_getter, options.key)
		if not runtime_ok or runtime_found ~= true then
			Logger.error(LOG, "LLM setting '%s' refused because runtime state is unavailable.",
				tostring(options.key))
			return false
		end

		local setting_value = nil
		if options.publish_setting == true then
			local setting_ok
			setting_ok, setting_value = read_native_setting(options.key)
			if not setting_ok then return false end
		end

		local snapshot = {
			key = options.key,
			state_value = clone_value(deps.state[options.key]),
			runtime_value = clone_value(runtime_value),
			setting_value = clone_value(setting_value),
		}
		local debt = {
			snapshot = snapshot,
			runtime_callback = runtime_callback,
			runtime = false,
			persist = false,
			setting = false,
			menu = false,
		}

		local function reject_transition(boundary)
			Logger.error(LOG,
				"LLM setting '%s' failed at '%s'; restoring the previous value.",
				tostring(options.key), tostring(boundary))
			setting_recovery_debt = debt
			restore_setting_transaction(debt)
			return false
		end

		local candidate = clone_value(options.value)
		debt.runtime = true
		if not invoke_required("LLM setting runtime sync", runtime_callback,
			clone_value(candidate)) then
			return reject_transition("runtime sync")
		end

		deps.state[options.key] = clone_value(candidate)
		debt.persist = true
		if not save_prefs(deps, "LLM setting preference save") then
			return reject_transition("preference save")
		end

		if options.publish_setting == true then
			debt.setting = true
			if not write_native_setting(options.key, candidate,
				"LLM native-setting publication") then
				return reject_transition("native-setting publication")
			end
		end

		debt.menu = true
		if not refresh_menu(deps, "LLM setting menu refresh") then
			return reject_transition("menu refresh")
		end

		setting_recovery_debt = nil
		Logger.info(LOG, "LLM setting '%s' committed successfully.", tostring(options.key))
		return true
	end

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
				return obj.apply_setting_transaction({
					key = "llm_debounce",
					value = new_val,
					runtime_fn = "set_llm_debounce",
					publish_setting = true,
				})
			end
		end
	end
	
	function obj.reset_debounce()
		return reset_to_default(obj.apply_setting_transaction, "llm_debounce",
			llm_mod.DEFAULT_STATE.llm_debounce, "set_llm_debounce")
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

			return obj.apply_setting_transaction({
				key = "llm_max_words",
				value = new_val,
				runtime_fn = "set_llm_max_words",
				publish_setting = true,
			})
		end
	end
	
	function obj.reset_max_words()
		return reset_to_default(obj.apply_setting_transaction, "llm_max_words",
			llm_mod.DEFAULT_STATE.llm_max_words, "set_llm_max_words")
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

			return obj.apply_setting_transaction({
				key = "llm_min_words",
				value = new_val,
				runtime_fn = "set_llm_min_words",
				publish_setting = true,
			})
		end
	end
	
	function obj.reset_min_words()
		return reset_to_default(obj.apply_setting_transaction, "llm_min_words",
			llm_mod.DEFAULT_STATE.llm_min_words, "set_llm_min_words")
	end

	--- Sets the AI temperature (creativity vs stability).
	function obj.set_temperature()
		return generic_numeric_prompt(deps, obj.apply_setting_transaction,
			i18n.get("menu.settings.temperature_title"),
			i18n.get("menu.settings.temperature_prompt"),
			"llm_temperature", nil, "set_llm_temperature", llm_mod.DEFAULT_STATE.llm_temperature, 0.0, 1.0
		)
	end
	
	function obj.reset_temperature()
		return reset_to_default(obj.apply_setting_transaction, "llm_temperature",
			llm_mod.DEFAULT_STATE.llm_temperature, "set_llm_temperature")
	end

	--- Sets the size of the text buffer sent as context to the AI.
	function obj.set_context_length()
		return generic_numeric_prompt(deps, obj.apply_setting_transaction,
			i18n.get("menu.settings.context_length_title"),
			i18n.get("menu.llm.context_length_prompt"),
			"llm_context_length", nil, "set_llm_context_length", llm_mod.DEFAULT_STATE.llm_context_length
		)
	end
	
	function obj.reset_context_length()
		return reset_to_default(obj.apply_setting_transaction, "llm_context_length",
			llm_mod.DEFAULT_STATE.llm_context_length, "set_llm_context_length")
	end

	--- Prompts for the local MLX server port and applies it. The port lives in
	--- api_mlx (persisted to hs.settings), NOT in the LLM state table, because it is
	--- a property of Ergopti's own MLX server — the one we launch with `--port` — and
	--- is read by the launcher, the health probe, and the boot cleanup. On a valid
	--- change the caller first joins the exact server-stop transaction. It receives
	--- a one-shot commit callback and may return true to defer persistence until the
	--- predecessor's native completion. A false/throw leaves the old port published.
	--- @param on_applied function|nil Called as (new_port, commit_port).
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
		local committed = false
		local commit_result = false
		local function commit_port()
			if committed then return commit_result end
			committed = true
			if not ApiMlx.set_port(new_port) then return false end
			Logger.info(LOG, "MLX server port set to %d via menu.", new_port)
			commit_result = refresh_menu(deps, "MLX port menu refresh")
			return commit_result
		end
		if type(on_applied) ~= "function" then return commit_port() end
		local ok_apply, apply_result = Logger.callback(
			LOG, "MLX port apply", on_applied, new_port, commit_port)
		if not ok_apply or apply_result == false then return false end
		-- Literal true transfers commit ownership to an asynchronous stop callback.
		-- Nil preserves the synchronous optional-hook contract used by other callers.
		if apply_result == true then return true end
		return commit_port()
	end

	--- Resets the MLX server port to its dedicated default and applies it.
	--- @param on_applied function|nil Called as (default_port, commit_port).
	function obj.reset_mlx_port(on_applied)
		local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
		if not ok_api or type(ApiMlx.set_port) ~= "function" then return end
		local default_port = ApiMlx.get_default_port()
		local committed = false
		local commit_result = false
		local function commit_port()
			if committed then return commit_result end
			committed = true
			if not ApiMlx.set_port(default_port) then return false end
			Logger.info(LOG, "MLX server port reset to default %d.", default_port)
			commit_result = refresh_menu(deps, "MLX port reset menu refresh")
			return commit_result
		end
		if type(on_applied) ~= "function" then return commit_port() end
		local ok_apply, apply_result = Logger.callback(
			LOG, "MLX port reset apply", on_applied, default_port, commit_port)
		if not ok_apply or apply_result == false then return false end
		if apply_result == true then return true end
		return commit_port()
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
					return obj.apply_setting_transaction({
						key = "llm_pred_indent",
						value = i,
						runtime_fn = "set_llm_pred_indent",
						publish_setting = true,
					})
				end or nil,
			})
		end
		return menu
	end

	--- Dynamic builder for modifier menus.
	local function build_modifier_menu(key, default_mods, hs_fn)
		local current_mods = Storage.get(key)
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
			{title = "⇧⌥ Shift + Option", mods = {"shift", "alt"}},
		}

		local menu = {}
		for _, opt in ipairs(opts) do
			table.insert(menu, {
				title = opt.title,
				checked = (table.concat(opt.mods, "+") == current_str) or nil,
				fn = not paused and function()
					return obj.apply_setting_transaction({
						key = key,
						value = opt.mods,
						runtime_fn = hs_fn,
						publish_setting = true,
					})
				end or nil,
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
