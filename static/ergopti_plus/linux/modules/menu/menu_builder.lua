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
		return { title = i18n_safe("menu.hotstrings.title", "⚡ Hotstrings"), menu = {
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

	return { title = i18n_safe("menu.hotstrings.title", "⚡ Hotstrings"), menu = items }
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local llm = ctx.llm
	if not llm then
		return { title = i18n_safe("menu.llm.title", "🤖 IA"), menu = {
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

	return { title = i18n_safe("menu.llm.title", "🤖 IA"), menu = items }
end

--- Builds the metrics/keylogger submenu.
local function _build_metrics(ctx)
	local k = ctx.keylogger
	if type(k) ~= "table" then
		return { title = i18n_safe("menu.metrics.title", "📊 Métriques"), menu = {
			{ title = "(métriques non disponibles)", fn = function() end, disabled = true },
		}}
	end

	return { title = i18n_safe("menu.metrics.title", "📊 Métriques"), menu = {
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

--- Builds the shortcuts submenu (P2.13).
local function _build_shortcuts(ctx)
	local sc = ctx.shortcuts
	if not sc then
		return { title = i18n_safe("menu.shortcuts.title", "⚙ Raccourcis"), menu = {
			{ title = "(shortcuts non disponible)", fn = function() end, disabled = true },
		}}
	end

	local enabled = sc.is_enabled()
	local caps_active = sc.is_caps_word_active()
	local items = {}

	-- Master toggle.
	items[#items + 1] = {
		title = "Activé " .. (enabled and "✓" or ""),
		fn = function() sc.toggle() end,
	}
	items[#items + 1] = { title = "-" }

	-- CapsWord toggle.
	items[#items + 1] = {
		title = "CapsWord " .. (caps_active and "✓" or ""),
		fn = function()
			sc.toggle_caps_word()
			Logger.info(LOG, "CapsWord toggled: %s", tostring(sc.is_caps_word_active()))
		end,
	}

	-- Text transforms (operate on current X11 selection).
	items[#items + 1] = { title = "-" }
	items[#items + 1] = {
		title = "→ MAJUSCULES",
		fn = function() sc.transform_uppercase() end,
	}
	items[#items + 1] = {
		title = "→ minuscules",
		fn = function() sc.transform_lowercase() end,
	}
	items[#items + 1] = {
		title = "→ Title Case",
		fn = function() sc.transform_titlecase() end,
	}

	items[#items + 1] = { title = "-" }

	-- Selection helpers.
	items[#items + 1] = {
		title = "Sélectionner le mot",
		fn = function() sc.select_word() end,
	}
	items[#items + 1] = {
		title = "Sélectionner la ligne",
		fn = function() sc.select_line() end,
	}
	items[#items + 1] = {
		title = "Coller sans formatage",
		fn = function() sc.paste_plain() end,
	}

	-- Wrap symbols submenu.
	local wrap_items = {}
	local wrap_pairs = sc.get_wrap_pairs()
	for ch, pair in pairs(wrap_pairs) do
		-- Only include opening chars to avoid duplicates.
		if ch == pair.left then
			local cap = ch
			wrap_items[#wrap_items + 1] = {
				title = ch .. " … " .. pair.right .. "  (" .. ch .. "texte" .. pair.right .. ")",
				fn = function() sc.wrap_selection(pair.left, pair.right) end,
			}
		end
	end
	items[#items + 1] = { title = "Wrap symbols", menu = wrap_items }

	return { title = i18n_safe("menu.shortcuts.title", "⚙ Raccourcis"), menu = items }
end

--- Builds the Kanata submenu (Linux's Karabiner — P2.5).
--- Actions delegate to the kanata manager module passed via ctx.kanata.
local function _build_kanata(ctx)
	local km = ctx.kanata

	-- Fallback: try direct require if not passed via context.
	if not km then
		local ok_km, km_mod = pcall(require, "modules.kanata.manager")
		if ok_km then km = km_mod end
	end

	local running = km and km.is_running() or false

	return { title = i18n_safe("menu.kanata.title", "🎹 Kanata"), menu = {
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

--- Builds the gestures submenu (P2.11).
local function _build_gestures(ctx)
	local ge = ctx.gestures
	if not ge then
		return { title = i18n_safe("menu.gestures.title", "🖐 Gestes"), menu = {
			{ title = "(gestures non disponible)", fn = function() end, disabled = true },
		}}
	end

	local enabled = ge.is_enabled()
	local items = {}

	-- Master toggle.
	items[#items + 1] = {
		title = "Activé " .. (enabled and "✓" or ""),
		fn = function()
			ge.toggle()
		end,
	}
	items[#items + 1] = { title = "-" }

	-- Show a subset of commonly-configured gesture slots.
	local quick_slots = {
		{ slot = "swipe_3_left",  label = "← 3 doigts gauche" },
		{ slot = "swipe_3_right", label = "→ 3 doigts droite" },
		{ slot = "swipe_3_up",    label = "↑ 3 doigts haut" },
		{ slot = "swipe_3_down",  label = "↓ 3 doigts bas" },
		{ slot = "swipe_4_left",  label = "← 4 doigts gauche" },
		{ slot = "swipe_4_right", label = "→ 4 doigts droite" },
		{ slot = "tap_3",         label = "👆 Tap 3 doigts" },
		{ slot = "tap_4",         label = "👆 Tap 4 doigts" },
	}

	for _, qs in ipairs(quick_slots) do
		local action = ge.get_action(qs.slot) or "none"
		local label = ge.get_action_label(action)
		items[#items + 1] = {
			title = qs.label .. " → " .. label,
			fn = function()
				-- Cycle through common actions for this slot.
				local cur = ge.get_action(qs.slot) or "none"
				local cycle = { "none", "ws_prev", "ws_next", "tab_prev", "tab_next", "vol_up", "vol_down" }
				local found = false
				for i, a in ipairs(cycle) do
					if a == cur then
						local next_a = cycle[i % #cycle + 1]
						ge.set_action(qs.slot, next_a)
						found = true
						break
					end
				end
				if not found then ge.set_action(qs.slot, "none") end
			end,
		}
	end

	items[#items + 1] = { title = "-" }

	-- Reading state.
	items[#items + 1] = {
		title = "Lecture libinput: " .. (ge.is_reading() and "active" or "inactive"),
		fn = function()
			if ge.is_reading() then
				ge.stop_reading()
			else
				ge.start_reading()
			end
		end,
	}

	-- Reset to defaults.
	items[#items + 1] = {
		title = "Réinitialiser les gestes",
		fn = function()
			ge.reset_defaults()
			Logger.info(LOG, "Gestures reset to defaults.")
		end,
	}

	return { title = i18n_safe("menu.gestures.title", "🖐 Gestes"), menu = items }
end

--- Builds the apps submenu (placeholder for per-app configs).
local function _build_apps(ctx)
	return { title = i18n_safe("menu.apps.title", "📱 Apps"), menu = {
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
				if ctx.on_enable_all then ctx.on_enable_all() end
			end,
		},
		{
			title = i18n_safe("menu.global.disable_all", "Désactiver tout"),
			fn = function()
				if ctx.on_disable_all then ctx.on_disable_all() end
			end,
		},
		{ title = "-" },
		{
			title = i18n_safe("menu.global.reset_defaults", "Réinitialiser"),
			fn = function()
				if ctx.on_reset_defaults then ctx.on_reset_defaults() end
			end,
		},
	}}
end

--- Builds the language selector submenu (P2.10).
--- Lists all available locales, marks the active one with a checkmark.
--- Switching persists via i18n.set_locale() → storage adapter.
local function _build_language(_ctx)
	local items = {}

	-- Try to load i18n for real locale list + switching.
	local i18n = nil
	local ok_i18n, i18n_mod = pcall(require, "lib.i18n")
	if ok_i18n then i18n = i18n_mod end

	if i18n then
		local active = i18n.get_locale()
		local locales = i18n.list_locales()
		for _, code in ipairs(locales) do
			local label = i18n.display_name(code) .. " (" .. code .. ")"
			if code == active then label = label .. " ✓" end
			local cap = code  -- capture for closure
			items[#items + 1] = {
				title = label,
				fn = function()
					i18n.set_locale(cap)
					Logger.info(LOG, "Language set to %s (persisted).", cap)
				end,
			}
		end
	else
		-- Fallback when i18n module is not loaded.
		items[#items + 1] = { title = "Français", fn = function()
			Logger.info(LOG, "[stub] Switch locale to fr.")
		end }
		items[#items + 1] = { title = "English", fn = function()
			Logger.info(LOG, "[stub] Switch locale to en.")
		end }
	end

	return { title = i18n_safe("menu.global.language", "🌐 Langue"), menu = items }
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

--- Builds the setup wizard launcher (P2.2 — opens WebKitGTK onboarding window).
local function _build_setup_wizard(ctx)
	return {
		title = i18n_safe("menu.global.setup_wizard", "🧙 Assistant"),
		fn = function()
			if ctx.on_show_setup_wizard then ctx.on_show_setup_wizard() end
		end,
	}
end

--- Builds the updater submenu (P2.9 — GitHub releases, channel switching, download).
local function _build_updates(ctx)
	local up = ctx.updater
	if not up then
		return { title = i18n_safe("menu.updates.title", "🔄 Mises à jour"), menu = {
			{ title = "(updater non disponible)", fn = function() end, disabled = true },
		}}
	end

	local channel = up.get_channel()
	local version = up.current_version()
	local items = {}

	-- Header showing current version and channel.
	items[#items + 1] = {
		title = "v" .. version .. " (" .. channel .. ")",
		fn = function() end,
		disabled = true,
	}
	items[#items + 1] = { title = "-" }

	-- Check for updates now.
	items[#items + 1] = {
		title = up.get_menu_label(),
		fn = function()
			local available = up.check_for_updates()
			if available then
				local rel = up.get_cached_release()
				if rel then
					Logger.info(LOG, "Update available: %s.", rel.tag)
				end
			else
				Logger.info(LOG, "No update available (current: %s).", up.current_version())
			end
		end,
	}

	-- Download + install (only shown when an update is available).
	local state = up.get_state()
	if state == "available" then
		local rel = up.get_cached_release()
		if rel then
			items[#items + 1] = {
				title = "Télécharger et installer " .. rel.tag,
				fn = function()
					local archive = up.download_update()
					if archive then
						up.install_update(archive)
					end
				end,
			}
		end
	end

	items[#items + 1] = { title = "-" }

	-- Channel switching.
	items[#items + 1] = {
		title = "Canal stable" .. (channel == "stable" and " ✓" or ""),
		fn = function()
			up.set_channel("stable")
			Logger.info(LOG, "Update channel set to stable.")
		end,
	}
	items[#items + 1] = {
		title = "Canal dev (préversions)" .. (channel == "dev" and " ✓" or ""),
		fn = function()
			up.set_channel("dev")
			Logger.info(LOG, "Update channel set to dev.")
		end,
	}

	items[#items + 1] = { title = "-" }

	-- Interval presets.
	local current_interval = up.get_check_interval()
	for _, preset in ipairs(up.INTERVAL_PRESETS) do
		local is_current = (preset.seconds == current_interval)
		items[#items + 1] = {
			title = "Vérifier toutes les " .. preset.code .. (is_current and " ✓" or ""),
			fn = function()
				up.set_check_interval(preset.seconds)
				up.stop_background_checks()
				up.start_background_checks()
			end,
		}
	end

	items[#items + 1] = { title = "-" }

	-- Open releases page.
	items[#items + 1] = {
		title = "Ouvrir la page des releases",
		fn = function()
			local url = up.releases_page_url()
			Logger.info(LOG, "Opening releases page: %s", url)
			os.execute(string.format("xdg-open '%s' 2>/dev/null &", url:gsub("'", "'\\''")))
		end,
	}

	return { title = i18n_safe("menu.updates.title", "🔄 Mises à jour"), menu = items }
end

--- Builds the about item.
local function _build_about(_ctx)
	return {
		title = i18n_safe("menu.global.about", "ℹ À propos"),
		fn = function()
			Logger.info(LOG, "Ergopti — ergonomic keyboard optimizer.")
		end,
	}
end

--- Builds the reload item.
local function _build_reload(_ctx)
	return {
		title = i18n_safe("menu.global.reload", "↺ Recharger"),
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
		title = i18n_safe("menu.global.quit", "✕ Quitter"),
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
				if ctx.on_open_logs then ctx.on_open_logs() end
			end,
		},
		{
			title = i18n_safe("menu.debug.healthcheck", "Diagnostic"),
			fn = function()
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
	items[#items + 1] = _build_updates(ctx)

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
