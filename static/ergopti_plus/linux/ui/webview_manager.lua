--- ui/webview_manager.lua

--- ==============================================================================
--- MODULE: WebView Manager (Linux)
--- DESCRIPTION:
--- Manages the lifecycle of WebKitGTK-based webview windows. Registers bridge
--- handlers for JS↔Lua communication, loads shared HTML/UI apps via
--- webkit_host.lua, and routes messages from the JS host_bridge.js to the
--- appropriate bridge handler module.
---
--- This module handles both the pure-Lua bridge routing (testable on any
--- platform) AND the native GTK/WebKit2GTK window creation (requires lgi on
--- Linux). Bridge handlers remain directly testable without GTK, but a user
--- request to show a window fails unless a native window is actually created.
---
--- FEATURES & RATIONALE:
--- 1. Bridge registry: each JS→Lua message handler name (from host_bridge.js)
---    maps to a bridge handler module that implements on_message(payload).
--- 2. Window pool: tracks open webview windows by app name so show/hide/close
---    operations work without leaking resources.
--- 3. Shared HTML loading: delegates to webkit_host.build_app_html() for
---    asset inlining and i18n injection.
--- 4. Daemon state injection: passes engine, keylogger, hotstrings_config, and
---    LLM references to bridge handlers so UIs can query/control daemon state.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Monotonic = require("infra.monotonic")
local LOG = "ui.webview_manager"

-- Windows that open by themselves while the user may be typing: shown
-- without taking the keyboard focus.
local UNFOCUSED_APPS = { error_dialog = true }

-- The generated shared policy owns branding for every native host.
local WindowTitles = require("window_titles")

-- webkit_host provides HTML building and bridge name registry.
local webkit_host = require("ui.webkit_host")

-- The shared JSON codec for page messages, replies and the geometry manifest.
-- This used dkjson, loaded optionally, which is neither shipped nor installed:
-- every object a page posted became nil and no reply reached a page, so the
-- metrics windows stayed empty and the editors' buttons did nothing.
local Json = require("json")


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Per-app window registry: { [app_name] = { bridge, html, handler_module } }
local _windows = {}

-- Daemon state passed to bridge handlers.
local _daemon_state = {}

-- Whether GTK/WebKit2GTK is available (lgi loaded successfully).
local _gtk_available = false

-- lgi library reference (stored after successful probe, used by GTK operations).
local _lgi = nil

-- Native GTK window references: { [app_name] = { window, webview } }
local _gtk_windows = {}
local _native_ready = false
local _native_query_generation = 0
local _shutting_down = false

-- Monotonic identity for each newly-created page context. A late blur or crash
-- callback from an older WebView must not release ownership acquired by its
-- replacement.
local _next_window_epoch = 0

-- Only the actual Versions and network progress producers require this protocol.
local DOCUMENT_APPS = { changelog = true, download_window = true }
local _document_windows, _document_debts = {}, {}

--- Announces a native initialization error without writing to the failed page.
--- The notifier admits a command only; no actual desktop delivery is claimed.
local function notify_document_refusal(private_current)
	local state = _daemon_state
	local pause = type(state) == "table" and state.is_paused or nil
	if type(private_current) ~= "function" or type(pause) ~= "function" then return false end
	local function admit()
		if _daemon_state ~= state or state.is_paused ~= pause or private_current() ~= true then return false end
		local ok, paused = pcall(pause)
		return ok and paused == false and _daemon_state == state and state.is_paused == pause
			and private_current() == true
	end
	local loaded, admitted = pcall(function()
		local I18n, Notifier = require("infra.i18n"), require("adapters.notifier")
		if type(Notifier.send_owned) ~= "function" or not admit() then return false end
		local title, message = I18n.get("error_dialog.heading"), I18n.get("error_dialog.intro")
		if type(title) ~= "string" or title == "" or title == "error_dialog.heading"
			or type(message) ~= "string" or message == "" or message == "error_dialog.intro"
			or not admit() then return false end
		return Notifier.send_owned(message, { title = title, level = "error" }, admit) == true
	end)
	return loaded and admitted == true
end

local function retire_document_entry(entry, defer_close)
	if not entry then return false end
	if not entry.retired then
		entry.retired = true
		-- Revocation is immediate; native cleanup can retain its exact capabilities.
		if _document_windows[entry.app_name] == entry then _document_windows[entry.app_name] = nil end
		if entry.owner then _document_debts[entry] = true end
	end
	if not entry.owner then return true end
	if defer_close then return false end
	entry.close_allowed = true
	if entry.closing then return false end
	entry.closing = true
	local called, settled = pcall(function()
		if not entry.close_started then
			local accepted = entry.owner.on_settled(function() _document_debts[entry] = nil end)
			if accepted ~= true then return false end
			entry.close_started = true
		end
		return entry.owner.close()
	end)
	entry.closing = false
	if called and settled == true then _document_debts[entry] = nil end
	return called and settled == true
end

local function retire_document(app_name, epoch, view, defer_close)
	local entry = _document_windows[app_name]
	if not entry or (epoch ~= nil and entry.epoch ~= epoch) or (view ~= nil and entry.view ~= view) then return end
	retire_document_entry(entry, defer_close)
end

function M.capture_document_owner(app_name)
	local entry = _document_windows[app_name]
	return entry and entry.owner and entry.owner.capture() or nil
end

function M.document_owner_current(lease)
	if type(lease) ~= "table" then return false end
	for _, entry in pairs(_document_windows) do
		if entry.owner and entry.owner.current(lease) then return _document_windows[entry.app_name] == entry end
	end
	return false
end

--- Pure final owner fence; fresh native observations remain required separately.
function M.document_owner_retained(lease)
	if type(lease) ~= "table" then return false end
	for _, entry in pairs(_document_windows) do
		local native = _gtk_windows[entry.app_name]
		if entry.owner and entry.owner.retains(lease) then
			return _document_windows[entry.app_name] == entry and not entry.retired
				and native ~= nil and native.epoch == entry.epoch
				and native.webview == entry.view and native.window == entry.window
				and M.current_epoch(entry.app_name) == entry.epoch
		end
	end
	return false
end

--- Writes only to the exact retained native document, with a page-nonce guard.
function M.eval_owned_js(app_name, lease, js_code)
	local entry = _document_windows[app_name]
	if not entry or not entry.owner or type(js_code) ~= "string" or js_code == ""
		or not entry.owner.current(lease) then return false end
	local arguments = Json.encode({ entry.bridge, lease.generation, lease.token, lease.page_nonce })
	if type(arguments) ~= "string" then return false end
	local code = "if(typeof runLinuxOwnedDocumentEffect==='function')runLinuxOwnedDocumentEffect.apply(null,"
		.. arguments .. ".concat([function(){" .. js_code .. "}]));"
	local ok = pcall(entry.view.run_javascript, entry.view, code, nil, nil, nil)
	return ok and _document_windows[app_name] == entry and entry.owner.current(lease)
