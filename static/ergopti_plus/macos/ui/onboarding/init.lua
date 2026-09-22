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
local WebviewResult = require("adapters.webview_result")

local i18n         = require("infra.i18n")
local toml_writer  = require("infra.toml.writer")
local toml_codec   = require("infra.toml.codec")
local notifications = require("infra.notifications")
local Paths        = require("infra.paths")
local Logger       = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local ManifestReader = require("infra.manifest_reader")
local FileSystem    = require("adapters.file_system")
local Storage       = require("adapters.storage")
local LOG          = "onboarding"

local SETTINGS_COMPLETED_KEY = "onboarding.completed"

-- MenuPaths.get() key that resolves <config_dir>/hammerspoon/config.toml.
local CONFIG_TOML_PATH_KEY   = "ConfigTomlPath"

-- Brand-less window title. ui_builder prefixes the product name, and
-- onboarding.welcome.title already carries it (it is the page heading).
local WINDOW_TITLE_KEY       = "onboarding.window_title"

-- Every locale string the shared wizard page reads. One list for both initData
-- and the live preview, so a locale switch cannot drop a key the first render had.
local STRING_KEYS = {
	"onboarding.welcome.title", "onboarding.welcome.heading",
	"onboarding.language.placeholder",
	"onboarding.layout.title", "onboarding.layout.desc",
	"onboarding.layout.yes",  "onboarding.layout.no",
	"onboarding.magic_key.title", "onboarding.magic_key.desc",
	"onboarding.magic_key.option_blackstar", "onboarding.magic_key.option_star",
	"onboarding.magic_key.option_ugrave", "onboarding.magic_key.option_semicolon",
	"onboarding.magic_key.option_custom", "onboarding.magic_key.choose_freely",
	"onboarding.metrics.title", "onboarding.metrics.desc",
	-- Raw {1} template: the page fills it with the metrics path of the folder
	-- chosen on the config step (window.setMetricsPath).
	"dialog.metrics.enable_warning",
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

-- Path to config.toml — set by M.run() before the wizard opens
local _config_path  = nil

-- WebView + usercontent bridge state (singleton)
local _webview      = nil
local _usercontent  = nil
local _closing_webview = nil
local _focus_owner = nil

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





-- ==========================================
-- ==========================================
-- ======= 1/ Locale string injection =======
-- ==========================================
-- ==========================================

--- Checks the exact window authority captured before external work.
local function publication_is_current(owner, view)
	return owner ~= nil and _focus_owner == owner and view ~= nil and _webview == view
end

--- Publishes one payload without treating native admission as execution success.
--- @param owner table Captured wizard owner.
--- @param view userdata|table Captured native window.
--- @param method string Fixed frontend function name.
--- @param payload table|string Frontend payload, never included in diagnostics.
local function submit_data(owner, view, method, payload)
	if not publication_is_current(owner, view) then return false end
	owner.javascript_failures = owner.javascript_failures or {}
	local function report(category)
		if not publication_is_current(owner, view) then return end
		local key = method .. ":" .. category
		if owner.javascript_failures[key] then return end
		owner.javascript_failures[key] = true
		Logger.error(LOG, "Onboarding JavaScript %s (%s; content withheld; repeats suppressed).", category, method)
	end
	-- hs.json.encode accepts only a table at the top level and RAISES on a bare
	-- string. setConfigDir takes the chosen path as a plain string, so encoding
	-- it directly failed every time and the picked folder never reached the
	-- field. Encoding the argument list as a one-element array serializes any
	-- JSON value; stripping the brackets yields the call's argument list.
	local encoded, json = pcall(hs.json.encode, { payload })
	local arguments = encoded and type(json) == "string" and json:match("^%s*%[(.*)%]%s*$") or nil
	if not arguments or arguments:match("^%s*$") then report("encoding failed"); return false end
	if not publication_is_current(owner, view) then return false end
	local admitted, settled, pending, failed = false, false, nil, false
	local function complete(_, script_error)
		if settled then return end
		if not admitted then pending = pending or { error = script_error }; return end
		settled = true
		if not publication_is_current(owner, view) then return end
		if WebviewResult.is_error(script_error) then failed = true; report("execution failed"); return end
		Logger.debug(LOG, "Onboarding JavaScript completed (%s).", method)
	end
	local ok, candidate = pcall(function()
		return view:evaluateJavaScript("window." .. method .. "(" .. arguments .. ")", complete)
	end)
	if not ok or candidate ~= view then
		settled = true
		report(ok and "submission refused" or "submission raised")
		return false
	end
	admitted = true
	if pending then complete(nil, pending.error) end
	return not failed and publication_is_current(owner, view)
end

--- Retitles the native window. WKWebView never mirrors document.title onto the
--- NSWindow, so a live language switch left the title in the opening locale.
--- @param owner table Captured wizard owner.
--- @param view userdata|table Captured native window.
--- @param title string Brand-less, already-translated title.
--- @return boolean applied
local function retitle(owner, view, title)
	if not publication_is_current(owner, view) then return false end
	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or type(ui_builder) ~= "table" or type(ui_builder.set_window_title) ~= "function" then
		Logger.error(LOG, "Onboarding window title cannot follow the locale; ui_builder is unavailable.")
		return false
	end
	return ui_builder.set_window_title(view, title)
end

--- Metrics store path for the folder typed on the config step, from the same
--- rule the keylogger uses to place the store. An empty field keeps the current
--- folder, because commit() persists no override for it.
--- @param config_dir string|nil Folder from the wizard field.
--- @return string Absolute metrics directory.
function M._metrics_path_for(config_dir)
	local ConfigPaths = require("infra.config_paths")
	local dir = (type(config_dir) == "string" and config_dir ~= "") and config_dir
		or ConfigPaths.get_config_dir()
	return ConfigPaths.metrics_dir(dir)
end

--- Loads the strings for a given locale code and injects them into the webview
--- via window.applyStrings().  Used both for the initial render and for the
--- live-preview when the user hovers over a language row.
--- @param code string Locale code, e.g. "fr".
--- @param owner table Captured wizard owner.
--- @param view userdata|table Captured native window.
local function inject_strings(code, owner, view)
	if not publication_is_current(owner, view) then return end
	local strings = {}

	-- Pull every translated string out of i18n by temporarily pointing it at
	-- the requested locale, then restoring the previous locale.
	local prev_code = i18n.get_locale()
	i18n.set_locale_no_reload(code)
	for _, k in ipairs(STRING_KEYS) do
		strings[k] = i18n.get(k)
	end
	local window_title = i18n.get(WINDOW_TITLE_KEY)

	i18n.set_locale_no_reload(prev_code)

	-- Wrap strings + the locale code together so the JS side can discard
	-- responses that arrived out of order (stale rapid-switch results).
	local payload = { locale = code, strings = strings }
	Logger.debug(LOG, "Injecting strings for locale '%s'…", code)
	submit_data(owner, view, "applyStrings", payload)
	retitle(owner, view, window_title)
end

--- Sends the full initData payload (locale + strings + default answers) to the
--- webview so the first step renders correctly on open.
local function inject_init_data()
	local owner, view = _focus_owner, _webview
	if not publication_is_current(owner, view) then return end

	local current_locale = i18n.get_locale()
	local strings = {}
	for _, k in ipairs(STRING_KEYS) do
		strings[k] = i18n.get(k)
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
			magic_key    = ManifestReader.default_for("hotstrings.trigger_char"),
			-- Pre-fill with the current config dir when it diverges from
			-- the OS default — otherwise leave empty so the placeholder
			-- shows the default and the wizard treats "no change" as the
			-- happy path.
			config_dir   = (cur_config_dir ~= default_config_dir) and cur_config_dir or "",
			use_metrics  = false,
			use_gestures = false,
		},
	}
	local resolved, metrics_path = pcall(M._metrics_path_for, payload.answers.config_dir)
	if not resolved then
		Logger.error(LOG, "Onboarding metrics path unresolved: %s.", tostring(metrics_path))
		return
	end
	payload.metrics_path = metrics_path

	Logger.debug(LOG, "Injecting initData into onboarding webview…")
	submit_data(owner, view, "initData", payload)
	-- initData resets the page to the current locale; keep the window in step.
	retitle(owner, view, i18n.get(WINDOW_TITLE_KEY))
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
--- HS config schema (infra/preferences.lua KEY_MAP) — lowercase sections, clean
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
		{ section = "hotstrings", key = "trigger_char", value = answers.magic_key or ManifestReader.default_for("hotstrings.trigger_char") },
		{ section = "metrics",    key = "enabled",      value = to_bool(answers.use_metrics)   },
		{ section = "gestures",   key = "enabled",      value = to_bool(answers.use_gestures)  },
	}
