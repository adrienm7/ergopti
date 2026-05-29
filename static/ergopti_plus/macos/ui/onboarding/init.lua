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
local toml_codec   = require("lib.toml_codec")
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

--- Resolve the absolute file:// URL to the Ergopti layout preview JPG so
--- the webview can <img src="…"> it directly. ASSETS_DIR is
--- static/ergopti_plus/macos/ui/onboarding/ ; the image lives at
--- static/img/ergopti.jpg, four directories above. Returns nil when the
--- file is missing so the JS side keeps the preview hidden gracefully.
--- @return string|nil
local function _layout_image_url()
	local img_path = ASSETS_DIR .. "../../../../img/ergopti.jpg"
	local attrs = hs.fs.attributes(img_path)
	if not attrs then
		Logger.debug(LOG, "Layout preview image missing at '%s' — step 2 renders without it.", img_path)
		return nil
	end
	-- Canonicalise to an absolute path so the file:// URI is well-formed
	-- regardless of which working directory Hammerspoon was launched from.
	local absolute = hs.fs.pathToAbsolute(img_path) or img_path
	-- Percent-encode spaces (and a handful of other reserved chars) so the
	-- browser engine treats the URL as a single resource. Slashes stay literal.
	local encoded = absolute:gsub("([^%w%-%./_~/\\:])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return "file://" .. encoded
end




-- ============================================
--- ==========================================
-- ======= 1/ Locale string injection =======
--- ==========================================
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
		"onboarding.welcome.title", "onboarding.welcome.heading",
		"onboarding.language.placeholder",
		"onboarding.layout.title", "onboarding.layout.desc",
		"onboarding.layout.yes",  "onboarding.layout.no",
		"onboarding.magic_key.title", "onboarding.magic_key.desc",
		"onboarding.magic_key.option_blackstar", "onboarding.magic_key.option_star",
		"onboarding.magic_key.option_ugrave", "onboarding.magic_key.option_semicolon",
		"onboarding.magic_key.option_custom", "onboarding.magic_key.choose_freely",
		"onboarding.metrics.title", "onboarding.metrics.desc",
		"onboarding.gestures.title", "onboarding.gestures.desc",
		-- Same macOS-gestures-conflict warning shown by the tray "Enable
		-- gestures" toggle — surfaced on step 5 in an orange box so the
		-- user knows about the system-setting conflict before committing.
		"dialog.gestures.warning_msg",
		"onboarding.yes", "onboarding.no",
		"onboarding.back", "onboarding.next", "onboarding.finish",
		-- Inserted config-folder step reuses the same labels as the
		-- tray-menu folder editor so we don't duplicate translations.
		"dialog.config_folder.title", "dialog.config_folder.label",
		"dialog.config_folder.hint", "dialog.config_folder.select_title",
		"common.browse",
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
		"onboarding.welcome.title", "onboarding.welcome.heading",
		"onboarding.language.placeholder",
		"onboarding.layout.title", "onboarding.layout.desc",
		"onboarding.layout.yes",  "onboarding.layout.no",
		"onboarding.magic_key.title", "onboarding.magic_key.desc",
		"onboarding.magic_key.option_blackstar", "onboarding.magic_key.option_star",
		"onboarding.magic_key.option_ugrave", "onboarding.magic_key.option_semicolon",
		"onboarding.magic_key.option_custom", "onboarding.magic_key.choose_freely",
		"onboarding.metrics.title", "onboarding.metrics.desc",
		"onboarding.gestures.title", "onboarding.gestures.desc",
		-- Same macOS-gestures-conflict warning shown by the tray "Enable
		-- gestures" toggle — surfaced on step 5 in an orange box so the
		-- user knows about the system-setting conflict before committing.
		"dialog.gestures.warning_msg",
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

	-- Also include the labels needed by the inserted config-folder step.
	local config_step_keys = {
		"dialog.config_folder.title", "dialog.config_folder.label",
		"dialog.config_folder.hint", "dialog.config_folder.select_title",
		"common.browse",
	}
	for _, k in ipairs(config_step_keys) do
		if strings[k] == nil then strings[k] = i18n.get(k) end
	end

	-- Resolve the current + default config directories so the wizard can
	-- pre-fill the input AND show the default as a placeholder.
	local cur_config_dir, default_config_dir = "", ""
	local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
	if ok_mp and menu_paths then
		local ok1, v1 = pcall(menu_paths.get_config_dir)
		if ok1 and type(v1) == "string" then cur_config_dir = v1 end
		if menu_paths.get_default_config_dir then
			local ok2, v2 = pcall(menu_paths.get_default_config_dir)
			if ok2 and type(v2) == "string" then default_config_dir = v2 end
		end
	end

	-- Detect the active macOS keyboard layout name so the JS step 3 can
	-- pre-select ù on AZERTY / ; on QWERTY. ``hs.keycodes.currentLayout``
	-- returns a string like "U.S." or "French" — pass it through and let
	-- the JS-side _pickDefaultMagicKey() classify by substring match.
	local system_layout = ""
	pcall(function()
		local v = hs.keycodes.currentLayout()
		if type(v) == "string" then system_layout = v end
	end)

	local payload = {
		locale             = current_locale,
		strings            = strings,
		default_config_dir = default_config_dir,
		system_layout      = system_layout,
		layout_image_url   = _layout_image_url(),
		-- Locale list rendered on step 1. Pulled from lib.i18n so the
		-- wizard, the menubar language submenu and the AHK tray menu
		-- all show identical ordering — non-Latin script names trail
		-- after the Latin ones rather than intermixing alphabetically.
		locales            = i18n.get_sorted_locales(),
		answers = {
			locale       = current_locale,
			use_ergopti  = true,
			-- ★ (BLACK STAR, U+2605) is the documented Ergopti default —
			-- a dedicated key on the Ergopti+ layout, and what the rest
			-- of the app already calls "the magic key". Step 3 will
			-- swap this to ù / ; if the user picks a non-Ergopti layout
			-- on step 2 and the system KB is AZERTY / QWERTY.
			magic_key    = "★",
			-- Pre-fill with the current config dir when it diverges from
			-- the OS default — otherwise leave empty so the placeholder
			-- shows the default and the wizard treats "no change" as the
			-- happy path.
			config_dir   = (cur_config_dir ~= default_config_dir) and cur_config_dir or "",
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

	-- Persist the chosen config dir to paths.toml BEFORE writing
	-- config.toml: the path resolver picks the new location up on the
	-- final reload, so subsequent saves go there straight away. An
	-- empty / unchanged path is a no-op (menu_paths handles the
	-- "drop the override" case internally).
	if type(answers.config_dir) == "string" and answers.config_dir ~= "" then
		local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
		if ok_mp and menu_paths and menu_paths.persist_config_dir_for_wizard then
			local ok_persist, err = pcall(menu_paths.persist_config_dir_for_wizard, answers.config_dir)
			if not ok_persist then
				Logger.warn(LOG, "Failed to persist config dir override: %s.", tostring(err))
			end
		end
	end

	local locale = type(answers.locale) == "string" and answers.locale ~= "" and answers.locale or "en"
	local updates = {
		{ section = "Script",    key = "Locale",          value = locale                            },
		{ section = "Layout",    key = "ErgoptiBase",     value = to_bool(answers.use_ergopti)      },
		{ section = "Layout",    key = "ErgoptiAltGr",    value = to_bool(answers.use_ergopti)      },
		{ section = "Layout",    key = "ErgoptiPlus",     value = to_bool(answers.use_ergopti)      },
		{ section = "Hotstrings", key = "MagicKey",       value = answers.magic_key or "*"          },
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

	elseif action == "pickConfigDir" then
		-- Open the macOS native folder picker via osascript and ship the
		-- chosen path back to JS so the input box fills in.
		local seed = type(body.current) == "string" and body.current or ""
		if seed == "" then
			-- Default seed = the current config dir resolved by menu_paths,
			-- so the picker opens somewhere meaningful even on first run.
			local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
			if ok_mp and menu_paths then
				local ok_v, v = pcall(menu_paths.get_config_dir)
				if ok_v and type(v) == "string" then seed = v end
			end
		end
		local escaped = seed:gsub('"', '\\"')
		local prompt = (i18n.get("dialog.config_folder.select_title") or ""):gsub('"', '\\"')
		local script = string.format([[
			try
				set r to choose folder with prompt "%s" default location ((POSIX file "%s") as alias)
				return POSIX path of r
			on error
				return ""
			end try
		]], prompt, escaped)
		local ok_as, _r2, raw = hs.osascript.applescript(script)
		Logger.debug(LOG, "pickConfigDir: ok=%s raw=%s.", tostring(ok_as), tostring(raw))
		local chosen = type(raw) == "string" and raw or ""
		chosen = chosen:gsub("^%s+", ""):gsub("%s+$", "")
		if chosen ~= "" then
			if not chosen:match("[/\\]$") then chosen = chosen .. "/" end
			-- Encode the path as a JSON string so AppleScript paths with
			-- spaces / accents survive the JS eval.
			local ok_enc, encoded = pcall(hs.json.encode, chosen)
			if ok_enc and encoded and _webview then
				pcall(function()
					_webview:evaluateJavaScript("if(window.setConfigDir) window.setConfigDir(" .. encoded .. ")")
				end)
			end
		end

	elseif action == "loadExistingConfig" then
		-- User confirmed a config directory on the config step. Check whether
		-- ``<dir>/hammerspoon/config.toml`` already exists; if so, parse it and
		-- ship the saved answers back to JS so steps 2-5 open pre-selected with
		-- the user's previous choices instead of the bare defaults.
		local chosen = type(body.config_dir) == "string" and body.config_dir or ""
		if chosen == "" then
			-- Empty input = "use the OS default" — read from the resolved
			-- default location so a returning user gets pre-fill regardless
			-- of whether they left the input empty or typed the same path.
			local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
			if ok_mp and menu_paths and menu_paths.get_default_config_dir then
				local ok_v, v = pcall(menu_paths.get_default_config_dir)
				if ok_v and type(v) == "string" then chosen = v end
			end
		end
		if chosen ~= "" then
			if not chosen:match("[/\\]$") then chosen = chosen .. "/" end
			local cfg_path = chosen .. "hammerspoon/config.toml"
			if hs.fs.attributes(cfg_path) then
				local ok_read, content = pcall(function()
					local f = io.open(cfg_path, "r")
					if not f then return nil end
					local c = f:read("*a")
					f:close()
					return c
				end)
				if ok_read and type(content) == "string" then
					local ok_dec, parsed = pcall(toml_codec.decode, content)
					if ok_dec and type(parsed) == "table" then
						-- Mirror the AHK helper: any Ergopti layout switch ON
						-- counts as "use Ergopti". A nil section yields false.
						local layout = parsed.Layout or {}
						local hotstrings = parsed.Hotstrings or {}
						local metrics = parsed.Metrics or {}
						local gestures = parsed.Gestures or {}
						local answers = {
							use_ergopti  = (layout.ErgoptiBase == true)
								or (layout.ErgoptiAltGr == true)
								or (layout.ErgoptiPlus == true),
							magic_key    = type(hotstrings.MagicKey) == "string" and hotstrings.MagicKey ~= ""
								and hotstrings.MagicKey or nil,
							use_metrics  = metrics.metrics_enabled == true,
							use_gestures = gestures.Enabled == true,
						}
						-- Strip nils so Object.assign on the JS side does not
						-- overwrite the default magic key with undefined.
						local clean = {}
						for k, v in pairs(answers) do
							if v ~= nil then clean[k] = v end
						end
						local ok_enc, json = pcall(hs.json.encode, clean)
						if ok_enc and json and _webview then
							Logger.info(LOG, "Pre-loaded wizard answers from existing config at '%s'.", cfg_path)
							pcall(function()
								_webview:evaluateJavaScript("if(window.applyExistingAnswers) window.applyExistingAnswers(" .. json .. ")")
							end)
						end
					end
				end
			else
				Logger.debug(LOG, "No existing config at '%s' — wizard keeps defaults.", cfg_path)
			end
		end

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
		title       = i18n.get("onboarding.welcome.title"),
		style_masks = style_masks,
		usercontent = _usercontent,
		assets_dir    = ASSETS_DIR,
		on_close      = function()
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