end

local function poll_documents()
	for _, entry in pairs(_document_windows) do if entry.owner then entry.owner.poll() end end
	for entry in pairs(_document_debts) do
		if entry.close_started and entry.owner.is_settled() then _document_debts[entry] = nil end
	end
end

-- Try to load lgi for GTK/WebKit2GTK access (only available on Linux).
local function _probe_gtk()
	local ok, lgi = pcall(require, "lgi")
	if not ok then
		Logger.debug(LOG, "lgi not available — webview rendering disabled (pure-Lua bridge mode).")
		return false
	end
	local read, native = pcall(function() return lgi.WebKit2 end)
	if not read then
		Logger.debug(LOG, "lgi.WebKit2 not available — webview rendering disabled.")
		return false
	end
	_lgi = lgi
	Logger.success(LOG, "GTK/WebKit2GTK available via lgi — webview rendering enabled.")
	return true, type(native) == "table" or type(native) == "userdata"
end





-- ==========================================
-- ==========================================
-- ======= 2/ Bridge Handler Registry =======
-- ==========================================
-- ==========================================

--- Resolves the driver root from this module's location.
--- @return string Absolute path to the linux driver root.
local function _driver_root()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- One level up from ui/, not three: the manager moved out of modules/ui/ when
	-- the driver's UI was reorganised by feature to match macOS and Windows, and a
	-- stale depth here resolves to a directory that exists but holds nothing —
	-- which is how every other wrong-depth path in this driver failed.
	return (src:match("^(.*)[/\\\\]ui[/\\\\]webview_manager%.lua$")
		or src:match("^(.*)[/\\\\]ui$")
		or "."):gsub("\\", "/")
end

--- Where each shared-UI app's bridge lives, as an explicit table rather than a
--- composed string.
---
--- The module name used to be built as
--- `"modules.ui.bridge_handlers." .. app_name .. "_bridge"`, which meant no
--- bridge module name appeared as a literal anywhere — so a rename that moved
--- them all found nothing to rewrite here, and the drivers' own gates could not
--- see the dependency either. It is the same composed-name trap that made two
--- menu-manifest sections look unreferenced and Windows look short of thirteen
--- gesture actions it implements.
---
--- The keys ARE the directory names under `_shared/ui/`, and that is not a
--- stylistic preference: `webkit_host.resolve_app_dir()` builds
--- `_shared/ui/<key>/index.html` and the window shows an error page when it is
--- not there. Until 2026-08-05 this table said otherwise, and its own comment
--- called it a feature — "four app names do not equal their directory". Three of
--- those four (`dl`, `token`, `hotstrings_config`) were names with a working
--- bridge and no page, and the one that was actually called opened the hotstring
--- delays-and-colours window as "Error: app 'hotstrings_config' not found".
---
local BRIDGE_MODULES = {
	config_cleanup        = "ui.config_cleanup.bridge",
	action_picker         = "ui.action_picker.bridge",
	physical_shortcuts     = "ui.physical_shortcuts.bridge",
	changelog             = "ui.changelog.bridge",
	download_window       = "ui.download_window.bridge",
	error_dialog          = "ui.error_dialog.bridge",
	healthcheck           = "ui.healthcheck.bridge",
	hotstring_editor      = "ui.hotstring_editor.bridge",
	-- Keyed by the DIRECTORY name. It read "hotstrings_config" until 2026-08-05,
	-- which gave that name a working bridge and no page: resolve_app_dir() looks
	-- for _shared/ui/<name>/index.html and there is no _shared/ui/hotstrings_config,
	-- so every caller using it got a window rendering "Error: app not found" while
	-- the bridge behind it was perfectly healthy. A half-registered name is worse
	-- than an unregistered one — it looks supported at the only place anyone checks.
	hotstrings_config_window = "ui.hotstrings_config_window.bridge",
	layer_editor          = "ui.layer_editor.bridge",
	metrics_apps          = "ui.metrics_apps.bridge",
	metrics_typing        = "ui.metrics_typing.bridge",
	model_browser         = "ui.model_browser.bridge",
	onboarding            = "ui.onboarding.bridge",
	layout_manager        = "ui.layout_manager.bridge",
	paths_editor          = "ui.paths_editor.bridge",
	personal_info_editor  = "ui.personal_info_editor.bridge",
	numeric_prompt        = "ui.numeric_prompt.bridge",
	prompt_editor         = "ui.prompt_editor.bridge",
	token_prompt          = "ui.token_prompt.bridge",
	update_check          = "ui.update_check.bridge",
}

--- Loads a bridge handler module by pcall-requiring it.
--- @param app_name string The shared-UI app directory name.
--- @return table|nil The handler module, or nil if not found.
local function _load_handler(app_name)
	local module_name = BRIDGE_MODULES[app_name]
	if not module_name then
		Logger.warn(LOG, "No bridge module declared for app '%s'.", tostring(app_name))
		return nil
	end
	local ok, mod = pcall(require, module_name)
	if ok and type(mod) == "table" and type(mod.on_message) == "function" then
		Logger.debug(LOG, "Bridge handler loaded: %s", module_name)
		return mod
	end
	Logger.warn(LOG, "Bridge handler not found or invalid: %s", module_name)
	return nil
end


-- =========================================
-- =========================================
-- ======= 3/ Window Management ============
-- =========================================
-- =========================================

local function _release_app_ownership(app_name, epoch)
	local gate = _daemon_state.input_capture_gate
	if type(gate) ~= "table" or type(gate.release) ~= "function" then return true end
	local ok, accepted = pcall(gate.release, app_name, epoch)
	if not ok then
		Logger.error(LOG, "Input ownership release for '%s' refused.", tostring(app_name))
		return false
	end
	if accepted ~= true then
		Logger.debug(LOG, "Ignored stale input release for '%s' at epoch %s.",
			tostring(app_name), tostring(epoch))
		return false
	end
	return true
end

--- Returns the current page-context epoch for an application.
--- @param app_name string
--- @return number|nil
function M.current_epoch(app_name)
	return _windows[app_name] and _windows[app_name].epoch or nil
end

