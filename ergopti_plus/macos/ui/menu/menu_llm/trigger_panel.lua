--- ui/menu/menu_llm/trigger_panel.lua

--- ==============================================================================
--- MODULE: LLM Trigger Panel
--- DESCRIPTION:
--- Builds the trigger-configuration submenu for the LLM tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: debounce, field filters, and app exclusions are cohesive
---    and kept together, away from the rest of init.lua.
--- 2. App exclusions delegate to AppPickerLib so the picker logic stays DRY.
--- 3. No shortcut row: a prediction on demand is the llm_generate_prediction
---    action, bound like any other in a keyboard slot (Ctrl+Space recommended).
--- ==============================================================================

local M = {}

local llm_mod      = require("modules.llm")
local AppPickerLib = require("infra.app_picker")
local i18n         = require("infra.i18n")
local ManifestMenu = require("infra.manifest_menu")
local Logger       = require("infra.logger")

local PrivacyPolicy = require("llm.trigger_policy")
local Preferences = require("infra.preferences")
local ConfigPaths = require("infra.config_paths")
local SettingsManager = require("ui.menu.menu_llm.settings_manager")

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
---   save_prefs, update_menu, settings_mgr.
--- @return table menu Populated trigger_menu table.
function M.build(ctx)
	local state               = ctx.state
	local is_disabled         = ctx.is_disabled
	local settings_mgr        = ctx.settings_mgr

	local rows = {}


	-- =====================================================
	-- ===== 1.1) Debounce =====
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
	-- ===== 1.2) Instant triggers =====
	-- =====================================================

	local leading_rows = rows
	rows = {}

	-- Fixed field filters belong to the declaration. Native owners prove the
	-- actual cached runtime and the preowned canonical file before any click.
	local function privacy_snapshot(key)
		local snapshot = { owner = settings_mgr, generation = 0, value = state[key],
			enabled = state.llm_enabled, backend = state.llm_backend,
			paused = true, blocked = true }
		local ok, detail = xpcall(function()
			local core = llm_mod.streaming_snapshot()
			local runtime = settings_mgr.setting_snapshot(key)
			local path = ConfigPaths.get("ConfigTomlPath")
			local canonical, physical = Preferences.current_view(path)
			snapshot.source = Preferences.source_snapshot(path)
			snapshot.paused = ctx.is_paused()
			snapshot.generation = core.generation + (runtime and runtime.generation or 0)
			local function canonical_value(field)
				if canonical == nil then return nil end
				if canonical[field] == nil then return llm_mod.DEFAULT_STATE[field] end
				return canonical[field]
			end
			snapshot.blocked = ctx.is_disabled ~= false or core.blocked ~= false
				or settings_mgr.scope_idle() ~= true or runtime == nil
				or (runtime and (runtime.owner ~= settings_mgr or runtime.value ~= snapshot.value))
				or core.enabled ~= snapshot.enabled or core.backend ~= snapshot.backend
				or not Preferences.source_matches(snapshot.source, physical)
				or canonical_value(key) ~= snapshot.value
				or canonical_value("llm_enabled") ~= snapshot.enabled
				or canonical_value("llm_backend") ~= snapshot.backend
		end, debug.traceback)
		if not ok then
			Logger.warn(LOG, "Privacy row source is unavailable: %s.", tostring(detail))
			snapshot.blocked = true
		end
		return snapshot
	end
	local url_source = privacy_snapshot("llm_url_bar_filter_enabled")
	local secure_source = privacy_snapshot("llm_secure_field_filter_enabled")
	local function privacy_command(expected, key, runtime_fn)
		local current = privacy_snapshot(key)
		if not Preferences.source_matches(expected.source, current.source) then return false end
		local decision = PrivacyPolicy.intent(expected, current)
		if decision.admitted ~= true then return false end
		return settings_mgr.apply_setting_transaction({
			key = key, value = decision.value, runtime_fn = runtime_fn, publish_setting = false,
			publication_guard = SettingsManager.publication_guard(Preferences,
				ConfigPaths.get("ConfigTomlPath"), expected.source),
		})
	end

	-- =====================================================
	-- ===== 1.4) App exclusions =====
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

	local function ready()
		return state.llm_enabled == true and ctx.is_disabled ~= true
			and not (type(ctx.is_paused) == "function" and ctx.is_paused() == true)
	end
	local shared_ctx = {
		commands = {
			["llm_url_bar_filter"] = function()
				return privacy_command(url_source, "llm_url_bar_filter_enabled", "set_llm_url_bar_filter_enabled")
			end,
			["llm_secure_field_filter"] = function()
				return privacy_command(secure_source, "llm_secure_field_filter_enabled", "set_llm_secure_field_filter_enabled")
			end,
			["llm_instant_on_word_end"] = function()
				if not ready() then return false end
				return apply_setting_transaction(settings_mgr, "llm_instant_on_word_end",
					not state.llm_instant_on_word_end, "set_llm_instant_on_word_end")
			end,
			["llm_after_hotstring"] = function()
				if not ready() then return false end
				return apply_setting_transaction(settings_mgr, "llm_after_hotstring",
					not state.llm_after_hotstring, "set_llm_after_hotstring")
			end,
		},
		state_getters = {
			["llm_url_bar_filter_enabled"] = function() return state.llm_url_bar_filter_enabled end,
			["llm_secure_field_filter_enabled"] = function() return state.llm_secure_field_filter_enabled end,
			["llm_url_bar_filter_ready"] = function() return PrivacyPolicy.ready(url_source) end,
			["llm_secure_field_filter_ready"] = function() return PrivacyPolicy.ready(secure_source) end,
			["llm_instant_on_word_end_enabled"] = function() return state.llm_instant_on_word_end end,
			["llm_after_hotstring_enabled"] = function() return state.llm_after_hotstring end,
			["llm_trigger_ready"] = ready,
		},
	}
	return ManifestMenu.build("llm_trigger_menu", "LLM", nil, nil, shared_ctx, {
		["llm_trigger_leading"] = function() return leading_rows end,
		["llm_trigger_remaining"] = function() return rows end,
	})
end

return M
