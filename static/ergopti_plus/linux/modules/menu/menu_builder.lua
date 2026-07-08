--- modules/menu/menu_builder.lua

--- ==============================================================================
--- MODULE: Menu Builder (Linux)
--- DESCRIPTION:
--- Builds the tray menu item list from the daemon's runtime state. Called by
--- ergopti_hotstrings.lua to populate the tray_menu adapter with dynamic items
--- reflecting the current hotstring groups, layouts, LLM models, and metrics.
---
--- The menu tree mirrors the macOS menubar (§9 of the parity plan):
---   Layout → Hotstrings → AI → Metrics → Shortcuts → Kanata → Gestures → Apps
---   → separator → Global Actions → Language → Config Folder → Setup Wizard
---   → About → Reload → Quit → Debug
---
--- Items that depend on features not yet implemented on Linux (P2.2-P2.13)
--- are present as labelled stubs that log the action — they don't crash and
--- they show the intended final shape.
---
--- FEATURES & RATIONALE:
--- 1. Hierarchical items: items with a `menu` sub-table are rendered as
---    submenus on SNI/dbusmenu; on yad they are flattened with a separator.
--- 2. All callbacks are closures over the daemon's state — zero global coupling.
--- 3. New sections (shortcuts, kanata, gestures, apps, global_actions, language,
---    config, debug) are added as documented stubs so the menu shape is correct.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.menu.menu_builder"

-- Single source of the driver version.
local Version = require("lib.version")


-- =========================================
-- =========================================
-- ======= 1/ Section Builders =============
-- =========================================
-- =========================================

--- Builds the top-level header with version.
--- Returns a single item (not an array) — callers insert it directly.
local function _build_header(ctx)
	local v = ctx._version or Version.VERSION
	return { title = "Ergopti — v" .. v, fn = function() end, disabled = true }
end

--- Builds the layout selection submenu.
local function _build_layouts(ctx)
	local current = ctx.layout or "qwerty"
	local on_change = ctx.on_layout_change
	return {
		title = i18n_safe("menu.layout.title", "⌨ Disposition"),
		menu = {
			{
				title = "qwerty " .. (current == "qwerty" and "✓" or ""),
				fn = function()
					if on_change then on_change("qwerty") end
				end,
			},
			{
				title = "azerty " .. (current == "azerty" and "✓" or ""),
				fn = function()
					if on_change then on_change("azerty") end
				end,
			},
		},
	}
end