--- Returns whether the exact native page has completed acquisition without debt.
--- @param app_name string Stable page owner.
--- @param epoch number Exact page identity.
--- @return boolean current
function M.page_current(app_name, epoch)
	local owned, native = _windows[app_name], _gtk_windows[app_name]
	return owned ~= nil and native ~= nil and native.epoch == epoch and not native.settled
		and not native.view_settled and native.registration == true and native.signal_id ~= nil
		and owned.epoch == epoch and not owned.acquiring
		and not owned.closing and not owned.debt and not owned.failed
end

-- Exported for the pure-Lua lifecycle regression harness.
M._release_app_ownership = _release_app_ownership

--- Builds the HTML a window loads for a shared UI app, with the page's
--- strings: active locale over English over French, so a key the active
--- locale lacks reads as English, not as a key. show() and the WebKitGTK
--- page-error harness (tests/hardware/run_page_errors.lua) both build
--- through here: that harness is the only place a real engine parses these
--- pages, and its own copy of this build had lost the seeded strings.
--- @param app_name string The shared UI app directory name.
--- @param active_locale string Locale code the page boots with.
--- @return string html Complete HTML, or an error page from the builder.
function M.build_page_html(app_name, active_locale)
	if type(app_name) ~= "string" or app_name == "" then
		error("build_page_html(): app_name must be a nonempty string", 2)
	end
	if type(active_locale) ~= "string" or active_locale == "" then
		error("build_page_html(): active_locale must be a nonempty string", 2)
	end
	local root = _driver_root()
	local ok_catalogue, catalogue = pcall(function() return require("infra.locale").catalogue() end)
	if not ok_catalogue or type(catalogue) ~= "table" or next(catalogue) == nil then
		Logger.error(LOG, "build_page_html(): '%s' opens without its strings: the locale catalogue is unavailable (%s).",
			app_name, tostring(catalogue))
		catalogue = nil
	end
	return webkit_host.build_app_html(root, app_name, active_locale, catalogue)
end

