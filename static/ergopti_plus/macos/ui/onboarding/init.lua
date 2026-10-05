--- ui/onboarding/init.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard
--- DESCRIPTION:
--- Hosts the shared first-run wizard (_shared/ui/onboarding) on macOS: one
--- opt-in page per configuration scope after the language and folder steps.
---
--- FEATURES & RATIONALE:
--- 1. Consistent UI: Uses the same webview + usercontent bridge pattern as all
---    other Ergopti panels — one coherent design language throughout the app.
--- 2. Live Locale Switch: Selecting a language in step 1 triggers a "previewLocale"
---    message; Lua loads the strings and injects them back via applyStrings() so
---    subsequent steps render in the chosen language without a reload.
--- 3. No interpretation: the page answers with manifest paths and values; the
---    shared onboarding_answers contract validates them against the generated
---    catalogue and they reach config.toml in one versioned batch_write, then
---    hs.reload() starts every module from the file. The Tap-Holds page's
---    checked keys go to the remap owner, which imports their recommendation
---    into config_karabiner.toml and switches the Tap-Holds on there. A key
---    whose recommended hold enters the navigation layer brings Ergopti's
---    recommended layer along when the folder has no layers.toml of its own.
--- 4. Re-run shows the values in force: the page receives the configured value
---    of every wizard path, for the folder it opens on and for any folder the
---    user picks, the tap-hold keys and switch included, which the remap owner
---    reports from that folder's config_karabiner.toml.
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
local Answers       = require("onboarding_answers")
local Json          = require("json")
local LOG          = "onboarding"

-- The catalogue platform this host reads and the id the config migration
-- registry knows this driver by.
local CATALOGUE_DRIVER = "macos"
local MIGRATION_DRIVER = "hs"

-- MenuPaths.get() key that resolves <config_dir>/hammerspoon/config.toml.
local CONFIG_TOML_PATH_KEY   = "ConfigTomlPath"

-- Brand-less window title. ui_builder prefixes the product name, and
-- onboarding.welcome.title already carries it (it is the document title).
local WINDOW_TITLE_KEY       = "onboarding.window_title"

-- Delay between the success notification and the reload that applies it.
local RELOAD_DELAY_SEC = 1.5

-- How long the running bridge may take to answer the tap-hold import before
-- the wizard reloads without its answer: its deployment waits on the remap
-- guardian (20 s at most to register) and the lease, never on the user.
local TAP_HOLD_IMPORT_TIMEOUT_SEC = 30

-- Path to config.toml — set by M.run() before the wizard opens
local _config_path  = nil

-- The generated catalogue of this driver, loaded by the first run.
local _catalogue = nil

-- Keeps each tap-hold import's backup of config_karabiner.toml unique.
local _backup_sequence = 0

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
	-- The shared codec preserves the wizard's map-shaped current values:
	-- LuaSkin would encode an empty Lua map as [], violating the page contract.
	-- It also accepts the folder picker's scalar string without an array wrapper.
	local encoded, json = pcall(Json.encode, payload)
	local arguments = encoded and type(json) == "string" and json or nil
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

--- Reads one shipped data file of the shared tree, through the read-only
--- accessor every module uses for shipped data (configuration goes through
--- read_with_status).
--- @param relative string Path under _shared/.
--- @return string|nil content
--- @return string|nil detail Why the file could not be read.
local function read_shared(relative)
	local path = Paths.shared(relative)
	local content = FileSystem.read(path)
	if type(content) ~= "string" then return nil, tostring(path) .. " is unreadable" end
	return content
end

--- The wizard catalogue of this driver, read once from the generated file.
--- Raises when the file is missing or malformed: the wizard cannot ask or
--- validate anything without it.
--- @return table index From onboarding_answers.load.
local function catalogue()
	if _catalogue then return _catalogue end
	local text, detail = read_shared(Answers.CATALOGUE_PATH)
	if not text then error("the onboarding catalogue is unreadable: " .. tostring(detail)) end
	_catalogue = Answers.load(text, CATALOGUE_DRIVER)
	return _catalogue
end