--- Builds the hotstrings submenu.
local function _build_hotstrings(ctx)
	local config = ctx.config
	local items = {}

	if type(config) ~= "table" then
		return { title = "⚡ Hotstrings", menu = {
			{ title = "(config non disponible)", fn = function() end, disabled = true },
		}}
	end

	local groups = {}
	if type(config.get_groups) == "function" then
		groups = config.get_groups() or {}
	end

	if #groups == 0 then
		items[#items + 1] = { title = "(aucun groupe chargé)", fn = function() end, disabled = true }
	else
		for _, group in ipairs(groups) do
			local gname = group
			local is_enabled = config.is_group_enabled and config.is_group_enabled(gname)
			items[#items + 1] = {
				title = gname .. (is_enabled and " ✓" or ""),
				fn = function()
					if config.toggle_group then config.toggle_group(gname) end
				end,
			}
		end
	end

	items[#items + 1] = { title = "-" }
	items[#items + 1] = {
		title = "Recharger les hotstrings",
		fn = function()
			if config.reload then config.reload() end
		end,
	}

	return { title = "⚡ Hotstrings", menu = items }
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local llm = ctx.llm
	if not llm then
		return { title = "🤖 IA", menu = {
			{ title = "LLM non disponible", fn = function() end, disabled = true },
			{ title = "(démarrer Ollama sur le port 11434)", fn = function() end, disabled = true },
		}}
	end

	local items = {}
	local enabled = llm.is_enabled and llm:is_enabled() or false

	items[#items + 1] = {
		title = "Activé " .. (enabled and "✓" or ""),
		fn = function()
			if llm.toggle then llm:toggle() end
		end,
	}

	if type(llm.get_models) == "function" then
		local models = llm:get_models()
		if type(models) == "table" then
			for _, model in ipairs(models) do
				local is_current = (llm.get_current_model and llm:get_current_model() == model)
				items[#items + 1] = {
					title = model .. (is_current and " ✓" or ""),
					fn = function()
						if llm.set_model then llm:set_model(model) end
					end,
				}
			end
		end
	end

	return { title = "🤖 IA", menu = items }
end

--- Builds the metrics/keylogger submenu.
local function _build_metrics(ctx)
	local k = ctx.keylogger
	if type(k) ~= "table" then
		return { title = "📊 Métriques", menu = {
			{ title = "(métriques non disponibles)", fn = function() end, disabled = true },
		}}
	end

	return { title = "📊 Métriques", menu = {
		{
			title = "Statistiques de session",
			fn = function()
				if type(k.get_session_stats) ~= "function" then return end
				local s = k.get_session_stats()
				Logger.info(LOG, "Session: %d keystrokes, ~%d words, %ds.",
					s.keystrokes, s.words, math.floor(s.duration_ms / 1000))
			end,
		},
		{
			title = "WPM actuel",
			fn = function()
				if type(k.get_wpm) ~= "function" then return end
				Logger.info(LOG, "WPM: %.1f", k.get_wpm())
			end,
		},
		{
			title = "Stats par application",
			fn = function()
				if type(k.get_app_stats) ~= "function" then return end
				local apps = k.get_app_stats()
				for app, s in pairs(apps) do
					Logger.info(LOG, "  %s: %d keystrokes", app, s.keystrokes)
				end
			end,
		},
		{ title = "-" },
		{
			title = "Suspendre " .. (type(k.is_suppressed) == "function" and k.is_suppressed() and "✓" or ""),
			fn = function()
				if type(k.is_suppressed) ~= "function" then return end
				if k.is_suppressed() then k.unsuppress() else k.suppress() end
			end,
		},
		{
			title = "Réinitialiser la session",
			fn = function()
				if type(k.reset_session) ~= "function" then return end
				k.reset_session()
				Logger.info(LOG, "Metrics session reset.")
			end,
		},
	}}
end

--- Builds the shortcuts submenu (P2.7 — stub).
local function _build_shortcuts(_ctx)
	return { title = "⚙ Raccourcis", menu = {
		{ title = "Wrap symbols " .. i18n_safe("menu.shortcuts.wrap_symbols", "…"), fn = function()
			Logger.info(LOG, "[stub] Wrap symbols editor — requires keyboard grab (P2.7).")
		end },
		{ title = "CapsWord " .. i18n_safe("menu.shortcuts.capsword", "…"), fn = function()
			Logger.info(LOG, "[stub] CapsWord config — requires keyboard grab (P2.7).")
		end },
		{ title = "Text manipulation " .. i18n_safe("menu.shortcuts.text_manip", "…"), fn = function()
			Logger.info(LOG, "[stub] Text manipulation — requires keyboard grab (P2.7).")
		end },
	}}
end

--- Builds the Kanata submenu (Linux's Karabiner — P2.5).
--- Actions delegate to the kanata manager module if loaded.
local function _build_kanata(_ctx)
	-- Try to load the kanata manager for real actions.
	local km = nil
	local ok_km, km_mod = pcall(require, "modules.kanata.manager")
	if ok_km then km = km_mod end

	local running = km and km.is_running() or false

	return { title = "🎹 Kanata", menu = {
		{
			title = "Générer le .kbd",
			fn = function()
				if km then
					if km.write_kbd() then
						Logger.info(LOG, "Kanata .kbd generated.")
					else
						Logger.error(LOG, "Kanata .kbd generation failed.")
					end
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = "Démarrer kanata" .. (running and " ✓" or ""),
			fn = function()
				if km then
					km.start()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = "Arrêter kanata",
			fn = function()
				if km then
					km.stop()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
		{
			title = "Redémarrer kanata",
			fn = function()
				if km then
					km.restart()
				else
					Logger.info(LOG, "[stub] Kanata manager not loaded.")
				end
			end,
		},
	}}
end

--- Builds the gestures submenu (P2.11 — stub).
local function _build_gestures(_ctx)
	return { title = "🖐 Gestes", menu = {
		{ title = "(non implémenté sur Linux)", fn = function() end, disabled = true },
		{ title = i18n_safe("menu.gestures.trackpad", "Trackpad…"), fn = function()
			Logger.info(LOG, "[stub] Trackpad gestures — P2.11 (libinput).")
		end },
	}}
end

--- Builds the apps submenu (placeholder for per-app configs).
local function _build_apps(ctx)
	return { title = "📱 Apps", menu = {
		{ title = "(configuration par application)", fn = function() end, disabled = true },
		{ title = "Ouvrir le dossier de config", fn = function()
			if ctx.on_open_config then ctx.on_open_config() end
		end },
	}}
end

--- Builds the global actions submenu.
local function _build_global_actions(ctx)
	return { title = i18n_safe("menu.global.title", "Actions globales"), menu = {
		{
			title = i18n_safe("menu.global.enable_all", "Activer tout"),
			fn = function()
				Logger.info(LOG, "[stub] enable_all — global hotstring toggle.")
				if ctx.on_enable_all then ctx.on_enable_all() end
			end,
		},
		{
			title = i18n_safe("menu.global.disable_all", "Désactiver tout"),
			fn = function()
				Logger.info(LOG, "[stub] disable_all.")
				if ctx.on_disable_all then ctx.on_disable_all() end
			end,
		},
		{ title = "-" },
		{
			title = i18n_safe("menu.global.reset_defaults", "Réinitialiser"),
			fn = function()
				Logger.info(LOG, "[stub] reset_defaults.")
				if ctx.on_reset_defaults then ctx.on_reset_defaults() end
			end,
		},
	}}
end

--- Builds the language selector submenu (P2.10 — stub).
local function _build_language(_ctx)
	return { title = i18n_safe("menu.global.language", "🌐 Langue"), menu = {
		{ title = "Français", fn = function()
			Logger.info(LOG, "[stub] Switch locale to fr — P2.10.")
		end },
		{ title = "English", fn = function()
			Logger.info(LOG, "[stub] Switch locale to en — P2.10.")
		end },
	}}
end

--- Builds the config folder launcher.
local function _build_config_folder(ctx)
	return {
		title = i18n_safe("menu.global.config_folder", "📂 Dossier de config"),
		fn = function()
			local dir = os.getenv("HOME") .. "/.config/ergopti/hotstrings"
			Logger.info(LOG, "Opening config folder: %s", dir)
			if ctx.on_open_config then ctx.on_open_config(dir) end
		end,
	}
end

--- Builds the setup wizard launcher (P2.2 — stub).
local function _build_setup_wizard(ctx)
	return {
		title = i18n_safe("menu.global.setup_wizard", "🧙 Assistant"),
		fn = function()
			Logger.info(LOG, "[stub] Setup wizard — P2.2 (webview).")
			if ctx.on_show_setup_wizard then ctx.on_show_setup_wizard() end
		end,
	}
end

--- Builds the about item.
local function _build_about(_ctx)
	return {
		title = "ℹ À propos",
		fn = function()
			Logger.info(LOG, "Ergopti — ergonomic keyboard optimizer.")
		end,
	}
end

--- Builds the reload item.
local function _build_reload(_ctx)
	return {
		title = "↺ Recharger",
		fn = function()
			Logger.info(LOG, "Reload requested — sending SIGHUP.")
			-- SIGHUP triggers on_sighup_reload in the daemon (if posix.signal is available).
			os.execute("kill -HUP " .. tostring(os.getpid and os.getpid() or "$$") .. " 2>/dev/null")
		end,
	}
end

--- Builds the quit item.
local function _build_quit(ctx)
	return {
		title = "✕ Quitter",
		fn = function()
			Logger.info(LOG, "Quit requested via tray menu.")
			if ctx.on_quit then ctx.on_quit() end
		end,
	}
end

--- Builds the debug submenu.
local function _build_debug(ctx)
	local log_levels = { "DEBUG", "INFO", "WARNING", "ERROR" }
	local level_items = {}
	for _, lvl in ipairs(log_levels) do
		level_items[#level_items + 1] = {
			title = lvl,
			fn = function()
				Logger.info(LOG, "[stub] Set log level to %s.", lvl)
				if ctx.on_set_log_level then ctx.on_set_log_level(lvl) end
			end,
		}
	end

	return { title = i18n_safe("menu.debug.title", "🐛 Débogage"), menu = {
		{
			title = i18n_safe("menu.debug.log_level", "Niveau de log"),
			menu = level_items,
		},
		{
			title = i18n_safe("menu.debug.open_logs", "Ouvrir les logs"),
			fn = function()
				Logger.info(LOG, "[stub] Open logs folder.")
				if ctx.on_open_logs then ctx.on_open_logs() end
			end,
		},
		{
			title = i18n_safe("menu.debug.healthcheck", "Diagnostic"),
			fn = function()
				Logger.info(LOG, "[stub] Healthcheck — P2.2 (webview).")
				if ctx.on_healthcheck then ctx.on_healthcheck() end
			end,
		},
	}}
end


-- =========================================
-- =========================================
-- ======= 2/ i18n Safe Fallback ===========
-- =========================================
-- =========================================

--- Returns a translated string if the i18n module is available, or the fallback.
--- Separated so the menu builder works before P2.10 (i18n wiring) is done.
--- @param key string i18n key
--- @param fallback string Fallback text
--- @return string
function i18n_safe(key, fallback)
	local ok, i18n = pcall(require, "lib.i18n")
	if ok and i18n and type(i18n.get) == "function" then
		local val = i18n.get(key)
		if val and val ~= key then return val end
	end
	return fallback or key
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Builds the full tray menu item list from the daemon's current state.
--- @param ctx table {
---   _version       string   Driver version string.
---   config         table    Hotstrings_config module.
---   layout         string   Current keyboard layout.
---   on_layout_change function Called with new layout name.
---   keylogger      table    Keylogger module.
---   llm            table|nil LLM prediction engine state.
---   dry_run        boolean  Dry-run mode flag.
---   verbose        boolean  Verbose flag.
---   on_quit        function Called when Quit is selected.
---   on_open_config function Called to open config dir.
---   on_enable_all  function (optional) Global enable.
---   on_disable_all function (optional) Global disable.
---   on_reset_defaults function (optional) Reset.
---   on_set_log_level function (optional) Log level change.
---   on_open_logs   function (optional) Open logs dir.
---   on_healthcheck function (optional) Launch healthcheck.
---   on_show_setup_wizard function (optional) Launch setup wizard.
--- }
--- @return table Array of { title, menu?, fn?, checked?, disabled? } items.
function M.build(ctx)
	local ctx = type(ctx) == "table" and ctx or {}
	local items = {}

	-- Header (non-interactive).
	items[#items + 1] = _build_header(ctx)

	-- ── Feature sections (mirroring macOS order) ──
	items[#items + 1] = { title = "-" }

	items[#items + 1] = _build_layouts(ctx)
	items[#items + 1] = _build_hotstrings(ctx)
	items[#items + 1] = _build_llm(ctx)
	items[#items + 1] = _build_metrics(ctx)
	items[#items + 1] = _build_shortcuts(ctx)
	items[#items + 1] = _build_kanata(ctx)
	items[#items + 1] = _build_gestures(ctx)
	items[#items + 1] = _build_apps(ctx)

	-- ── Separator before system-level actions ──
	items[#items + 1] = { title = "-" }

	items[#items + 1] = _build_global_actions(ctx)
	items[#items + 1] = _build_language(ctx)
	items[#items + 1] = _build_config_folder(ctx)
	items[#items + 1] = _build_setup_wizard(ctx)
	items[#items + 1] = _build_about(ctx)
	items[#items + 1] = _build_reload(ctx)

	items[#items + 1] = { title = "-" }
	items[#items + 1] = _build_debug(ctx)

	items[#items + 1] = { title = "-" }
	items[#items + 1] = _build_quit(ctx)

	return items
end

return M