--- Opens a webview window for the given shared UI app.
--- If the window already exists, brings it to front instead of creating a new one.
--- @param app_name string The shared UI app directory name (e.g. "action_picker").
--- @param active_locale string|nil Locale code (default: the interface's).
--- @return boolean true if the window was opened or brought to front.
function M.show(app_name, active_locale)
	if _shutting_down then return false end
	if type(app_name) ~= "string" or app_name == "" then
		Logger.error(LOG, "show(): app_name is required.")
		return false
	end
	-- No caller passes a locale, and the page builder fell back to French: every
	-- window was French whatever language the tray was set to.
	if type(active_locale) ~= "string" or active_locale == "" then
		local ok, I18n = pcall(require, "infra.i18n")
		active_locale = ok and type(I18n.get_locale) == "function" and I18n.get_locale() or nil
		if type(active_locale) ~= "string" or active_locale == "" then
			active_locale = require("infra.manifest_reader").default_for("script.locale")
		end
	end

	-- If window already exists, bring to front.
	if _windows[app_name] then
		local previous = _windows[app_name]
		if previous.acquiring or previous.closing then return false end
		if previous.failed or previous.debt then
			if M.hide(app_name, previous.epoch) ~= true then return false end
			-- Final document close may have admitted a fresh page after native ACKs.
			local replacement = _windows[app_name]
			if replacement then
				if replacement.acquiring or replacement.closing or replacement.failed or replacement.debt then return false end
				M.bring_to_front(app_name)
				return _windows[app_name] == replacement
			end
		else
			Logger.debug(LOG, "Window '%s' already open — bringing to front.", app_name)
			M.bring_to_front(app_name)
			return true
		end
	end

	local html = M.build_page_html(app_name, active_locale)
	if not html or html == "" then
		Logger.error(LOG, "show(): failed to build HTML for '%s'.", app_name)
		return false
	end

	-- Load and verify the page's sole bridge before exposing a window.
	local handler = _load_handler(app_name)
	local expected_bridge = webkit_host.bridge_for_app(app_name)
	if not expected_bridge or not handler or handler.bridge_name ~= expected_bridge then
		Logger.error(LOG, "show(): app '%s' has no valid owned bridge.", app_name)
		return false
	end

	-- Store window state.
	_next_window_epoch = _next_window_epoch + 1
	_windows[app_name] = {
		html    = html,
		handler = handler,
		visible = false,
		epoch   = _next_window_epoch,
		opened_ms = Monotonic.now_ms(), acquiring = true,
	}

	local owned = _windows[app_name]
	if type(handler.on_window_acquiring) == "function" then
		local called, accepted = pcall(handler.on_window_acquiring, owned.epoch)
		if not called or accepted ~= true then
			owned.acquiring, owned.failed = false, true
			M.hide(app_name, owned.epoch)
			return false
		end
	end

	-- A logical page context is only provisional until the native owner exists.
	-- Returning success in headless/pure-Lua mode made tray actions look healthy
	-- while displaying nothing, and left is_visible() reporting a fictional
	-- window. The exported creator is invoked unconditionally so unit tests can
	-- inject a native boundary without weakening the production contract.
	local creation_owner = _windows[app_name]
	local create_ok, created, create_err = xpcall(function()
		return M._create_gtk_window(app_name, html, handler)
	end, debug.traceback)
	owned.acquiring = false
	if not create_ok or created ~= true or owned.cancelled or _windows[app_name] ~= owned then
		owned.failed = true
		if _windows[app_name] == owned then M.hide(app_name, owned.epoch) end
		Logger.error(LOG, "show(): native window acquisition refused for '%s'.", app_name)
		if DOCUMENT_APPS[app_name] then
			notify_document_refusal(function()
				return _next_window_epoch == creation_owner.epoch
					and (_windows[app_name] == nil or _windows[app_name] == creation_owner)
			end)
		end
		return false
	end
	if _windows[app_name] ~= creation_owner then return false end

	_windows[app_name].visible = true
	Logger.info(LOG, "Webview '%s' opened in %.0f ms.", app_name,
		Monotonic.now_ms() - _windows[app_name].opened_ms)
	return true
end

--- Closes a webview window by app name.
--- @param app_name string The app name.
--- @param expected_epoch number|nil Refuse to close a replacement page when set.
--- @return boolean true when the owned page was closed.
function M.hide(app_name, expected_epoch)
	local owned = _windows[app_name]
	if not owned or (expected_epoch ~= nil and owned.epoch ~= expected_epoch) then return false end
	if owned.acquiring then
		owned.cancelled = true
		local native = _gtk_windows[app_name]
		if native and native.epoch == owned.epoch then native.cancelled = true end
		return false
	end
	if owned.closing then return false end
	owned.closing = true
	local native = _gtk_windows[app_name]
	if native and native.epoch == owned.epoch then owned.document_entry = native.document_entry end
	if native then
		local called, retired = pcall(M._destroy_gtk_window, app_name, owned.epoch)
		if not called or retired ~= true then
			owned.closing, owned.debt = false, true
			return false
		end
	end
	if _release_app_ownership(app_name, owned.epoch) ~= true or _windows[app_name] ~= owned then
		owned.closing, owned.debt = false, true
		return false
	end
	owned.closing = false
	_windows[app_name] = nil
	-- Only acknowledged native/input release permits timer-close reentry.
	retire_document_entry(owned.document_entry)
	local handler = owned.handler
	if type(handler) == "table" and type(handler.on_window_closed) == "function" then
		local ok, err = pcall(handler.on_window_closed, owned.epoch)
		if not ok then Logger.error(LOG, "The '%s' bridge refused its close notification.", app_name) end
	end
	Logger.info(LOG, "Webview '%s' closed after %.1f s open.", app_name,
		(Monotonic.now_ms() - (owned.opened_ms or Monotonic.now_ms())) / 1000)
	return true
end

--- Closes the page context that owns a GTK delete-event.
--- A stale callback returns false so GTK may destroy only its old native window
--- without closing a replacement page registered under the same application name.
--- @param app_name string The app name.
--- @param window_epoch number The page-context epoch captured by the callback.
--- @return boolean true when the close was handled explicitly.
function M._handle_delete_event(app_name, window_epoch)
	return M.hide(app_name, window_epoch)
end

--- Brings an existing window to the front.
--- @param app_name string The app name.
function M.bring_to_front(app_name)
	if not _windows[app_name] then return end
	_windows[app_name].visible = true
	-- GTK window focus is handled by _create_gtk_window on first show;
	-- subsequent front-bringing needs GTK API (not available in pure Lua).
	if _gtk_available then
		M._focus_gtk_window(app_name)
	end
	Logger.debug(LOG, "Window '%s' brought to front.", app_name)
end

--- Returns true if a window is currently visible.
--- @param app_name string The app name.
--- @return boolean
function M.is_visible(app_name)
	return _windows[app_name] ~= nil and _windows[app_name].visible == true
end

--- Composes a native window title. The product name is added here only, so
--- callers pass a brand-less, already-translated label.
--- @param label string|nil Brand-less title.
--- @return string
function M.window_title(label)
	return WindowTitles.compose(label)
end

--- Retitles an open window, e.g. after a live language switch. WebKitGTK does
--- not mirror document.title onto the GtkWindow.
--- @param app_name string The app name.
--- @param label string Brand-less, already-translated title.
--- @return boolean true when the live window was retitled.
function M.set_title(app_name, label)
	local wref = _gtk_windows[app_name]
	if not wref or not wref.window then
		Logger.debug(LOG, "set_title: no live window for '%s'.", tostring(app_name))
		return false
	end
	local ok, err = pcall(function() wref.window:set_title(M.window_title(label)) end)
	if not ok then
		Logger.error(LOG, "set_title failed for '%s': %s.", tostring(app_name), tostring(err))
		return false
	end
	return true
end





-- =========================================
-- =========================================
-- ======= 4/ Daemon State Injection =======
-- =========================================
-- =========================================

--- Registers daemon state that bridge handlers can access to query/control
--- the running daemon.
--- @param state table { engine, keylogger, config, llm, layout }
function M.set_daemon_state(state)
	_daemon_state = type(state) == "table" and state or {}
	Logger.debug(LOG, "Daemon state registered for bridge handlers.")
end

--- Returns the current daemon state (for bridge handler use).
--- @return table
function M.get_daemon_state()
	return _daemon_state
end





-- =========================================
-- =========================================
-- ======= 5/ JS→Lua Message Routing =======
-- =========================================
-- =========================================

--- Evaluates JavaScript inside an app's live webview — the host→page direction.
---
--- Everything else here is page→host: the page posts, a handler answers, and the
--- answer travels back on the same message. That is enough for a request/response
--- exchange and not enough for the one thing several shared pages need, which is
--- to be HANDED their data once they report ready. A bridge handler is given only
--- (payload, state), so without this it had no way to reach its own window and
--- the action picker rendered empty on Linux while looking wired from both ends.
---
--- Silent when the window is not open: a push into a webview that does not exist
--- is not an error, it is a page the user closed before it finished loading.
--- @param app_name string The shared UI app directory name (e.g. "action_picker").
--- @param js_code string JavaScript source to evaluate in the page.
--- @return boolean True when the call was handed to WebKit.
function M.eval_js(app_name, js_code)
	if DOCUMENT_APPS[app_name] then
		local lease = M.capture_document_owner(app_name)
		return lease ~= nil and M.eval_owned_js(app_name, lease, js_code)
	end
	if type(app_name) ~= "string" or type(js_code) ~= "string" or js_code == "" then
		Logger.warn(LOG, "eval_js: bad arguments (app=%s).", tostring(app_name))
		return false
	end
	local wref = _gtk_windows[app_name]
	if not wref or not wref.webview then
		Logger.debug(LOG, "eval_js: no live webview for '%s' — nothing to push to.", app_name)
		return false
	end
	local ok, err = pcall(function() wref.webview:run_javascript(js_code, nil, nil, nil) end)
	if not ok then
		Logger.error(LOG, "eval_js: run_javascript failed for '%s': %s", app_name, tostring(err))
		return false
	end
	Logger.debug(LOG, "eval_js: pushed %d char(s) to '%s'.", #js_code, app_name)
	return true
end

--- The live WebKit view for an app, or nil when it has no window.
---
--- Published for the hardware harness, which has to read a value BACK out of the
--- page: `eval_js` is fire-and-forget by design, and the only honest way to ask
--- "did that push change anything" is to query the DOM afterwards. Nothing in
--- the driver uses this — the daemon pushes and never reads.
--- @param app_name string
--- @return userdata|nil
function M.webview_for(app_name)
	local window = _gtk_windows[app_name]
	return window and window.webview or nil
end

--- Routes a JS message from host_bridge.js to the appropriate bridge handler.
--- Called by the GTK script-message-received callback or by tests.
--- @param app_name string The trusted window identity supplied by the native callback.
--- @param bridge_name string The bridge handler name (e.g. "action_picker_bridge").
--- @param payload any The message payload (string or table).
--- @param source_epoch number|nil Page-context epoch captured by the native callback.
--- @return any The handler's response, or nil.
function M.route_message(app_name, bridge_name, payload, source_epoch)
	local expected_bridge = webkit_host.bridge_for_app(app_name)
	if not expected_bridge or bridge_name ~= expected_bridge then
		Logger.warn(LOG, "Bridge '%s' is not owned by app '%s'.",
			tostring(bridge_name), tostring(app_name))
		return nil
	end
	local current_epoch = M.current_epoch(app_name)
	-- Native callbacks keep their captured epoch after public hide. No live
	-- epoch means their page has retired, rather than permission to reload it.
	if source_epoch ~= nil and source_epoch ~= current_epoch then
		Logger.debug(LOG, "Ignoring stale message for '%s' from epoch %s (current %s).",
			app_name, tostring(source_epoch), tostring(current_epoch))
		return nil
	end

	local handler = _windows[app_name] and _windows[app_name].handler or _load_handler(app_name)
	if not handler or handler.bridge_name ~= expected_bridge
		or type(handler.on_message) ~= "function" then
		Logger.warn(LOG, "Owned handler for '%s' is unavailable or mismatched.", app_name)
		return nil
	end

	local document_owner = nil
	if DOCUMENT_APPS[app_name] then
		local entry = _document_windows[app_name]
		if not entry or not entry.owner or source_epoch ~= entry.epoch then return nil end
		if type(payload) ~= "table" then return nil end
		if payload.__ergopti_document_ack ~= nil then
			entry.owner.ack(payload.__ergopti_document_ack)
			return nil
		end
		document_owner = entry.owner.admit(payload.__ergopti_document, payload.payload)
		if not document_owner or _document_windows[app_name] ~= entry then return nil end
		payload = payload.payload
	end
	local routed_epoch = source_epoch or M.current_epoch(app_name)
	local context = {
		app_name = app_name,
		epoch = routed_epoch,
		document_owner = document_owner,
	}
	context.close_owned_window = function()
		if document_owner and not M.document_owner_current(document_owner) then return false end
		if routed_epoch ~= nil and M.current_epoch(app_name) ~= routed_epoch then return false end
		M.hide(app_name)
		return M.is_visible(app_name) ~= true
	end
	local ok, result = pcall(handler.on_message, payload, _daemon_state, context)
	if not ok then
		Logger.error(LOG, "Bridge '%s' handler error: %s", bridge_name, tostring(result))
		return nil
	end

	if document_owner and not M.document_owner_current(document_owner) then return nil end
	return result, document_owner
end


-- =========================================
-- =========================================
-- ======= 6/ GTK-specific Helpers =========
-- =========================================
-- =========================================

--- Converts a JSCore.Value to a Lua value (handles string, number, boolean, object).
--- @param js_value any JSCore.Value from js_result:get_js_value().
--- @return any Lua value.
local function _js_value_to_lua(js_value)
	if not js_value then return nil end
	local ok, result = pcall(function()
		if js_value:is_string() then
			return js_value:to_string()
		elseif js_value:is_number() then
			return js_value:to_double()
		elseif js_value:is_boolean() then
			return js_value:to_boolean()
		elseif js_value:is_null() or js_value:is_undefined() then
			return nil
		elseif js_value:is_object() then
			-- Try JSON.stringify round-trip for objects.
			local json_str = js_value:to_json(0)
			if json_str and json_str ~= "" then
				local parsed = Json.decode(json_str)
				if parsed ~= nil then return parsed end
				Logger.warn(LOG, "A page message could not be decoded as JSON — dropped.")
			end
			return nil
		end
		return js_value:to_string()  -- fallback
	end)
	if ok then return result end
	return nil
end

--- Sends a Lua value back to JavaScript via webview:run_javascript().
--- Uses a callback on window.__hostBridgeResponse if the JS side defines one.
--- The string is base64-encoded to avoid escaping issues with quotes/newlines.
--- @param webview WebKit2.WebView The target webview.
--- @param bridge_name string The bridge handler name.
--- @param value any Lua value to send (converted to JSON then base64).
local function _send_response_to_js(webview, bridge_name, value, app_name, document_owner)
	if not webview or value == nil then return end
	-- Encode the value as JSON, then base64 to avoid any escaping hazards.
	local json_str = Json.encode(value)
	if not json_str then return end
	local b64 = require("compat.base64")
	local encoded = b64 and b64.encode(json_str) or json_str:gsub("[^%w]", function(c)
		return string.format("%%%02X", c:byte())
	end)
	local use_b64 = (b64 ~= nil)
	local js_code = string.format(
		[[if(window.__hostBridgeResponse)window.__hostBridgeResponse('%s',%s,'%s')]],
		bridge_name, use_b64 and "true" or "false", encoded:gsub("'", "\\'")
	)
	if document_owner then
		M.eval_owned_js(app_name, document_owner, js_code)
	else
		pcall(function() webview:run_javascript(js_code, nil, nil, nil) end)
	end
end

--- Reads per-app geometry from _shared/ui/apps.manifest.json.
--- @param app_name string The app directory name.
--- @return table { width, height, min_width, min_height }
local function _read_app_geometry(app_name)
	local defaults = { width = 800, height = 600, min_width = 400, min_height = 300 }
	-- One resolver, no "try the other depth" dance. The alternate path this used
	-- to fall back to was simply wrong; keeping both meant the correct one was
	-- indistinguishable from a lucky guess.
	local ok_paths, Paths = pcall(require, "infra.paths")
	local manifest_path = ok_paths and Paths.shared("ui/apps.manifest.json") or nil
	local fh = manifest_path and io.open(manifest_path, "r") or nil
	if not fh then return defaults end
	local raw = fh:read("*a")
	fh:close()
	if not raw or raw == "" then return defaults end
	local manifest = Json.decode(raw)
	if type(manifest) ~= "table" or type(manifest.apps) ~= "table" then return defaults end
	local app = manifest.apps[app_name]
	if app then
		return {
			width      = app.width      or defaults.width,
			height     = app.height     or defaults.height,
			min_width  = app.min_width  or defaults.min_width,
			min_height = app.min_height or defaults.min_height,
		}
	end
	return defaults
end

--- Builds a human-readable window title from the app directory name.
--- @param app_name string The app directory name.
--- @return string

local function _app_title(app_name)
	local key = assert(WindowTitles.key_for_app(app_name), "Unknown shared UI app: " .. tostring(app_name))
	return require("infra.i18n").get(key)
end
M._app_title = _app_title


-- =========================================
-- ======= 7/ GTK Window Operations ========
-- =========================================
-- =========================================

--- Installs the exact child's terminal signal before any destruction attempt.
--- Refused installation retains the live child for an owned retry.
--- @return boolean observed
local function observe_child(attempt, app_name, window_epoch)
	if attempt.view_observed then return true end
	local called = pcall(function()
		attempt.webview.on_destroy = function()
			attempt.view_settled = true
			retire_document(app_name, window_epoch, attempt.webview, true)
			if attempt.retiring then return end
			attempt.cancelled = true
			local owned = _windows[app_name]
			if owned and owned.epoch == window_epoch then
				owned.cancelled = true
				if not owned.acquiring and not owned.closing then M.hide(app_name, window_epoch) end
			elseif not attempt.acquiring then M._destroy_gtk_window(app_name, window_epoch) end
		end
	end)
	if called then attempt.view_observed = true end
	return called
end

--- Creates a GTK WebKit2 window (Linux only, requires lgi).
---
--- Lifecycle: GTK window is created on demand via show(), tracked in _gtk_windows
--- for focus/destroy operations. The window is NOT a child of the daemon — it runs
--- its own GTK event loop iteration via GLib.idle_add or is driven by the daemon's
--- luv event loop when available.
---
--- @param app_name string The app name.
--- @param html string The HTML string to load.
--- @param handler table|nil The bridge handler module.
--- @return boolean true only after the native window is tracked.
--- @return string|nil error_message Exact refusal reason.
function M._create_gtk_window(app_name, html, handler)
	if not _gtk_available or not _lgi then return false, "GTK/WebKit unavailable" end
	if _gtk_windows[app_name] then return false, "native acquisition already owned" end
	local window_epoch = M.current_epoch(app_name) or 0
	local attempt = { epoch = window_epoch, acquiring = true }
	_gtk_windows[app_name] = attempt
	local called, created, detail = pcall(function()

		local Gtk     = _lgi.Gtk
		local WebKit2 = _lgi.WebKit2
		local GLib    = _lgi.GLib

		-- Read geometry from the single-source manifest.
		local geometry = _read_app_geometry(app_name)

		-- ── Create the GTK window ──
		local window = Gtk.Window({
			title            = M.window_title(_app_title(app_name)),
			default_width    = geometry.width,
			default_height   = geometry.height,
			window_position  = Gtk.WindowPosition.CENTER,
			type             = Gtk.WindowType.TOPLEVEL,
			-- A window that can appear while the user types must not take the keyboard
			focus_on_map     = not UNFOCUSED_APPS[app_name],
		})

		attempt.window = window
		if window == nil or window == false or attempt.cancelled then return false, "native acquisition revoked" end

		-- Set minimum size if supported.
		local ok_size, size_err = pcall(function()
			window:set_size_request(geometry.min_width, geometry.min_height)
		end)
		if not ok_size then
			Logger.warn(LOG, "Minimum size not applied to '%s': %s.", app_name, tostring(size_err))
		end

		-- Register only the capability owned by this page. A UserContentManager is
		-- page-local, so there is no reason to expose any foreign handler name.
		local ucm = WebKit2.UserContentManager()
		attempt.ucm = ucm
		local bridge_name = webkit_host.bridge_for_app(app_name)
		if not bridge_name or not handler or handler.bridge_name ~= bridge_name then
			Logger.error(LOG, "Cannot create '%s': owned bridge is unavailable.", app_name)
			return false, "owned bridge unavailable"
		end
		local registered, accepted = pcall(function()
			return ucm:register_script_message_handler(bridge_name)
		end)
		if not registered or accepted ~= true then
			Logger.error(LOG, "Cannot create '%s': bridge registration failed.", app_name)
			return false, "bridge registration failed"
		end

		attempt.registration, attempt.bridge_name = true, bridge_name
		-- Detailed connect retains the exact native handler ID for its inverse.
		-- Assignment connects the same signal but drops this physical capability.
		local function handle_script_message(js_result)
			local js_value = js_result:get_js_value()
			local payload = _js_value_to_lua(js_value)
			local response, document_owner = M.route_message(app_name, bridge_name, payload, window_epoch)
			if response ~= nil and _gtk_windows[app_name] and _gtk_windows[app_name].webview then
				_send_response_to_js(_gtk_windows[app_name].webview, bridge_name, response, app_name, document_owner)
			end
		end

		local ok_sig, signal_id = pcall(function()
			return ucm.on_script_message_received:connect(function(_manager, js_result)
				local ok_handle, handle_err = pcall(handle_script_message, js_result)
				if not ok_handle then
					Logger.error(LOG, "Message from '%s' could not be handled: %s.", app_name, tostring(handle_err))
				end
			end, bridge_name)
		end)
		if not ok_sig or type(signal_id) ~= "number" or signal_id <= 0 then
			Logger.error(LOG, "Cannot create '%s': its page message receiver refused.", app_name)
			return false, "bridge signal connection failed"
		end

		attempt.signal_id = signal_id
		-- ── Create the WebView ──
		local webview = WebKit2.WebView({
			user_content_manager = ucm,
			visible              = true,
		})

		attempt.webview = webview
		if webview == nil or webview == false then return false, "native acquisition revoked" end
		if observe_child(attempt, app_name, window_epoch) ~= true then return false, "native child observer refused" end
		if attempt.cancelled then return false, "native acquisition revoked" end


		local document_entry = nil
		if DOCUMENT_APPS[app_name] then
			local previous_document = _document_windows[app_name]
			if previous_document then retire_document_entry(previous_document) end
			if M.current_epoch(app_name) ~= window_epoch or _document_windows[app_name] ~= nil then
				return false, "document window replaced during initialization"
			end
			document_entry = { app_name = app_name, bridge = bridge_name, epoch = window_epoch, view = webview, window = window }
			attempt.document_entry = document_entry
			_document_windows[app_name] = document_entry
			local loaded, err = pcall(function()
				local Lease = require("webview.document_lease")
				local Deadline = require("infra.managed_http_deadline")
				local Timings = require("infra.timings")
				assert(Monotonic.has_hires(), "document admission requires an actual monotonic clock")
				local function native_current()
					local native = _gtk_windows[app_name]
					return _document_windows[app_name] == document_entry and M.current_epoch(app_name) == window_epoch
						and native == attempt and not attempt.cancelled and not attempt.settled and not attempt.retiring
						and native.epoch == window_epoch and native.webview == webview and native.window == window
				end
				local function evaluate(name, generation, token, page_nonce)
					local arguments = Json.encode({ bridge_name, generation, token, page_nonce })
					if not native_current() or type(arguments) ~= "string" then return false end
					webview:run_javascript("if(typeof " .. name .. "==='function')" .. name .. ".apply(null," .. arguments .. ");", nil, nil, nil)
					return native_current()
				end
				document_entry.owner = Lease.new({
					timeout_ms = Timings.ms("ui", "document_initialization_ack_timeout_ms"), uri = "file:///",
					clock = Monotonic.now_ms, current = native_current,
					on_refused = function(record, reason)
						Logger.error(LOG, "Managed document initialization refused for '%s' (%s).", app_name, reason)
						notify_document_refusal(function()
							return native_current() and document_entry.owner ~= nil
								and document_entry.owner.refusal_current(record) == true
						end)
					end,
					-- LGI exposes WebKit's is-loading property as a boolean, not a callable.
					read_document = function() return webview:get_uri(), webview.is_loading end,
					nonce = webkit_host.native_nonce, deadline = Deadline.start,
					read_nonce = function(done)
						if not native_current() then return false end
						local code = "typeof getLinuxDocumentNonce==='function'?getLinuxDocumentNonce(" .. Json.encode(bridge_name) .. "):null"
						webview:run_javascript(code, nil, function(_, result)
							-- The ledger's callback captures exact load generation. Native result
							-- reads may reenter; it validates that captured owner again afterward.
							if not native_current() then return end
							local ok, value = pcall(function() return _js_value_to_lua(webview:run_javascript_finish(result):get_js_value()) end)
							if native_current() then done(ok and value or nil) end
						end)
						return native_current()
					end,
					challenge = function(generation, token, page_nonce)
						return evaluate("initializeLinuxDocumentBridge", generation, token, page_nonce)
					end,
					confirm = function(generation, token, page_nonce)
						return evaluate("confirmLinuxDocumentBridge", generation, token, page_nonce)
					end,
				})
			end)
			if not loaded or _document_windows[app_name] ~= document_entry or M.current_epoch(app_name) ~= window_epoch then
				retire_document_entry(document_entry, true)
				Logger.error(LOG, "Managed document admission unavailable: %s", tostring(err))
				return false, "document admission unavailable"
			end
		end


		-- Load the inline HTML with an explicit base URI.
		--
		-- It was nil, and the comment called that "no file:// origin" as though the
		-- absence were the point. A nil base makes WebKit treat the document as
		-- about:blank with a unique opaque origin, and that is the only difference
		-- between this path and the one in tests/hardware/run_page_errors.lua — which
		-- builds the SAME html, loads it with "file:///", and finds window.setData
		-- defined and no exception raised. Through this path it was undefined, so the
		-- host's `if(window.setData)` guard discarded every push and the settings
		-- window drew nothing.
		--
		-- Everything is inlined by build_injected_html, so nothing is ever fetched
		-- relative to this URI. It exists to give the document an ordinary origin
		-- rather than an opaque one.
		-- The page load is the slow half of opening a window and the half a blank
		-- window points at, so its completion is logged with its duration.
		local load_started_ms = Monotonic.now_ms()
		local ok_load_signal, load_signal_err = pcall(function()
			webview.on_load_changed = function(_view, event)
				if document_entry and document_entry.owner and not document_entry.retired
					and _document_windows[app_name] == document_entry and _gtk_windows[app_name] == attempt
					and not attempt.cancelled and not attempt.settled and not attempt.retiring then
					if event == "STARTED" or event == WebKit2.LoadEvent.STARTED then document_entry.owner.start_load() end
					if event == "FINISHED" or event == WebKit2.LoadEvent.FINISHED then document_entry.owner.finished_load() end
				end
				if event == "FINISHED" or event == WebKit2.LoadEvent.FINISHED then
					Logger.info(LOG, "Webview '%s' page loaded in %.0f ms.", app_name,
						Monotonic.now_ms() - load_started_ms)
				end
			end
		end)
		if not ok_load_signal then
			Logger.warn(LOG, "Load-completion signal unavailable for '%s': %s.", app_name,
				tostring(load_signal_err))
		end
		if not ok_load_signal and document_entry then
			retire_document_entry(document_entry, true)
			return false, "document admission unavailable"
		end
		webview:load_html(html, "file:///")

		-- ── Window lifecycle: close → destroy the page context ──
		window.on_destroy = function()
			attempt.settled = true
			retire_document_entry(document_entry, true)
			local owned = _windows[app_name]
			if owned and owned.epoch == window_epoch then
				if owned.acquiring then owned.cancelled, attempt.cancelled = true, true
				elseif not owned.closing then M.hide(app_name, window_epoch) end
			elseif _gtk_windows[app_name] == attempt and not attempt.retiring then
				if attempt.acquiring then attempt.cancelled = true
				elseif M._destroy_gtk_window(app_name, window_epoch) == true and not document_entry then
					_release_app_ownership(app_name, window_epoch)
				end
			end
		end

		window.on_delete_event = function()
			Logger.debug(LOG, "GTK window '%s' delete-event — closing page context.", app_name)
			return M._handle_delete_event(app_name, window_epoch)
		end

		-- A renderer crash can bypass blur/delete-event while leaving the native
		-- window object alive. Release only the epoch owned by this WebView.
		pcall(function()
			webview.on_web_process_terminated = function()
				if document_entry then
					-- A process crash does not acknowledge view/signal/window cleanup.
					retire_document_entry(document_entry, true)
					attempt.cancelled = true
					local owned = _windows[app_name]
					if owned and owned.epoch == window_epoch then
						owned.cancelled = true
						if not owned.acquiring and not owned.closing then M.hide(app_name, window_epoch) end
					elseif not attempt.acquiring and not attempt.retiring then
						M._destroy_gtk_window(app_name, window_epoch)
					end
					Logger.error(LOG, "WebKit process for '%s' terminated.", app_name)
				else
					Logger.error(LOG, "WebKit process for '%s' terminated.", app_name)
					_release_app_ownership(app_name, window_epoch)
				end
			end
		end)

		-- ── Assemble and show ──
		window:add(webview)
		M._present_gtk_window(window, not UNFOCUSED_APPS[app_name])

		-- ── Track native references ──
		if attempt.cancelled or attempt.settled or _gtk_windows[app_name] ~= attempt then
			return false, "native acquisition revoked"
		end

		Logger.success(LOG, "GTK window '%s' created (%dx%d).", app_name, geometry.width, geometry.height)

		-- Pump GTK events: if the daemon has a luv event loop, integrate.
		local ok_pump, pump_err = pcall(function()
			local event_loop = require("adapters.event_loop")
			if event_loop and event_loop.add_idle_handler then
				event_loop.add_idle_handler(function()
					poll_documents()
					if _gtk_windows[app_name] then
						local ctx = GLib.MainContext.default()
						if ctx then ctx:iteration(false) end
					end
				end)
			end
		end)
		if not ok_pump then
			-- Without this integration the window paints once and then freezes.
			Logger.error(LOG, "GTK event pump could not be attached for '%s': %s.", app_name,
				tostring(pump_err))
		end
		return true
	end)
	attempt.acquiring = false
	if not called or created ~= true then retire_document_entry(attempt.document_entry, true) end
	if not attempt.window and _gtk_windows[app_name] == attempt then _gtk_windows[app_name] = nil end
	if not called then return false, "native construction refused" end
	return created == true, detail
end

--- Destroys a GTK window (Linux only).
--- @param app_name string The app name.
--- @param expected_epoch number|nil Refuse to destroy a replacement window when set.
--- @return boolean true when a native window was destroyed.
function M._destroy_gtk_window(app_name, expected_epoch)
	local wref = _gtk_windows[app_name]
	if not wref or (expected_epoch ~= nil and wref.epoch ~= expected_epoch) then return false end
	if wref.acquiring then wref.cancelled = true; return false end
	if wref.retiring then return false end
	wref.retiring = true
	local logical = _windows[app_name]
	if logical and logical.epoch == wref.epoch then logical.document_entry = wref.document_entry end
	local close_without_page = wref.document_entry and (not logical or logical.epoch ~= wref.epoch)
	local called, retired = pcall(function()
		retire_document(app_name, wref.epoch, wref.webview, true)
		if wref.webview and not wref.view_settled then
			if observe_child(wref, app_name, wref.epoch) ~= true then return false end
			local removed, accepted = pcall(function() return wref.webview:destroy() end)
			if not removed or accepted == false or not wref.view_settled then return false end
		end
		if wref.signal_id then
			local GObject = _lgi.GObject
			local detached, accepted = pcall(GObject.signal_handler_disconnect, wref.ucm, wref.signal_id)
			if not detached or accepted == false then return false end
			local checked, connected = pcall(GObject.signal_handler_is_connected, wref.ucm, wref.signal_id)
			if not checked or connected ~= false then return false end
			wref.signal_id = nil
		end
		if wref.registration then
			local removed, accepted = pcall(function() return wref.ucm:unregister_script_message_handler(wref.bridge_name) end)
			if not removed or accepted == false then return false end
			wref.registration = false
		end
		if not wref.settled and wref.window then
			local removed, accepted = pcall(function() return wref.window:destroy() end)
			if not removed or accepted == false then return false end
			wref.settled = true
		end
		if close_without_page and _release_app_ownership(app_name, wref.epoch) ~= true then return false end
		return true
	end)
	wref.retiring = false
	if not called or retired ~= true or _gtk_windows[app_name] ~= wref then
		Logger.error(LOG, "Native GTK page retirement refused for '%s'; exact capabilities retained.", app_name)
		return false
	end
	_gtk_windows[app_name] = nil
	if close_without_page then retire_document_entry(wref.document_entry) end
	Logger.debug(LOG, "GTK window '%s' destroyed.", app_name)
	return true
end

--- Presents a native window, the driver's one "present window" step for a
--- window that opens or is requested again: maps it, then raises and focuses
--- it with present() unless it must leave the keyboard where the user types.
--- It never sets keep-above or a floating type hint: an Ergopti window is
--- focused, never kept above the windows the user opens afterwards.
--- @param window userdata The Gtk.Window.
--- @param take_focus boolean False for a window that must not take the keyboard.
function M._present_gtk_window(window, take_focus)
	if not window.visible then window:show_all() end
	if take_focus then window:present() end
end

--- Focuses a GTK window, bringing it to the front (Linux only).
--- @param app_name string The app name.
function M._focus_gtk_window(app_name)
	if not _gtk_available or not _lgi then return end
	local wref = _gtk_windows[app_name]
	if not wref or not wref.window then
		Logger.debug(LOG, "GTK window '%s' not found — cannot focus.", app_name)
		return
	end
	local ok, err = pcall(M._present_gtk_window, wref.window, true)
	if not ok then
		Logger.error(LOG, "GTK window '%s' could not be presented: %s.", app_name, tostring(err))
		return
	end
	Logger.debug(LOG, "GTK window '%s' focused.", app_name)
end


-- =========================================
-- =========================================
-- ======= 8/ Initialisation ===============
-- =========================================
-- =========================================

--- Returns only the acknowledged native window readiness cached by initialization.
--- Physical key capture is a separate capability and is never inferred here.
--- @return boolean available
function M.native_available() return _native_ready and _gtk_available == true end

--- Initialises the webview manager. Probes for GTK availability.
function M.init()
	_native_query_generation = _native_query_generation + 1
	local query_generation = _native_query_generation
	_native_ready = false
	local native_probe_ready
	_gtk_available, native_probe_ready = _probe_gtk()
	Logger.info(LOG, "WebView manager initialised (GTK available: %s).", tostring(_gtk_available))
	if _native_query_generation == query_generation then _native_ready = _gtk_available == true and native_probe_ready == true end
end

--- Retires owned pages without discarding a refused exact native cleanup.
--- @return boolean retired All owned page and native capabilities acknowledged release.
function M.shutdown()
	if _shutting_down then return false end
	_shutting_down = true
	_native_query_generation = _native_query_generation + 1
	_native_ready = false
	local retired = true
	local app_names = {}
	for app_name in pairs(_windows) do app_names[#app_names + 1] = app_name end
	for _, app_name in ipairs(app_names) do
		if M.hide(app_name) ~= true then retired = false end
	end
	-- Direct native harness callers can own a window without a logical page.
	local native_names = {}
	for app_name in pairs(_gtk_windows) do
		if _windows[app_name] == nil then native_names[#native_names + 1] = app_name end
	end
	for _, app_name in ipairs(native_names) do
		local native = _gtk_windows[app_name]
		if native then
			local called, accepted = pcall(M._destroy_gtk_window, app_name, native.epoch)
			if not called or accepted ~= true then retired = false end
		end
	end
	-- Retry only captured document owners whose native/input retirement was admitted.
	local documents = {}
	for entry in pairs(_document_debts) do documents[#documents + 1] = entry end
	for _, entry in ipairs(documents) do
		if entry.close_allowed and retire_document_entry(entry) ~= true then retired = false end
	end
	if next(_windows) ~= nil or next(_gtk_windows) ~= nil
		or next(_document_windows) ~= nil or next(_document_debts) ~= nil then retired = false end
	if retired then
		local gate = _daemon_state.input_capture_gate
		if type(gate) == "table" and type(gate.release_all) == "function" then
			local called, accepted = pcall(gate.release_all)
			if not called or accepted == false then
				retired = false
				Logger.error(LOG, "Input ownership shutdown refused.")
			end
		end
	end
	_shutting_down = false
	if retired then Logger.info(LOG, "WebView manager shut down.") end
	return retired
end

-- Auto-init on module load so the GTK probe runs once.
M.init()


--- Exposes the page-message decoder and the reply encoder to tests.
M._js_value_to_lua_for_test = _js_value_to_lua
M._send_response_to_js_for_test = _send_response_to_js

return M
