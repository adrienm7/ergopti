--- modules/menu/menu_builder.lua

--- ==============================================================================
--- MODULE: Menu Builder (Linux)
--- DESCRIPTION:
--- Builds the tray menu item list from the daemon's runtime state. Called by
--- ergopti_hotstrings.lua to populate the tray_menu adapter with dynamic items
--- reflecting the current hotstring groups, layouts, LLM models, and metrics.
--- Separated from the daemon entry point to keep ergopti_hotstrings.lua thin.
---
--- FEATURES & RATIONALE:
--- 1. Dynamic groups: each loaded hotstring group becomes a checkbox menu item
---    that toggles enable/disable for that group.
--- 2. Layout selection: radio-style items for qwerty/azerty.
--- 3. LLM model selection: populated from the LLM profiles module.
--- 4. Metrics: toggle keylogger on/off, show WPM, reset session.
--- 5. Quit: stops the keyboard hook and exits the daemon cleanly.
--- 6. All menu callbacks are closures over the daemon's engine/metrics/LLM
---    state — no global state coupling.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.menu.menu_builder"


-- =========================================
-- =========================================
-- ======= 1/ Builders =====================
-- =========================================
-- =========================================

--- Builds the top-level "Ergopti" header item and the separator.
--- @param ctx table The build context (has _version field).
--- @return table Array of menu items.
local function _build_header(ctx)
	local version = ctx._version or _VERSION or "3.0.0"
	return {
		{ title = "Ergopti — v" .. version, fn = function() end, disabled = true },
		{ title = "───────────────", fn = function() end, disabled = true },
	}
end