end

--- Resolves a canonical boolean, falling back to the legacy migration value
--- only when the canonical key is absent.
--- @param canonical any Canonical value, nil when absent.
--- @param legacy_enabled boolean Legacy migration value.
--- @return boolean enabled
local function canonical_boolean_or_legacy(canonical, legacy_enabled)
	if canonical ~= nil then
		return canonical == true or canonical == "true"
	end
	return legacy_enabled == true
end

--- Extracts wizard answers from a decoded config.toml table.
--- Reads the canonical HS lowercase schema first ([hotstrings].enabled,
--- [hotstrings].trigger_char, [metrics].enabled, [gestures].enabled) so a
--- config written by commit() round-trips correctly. Falls back to the AHK
--- PascalCase schema (Layout.ErgoptiBase, Hotstrings.MagicKey, …) for users
--- migrating a Windows config file. Every key is read unconditionally, so the
--- keys marked for the unused-key cleanup never depend on another key's value.
--- @param parsed table Decoded TOML as a Lua table.
--- @param mark function|nil mark(...segments) for each key present and read.
--- @return table { use_ergopti, magic_key, use_metrics, use_gestures }
function M._answers_from_config(parsed, mark)
	if type(parsed) ~= "table" then return {} end
	local function section(name)
		local values = type(parsed[name]) == "table" and parsed[name] or {}
		return function(key)
			local value = values[key]
			if value ~= nil and mark then mark(name, key) end
			return value
		end
	end
	-- Canonical lowercase sections (written by commit / _build_config_updates)
	local hs_sec  = section("hotstrings")
	local met_sec = section("metrics")
	local ges_sec = section("gestures")
	-- AHK PascalCase fallback (Windows config import)
	local layout_ahk   = section("Layout")
	local hotstr_ahk   = section("Hotstrings")
	local metrics_ahk  = section("Metrics")
	local gestures_ahk = section("Gestures")
	local legacy_base  = layout_ahk("ErgoptiBase") == true
	local legacy_altgr = layout_ahk("ErgoptiAltGr") == true
	local legacy_plus  = layout_ahk("ErgoptiPlus") == true
	local trigger_char = hs_sec("trigger_char")
	local legacy_magic = hotstr_ahk("MagicKey")
	-- Prefer canonical schema; fall back to AHK keys only when canonical absent
	local use_ergopti = canonical_boolean_or_legacy(hs_sec("enabled"),
		legacy_base or legacy_altgr or legacy_plus)
	local magic_key = (type(trigger_char) == "string" and trigger_char ~= "" and trigger_char)
		or (type(legacy_magic) == "string" and legacy_magic ~= "" and legacy_magic)
		or nil
	local use_metrics = canonical_boolean_or_legacy(met_sec("enabled"),
		metrics_ahk("metrics_enabled") == true)
	local use_gestures = canonical_boolean_or_legacy(ges_sec("enabled"),
		gestures_ahk("Enabled") == true)
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
	local _, read_status, read_detail = FileSystem.read_with_status(path)
	if read_status ~= "ok" and read_status ~= "absent" then
		return false, tostring(read_detail or "destination is not safely readable")
	end
	local ok, wrote, write_err = pcall(function()
		return writer.batch_write(path, updates)
	end)
	if not ok then return false, tostring(wrote) end
	-- nil is treated like false: a writer that returns nothing has not confirmed
	-- the write, and this path must never assume success it was not told about.
	if wrote ~= true then return false, tostring(write_err) end
	return true
