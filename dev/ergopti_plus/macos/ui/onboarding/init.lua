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
local toml_writer  = require("lib.toml.writer")
local toml_codec   = require("lib.toml.codec")
local notifications = require("lib.notifications")
local Paths        = require("lib.paths")
local Logger       = require("lib.logger")
local text_utils   = require("lib.text_utils")
local LOG          = "onboarding"

local SETTINGS_COMPLETED_KEY = "ergopti.onboarding.completed"

-- MenuPaths.get() key that resolves <config_dir>/hammerspoon/config.toml.
local CONFIG_TOML_PATH_KEY   = "ConfigTomlPath"

-- Path to config.toml — set by M.run() before the wizard opens
local _config_path  = nil

-- WebView + usercontent bridge state (singleton)
local _webview      = nil
local _usercontent  = nil

-- Absolute path to the assets folder. The onboarding frontend (index.html,
-- script.js, style.css) lives in the cross-driver _shared/ui/ tree so the
-- Windows driver can consume the same files via its WebView2 host; resolve it
-- through Paths.shared (mirrors changelog / download_window / model_browser).
local ASSETS_DIR = (Paths.shared("ui/onboarding") or "") .. "/"

--- Resolve the absolute file:// URL to the Ergopti layout preview JPG so
--- the webview can <img src="…"> it directly. ASSETS_DIR is
--- static/ergopti_plus/_shared/ui/onboarding/ ; the image lives at
--- static/img/ergopti.jpg, four directories above (same depth as the former
--- macos/ui/onboarding/ location, so the relative path is unchanged). Returns
--- nil when the file is missing so the JS side keeps the preview hidden.
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
-- ==========================================
-- ======= 1/ Locale string injection =======
-- ==========================================
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
	-- i18n.format, not string.format: the shared locale strings use {1}, and
	-- string.format looks for %s — it left the placeholder on screen verbatim.
	strings["dialog.metrics.enable_warning_formatted"] =
		i18n.format("dialog.metrics.enable_warning", metrics_dir .. "metrics")

	i18n.set_locale_no_reload(prev_code)

	-- Wrap strings + the locale code together so the JS side can discard
	-- responses that arrived out of order (stale rapid-switch results).
	local payload = { locale = code, strings = strings }
	local ok_enc, json = pcall(hs.json.encode, payload)
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
	-- i18n.format, not string.format: the shared locale strings use {1}, and
	-- string.format looks for %s — it left the placeholder on screen verbatim.
	strings["dialog.metrics.enable_warning_formatted"] =
		i18n.format("dialog.metrics.enable_warning", metrics_dir .. "metrics")

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

--- Converts a JS truthy value to a real Lua boolean so toml_writer emits a BARE
--- TOML boolean (`true`/`false`), not a quoted "true"/"false" string. A quoted
--- "false" decodes back to the Lua STRING "false", which is truthy — so a feature
--- the user explicitly DECLINED in the wizard would silently re-activate on the
--- post-wizard reload (every boot gate is a bare `if state.flag then`).
--- @param value any
--- @return boolean
local function to_bool(value)
	return value == true or value == "true"
end

--- Builds the config.toml update list from the wizard answers, using the CANONICAL
--- HS config schema (ui/menu/preferences.lua KEY_MAP) — lowercase sections, clean
--- ``enabled`` flags. Pure (no I/O) so the schema is unit-testable: a regression
--- to AHK-style keys (which the macOS loader ignores, silently dropping every
--- wizard choice) is caught by tests/unit/ui/test_onboarding_config_schema.lua.
--- @param answers table The wizard answers (use_ergopti, magic_key, use_metrics, use_gestures).
--- @return table Array of { section, key, value } updates for toml_writer.batch_write.
function M._build_config_updates(answers)
	answers = type(answers) == "table" and answers or {}
	return {
		-- use_ergopti = "use the Ergopti hotstring engine" → [hotstrings].enabled.
		{ section = "hotstrings", key = "enabled",      value = to_bool(answers.use_ergopti)  },
		{ section = "hotstrings", key = "trigger_char", value = answers.magic_key or "★"       },
		{ section = "metrics",    key = "enabled",      value = to_bool(answers.use_metrics)   },
		{ section = "gestures",   key = "enabled",      value = to_bool(answers.use_gestures)  },
	}