--- The complete string table of a locale, straight from its locale file: the
--- page resolves every label the catalogue names, so no hand-kept subset can
--- drop one.
--- @param code string Locale code.
--- @return table|nil strings
local function locale_strings(code)
	local text, detail = read_shared("data/locales/" .. tostring(code) .. ".json")
	local strings = text and Json.decode(text) or nil
	if type(strings) ~= "table" then
		Logger.error(LOG, "Onboarding locale '%s' is unavailable (%s).", tostring(code),
			tostring(text and "invalid JSON" or detail))
		return nil
	end
	return strings
end

--- Whether a locale code is one this build ships.
--- @param code any
--- @return boolean
local function known_locale(code)
	if type(code) ~= "string" then return false end
	for _, entry in ipairs(require("_generated.locale_table")) do
		if entry.code == code then return true end
	end
	return false
end

--- The configured value of every wizard path of a decoded config.toml. The
--- wizard reads the file on a re-run, so the unused-key cleanup marks what it
--- takes through the same projection.
--- @param decoded table Decoded config.toml.
--- @param mark function|nil mark(...segments) for each key present and read.
--- @return table values `{ [path] = value }`.
function M.config_values(decoded, mark)
	return Answers.current_values(catalogue(), decoded, mark)
end

--- The config_karabiner.toml beside a config.toml: the remap settings of the
--- same configuration folder, named as the path resolver names them.
--- @param config_path string Absolute config.toml path.
--- @return string
local function remap_settings_beside(config_path)
	local name = require("infra.config_paths").get("KarabinerConfigPath"):match("([^/\\]+)$")
	local folder = type(config_path) == "string" and config_path:match("^(.*)[/\\][^/\\]+$") or nil
	assert(name and folder, "no remap settings file beside " .. tostring(config_path))
	return folder .. "/" .. name
end

--- The wizard values of the tap-hold keys and switch the remap owner reports
--- beside a config.toml: a configured key is shown as kept, never imported over.
--- @param config_path string Absolute config.toml path.
--- @return table|nil values nil when the remap settings cannot be read.
local function tap_hold_values(config_path)
	local ok, report, err = pcall(function()
		return require("platform.remap").recommended_key_report(remap_settings_beside(config_path))
	end)
	if not ok or type(report) ~= "table" then
		Logger.error(LOG, "The tap-hold keys in force could not be read: %s.", tostring(ok and err or report))
		return nil
	end
	return Answers.tap_hold_values(catalogue(), report)
end

--- Adds the tap-hold values beside a config.toml to its configured values.
--- @param values table Values of config.toml, completed in place.
--- @param config_path string Absolute config.toml path.
--- @return table|nil values nil when the remap settings cannot be read.
local function with_tap_hold_values(values, config_path)
	local tap_holds = tap_hold_values(config_path)
	if not tap_holds then return nil end
	for path, value in pairs(tap_holds) do values[path] = value end
	return values
end

--- The configured value of every wizard path in a config file and in the
--- remap settings beside it.
--- @param path string Absolute config.toml path.
--- @return table|nil values Empty for absent files, nil when one is unreadable.
local function current_values(path)
	local content, status = FileSystem.read_with_status(path)
	if status == "absent" then return with_tap_hold_values({}, path) end
	if status ~= "ok" or type(content) ~= "string" then
		Logger.error(LOG, "The configuration in force could not be read (%s).", tostring(status))
		return nil
	end
	local decoded_ok, decoded = pcall(toml_codec.decode, content)
	if not decoded_ok or type(decoded) ~= "table" then
		Logger.error(LOG, "The configuration in force could not be decoded.")
		return nil
	end
	return with_tap_hold_values(M.config_values(decoded), path)
end
M._current_values = current_values

--- Loads the strings for a given locale code and injects them into the webview
--- via window.applyStrings(). Used both for the initial render and for the
--- live preview when the user clicks a language row.
--- @param code string Locale code, e.g. "fr".
--- @param owner table Captured wizard owner.
--- @param view userdata|table Captured native window.
local function inject_strings(code, owner, view)
	if not publication_is_current(owner, view) then return end
	local strings = locale_strings(code)
	if not strings then return end
	-- Wrap strings + the locale code together so the JS side can discard
	-- responses that arrived out of order (stale rapid-switch results).
	Logger.debug(LOG, "Injecting strings for locale '%s'…", code)
	submit_data(owner, view, "applyStrings", { locale = code, strings = strings })
	retitle(owner, view, strings[WINDOW_TITLE_KEY] or WINDOW_TITLE_KEY)
