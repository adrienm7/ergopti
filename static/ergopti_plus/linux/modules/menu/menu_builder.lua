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

--- Builds the hotstrings submenu from the loaded engine state.
--- @param engine table The hotstring engine instance (has get_groups? method).
--- @param mappings table The loaded mappings array.
--- @return table Array of menu items.
local function _build_hotstrings(engine, mappings)
	local items = {}
	if type(mappings) ~= "table" then return items end

	-- Collect unique groups from mappings.
	local groups = {}
	for _, m in ipairs(mappings) do
		if type(m.group) == "string" and m.group ~= "" then
			groups[m.group] = (groups[m.group] or 0) + 1
		end
	end

	if next(groups) == nil then
		items[#items + 1] = { title = "(aucun groupe chargé)", fn = function() end, disabled = true }
		return items
	end

	for group, count in pairs(groups) do
		local group_name = group
		items[#items + 1] = {
			title = group_name .. " (" .. count .. ")",
			fn = function()
				-- Placeholder: toggle group enable/disable.
				-- Future: call engine:set_group_enabled(group_name, not enabled).
				Logger.debug(LOG, "Toggle hotstring group: %s", group_name)
			end,
		}
	end

	-- Separator + reload action.
	items[#items + 1] = { title = "───────────────", fn = function() end, disabled = true }
	items[#items + 1] = {
		title = "Recharger les hotstrings",
		fn = function()
			-- Placeholder: trigger a hotstring reload.
			Logger.info(LOG, "Hotstring reload requested.")
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
--- @param metrics table The metrics_collector module.
--- @return table Array of menu items.
local function _build_metrics(metrics)
	return {
		{
			title = "Afficher les statistiques",
			fn = function()
				local stats = metrics.get_session_stats()
				Logger.info(LOG, "Session: %d keystrokes, ~%d words, %ds.",
					stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
			end,
		},
		{
			title = "Top 10 bigrammes",
			fn = function()
				local ngrams = metrics.get_ngrams(10)
				for _, ng in ipairs(ngrams) do
					Logger.info(LOG, "  %s: %d", ng.gram, ng.count)
				end
			end,
		},
		{
			title = "Réinitialiser la session",
			fn = function()
				metrics.reset_session()
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
---   mappings  table   Loaded hotstring mappings array.
---   layout    string  Current keyboard layout ("qwerty" or "azerty").
---   on_layout_change  function  Called with new layout name.
---   metrics   table   Metrics collector module.
---   llm       table|nil  LLM prediction engine state (or nil).
---   dry_run   boolean  Dry-run mode flag (mutable reference).
---   verbose   boolean  Verbose flag (mutable reference).
---   on_quit   function  Called when Quit is selected.
--- }
--- @return table Flat array of { title, fn, disabled?, checked? } tables.
function M.build(ctx)
	local ctx = type(ctx) == "table" and ctx or {}
	local items = {}

	-- Header.
	local header = _build_header(ctx)
	for _, item in ipairs(header) do items[#items + 1] = item end

	-- Hotstrings section.
	items[#items + 1] = { title = "Hotstrings ▼", fn = function() end, disabled = true }
	local hs_items = _build_hotstrings(ctx.engine, ctx.mappings)
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

	-- Metrics section.
	items[#items + 1] = { title = "Métriques ▼", fn = function() end, disabled = true }
	local metric_items = _build_metrics(ctx.metrics)
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