end

--- Extracts wizard answers from a decoded config.toml table.
--- Reads the canonical HS lowercase schema first ([hotstrings].enabled,
--- [hotstrings].trigger_char, [metrics].enabled, [gestures].enabled) so a
--- config written by commit() round-trips correctly. Falls back to the AHK
--- PascalCase schema (Layout.ErgoptiBase, Hotstrings.MagicKey, …) for users
--- migrating a Windows config file.
--- @param parsed table Decoded TOML as a Lua table.
--- @return table { use_ergopti, magic_key, use_metrics, use_gestures }
function M._answers_from_config(parsed)
	if type(parsed) ~= "table" then return {} end
	-- Canonical lowercase sections (written by commit / _build_config_updates)
	local hs_sec  = type(parsed.hotstrings) == "table" and parsed.hotstrings or {}
	local met_sec = type(parsed.metrics)    == "table" and parsed.metrics    or {}
	local ges_sec = type(parsed.gestures)   == "table" and parsed.gestures   or {}
	-- AHK PascalCase fallback (Windows config import)
	local layout_ahk     = type(parsed.Layout)     == "table" and parsed.Layout     or {}
	local hotstr_ahk     = type(parsed.Hotstrings)  == "table" and parsed.Hotstrings or {}
	local metrics_ahk    = type(parsed.Metrics)     == "table" and parsed.Metrics    or {}
	local gestures_ahk   = type(parsed.Gestures)    == "table" and parsed.Gestures   or {}
	-- Prefer canonical schema; fall back to AHK keys only when canonical absent
	local has_canonical_ergopti = hs_sec.enabled ~= nil
	local use_ergopti = has_canonical_ergopti
		and (hs_sec.enabled == true or hs_sec.enabled == "true")
		or  (layout_ahk.ErgoptiBase == true or layout_ahk.ErgoptiAltGr == true or layout_ahk.ErgoptiPlus == true)
	local magic_key = (type(hs_sec.trigger_char) == "string" and hs_sec.trigger_char ~= "" and hs_sec.trigger_char)
		or (type(hotstr_ahk.MagicKey) == "string" and hotstr_ahk.MagicKey ~= "" and hotstr_ahk.MagicKey)
		or nil
	local use_metrics = (met_sec.enabled ~= nil)
		and (met_sec.enabled == true or met_sec.enabled == "true")
		or  (metrics_ahk.metrics_enabled == true)
	local use_gestures = (ges_sec.enabled ~= nil)
		and (ges_sec.enabled == true or ges_sec.enabled == "true")
		or  (gestures_ahk.Enabled == true)
	return {
		use_ergopti  = use_ergopti  or false,
		magic_key    = magic_key,
		use_metrics  = use_metrics  or false,
		use_gestures = use_gestures or false,
	}
end

--- Writes the wizard's answers, distinguishing a RAISE from a returned failure.
--- Extracted for the same reason as M._resolve_commit_path below: commit() is only
--- reachable through the webview callback and ends in hs.reload(), so the outcome
--- is untestable unless the write itself is injectable.
---
--- toml_codec's batch_write signals every I/O failure by RETURNING false plus a
--- reason and NEVER raises. Wrapping it in a bare pcall whose closure dropped the
--- return value therefore reported a failed write as a success: the wizard showed
--- its "done" notification, marked onboarding complete in hs.settings, and reloaded
--- with none of the user's answers on disk — the first-run choices were silently
--- lost and the wizard never offered itself again.
--- @param writer table The toml_writer module (or a test double).
--- @param path string Absolute path to config.toml.
--- @param updates table The key/value updates to persist.
--- @return boolean ok True only when the file was actually written.
--- @return string|nil err Failure reason, from either the raise or the return.
function M._commit_write(writer, path, updates)
	local ok, wrote, write_err = pcall(function()
		return writer.batch_write(path, updates)
	end)
	if not ok then return false, tostring(wrote) end
	-- nil is treated like false: a writer that returns nothing has not confirmed
	-- the write, and this path must never assume success it was not told about.
	if wrote ~= true then return false, tostring(write_err) end
	return true
