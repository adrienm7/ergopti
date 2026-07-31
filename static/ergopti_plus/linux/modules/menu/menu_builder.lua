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
--- Items that depend on features not yet implemented on Linux
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

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function gesture_slot_label(slot)
	local fingers, direction = tostring(slot):match("^swipe_(%d+)_(.+)$")
	if fingers and direction then
		local directions = {
			left = "gauche", right = "droite", up = "haut", down = "bas",
			up_left = "haut-gauche", up_right = "haut-droite",
			down_left = "bas-gauche", down_right = "bas-droite",
		}
		return "Balayage " .. fingers .. " doigts vers " .. (directions[direction] or direction)
	end
	local tap_fingers = tostring(slot):match("^tap_(%d+)$")
	if tap_fingers then return "Tap " .. tap_fingers .. " doigts" end
	return tostring(slot)
end


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
		title = i18n_safe("menu.layout.title"),
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
		return { title = i18n_safe("menu.hotstrings.title"), menu = {
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

	return { title = i18n_safe("menu.hotstrings.title"), menu = items }
end

--- Builds the AI / LLM submenu.
local function _build_llm(ctx)
	local llm = ctx.llm
	if not llm then
		return { title = i18n_safe("menu.llm.title"), menu = {
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

	return { title = i18n_safe("menu.llm.title"), menu = items }
end

--- Builds the metrics/keylogger submenu.
--- Builds one privacy-toggle entry for the metrics submenu.
--- Reads the live value from get_privacy_state() rather than a cached copy, so
--- the tick always reflects what the keylogger is actually doing.
--- @param k       table    The keylogger module.
--- @param key     string   Field of get_privacy_state() this entry reflects.
--- @param label   string   User-facing label (French, per the UI convention).
--- @param setter  function Setter to call on toggle.
--- @return table The menu entry.
local function _privacy_toggle(k, key, label, setter)
	local available = type(k.get_privacy_state) == "function" and type(setter) == "function"
	if not available then
		return { title = label .. " (indisponible)", fn = function() end, disabled = true }
	end
	local active = k.get_privacy_state()[key] == true
	return {
		title = label .. (active and " ✓" or ""),
		fn = function() setter(not k.get_privacy_state()[key]) end,
	}
end

--- Reports the at-rest migration and offers to stop it.
--- Converting a year of stored rows takes minutes, and without this entry the
--- user ticks "Chiffrer les données au repos" and sees nothing happen at all.
--- @param k table The keylogger module.
--- @return table One menu entry.
local function _migration_status(k)
	if type(k.get_migration_progress) ~= "function" then
		return { title = "Migration du chiffrement (indisponible)", fn = function() end, disabled = true }
	end
	local progress = k.get_migration_progress()
	if not progress.running then
		return { title = "Migration du chiffrement : inactive", fn = function() end, disabled = true }
	end
	return {
		title = string.format("Migration : %d/%d ligne(s) — cliquer pour arrêter",
			progress.scanned, progress.total),
		fn = function()
			if type(k.cancel_migration) == "function" then k.cancel_migration() end
		end,
	}
end

local function _build_metrics(ctx)
	local k = ctx.keylogger
	if type(k) ~= "table" then
		return { title = i18n_safe("menu.metrics.title"), menu = {
			{ title = "(métriques non disponibles)", fn = function() end, disabled = true },
		}}
	end

	return { title = i18n_safe("menu.metrics.title"), menu = {
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
		-- Privacy posture. The four toggles below mirror macOS and Windows and
		-- read the same shared manifest defaults; the driver shipped without any
		-- of them, so metrics could not be turned off at all.
		_privacy_toggle(k, "enabled", "Collecte activée", k.set_enabled),
		_privacy_toggle(k, "private_filter_enabled",
			"Ignorer la navigation privée", k.set_private_filter_enabled),
		_privacy_toggle(k, "secure_filter_enabled",
			"Ignorer les champs de mot de passe", k.set_secure_filter_enabled),
		_privacy_toggle(k, "system_auth_filter_enabled",
			"Ignorer les invites d'authentification", k.set_system_auth_filter_enabled),
		_privacy_toggle(k, "encrypt",
			"Chiffrer les données au repos", k.set_encrypt_enabled),
		_migration_status(k),
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

--- Builds the shortcuts submenu.
local function _build_shortcuts(ctx)
	local sc = ctx.shortcuts
	if not sc then
		return { title = i18n_safe("menu.shortcuts.title"), menu = {
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

	return { title = i18n_safe("menu.shortcuts.title"), menu = items }
end

--- Builds the Kanata submenu (Linux's Karabiner equivalent).
--- Actions delegate to the kanata manager module passed via ctx.kanata.
local function _build_kanata(ctx)
	local km = ctx.kanata

	-- Fallback: try direct require if not passed via context.
	if not km then
		local ok_km, km_mod = pcall(require, "modules.kanata.manager")
		if ok_km then km = km_mod end
	end

	local running = km and km.is_running() or false

	return { title = i18n_safe("menu.kanata.title"), menu = {
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

--- Builds the gestures submenu.
local function _build_gestures(ctx)
	local ge = ctx.gestures
	if not ge then
		return { title = i18n_safe("menu.gestures.title"), menu = {
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
	items[#items + 1] = {
		title = "Réinitialiser les actions par défaut",
		fn = function() ge.reset_defaults() end,
	}
	items[#items + 1] = {
		title = "Tout mettre à vide",
		fn = function() if ge.disable_all_actions then ge.disable_all_actions() end end,
	}
	items[#items + 1] = { title = "-" }

	local function prompt_parameter(slot, action, spec, prior)
		if type(ctx.prompt_action_parameter) == "function" then
			return ctx.prompt_action_parameter(slot, action, spec, prior)
		end
		local prompt = spec == "search_url"
			and "URL de recherche (un seul %s pour la requête) :"
			or "Lien à ouvrir :"
		local command = "zenity --entry --title=" .. shell_quote("Configurer " .. (ge.get_action_label(action) or action))
			.. " --text=" .. shell_quote(prompt) .. " --entry-text=" .. shell_quote(prior or "") .. " 2>/dev/null"
		local pipe = io.popen(command, "r")
		if not pipe then
			Logger.error(LOG, "Zenity is unavailable: cannot configure %s for %s.", tostring(action), tostring(slot))
			return nil
		end
		local value = pipe:read("*a") or ""
		local ok = pipe:close()
		if not ok then return nil end
		return value:gsub("%s+$", "")
	end

	local function assign_action(slot, action)
		local spec = ge.get_action_parameter_spec and ge.get_action_parameter_spec(action) or nil
		if spec then
			local prior = ge.get_action_parameter and ge.get_action_parameter(slot, action) or ""
			local value = prompt_parameter(slot, action, spec, prior)
			if value == nil then return end
			if not ge.validate_action_parameter or not ge.validate_action_parameter(action, value) then
				Logger.warn(LOG, "Invalid parameter for gesture '%s' action '%s'.", tostring(slot), tostring(action))
				return
			end
			if not ge.set_action_parameter(slot, action, value) then return end
		end
		ge.set_action(slot, action)
	end

	-- Every known slot is configurable here. A partial quick list made
	-- parameterized actions unreachable for the omitted gesture bindings.
	local slots = {}
	for slot in pairs(ge.DEFAULT_GESTURES or {}) do slots[#slots + 1] = slot end
	table.sort(slots)
	for _, slot in ipairs(slots) do
		local action = ge.get_action(slot) or "none"
		local label = ge.get_action_display_label and ge.get_action_display_label(slot) or ge.get_action_label(action)
		local choices = {}
		for _, option in ipairs(ge.get_action_names and ge.get_action_names() or { "none" }) do
			local selected = option == action
			choices[#choices + 1] = {
				title = ge.get_action_label(option) .. (selected and " ✓" or ""),
				fn = function() assign_action(slot, option) end,
			}
		end
		items[#items + 1] = {
			title = gesture_slot_label(slot) .. " → " .. label,
			menu = choices,
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

	return { title = i18n_safe("menu.gestures.title"), menu = items }
end

--- Builds the apps submenu (per-app configs via webview).
local function _build_apps(ctx)
	return { title = i18n_safe("menu.apps.title"), menu = {
		{
			title = i18n_safe("menu.apps.config_per_app"),
			fn = function()
				if ctx.webview then
					ctx.webview.show("hotstrings_config_window")
					Logger.info(LOG, "Opening hotstrings config window.")
				else
					Logger.info(LOG, "[stub] Webview manager not available — cannot open hotstrings config.")
				end
			end,
		},
		{ title = "-" },
		{ title = "Ouvrir le dossier de config", fn = function()
			if ctx.on_open_config then ctx.on_open_config() end
		end },
	}}
end

--- Builds the global actions submenu.
local function _build_global_actions(ctx)
	return { title = i18n_safe("menu.global.title"), menu = {
		{
			title = i18n_safe("menu.global.enable_all"),
			fn = function()
				if ctx.on_enable_all then ctx.on_enable_all() end
			end,
		},
		{
			title = i18n_safe("menu.global.disable_all"),
			fn = function()
				if ctx.on_disable_all then ctx.on_disable_all() end
			end,
		},
		{ title = "-" },
		{
			title = i18n_safe("menu.global.reset_defaults"),
			fn = function()
				if ctx.on_reset_defaults then ctx.on_reset_defaults() end
			end,
		},
	}}
end

--- Builds the language selector submenu.
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

	return { title = i18n_safe("menu.global.language"), menu = items }
end

--- Builds the config folder launcher.
local function _build_config_folder(ctx)
	return {
		title = i18n_safe("menu.global.config_folder"),
		fn = function()
			local dir = os.getenv("HOME") .. "/.config/ergopti/hotstrings"
			Logger.info(LOG, "Opening config folder: %s", dir)
			if ctx.on_open_config then ctx.on_open_config(dir) end
		end,
	}
end

--- Builds the setup wizard launcher (opens the WebKitGTK onboarding window).
local function _build_setup_wizard(ctx)
	return {
		title = i18n_safe("menu.global.setup_wizard"),
		fn = function()
			if ctx.on_show_setup_wizard then ctx.on_show_setup_wizard() end
		end,
	}
end

--- Builds the updater submenu (GitHub releases, channel switching, download).
local function _build_updates(ctx)
	local up = ctx.updater
	if not up then
		return { title = i18n_safe("menu.updates.title"), menu = {
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

	return { title = i18n_safe("menu.updates.title"), menu = items }
end

--- Builds the about item.
local function _build_about(_ctx)
	return {
		title = i18n_safe("menu.about.title"),
		fn = function()
			Logger.info(LOG, "Ergopti — ergonomic keyboard optimizer.")
		end,
	}
end

--- Builds the reload item.
local function _build_reload(_ctx)
	return {
		title = i18n_safe("menu.global.reload"),
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
		title = i18n_safe("menu.global.quit"),
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

	return { title = i18n_safe("menu.debug.title"), menu = {
		{
			title = i18n_safe("menu.debug.log_level"),
			menu = level_items,
		},
		{
			title = i18n_safe("menu.debug.open_logs"),
			fn = function()
				if ctx.on_open_logs then ctx.on_open_logs() end
			end,
		},
		{
			title = i18n_safe("menu.debug.healthcheck"),
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

--- Returns the translated string, or the KEY when the i18n module cannot be
--- loaded at all. Separated so the menu builder works before the i18n wiring is
--- done — the pcall guards a real boot-order case, not a missing translation.
---
--- It used to take a French `fallback` second argument, supplied at all 30 call
--- sites. Every one of those keys exists in en.json and the locale-parity gate
--- keeps all 21 locales in step with it, so the fallback was unreachable — and
--- had it ever been reached, it would have shown French to a user of any of the
--- other 20 languages. A raw key on screen is ugly and diagnosable; a silently
--- wrong language is neither.
--- @param key string i18n key.
--- @return string The translation, or the key itself.
function i18n_safe(key)
	local ok, i18n = pcall(require, "lib.i18n")
	if ok and i18n and type(i18n.get) == "function" then
		local val = i18n.get(key)
		if val and val ~= key then return val end
	end
	return key
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