end

--- Persists the wizard's selected config directory and requires an explicit
--- acknowledgement from the menu_paths bridge. pcall success is insufficient:
--- the filesystem writer reports ordinary I/O failures by returning false.
--- @param menu_paths table Resolver/UI bridge.
--- @param new_dir string User-selected directory.
--- @return boolean persisted
--- @return string|nil err
function M._persist_config_dir(menu_paths, new_dir)
	if type(menu_paths) ~= "table"
			or type(menu_paths.persist_config_dir_for_wizard) ~= "function" then
		return false, "config path persistence is unavailable"
	end
	local ok, persisted, detail = pcall(menu_paths.persist_config_dir_for_wizard, new_dir)
	if not ok then return false, tostring(persisted) end
	if persisted ~= true then return false, tostring(detail or "write was not confirmed") end
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

--- Releases a staged or committed native message callback.
--- @param usercontent userdata|table|nil
--- @return boolean released
local function release_usercontent(usercontent)
	if not usercontent then return true end
	if type(usercontent.setCallback) ~= "function" then
		Logger.error(LOG, "Cannot release onboarding usercontent callback.")
		return false
	end
	local ok, err = xpcall(function() usercontent:setCallback(nil) end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Failed to release onboarding usercontent callback: %s.", tostring(err))
		return false
	end
	return true
end

--- Closes the webview cleanly.
--- @return boolean committed
local function close_webview()
	_focus_owner = nil
	local webview = _webview
	local usercontent = _usercontent
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Onboarding close refused; owned WebView has no delete method.")
			return false
		end
		_closing_webview = webview
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		if _closing_webview == webview then _closing_webview = nil end
		if not ok then
			_webview = webview
			_usercontent = usercontent
			Logger.error(LOG, "Onboarding close did not commit; exact WebView retained: %s.",
				tostring(err))
			return false
		end
		if _webview == webview then _webview = nil end
	end
	if usercontent and _usercontent == usercontent then
		if not release_usercontent(usercontent) then return false end
		_usercontent = nil
	end
	return true
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
		local persisted, persist_err = M._persist_config_dir(
			ok_mp and menu_paths or nil,
			answers.config_dir
		)
		if not persisted then
			Logger.error(LOG, "Failed to persist config dir override: %s.", tostring(persist_err))
			close_webview()
			local dialog = require("infra.dialog_util")
			dialog.block_alert(
				i18n.get("paths_editor.save_failed_title"),
				i18n.get("paths_editor.save_failed"),
				i18n.get("onboarding.btn.ok")
			)
			return
		end
		-- _config_path was captured in M.run() from the config dir as it stood
		-- BEFORE the wizard ran; persistence above moved the resolver. Writing
		-- through the stale path would leave the NEW directory without config.toml,
		-- so should_run() would reopen the wizard with every answer lost.
		_config_path = M._resolve_commit_path(menu_paths, _config_path)
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
	local locale_ok, locale_persisted = xpcall(function()
		return i18n.persist_locale(locale)
	end, debug.traceback)
	if not locale_ok or locale_persisted ~= true then
		Logger.error(LOG, "commit: locale persistence failed — %s.",
			tostring(locale_persisted))
		close_webview()
		local dialog = require("infra.dialog_util")
		dialog.block_alert(
			i18n.get("onboarding.error.title"),
			i18n.get("onboarding.error.locale_persist_failed"),
			i18n.get("onboarding.btn.ok")
		)
		return
	end

	local ok, err = M._commit_write(toml_writer, _config_path, updates)

	if not ok then
		Logger.error(LOG, "commit: toml_writer failed — %s.", tostring(err))
		close_webview()
		local dialog = require("infra.dialog_util")
		dialog.block_alert(
			i18n.get("onboarding.error.title"),
			i18n.get("onboarding.error.write_failed") .. "\n\n" .. tostring(err),
			i18n.get("onboarding.btn.ok")
		)
		return
	end

	Logger.success(LOG, "Onboarding answers written successfully.")
	Storage.set(SETTINGS_COMPLETED_KEY, true)
	close_webview()

	notifications.notify(i18n.get("onboarding.done.title"), i18n.get("onboarding.done.body"))
	DeferredWork.after(1.5, function()
		hs.reload()
	end, "onboarding.reload")
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
	local owner, view = _focus_owner, _webview
	local action = body.action
	Logger.debug(LOG, "usercontent message: action='%s'.", tostring(action))

	if action == "ready" then
		-- JS page finished loading — inject initial data
		DeferredWork.after(0.05, function()
			if publication_is_current(owner, view) then inject_init_data() end
		end, "onboarding.ready")

	elseif action == "previewLocale" then
		-- User hovered/clicked a language row — inject its strings live
		local code = type(body.locale) == "string" and body.locale or "en"
		inject_strings(code, owner, view)

	elseif action == "localeSelected" then
		-- User confirmed language and moved to step 2 — switch locale in memory
		local code = type(body.locale) == "string" and body.locale or "en"
		i18n.set_locale_no_reload(code)
		Logger.info(LOG, "Onboarding locale set to '%s'.", code)

	elseif action == "pickConfigDir" then
		-- The path editor's picker is the single native folder dialog: the
		-- wizard's former copy read the raw AppleEvent descriptor instead of the
		-- parsed result, so the two could disagree on the very same answer.
		local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
		if not ok_mp or type(menu_paths) ~= "table" or type(menu_paths.pick_config_dir) ~= "function" then
			Logger.error(LOG, "pickConfigDir: the native folder picker is unavailable.")
			return
		end
		local seed = type(body.current) == "string" and body.current or ""
		local picked, chosen = pcall(menu_paths.pick_config_dir, seed,
			i18n.get("dialog.config_folder.select_title"))
		if not picked then
			Logger.error(LOG, "pickConfigDir: the native folder picker failed: %s.", tostring(chosen))
			return
		end
		Logger.debug(LOG, "pickConfigDir: %s.", type(chosen) == "string" and "folder chosen" or "cancelled")
		if type(chosen) == "string" and chosen ~= "" then
			submit_data(owner, view, "setConfigDir", chosen)
		end

	elseif action == "resolveMetricsPath" then
		-- The config step was confirmed: name the metrics store of THAT folder in
		-- the step-4 consent warning. The request number is echoed so the page can
		-- drop a reply for a folder the user has since changed.
		if type(body.request) ~= "number" then
			Logger.error(LOG, "resolveMetricsPath: request number missing.")
			return
		end
		local resolved, path = pcall(M._metrics_path_for, body.config_dir)
		if not resolved then
			Logger.error(LOG, "resolveMetricsPath: metrics path unresolved: %s.", tostring(path))
			return
		end
		submit_data(owner, view, "setMetricsPath", { request = body.request, path = path })

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
			if not publication_is_current(owner, view) then return false end
			local reported = false
			local function import_failure(category)
				if not publication_is_current(owner, view) then return end
				reported = true
				local categories = { inspect = true, open = true, read = true, close = true,
					path_changed = true, identity_changed = true, validation = true,
					absent = true, decode = true, answers = true }
				local label = categories[category] and category or "dependency"
				owner.import_failures = owner.import_failures or {}
				if owner.import_failures[label] then return end
				owner.import_failures[label] = true
				if label == "absent" then
					Logger.debug(LOG, "Onboarding existing configuration absent; defaults retained (repeats suppressed).")
					return
				end
				Logger.error(LOG, "Onboarding existing configuration import failed (%s; content withheld; repeats suppressed).", label)
			end
			local read_ok, content, status = pcall(FileSystem.read_with_status, cfg_path, import_failure)
			if not publication_is_current(owner, view) then return false end
			if not read_ok then import_failure("dependency"); return false end
			if status ~= "ok" or type(content) ~= "string" then
				if not reported then import_failure(status == "absent" and "absent" or "read") end
				return false
			end
			local decoded, parsed = pcall(toml_codec.decode, content)
			if not publication_is_current(owner, view) then return false end
			if not decoded or type(parsed) ~= "table" then import_failure("decode"); return false end
			local projected, answers = pcall(M._answers_from_config, parsed)
			if not publication_is_current(owner, view) then return false end
			if not projected or type(answers) ~= "table" then import_failure("answers"); return false end
			local clean = {}
			for key, value in pairs(answers) do
				if value ~= nil then clean[key] = value end
			end
			return submit_data(owner, view, "applyExistingAnswers", clean)
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
--- @return boolean opened True only when the wizard window is active.
function M.run(config_path)
	if type(config_path) ~= "string" or config_path == "" then
		Logger.error(LOG, "M.run() called with missing config_path.")
		return false
	end
	_config_path = config_path

	-- Bring the existing window to front if the wizard is already open
	if _webview then
		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if ok_ui then
			local view, focus_owner = _webview, _focus_owner
			ui_builder.force_focus(view, false, { is_current = function()
				return focus_owner ~= nil and _focus_owner == focus_owner and _webview == view
			end })
		else pcall(function() _webview:bringToFront() end) end
		return true
	end
	if _usercontent and close_webview() ~= true then
		Logger.error(LOG, "Cannot open onboarding while bridge cleanup remains pending.")
		return false
	end

	Logger.start(LOG, "Opening onboarding wizard…")

	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or not ui_builder then
		Logger.error(LOG, "Failed to load ui_builder module.")
		return false
	end

	local screen  = hs.screen.mainScreen()
	local sf      = screen and type(screen.frame) == "function" and screen:frame() or { w = 1440, h = 900 }
	-- Manifest is the SSoT max; clamp to a screen fraction so the window fits on
	-- small displays. See _shared/ui/apps.manifest.json (onboarding).
	local geo     = ui_builder.get_app_geometry("onboarding")
	if not geo then
		Logger.error(LOG, "Onboarding window not opened — geometry unavailable.")
		return false
	end
	local win_h   = math.min(geo.height, math.floor(sf.h * 0.60))
	local win_w   = math.min(geo.width, math.floor(sf.w * 0.35))

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsOnboarding")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create usercontent bridge.")
		return false
	end
	local focus_owner = {}
	local webview
	local cleanup_retrying = false
	local callback_ok = pcall(function()
		uc:setCallback(function(message)
			if _focus_owner ~= focus_owner then
				local body = type(message) == "table" and message.body or nil
				if _focus_owner == nil and _usercontent == uc and webview ~= nil and _webview == webview
					and _closing_webview == nil and not cleanup_retrying and type(body) == "table"
					and (body.action == "finish" or body.action == "cancel") then
					-- Retained native ownership permits cleanup, never another configuration commit
					cleanup_retrying = true
					close_webview()
					cleanup_retrying = false
				end
				return
			end
			if message and type(message.body) == "table" then
				handle_message(message.body)
			end
		end)
	end)
	if callback_ok ~= true then
		Logger.error(LOG, "Failed to register onboarding bridge callback.")
		if not release_usercontent(uc) then _usercontent = uc end
		return false
	end

	local masks       = hs.webview.windowMasks
	local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)

	local closed = false
	_focus_owner = focus_owner
	local show_ok, candidate = xpcall(function()
		return ui_builder.show_webview({
			frame       = ui_builder.get_centered_frame(win_w, win_h),
			title       = i18n.get(WINDOW_TITLE_KEY),
			style_masks = style_masks,
			usercontent = uc,
			assets_dir    = ASSETS_DIR,
			is_current = function()
				return _focus_owner == focus_owner and not closed
			end,
			on_close      = function()
				if webview ~= nil and _closing_webview == webview then return end
				if _focus_owner == focus_owner then _focus_owner = nil end
				closed = true
				if _webview == webview then _webview = nil end
				if _usercontent == uc then
					if release_usercontent(uc) then _usercontent = nil end
				end
			end,
			on_navigation = function(action)
				if _focus_owner ~= focus_owner or closed then return false end
				if action == "didFinishNavigation" then
					Logger.debug(LOG, "Navigation finished — injecting initData.")
					DeferredWork.after(0.05, function()
						if publication_is_current(focus_owner, webview) then inject_init_data() end
					end, "onboarding.navigation")
				end
				return true
			end,
		})
	end, debug.traceback)
	webview = candidate
	if show_ok ~= true or webview == nil or webview == false or closed then
		if _focus_owner == focus_owner then _focus_owner = nil end
		if webview and not closed then
			local delete_ok, delete_err = xpcall(function() webview:delete() end, debug.traceback)
			if not delete_ok then
				_webview = webview
				_usercontent = uc
				Logger.error(LOG, "Onboarding refused candidate cleanup; exact owners retained: %s.",
					tostring(delete_err))
				return false
			end
		end
		if not release_usercontent(uc) then _usercontent = uc end
		Logger.error(LOG, "Onboarding webview creation failed: %s.",
			tostring(webview))
		return false
	end
	_usercontent = uc
	_webview = webview

	Logger.success(LOG, "Onboarding wizard opened.")
	return true
end

--- Starts the onboarding wizard regardless of whether config.toml exists.
--- Useful when the user triggers the wizard manually from a menu item.
--- @param config_path string Absolute path to the user's config.toml.
--- @return boolean opened
function M.run_from_menu(config_path)
	return M.run(config_path)
end

return M
