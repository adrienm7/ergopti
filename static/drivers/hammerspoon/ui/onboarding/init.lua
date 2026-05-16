--- ui/onboarding/init.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard
--- DESCRIPTION:
--- First-launch setup wizard guiding the user through the initial configuration
--- of Ergopti via a webview-based multi-step form.
---
--- FEATURES & RATIONALE:
--- 1. Consistent UI: Uses the same webview + usercontent bridge pattern as all
---    other Ergopti panels — one coherent design language throughout the app.
--- 2. Live Locale Switch: Selecting a language in step 1 triggers a "previewLocale"
---    message; Lua loads the strings and injects them back via applyStrings() so
---    subsequent steps render in the chosen language without a reload.
--- 3. Atomic Write: All collected answers are flushed to config.toml in a single
---    toml_writer.batch_write() call at the end, then hs.reload().
--- 4. Single-message Finish: The JS sends one "finish" message containing all
---    answers at once, so Lua never has to maintain per-step state.
--- ==============================================================================

local M = {}

local i18n         = require("lib.i18n")
local toml_writer  = require("lib.toml_writer")
local notifications = require("lib.notifications")
local Logger       = require("lib.logger")
local LOG          = "onboarding"

local SETTINGS_COMPLETED_KEY = "ergopti.onboarding.completed"

-- Path to config.toml — set by M.run() before the wizard opens
local _config_path  = nil

-- WebView + usercontent bridge state (singleton)
local _webview      = nil
local _usercontent  = nil

-- Absolute path to the assets folder (same directory as this file)
local _src       = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"




-- ============================================
-- ============================================
-- ======= 1/ Locale string injection =======
-- ============================================
-- ============================================

--- Loads the strings for a given locale code and injects them into the webview
--- via window.applyStrings().  Used both for the initial render and for the
--- live-preview when the user hovers over a language row.
--- @param code string Locale code, e.g. "fr".
local function inject_strings(code)
	if not _webview then return end
	local strings = {}

	-- Pull every translated string out of i18n by temporarily pointing it at
	-- the requested locale, then restoring the previous locale.
	local prev_code = i18n.get_locale()
	i18n.set_locale_no_reload(code)

	-- Collect all onboarding keys the JS wizard needs
	local keys = {
		"onboarding.language.placeholder",
		"onboarding.layout.title", "onboarding.layout.desc",
		"onboarding.layout.yes",  "onboarding.layout.no",
		"onboarding.magic_key.title", "onboarding.magic_key.desc",
		"onboarding.magic_key.hint",
		"onboarding.metrics.title", "onboarding.metrics.desc",
		"onboarding.gestures.title", "onboarding.gestures.desc",
		"onboarding.yes", "onboarding.no",
		"onboarding.back", "onboarding.next", "onboarding.finish",
	}
	for _, k in ipairs(keys) do
		strings[k] = i18n.get(k)
	end

	-- Inject the privacy warning pre-formatted with the actual metrics path so
	-- the user sees exactly the same text as the tray-menu toggle dialog
	local metrics_dir = (_config_path or ""):match("^(.*[/\\])") or ""
	strings["dialog.metrics.enable_warning_formatted"] =
		string.format(i18n.get("dialog.metrics.enable_warning"), metrics_dir .. "metrics")

	i18n.set_locale_no_reload(prev_code)

	local ok_enc, json = pcall(hs.json.encode, strings)
	if not ok_enc or not json then
		Logger.error(LOG, "inject_strings: failed to encode strings for '%s'.", code)
		return
	end

	Logger.debug(LOG, "Injecting strings for locale '%s'…", code)
	pcall(function()
		_webview:evaluateJavaScript("if(window.applyStrings) window.applyStrings(" .. json .. ")")
	end)
end