end

--- Sends the initData payload (locale, strings, folders and the values in
--- force) so the first step renders correctly on open.
local function inject_init_data()
	local owner, view = _focus_owner, _webview
	if not publication_is_current(owner, view) then return end

	local current_locale = i18n.get_locale()
	local strings = locale_strings(current_locale)
	if not strings then return end

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

	-- The active input source ("U.S.", "French", "Ergopti") lets the hotstrings
	-- page propose a trigger character the user can type.
	local system_layout = ""
	pcall(function()
		local v = hs.keycodes.currentLayout()
		if type(v) == "string" then system_layout = v end
	end)

	local values = current_values(_config_path)
	if not values then return end

	local config_dir = (cur_config_dir ~= default_config_dir) and cur_config_dir or ""
	local resolved, metrics_path = pcall(M._metrics_path_for, config_dir)
	if not resolved then
		Logger.error(LOG, "Onboarding metrics path unresolved: %s.", tostring(metrics_path))
		return
	end

	Logger.debug(LOG, "Injecting initData into onboarding webview…")
	submit_data(owner, view, "initData", {
		platform           = CATALOGUE_DRIVER,
		locale             = current_locale,
		strings            = strings,
		-- One locale order for the wizard and every tray language menu.
		locales            = i18n.get_sorted_locales(),
		default_config_dir = default_config_dir,
		-- Empty when the folder is the OS default: the placeholder shows it.
		config_dir         = config_dir,
		system_layout      = system_layout,
		current            = values,
		metrics_path       = metrics_path,
	})
	-- initData resets the page to the current locale; keep the window in step.
	retitle(owner, view, strings[WINDOW_TITLE_KEY] or WINDOW_TITLE_KEY)
end




-- ============================================
-- ============================================
-- ======= 2/ Finish and commit =============
-- ============================================
-- ============================================

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

--- Closes the wizard and tells the user why nothing was saved.
--- @param title_key string Alert title key.
--- @param body string Localised alert body.
local function fail_commit(title_key, body)
	close_webview()
	require("infra.dialog_util").block_alert(i18n.get(title_key), body, i18n.get("onboarding.btn.ok"))
end

--- Versions a config.toml the wizard is about to write: the boot migration
--- ran on the folder the session started with, and the wizard may target
--- another one. A file this build cannot version is refused, never rewritten.
--- @param path string Destination config.toml.
--- @return boolean writable
--- @return string|nil detail
local function prepare_destination(path)
	local ConfigMigrate = require("config_migrate")
	local result = ConfigMigrate.boot({
		path          = path,
		driver        = MIGRATION_DRIVER,
		registry_path = Paths.shared(ConfigMigrate.REGISTRY_PATH),
		file_adapter  = FileSystem,
	})
	if result.read_only then return false, result.detail end
	return true
end

--- Imports the checked tap-hold keys through the remap owner. The running
--- bridge takes them in its settings transaction when it runs the folder the
--- wizard set up; before it starts (the first run), once it stopped, or for a
--- folder the wizard moves the configuration to, the owner saves them to that
--- folder's file, which the reload reads.
--- Either way the owner backs the file up first.
--- @param keys table Key ids of tap_hold_keys.json, at least one.
--- @param moved boolean Whether the wizard moved the configuration folder.
--- @param on_done function Callback fn(ok, detail), called exactly once.
local function import_tap_holds(keys, moved, on_done)
	local ok_remap, Remap = pcall(require, "platform.remap")
	if not ok_remap or type(Remap) ~= "table" then
		on_done(false, "the remap owner is unavailable: " .. tostring(Remap))
		return
	end
	local ok_path, path = pcall(require("infra.config_paths").get, "KarabinerConfigPath")
	if not ok_path then
		on_done(false, "the remap settings file cannot be resolved: " .. tostring(path))
		return
	end
	_backup_sequence = _backup_sequence + 1
	local backup_path = string.format("%s.tap_holds-%d-%d.bak", path, os.time(), _backup_sequence)
	if Remap.is_running() and not moved then
		Remap.import_recommended_keys({ keys = keys, backup_path = backup_path },
			function(ok, reason) on_done(ok == true, reason) end)
		return
	end
	local saved_ok, saved, detail = pcall(Remap.save_recommended_keys,
		{ keys = keys, path = path, backup_path = backup_path })
	on_done(saved_ok and saved == true, saved_ok and detail or saved)
