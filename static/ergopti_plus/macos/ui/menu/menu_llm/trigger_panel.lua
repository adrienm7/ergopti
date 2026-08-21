--- ui/menu/menu_llm/trigger_panel.lua

--- ==============================================================================
--- MODULE: LLM Trigger Panel
--- DESCRIPTION:
--- Builds the trigger-configuration submenu for the LLM tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: debounce, shortcut, field filters, and app exclusions are
---    cohesive and kept together, away from the rest of init.lua.
--- 2. App exclusions delegate to AppPickerLib so the picker logic stays DRY.
--- ==============================================================================

local M = {}

local llm_mod      = require("modules.llm")
local shortcut_ui  = require("ui.menu.shortcut_utils")
local AppPickerLib = require("infra.app_picker")
local i18n         = require("infra.i18n")
local ManifestMenu = require("infra.manifest_menu")
local Logger       = require("infra.logger")

local LOG = "menu_llm.trigger_panel"

--- Routes one trigger setting through the shared transactional owner.
--- @param settings_mgr table Settings manager instance.
--- @param key string Shared state key.
--- @param value any Candidate value.
--- @param runtime_fn string Keymap setter name.
--- @return boolean committed True only when every boundary commits.
local function apply_setting_transaction(settings_mgr, key, value, runtime_fn)
	if type(settings_mgr) ~= "table"
		or type(settings_mgr.apply_setting_transaction) ~= "function" then
		Logger.error(LOG,
			"Trigger setting '%s' refused because the transaction owner is unavailable.",
			tostring(key))
		return false
	end
	return settings_mgr.apply_setting_transaction({
		key = key,
		value = value,
		runtime_fn = runtime_fn,
		publish_setting = false,
	})
end





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the trigger submenu: this panel answers what the rows ARE, and the
--- shared renderer materialises every one of them.
--- @param ctx table Context with fields: state, keymap, is_disabled,
---   save_prefs, update_menu, settings_mgr, apply_llm_shortcut.
--- @return table menu Populated trigger_menu table.
function M.build(ctx)
	local state               = ctx.state
	local is_disabled         = ctx.is_disabled
	local settings_mgr        = ctx.settings_mgr
	local apply_llm_shortcut  = ctx.apply_llm_shortcut

	local rows = {}


	-- =====================================================
	-- ===== 1.1) Trigger shortcut =====
	-- =====================================================

	local sc_label = shortcut_ui.shortcut_to_label(state.llm_trigger_shortcut, i18n.get("common.none"))
	rows[#rows + 1] = {
		label    = string.format(i18n.get("menu.llm.trigger_shortcut_label"), sc_label),
		disabled = is_disabled or nil,
		action   = function()
			shortcut_ui.prompt_shortcut({
				title            = i18n.get("menu.llm.trigger_shortcut_title"),
				message          = i18n.get("menu.llm.shortcut_prompt"),
				current_shortcut = state.llm_trigger_shortcut,
				default_mods     = {"ctrl"},
				on_apply         = apply_llm_shortcut,
			})
		end
	}


	-- =====================================================
	-- ===== 1.2) Debounce =====
	-- =====================================================

	local debounce_val     = tonumber(state.llm_debounce) or llm_mod.DEFAULT_STATE.llm_debounce
	local debounce_display = (debounce_val <= 0) and i18n.get("menu.settings.never") or (math.floor(debounce_val * 1000) .. " ms…")

	rows[#rows + 1] = {
		label    = string.format(i18n.get("menu.llm.debounce_label"), debounce_display),
		disabled = is_disabled or nil,
		action   = settings_mgr.set_debounce,
	}
	if state.llm_debounce ~= llm_mod.DEFAULT_STATE.llm_debounce then
		rows[#rows + 1] = {
			label    = string.format(i18n.get("menu.llm.reset_label"), math.floor(llm_mod.DEFAULT_STATE.llm_debounce * 1000) .. " ms"),
			disabled = is_disabled or nil,
			action   = settings_mgr.reset_debounce,
		}
	end


	-- =====================================================
	-- ===== 1.3) Instant triggers =====
	-- =====================================================

	rows[#rows + 1] = {
		label    = i18n.get("menu.llm.instant_on_word_end"),
		checked  = state.llm_instant_on_word_end,
		disabled = is_disabled or nil,
		action   = not is_disabled and function()
			return apply_setting_transaction(settings_mgr,
				"llm_instant_on_word_end",
				not state.llm_instant_on_word_end,
				"set_llm_instant_on_word_end")
		end or nil,
	}

	rows[#rows + 1] = {
		label    = i18n.get("menu.llm.after_hotstring"),
		checked  = state.llm_after_hotstring,
		disabled = is_disabled or nil,
		action   = not is_disabled and function()
			return apply_setting_transaction(settings_mgr,
				"llm_after_hotstring",
				not state.llm_after_hotstring,
				"set_llm_after_hotstring")
		end or nil,
	}

	rows[#rows + 1] = { separator = true }


	-- =====================================================
	-- ===== 1.4) Field filters =====
	-- =====================================================

	rows[#rows + 1] = {
		label    = i18n.get("menu.llm.disable_url_bars"),
		checked  = state.llm_url_bar_filter_enabled,
		disabled = is_disabled or nil,
		action   = not is_disabled and function()
			return apply_setting_transaction(settings_mgr,
				"llm_url_bar_filter_enabled",
				not state.llm_url_bar_filter_enabled,
				"set_llm_url_bar_filter_enabled")
		end or nil,
	}

	rows[#rows + 1] = {
		label    = i18n.get("menu.llm.disable_password_fields"),
		checked  = state.llm_secure_field_filter_enabled,
		disabled = is_disabled or nil,
		action   = not is_disabled and function()
			return apply_setting_transaction(settings_mgr,
				"llm_secure_field_filter_enabled",
				not state.llm_secure_field_filter_enabled,
				"set_llm_secure_field_filter_enabled")
		end or nil,
	}


	-- =====================================================
	-- ===== 1.5) App exclusions =====
	-- =====================================================

	local disabled_count = #(type(state.llm_disabled_apps) == "table" and state.llm_disabled_apps or {})
	local disabled_label = string.format(i18n.get("menu.llm.disabled_in_label"), disabled_count, disabled_count > 1 and "s" or "")

	-- AppPickerLib's rows. They are provider data since 2026-08-08, so they are
	-- materialised by the renderer like everything else in this panel.
	local exclusion_menu = AppPickerLib.build_menu(
		state.llm_disabled_apps,
		function(new_list)
			return apply_setting_transaction(settings_mgr,
				"llm_disabled_apps", new_list, "set_llm_disabled_apps")
		end,
		i18n.get("menu.llm.exclude_from_ai")
	)

	rows[#rows + 1] = {
		label    = disabled_label,
		disabled = is_disabled or nil,
		items    = exclusion_menu,
	}

	return ManifestMenu.render_rows(rows, "llm_trigger")
end

return M