--- Builds the hotstrings submenu from hotstrings_config state.
--- @param config table The hotstrings_config module (has get_groups, toggle_group, is_group_enabled, reload).
--- @return table Array of menu items.
local function _build_hotstrings(config)
	local items = {}
	if type(config) ~= "table" then
		items[#items + 1] = { title = "(config non disponible)", fn = function() end, disabled = true }
		return items
	end

	local groups = {}
	if type(config.get_groups) == "function" then
		groups = config.get_groups() or {}
	end

	if #groups == 0 then
		items[#items + 1] = { title = "(aucun groupe chargé)", fn = function() end, disabled = true }
		return items
	end

	for _, group in ipairs(groups) do
		local group_name = group
		local is_enabled = config.is_group_enabled and config:is_group_enabled(group_name)
		items[#items + 1] = {
			title = group_name .. (is_enabled and " ✓" or ""),
			fn = function()
				-- Toggle group enable/disable and reload.
				if config.toggle_group then config:toggle_group(group_name) end
			end,
		}
	end

	-- Separator + reload action.
	items[#items + 1] = { title = "───────────────", fn = function() end, disabled = true }
	items[#items + 1] = {
		title = "Recharger les hotstrings",
		fn = function()
			if config.reload then config:reload() end
		end,
	}

	return items
end

--- Builds the layout selection submenu.
--- @param current_layout string "qwerty" or "azerty".
--- @param on_change function Called with the new layout name.
--- @return table Array of menu items.
local function _build_layouts(current_layout, on_change)
	return {
		{
			title = "qwerty " .. (current_layout == "qwerty" and "✓" or ""),
			fn = function()
				if on_change then on_change("qwerty") end
			end,
		},
		{
			title = "azerty " .. (current_layout == "azerty" and "✓" or ""),
			fn = function()
				if on_change then on_change("azerty") end
			end,
		},
	}
end

--- Builds the LLM submenu (model selection + enable/disable).
--- @param llm_state table|nil The LLM prediction engine state, or nil if LLM not loaded.
--- @return table Array of menu items.
local function _build_llm(llm_state)
	if not llm_state then
		return {
			{ title = "LLM non disponible", fn = function() end, disabled = true },
			{ title = "(démarrer Ollama sur le port 11434)", fn = function() end, disabled = true },
		}
	end

	local items = {}
	local enabled = llm_state.is_enabled and llm_state:is_enabled() or false

	items[#items + 1] = {
		title = "Activé " .. (enabled and "✓" or ""),
		fn = function()
			if llm_state.toggle then llm_state:toggle() end
		end,
	}

	-- Model selection.
	if type(llm_state.get_models) == "function" then
		local models = llm_state:get_models()
		if type(models) == "table" then
			for _, model in ipairs(models) do
				local is_current = (llm_state.get_current_model and llm_state:get_current_model() == model)
				items[#items + 1] = {
					title = model .. (is_current and " ✓" or ""),
					fn = function()
						if llm_state.set_model then llm_state:set_model(model) end
					end,
				}
			end
		end
	end

	return items
end

--- Builds the metrics/keylogger submenu.
--- @param keylogger table The keylogger module (has get_session_stats, get_wpm, get_app_stats, etc.).
--- @return table Array of menu items.
local function _build_metrics(keylogger)
	if type(keylogger) ~= "table" then
		return {
			{ title = "(métriques non disponibles)", fn = function() end, disabled = true },
		}
	end

	return {
		{
			title = "Afficher les statistiques",
			fn = function()
				if type(keylogger.get_session_stats) ~= "function" then return end
				local stats = keylogger.get_session_stats()
				Logger.info(LOG, "Session: %d keystrokes, ~%d words, %ds.",
					stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
			end,
		},
		{
			title = "Afficher le WPM",
			fn = function()
				if type(keylogger.get_wpm) ~= "function" then return end
				local wpm = keylogger.get_wpm()
				Logger.info(LOG, "WPM actuel: %.1f", wpm)
			end,
		},
		{
			title = "Stats par application",
			fn = function()
				if type(keylogger.get_app_stats) ~= "function" then return end
				local apps = keylogger.get_app_stats()
				for app, stats in pairs(apps) do
					Logger.info(LOG, "  %s: %d keystrokes", app, stats.keystrokes)
				end
			end,
		},
		{ title = "───────────────", fn = function() end, disabled = true },
		{
			title = "Suspendre le keylogger " .. (type(keylogger.is_suppressed) == "function" and keylogger.is_suppressed() and "✓" or ""),
			fn = function()
				if type(keylogger.is_suppressed) ~= "function" then return end
				if keylogger.is_suppressed() then
					keylogger.unsuppress()
				else
					keylogger.suppress()
				end
				Logger.info(LOG, "Keylogger suppression: %s", tostring(keylogger.is_suppressed()))
			end,
		},
		{
			title = "Réinitialiser la session",
			fn = function()
				if type(keylogger.reset_session) ~= "function" then return end
				keylogger.reset_session()
				Logger.info(LOG, "Metrics session reset.")
			end,
		},
	}
end

--- Builds the preferences/info submenu.
--- @param opts table { layout, dry_run, verbose }
--- @return table Array of menu items.
local function _build_preferences(ctx)
	return {
		{
			title = "Mode dry-run " .. ((ctx.dry_run) and "✓" or ""),
			fn = function()
				Logger.info(LOG, "Dry-run toggle requested (restart required for effect).")
			end,
		},
		{
			title = "Verbose " .. ((ctx.verbose) and "✓" or ""),
			fn = function()
				Logger.info(LOG, "Verbose toggle requested (restart required for effect).")
			end,
		},
		{ title = "───────────────", fn = function() end, disabled = true },
		{
			title = "À propos",
			fn = function()
				Logger.info(LOG, "Ergopti — ergonomic keyboard optimizer.")
			end,
		},
	}
end

--- Builds the quit action.
--- @param on_quit function Called when the user clicks Quit.
--- @return table Single menu item.
local function _build_quit(on_quit)
	return {
		{
			title = "Quitter",
			fn = function()
				Logger.info(LOG, "Quit requested via tray menu.")
				if on_quit then on_quit() end
			end,
		},
	}
end


-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Builds the full tray menu item list from the daemon's current state.
--- @param ctx table {
---   engine    table   Hotstring engine instance.
---   config    table   Hotstrings_config module (new) — use this for group toggles.
---   mappings  table   (legacy) Loaded hotstring mappings array — fallback if config absent.
---   layout    string  Current keyboard layout ("qwerty" or "azerty").
---   on_layout_change  function  Called with new layout name.
---   keylogger table   Keylogger module (new) — use this for metrics.
---   metrics   table   (legacy) Metrics collector module — fallback if keylogger absent.
---   llm       table|nil  LLM prediction engine state (or nil).
---   dry_run   boolean  Dry-run mode flag.
---   verbose   boolean  Verbose flag.
---   on_quit   function  Called when Quit is selected.
--- }
--- @return table Flat array of { title, fn, disabled?, checked? } tables.
function M.build(ctx)
	local ctx = type(ctx) == "table" and ctx or {}
	local items = {}

	-- Resolve new vs legacy fields.
	local config    = ctx.config    -- hotstrings_config (preferred)
	local keylogger = ctx.keylogger -- keylogger module (preferred)
	local metrics   = ctx.metrics   -- legacy metrics_collector
	local mappings  = ctx.mappings  -- legacy mappings array

	-- Header.
	local header = _build_header(ctx)
	for _, item in ipairs(header) do items[#items + 1] = item end

	-- Hotstrings section — prefer config over raw mappings.
	items[#items + 1] = { title = "Hotstrings ▼", fn = function() end, disabled = true }
	local hs_items = _build_hotstrings(config)
	for _, item in ipairs(hs_items) do items[#items + 1] = item end

	-- Separator.
	items[#items + 1] = { title = "", fn = function() end, disabled = true }

	-- Layout section.
	items[#items + 1] = { title = "Disposition ▼", fn = function() end, disabled = true }
	local layout_items = _build_layouts(ctx.layout or "qwerty", ctx.on_layout_change)
	for _, item in ipairs(layout_items) do items[#items + 1] = item end

	-- Separator.
	items[#items + 1] = { title = "", fn = function() end, disabled = true }

	-- LLM section.
	items[#items + 1] = { title = "LLM ▼", fn = function() end, disabled = true }
	local llm_items = _build_llm(ctx.llm)
	for _, item in ipairs(llm_items) do items[#items + 1] = item end

	-- Separator.
	items[#items + 1] = { title = "", fn = function() end, disabled = true }

	-- Metrics section — prefer keylogger over legacy metrics.
	items[#items + 1] = { title = "Métriques ▼", fn = function() end, disabled = true }
	local metric_items = _build_metrics(keylogger or metrics)
	for _, item in ipairs(metric_items) do items[#items + 1] = item end

	-- Separator.
	items[#items + 1] = { title = "", fn = function() end, disabled = true }

	-- Preferences section.
	items[#items + 1] = { title = "Préférences ▼", fn = function() end, disabled = true }
	local prefs_items = _build_preferences(ctx)
	for _, item in ipairs(prefs_items) do items[#items + 1] = item end

	-- Separator + Quit.
	items[#items + 1] = { title = "", fn = function() end, disabled = true }
	local quit_items = _build_quit(ctx.on_quit)
	for _, item in ipairs(quit_items) do items[#items + 1] = item end

	return items
end

return M