end

--- Creates layers.toml from Ergopti's recommended navigation layer when one of
--- the imported keys' recommended hold enters that layer and the configuration
--- folder has none: without it the key would enter an empty layer, since an
--- absent layers.toml binds no key. An existing file is the user's and stays.
--- @param keys table Key ids of tap_hold_keys.json the wizard imports.
--- @return table|nil import What the nav layer owner imported, nil when nothing was due.
--- @return boolean failed True when the layer was due and could not be written.
local function import_nav_layer(keys)
	local ok, import, failed = pcall(function()
		local NavLayer = require("platform.remap.nav_layer")
		if not NavLayer.recommendation_enters_layer(keys, require("platform.remap.defaults").tap_hold) then
			return nil, false
		end
		local imported = NavLayer.import_recommended({ config_dir = require("infra.config_paths").get_config_dir() })
		return imported, imported == nil
	end)
	if not ok then
		Logger.error(LOG, "The recommended navigation layer could not be imported: %s.", tostring(import))
		return nil, true
	end
	return import, failed
end

--- Shows a notice once deferred work runs: never inside the callback of an
--- owner that is still dispatching, such as a Karabiner terminal.
--- @param key string Locale key of the notice.
--- @param after function|nil Work to run once the user dismissed it.
local function deferred_notice(key, after)
	local scheduled = DeferredWork.after(0, function()
		require("infra.dialog_util").block_alert(i18n.get("onboarding.error.title"), i18n.get(key),
			i18n.get("onboarding.btn.ok"))
		if after then after() end
	end, "onboarding.notice")
	if scheduled ~= true then
		Logger.error(LOG, "The notice '%s' could not be scheduled.", key)
		if after then after() end
	end
end

--- Reloads Hammerspoon so every module starts from the saved answers. Once the
--- termination coordinator runs, the reload is an owned request: a refusal or
--- an abort tells the user the answers still wait for a reload. Without it no
--- Karabiner lease was taken this session, and the reload wrapper reloads
--- natively, as it does for every caller.
local function reload_applying_answers()
	local TerminationCoordinator = require("infra.termination_coordinator")
	if TerminationCoordinator.is_initialized() ~= true then
		hs.reload()
		return
	end
	local told = false
	local function reload_still_needed(detail)
		if told then return end
		told = true
		Logger.error(LOG, "The reload that applies the onboarding answers did not run: %s.", tostring(detail))
		deferred_notice("onboarding.error.reload_pending")
	end
	local call_ok, accepted = pcall(TerminationCoordinator.request_reload_owned, "onboarding",
		reload_still_needed)
	-- An accepted reload may already have finalized this environment: nothing
	-- runs after it.
	if not call_ok or accepted ~= true then
		reload_still_needed(call_ok and "the reload request was refused" or accepted)
	end
end