--- Sends the full initData payload (locale + strings + default answers) to the
--- webview so the first step renders correctly on open.
local function inject_init_data()
	if not _webview then return end

	local current_locale = i18n.get_locale()
	local strings = {}
	local keys = {
		"onboarding.language.placeholder",
		"onboarding.layout.title", "onboarding.layout.desc",
		"onboarding.layout.yes",  "onboarding.layout.no",
		"onboarding.magic_key.title", "onboarding.magic_key.desc",
		"onboarding.magic_key.hint",
		"onboarding.metrics.title", "onboarding.metrics.desc",
		"onboarding.gestures.title", "onboarding.gestures.desc",
		"onboarding.yes", "onboarding.no",
		"onboarding.back", "onboarding.next", "onboarding.finish",
	}
	for _, k in ipairs(keys) do
		strings[k] = i18n.get(k)
	end

	-- Same privacy warning as inject_strings — pre-formatted with the metrics path
	local metrics_dir = (_config_path or ""):match("^(.*[/\\])") or ""
	strings["dialog.metrics.enable_warning_formatted"] =
		string.format(i18n.get("dialog.metrics.enable_warning"), metrics_dir .. "metrics")

	local payload = {
		locale  = current_locale,
		strings = strings,
		answers = {
			locale       = current_locale,
			use_ergopti  = true,
			magic_key    = "★",
			use_metrics  = false,
			use_gestures = false,
		},
	}

	local ok_enc, json = pcall(hs.json.encode, payload)
	if not ok_enc or not json then
		Logger.error(LOG, "inject_init_data: failed to encode payload.")
		return
	end

	Logger.debug(LOG, "Injecting initData into onboarding webview…")
	pcall(function()
		_webview:evaluateJavaScript("if(window.initData) window.initData(" .. json .. ")")
	end)
end




-- ============================================
-- ============================================
-- ======= 2/ Finish and commit =============
-- ============================================
-- ============================================

--- Converts a JS truthy value to a TOML boolean string.
--- @param value any
--- @return string
local function to_bool(value)
	return (value == true or value == "true") and "true" or "false"
end

--- Closes the webview cleanly.
local function close_webview()
	if _webview then
		pcall(function() _webview:delete() end)
		_webview     = nil
		_usercontent = nil
	end
end

--- Writes all collected answers to config.toml and reloads Hammerspoon.
--- @param answers table The answers object from the JS "finish" message.
local function commit(answers)
	Logger.start(LOG, "Writing onboarding answers to config.toml…")

	local locale = type(answers.locale) == "string" and answers.locale ~= "" and answers.locale or "en"
	local updates = {
		{ section = "Script",    key = "Locale",          value = locale                            },
		{ section = "Layout",    key = "ErgoptiBase",     value = to_bool(answers.use_ergopti)      },
		{ section = "Layout",    key = "ErgoptiAltGr",    value = to_bool(answers.use_ergopti)      },
		{ section = "Layout",    key = "ErgoptiPlus",     value = to_bool(answers.use_ergopti)      },
		{ section = "Hotstrings", key = "MagicKey",       value = answers.magic_key or "★"          },
		{ section = "Metrics",   key = "metrics_enabled", value = to_bool(answers.use_metrics)      },
		{ section = "Gestures",  key = "Enabled",         value = to_bool(answers.use_gestures)     },
	}

	-- Switch to the chosen locale before writing so success messages are translated
	i18n.set_locale_no_reload(locale)

	local ok, err = pcall(function()
		toml_writer.batch_write(_config_path, updates)
	end)

	if not ok then
		Logger.error(LOG, "commit: toml_writer failed — %s.", tostring(err))
		close_webview()
		hs.dialog.blockAlert(
			i18n.get("onboarding.error.title"),
			i18n.get("onboarding.error.write_failed") .. "\n\n" .. tostring(err),
			i18n.get("onboarding.btn.ok")
		)
		return
	end

	Logger.success(LOG, "Onboarding answers written successfully.")
	hs.settings.set(SETTINGS_COMPLETED_KEY, true)
	close_webview()

	notifications.notify(i18n.get("onboarding.done.title"), i18n.get("onboarding.done.body"))
	hs.timer.doAfter(1.5, function()
		hs.reload()
	end)