end

--- Returns the config.toml path the wizard must write to, re-resolved through
--- MenuPaths so a config-dir change made moments earlier is honoured. Pure apart
--- from the injected resolver, so the retarget is testable without a webview.
--- @param menu_paths table The ui.menu.menu_paths module (or a test double).
--- @param fallback string Path to keep when the resolver yields nothing usable.
--- @return string Absolute path to config.toml.
function M._resolve_commit_path(menu_paths, fallback)
	if type(menu_paths) ~= "table" or type(menu_paths.get) ~= "function" then
		return fallback
	end
	local ok, resolved = pcall(menu_paths.get, CONFIG_TOML_PATH_KEY)
	-- A resolver that throws or hands back anything but a usable path must never
	-- redirect the write: keeping the fallback still lands the answers somewhere
	-- readable, whereas an empty target would drop them on the floor.
	if not ok or type(resolved) ~= "string" or resolved == "" then
		return fallback
	end
	if resolved ~= fallback then
		Logger.info(LOG, "Config write retargeted to '%s' (was '%s').", resolved, tostring(fallback))
	end
	return resolved
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
			if ok_persist then
				-- _config_path was captured in M.run() from the config dir as it
				-- stood BEFORE the wizard ran; the persist above just moved the
				-- resolver. Writing through the stale path would leave the NEW
				-- directory without a config.toml, so should_run() fires again and
				-- the wizard re-opens blank with every answer lost.
				_config_path = M._resolve_commit_path(menu_paths, _config_path)
			else
				Logger.warn(LOG, "Failed to persist config dir override: %s.", tostring(err))
			end
		end
	end

	local locale = type(answers.locale) == "string" and answers.locale ~= "" and answers.locale or "en"
	-- Build the updates with the CANONICAL HS schema (see M._build_config_updates).
	-- The wizard previously wrote AHK-style keys the macOS loader never reads, so
	-- every choice was silently dropped on the post-wizard reload — the
	-- "metrics + gestures not active after the wizard" bug. Locale is persisted
	-- separately (hs.settings), not via config.toml, so it is handled below.
	local updates = M._build_config_updates(answers)

	-- Switch to the chosen locale before writing so success messages are translated,
	-- AND persist it to hs.settings so it survives the reload below (the in-memory
	-- set_locale_no_reload alone is wiped by the reload — that lost the language too).
	i18n.set_locale_no_reload(locale)
	pcall(i18n.persist_locale, locale)

	local ok, err = M._commit_write(toml_writer, _config_path, updates)

	if not ok then
		Logger.error(LOG, "commit: toml_writer failed — %s.", tostring(err))
		close_webview()
		local dialog = require("lib.dialog_util")
		dialog.block_alert(
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
		-- Both values land inside AppleScript string literals, where the
		-- backslash is itself an escape character. Escaping only the double
		-- quote left a seed path containing a backslash producing a literal the
		-- picker could not parse — and the seed is the user-configurable config
		-- directory, so it is exactly the value most likely to carry one.
		local script = text_utils.applescript_format([[
			try
				set r to choose folder with prompt "%s" default location ((POSIX file "%s") as alias)
				return POSIX path of r
			on error
				return ""
			end try
		]], i18n.get("dialog.config_folder.select_title") or "", seed)
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
						-- Read the canonical lowercase schema written by commit();
						-- fall back to AHK PascalCase for Windows config migration.
						local answers = M._answers_from_config(parsed)
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
	-- Manifest is the SSoT max; clamp to a screen fraction so the window fits on
	-- small displays. See _shared/ui/apps.manifest.json (onboarding).
	local geo     = ui_builder.get_app_geometry("onboarding")
	if not geo then return end
	local win_h   = math.min(geo.height, math.floor(sf.h * 0.60))
	local win_w   = math.min(geo.width, math.floor(sf.w * 0.35))

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