--- Validates the answers, persists the folder and the language, writes every
--- answer to config.toml in one batch, imports the checked tap-hold keys and
--- reloads Hammerspoon.
--- @param answers table The answers object from the JS "finish" message.
local function commit(answers)
	Logger.start(LOG, "Committing the onboarding answers…")

	-- Validate the whole payload before any side effect: a refused answer must
	-- not leave the folder or the language changed behind it.
	local catalogue_ok, index = pcall(catalogue)
	local rows, refusal, tap_hold_keys
	if catalogue_ok then
		rows, refusal = Answers.rows(index, answers.operations, ManifestReader)
		tap_hold_keys = rows and Answers.tap_hold_keys(index, answers.operations, ManifestReader)
	else
		refusal = index
	end
	if not rows or not known_locale(answers.locale) or type(answers.config_dir) ~= "string" then
		Logger.error(LOG, "Onboarding answers refused: %s.",
			tostring(refusal or "the language or the folder is invalid"))
		fail_commit("onboarding.error.title", i18n.get("onboarding.error.invalid_answers"))
		return
	end

	-- Persist the chosen config dir to paths.toml BEFORE writing
	-- config.toml: the path resolver picks the new location up on the
	-- final reload, so subsequent saves go there straight away. An
	-- empty / unchanged path is a no-op (menu_paths handles the
	-- "drop the override" case internally).
	local previous_config_path = _config_path
	if answers.config_dir ~= "" then
		local ok_mp, menu_paths = pcall(require, "ui.menu.menu_paths")
		local persisted, persist_err = M._persist_config_dir(
			ok_mp and menu_paths or nil,
			answers.config_dir
		)
		if not persisted then
			Logger.error(LOG, "Failed to persist config dir override: %s.", tostring(persist_err))
			fail_commit("paths_editor.save_failed_title", i18n.get("paths_editor.save_failed"))
			return
		end
		-- _config_path was captured in M.run() from the config dir as it stood
		-- BEFORE the wizard ran; persistence above moved the resolver. Writing
		-- through the stale path would leave the NEW directory without config.toml,
		-- so should_run() would reopen the wizard with every answer lost.
		_config_path = M._resolve_commit_path(menu_paths, _config_path)
	end

	-- Switch to the chosen locale before writing so success messages are translated,
	-- AND persist it to hs.settings so it survives the reload below (the in-memory
	-- set_locale_no_reload alone is wiped by the reload — that lost the language too).
	i18n.set_locale_no_reload(answers.locale)
	local locale_ok, locale_persisted = xpcall(function()
		return i18n.persist_locale(answers.locale)
	end, debug.traceback)
	if not locale_ok or locale_persisted ~= true then
		Logger.error(LOG, "commit: locale persistence failed — %s.",
			tostring(locale_persisted))
		fail_commit("onboarding.error.title", i18n.get("onboarding.error.locale_persist_failed"))
		return
	end

	local committed, err = Answers.commit({
		index      = index,
		operations = answers.operations,
		manifest   = ManifestReader,
		path       = _config_path,
		prepare    = prepare_destination,
		write      = function(path, batch) return toml_writer.batch_write(path, batch) end,
	})
	if not committed then
		Logger.error(LOG, "commit: the configuration batch failed — %s.", tostring(err))
		fail_commit("onboarding.error.title", i18n.get("onboarding.error.write_failed") .. "\n\n" .. tostring(err))
		return
	end

	Logger.success(LOG, "Onboarding answers committed (%d configuration row(s)).", #rows)
	close_webview()

	local function announce_and_reload()
		notifications.notify(i18n.get("onboarding.done.title"), i18n.get("onboarding.done.body"))
		if DeferredWork.after(RELOAD_DELAY_SEC, reload_applying_answers, "onboarding.reload") ~= true then
			Logger.error(LOG, "The reload that applies the onboarding answers could not be scheduled.")
			deferred_notice("onboarding.error.reload_pending")
		end
	end
	if #tap_hold_keys == 0 then
		announce_and_reload()
		return
	end
	-- The layer the imported keys enter is written first, so a live bridge's
	-- regeneration already deploys it; a refused key import takes it back.
	local layer, layer_failed = import_nav_layer(tap_hold_keys)
	-- The answers are saved: a refused import leaves config_karabiner.toml as
	-- it was, says so, and the reload still applies the rest. A bridge that
	-- never answers cannot hold the reload back past the timeout either.
	local settled = false
	local function settle(ok, detail, notice_key)
		settled = true
		if ok then
			Logger.success(LOG, "Imported %d recommended tap-hold key(s).", #tap_hold_keys)
			if layer_failed then
				deferred_notice("onboarding.error.nav_layer_import", announce_and_reload)
				return
			end
			announce_and_reload()
			return
		end
		Logger.error(LOG, "The recommended tap-hold keys were not imported: %s.", tostring(detail))
		deferred_notice(notice_key, announce_and_reload)
	end
	local armed = DeferredWork.after(TAP_HOLD_IMPORT_TIMEOUT_SEC, function()
		if settled then return end
		settle(false, string.format("no answer within %d s", TAP_HOLD_IMPORT_TIMEOUT_SEC),
			"onboarding.error.tap_holds_import_timeout")
	end, "onboarding.tap_holds_import_timeout")
	if armed ~= true then
		Logger.error(LOG, "The tap-hold import timeout could not be armed; the import runs without it.")
	end
	import_tap_holds(tap_hold_keys, _config_path ~= previous_config_path, function(ok, detail)
		-- Only a refusal takes the layer back: after a timeout the keys may
		-- still land, and they must not enter an empty layer then.
		if not ok then require("platform.remap.nav_layer").undo_import(layer) end
		if settled then
			Logger.warn(LOG, "The tap-hold import answered after the wizard went on without it: %s.",
				tostring(detail))
			return
		end
		settle(ok, detail, "onboarding.error.tap_holds_import")
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
		-- User confirmed another config directory on the config step. The pages
		-- restart from ``<dir>/hammerspoon/config.toml``: its values when it
		-- exists, the neutral ones when it does not. The request number is
		-- echoed so the page drops a reply for a folder it has since left.
		if type(body.request) ~= "number" then
			Logger.error(LOG, "loadExistingConfig: request number missing.")
			return
		end
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
					Logger.debug(LOG, "Onboarding existing configuration absent; neutral values shown (repeats suppressed).")
					return
				end
				Logger.error(LOG, "Onboarding existing configuration import failed (%s; content withheld; repeats suppressed).", label)
			end
			local read_ok, content, status = pcall(FileSystem.read_with_status, cfg_path, import_failure)
			if not publication_is_current(owner, view) then return false end
			if not read_ok then import_failure("dependency"); return false end
			if status == "absent" then
				if not reported then import_failure("absent") end
				local absent_values = with_tap_hold_values({}, cfg_path)
				if not publication_is_current(owner, view) then return false end
				if not absent_values then import_failure("answers"); return false end
				return submit_data(owner, view, "applyCurrentValues", { request = body.request, values = absent_values })
			end
			if status ~= "ok" or type(content) ~= "string" then
				if not reported then import_failure("read") end
				return false
			end
			local decoded, parsed = pcall(toml_codec.decode, content)
			if not publication_is_current(owner, view) then return false end
			if not decoded or type(parsed) ~= "table" then import_failure("decode"); return false end
			local projected, values = pcall(function()
				return with_tap_hold_values(Answers.current_values(catalogue(), parsed), cfg_path)
			end)
			if not publication_is_current(owner, view) then return false end
			if not projected or type(values) ~= "table" then import_failure("answers"); return false end
			return submit_data(owner, view, "applyCurrentValues", { request = body.request, values = values })
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
		local view, focus_owner = _webview, _focus_owner
		require("ui.ui_builder").force_focus(view, false, { is_current = function()
			return focus_owner ~= nil and _focus_owner == focus_owner and _webview == view
		end })
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

	-- The catalogue is the page's whole content: without it the wizard can
	-- neither ask its questions nor validate the answers, so no window opens.
	local catalogue_ok, catalogue_error = pcall(catalogue)
	if not catalogue_ok then
		Logger.error(LOG, "Onboarding window not opened — %s.", tostring(catalogue_error))
		return false
	end

	-- The manifest geometry bounded by the screen, like every configuration
	-- window; the page scrolls inside it (_shared/ui/apps.manifest.json).
	local screen = hs.screen.mainScreen()
	local geo    = ui_builder.get_app_geometry("onboarding")
	if not screen or type(screen.frame) ~= "function" or not geo then
		Logger.error(LOG, "Onboarding window not opened — screen or geometry unavailable.")
		return false
	end
	local sf    = screen:frame()
	local win_w = math.min(geo.width, sf.w)
	local win_h = math.min(geo.height, sf.h)

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