end




-- ============================================
-- ============================================
-- ======= 3/ Message handler ===============
-- ============================================
-- ============================================

--- Dispatches incoming usercontent messages from the JS wizard.
--- @param body table The decoded message body.
local function handle_message(body)
	if type(body) ~= "table" then return end
	local action = body.action
	Logger.debug(LOG, "usercontent message: action='%s'.", tostring(action))

	if action == "ready" then
		-- JS page finished loading — inject initial data
		hs.timer.doAfter(0.05, inject_init_data)

	elseif action == "previewLocale" then
		-- User hovered/clicked a language row — inject its strings live
		local code = type(body.locale) == "string" and body.locale or "en"
		inject_strings(code)

	elseif action == "localeSelected" then
		-- User confirmed language and moved to step 2 — switch locale in memory
		local code = type(body.locale) == "string" and body.locale or "en"
		i18n.set_locale_no_reload(code)
		Logger.info(LOG, "Onboarding locale set to '%s'.", code)

	elseif action == "finish" then
		-- User reached the last step and clicked Finish — write config and reload
		if type(body.answers) == "table" then
			commit(body.answers)
		else
			Logger.error(LOG, "finish message missing answers table.")
		end
	end
end




-- ============================================
-- ============================================
-- ======= 4/ Public API ====================
-- ============================================
-- ============================================

--- Returns true when the onboarding wizard should run.
--- @param config_path string Absolute path to the user's config.toml.
--- @return boolean True if the wizard should be displayed.
function M.should_run(config_path)
	if type(config_path) ~= "string" or config_path == "" then
		return false
	end
	return not hs.fs.attributes(config_path)
end

--- Opens the onboarding wizard webview.
--- Resets all collected answers to their defaults before beginning.
--- @param config_path string Absolute path where config.toml should be written.
function M.run(config_path)
	if type(config_path) ~= "string" or config_path == "" then
		Logger.error(LOG, "M.run() called with missing config_path.")
		return
	end
	_config_path = config_path

	-- Bring the existing window to front if the wizard is already open
	if _webview then
		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if ok_ui then ui_builder.force_focus(_webview)
		else pcall(function() _webview:bringToFront() end) end
		return
	end

	Logger.start(LOG, "Opening onboarding wizard…")

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsOnboarding")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create usercontent bridge.")
		return
	end
	_usercontent = uc
	_usercontent:setCallback(function(message)
		if message and type(message.body) == "table" then
			handle_message(message.body)
		end
	end)

	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or not ui_builder then
		Logger.error(LOG, "Failed to load ui_builder module.")
		return
	end

	local screen  = hs.screen.mainScreen()
	local sf      = screen and type(screen.frame) == "function" and screen:frame() or { w = 1440, h = 900 }
	local win_h   = math.min(520, math.floor(sf.h * 0.60))
	local win_w   = math.min(460, math.floor(sf.w * 0.35))

	local masks       = hs.webview.windowMasks
	local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)

	_webview = ui_builder.show_webview({
		frame       = ui_builder.get_centered_frame(win_w, win_h),
		title       = "Ergopti — Setup",
		style_masks = style_masks,
		usercontent = _usercontent,
		assets_dir  = ASSETS_DIR,
		on_close    = function()
			_webview     = nil
			_usercontent = nil
		end,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				Logger.debug(LOG, "Navigation finished — injecting initData.")
				hs.timer.doAfter(0.05, inject_init_data)
			end
			return true
		end,
	})

	Logger.success(LOG, "Onboarding wizard opened.")
end

--- Starts the onboarding wizard regardless of whether config.toml exists.
--- Useful when the user triggers the wizard manually from a menu item.
--- @param config_path string Absolute path to the user's config.toml.
function M.run_from_menu(config_path)
	M.run(config_path)
end

return M
