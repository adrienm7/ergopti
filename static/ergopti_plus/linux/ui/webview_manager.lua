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
--- Linux). When lgi is not available, all GTK operations gracefully no-op
--- and bridge handler logic remains testable.
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
local LOG = "ui.webview_manager"

-- webkit_host provides HTML building and bridge name registry.
local webkit_host = require("ui.webkit_host")

-- Optional JSON codec for manifest parsing and JS value conversion.
local dkjson = nil
pcall(function()
	local ok, mod = pcall(require, "dkjson")
	if ok then dkjson = mod end
end)


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

-- Try to load lgi for GTK/WebKit2GTK access (only available on Linux).
local function _probe_gtk()
	local ok, lgi = pcall(require, "lgi")
	if not ok then
		Logger.debug(LOG, "lgi not available — webview rendering disabled (pure-Lua bridge mode).")
		return false
	end
	if not pcall(function() return lgi.WebKit2 end) then
		Logger.debug(LOG, "lgi.WebKit2 not available — webview rendering disabled.")
		return false
	end
	_lgi = lgi
	Logger.success(LOG, "GTK/WebKit2GTK available via lgi — webview rendering enabled.")
	return true
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
--- `personal_toml_editor` is the one real exception: not a page of its own but a
--- second bridge onto `personal_info_editor`, the TOML flavour, reached through
--- the page it shares. That is what still makes a lookup better than a suffix
--- rule. tests/unit/meta/test_webview_app_names_have_pages.lua pins both halves.
local BRIDGE_MODULES = {
	action_picker         = "ui.action_picker.bridge",
	changelog             = "ui.changelog.bridge",
	download_window       = "ui.download_window.bridge",
	healthcheck           = "ui.healthcheck.bridge",
	hotstring_editor      = "ui.hotstring_editor.bridge",
	-- Keyed by the DIRECTORY name. It read "hotstrings_config" until 2026-08-05,
	-- which gave that name a working bridge and no page: resolve_app_dir() looks
	-- for _shared/ui/<name>/index.html and there is no _shared/ui/hotstrings_config,
	-- so every caller using it got a window rendering "Error: app not found" while
	-- the bridge behind it was perfectly healthy. A half-registered name is worse
	-- than an unregistered one — it looks supported at the only place anyone checks.
	hotstrings_config_window = "ui.hotstrings_config_window.bridge",
	metrics_apps          = "ui.metrics_apps.bridge",
	metrics_typing        = "ui.metrics_typing.bridge",
	model_browser         = "ui.model_browser.bridge",
	onboarding            = "ui.onboarding.bridge",
	paths_editor          = "ui.paths_editor.bridge",
	personal_info_editor  = "ui.personal_info_editor.bridge",
	personal_toml_editor  = "ui.personal_info_editor.bridge_toml",
	prompt_editor         = "ui.prompt_editor.bridge",
	token_prompt          = "ui.token_prompt.bridge",
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

--- Opens a webview window for the given shared UI app.
--- If the window already exists, brings it to front instead of creating a new one.
--- @param app_name string The shared UI app directory name (e.g. "action_picker").
--- @param active_locale string|nil Locale code (default: "fr").
--- @return boolean true if the window was opened or brought to front.
function M.show(app_name, active_locale)
	if type(app_name) ~= "string" or app_name == "" then
		Logger.error(LOG, "show(): app_name is required.")
		return false
	end

	-- If window already exists, bring to front.
	if _windows[app_name] then
		Logger.debug(LOG, "Window '%s' already open — bringing to front.", app_name)
		M.bring_to_front(app_name)
		return true
	end

	-- Build the HTML.
	local root = _driver_root()
	local html = webkit_host.build_app_html(root, app_name, active_locale)
	if not html or html == "" then
		Logger.error(LOG, "show(): failed to build HTML for '%s'.", app_name)
		return false
	end

	-- Load the bridge handler.
	local handler = _load_handler(app_name)

	-- Store window state.
	_windows[app_name] = {
		html    = html,
		handler = handler,
		visible = false,
	}

	-- If GTK is available, create the actual window.
	if _gtk_available then
		M._create_gtk_window(app_name, html, handler)
	else
		Logger.info(LOG, "Window '%s' registered in pure-Lua mode (no GTK). HTML: %d bytes.",
			app_name, #html)
	end

	_windows[app_name].visible = true
	return true
end

--- Hides/closes a webview window by app name.
--- @param app_name string The app name.
function M.hide(app_name)
	if not _windows[app_name] then return end
	_windows[app_name].visible = false
	if _gtk_available then
		M._destroy_gtk_window(app_name)
	end
	Logger.debug(LOG, "Window '%s' hidden.", app_name)
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
	return _windows[app_name] and _windows[app_name].visible == true
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

--- Routes a JS message from host_bridge.js to the appropriate bridge handler.
--- Called by the GTK script-message-received callback or by tests.
--- @param bridge_name string The bridge handler name (e.g. "action_picker_bridge").
--- @param payload any The message payload (string or table).
--- @return any The handler's response, or nil.
function M.route_message(bridge_name, payload)
	if not webkit_host.is_valid_bridge(bridge_name) then
		Logger.warn(LOG, "Unknown bridge name: %s", bridge_name)
		return nil
	end

	-- Find which app window this bridge belongs to.
	local app_name = nil
	for name, win in pairs(_windows) do
		if win.handler and win.handler.bridge_name == bridge_name then
			app_name = name
			break
		end
	end

	if not app_name then
		-- Try to load the handler on demand.
		app_name = bridge_name:gsub("_bridge$", "")
		local handler = _load_handler(app_name)
		if handler and handler.bridge_name == bridge_name then
			_windows[app_name] = { handler = handler, visible = false }
		else
			Logger.warn(LOG, "No handler found for bridge: %s", bridge_name)
			return nil
		end
	end

	local handler = _windows[app_name] and _windows[app_name].handler
	if not handler or type(handler.on_message) ~= "function" then
		Logger.warn(LOG, "Handler for '%s' has no on_message.", app_name)
		return nil
	end

	local ok, result = pcall(handler.on_message, payload, _daemon_state)
	if not ok then
		Logger.error(LOG, "Bridge '%s' handler error: %s", bridge_name, tostring(result))
		return nil
	end

	return result
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
			if json_str and json_str ~= "" and dkjson then
				local ok_json, parsed = pcall(dkjson.decode, json_str)
				if ok_json then return parsed end
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
local function _send_response_to_js(webview, bridge_name, value)
	if not webview or value == nil then return end
	if not dkjson then return end
	-- Encode the value as JSON, then base64 to avoid any escaping hazards.
	local json_str = dkjson.encode(value)
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
	pcall(function() webview:run_javascript(js_code, nil, nil, nil) end)
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
	if not raw or raw == "" or not dkjson then return defaults end
	local ok_dec, manifest = pcall(dkjson.decode, raw)
	if not ok_dec or not manifest or not manifest.apps then return defaults end
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
	local titles = {
		action_picker           = "Action Picker",
		changelog               = "Release Notes",
		download_window         = "Download",
		healthcheck             = "Diagnostic",
		hotstrings_config_window = "Hotstrings Config",
		hotstring_editor        = "Hotstring Editor",
		metrics_apps            = "Metrics — Apps",
		metrics_typing          = "Metrics — Typing",
		model_browser           = "Model Browser",
		onboarding              = "Setup Wizard",
		paths_editor            = "Paths Editor",
		personal_info_editor    = "Personal Info",
		prompt_editor           = "Prompt Editor",
		token_prompt            = "Token Settings",
	}
	return titles[app_name] or app_name:gsub("_", " "):gsub("(%a)([%w_]*)", function(a, b)
		return (a:upper() .. b:gsub("_", " "))
	end)
end


-- =========================================
-- ======= 7/ GTK Window Operations ========
-- =========================================
-- =========================================

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
function M._create_gtk_window(app_name, html, handler)
	if not _gtk_available or not _lgi then return end

	local Gtk     = _lgi.Gtk
	local WebKit2 = _lgi.WebKit2
	local GLib    = _lgi.GLib

	-- Read geometry from the single-source manifest.
	local geometry = _read_app_geometry(app_name)

	-- ── Create the GTK window ──
	local window = Gtk.Window({
		title            = "Ergopti — " .. _app_title(app_name),
		default_width    = geometry.width,
		default_height   = geometry.height,
		window_position  = Gtk.WindowPosition.CENTER,
		type             = Gtk.WindowType.TOPLEVEL,
	})

	-- Set minimum size if supported.
	pcall(function()
		window:set_size_request(geometry.min_width, geometry.min_height)
	end)

	-- ── UserContentManager: register all 14 bridge script-message handlers ──
	local ucm = WebKit2.UserContentManager()
	local bridge_names = webkit_host.get_bridge_names()

	for _, bridge_name in ipairs(bridge_names) do
		pcall(function()
			ucm:register_script_message_handler(bridge_name)
		end)
	end

	-- ── Connect script-message-received signals ──
	-- lgi supports detailed GObject signals via table-of-callbacks assignment:
	--   ucm.on_script_message_received = { [detail] = callback, ... }
	-- Each bridge name maps to a closure that parses the JS value and dispatches
	-- to M.route_message(), sending any response back to the webview.
	local function handle_script_message(bridge_name, js_result)
		local js_value = js_result:get_js_value()
		local payload = _js_value_to_lua(js_value)
		local response = M.route_message(bridge_name, payload)
		if response ~= nil and _gtk_windows[app_name] and _gtk_windows[app_name].webview then
			_send_response_to_js(_gtk_windows[app_name].webview, bridge_name, response)
		end
	end

	local detailed_signals = {}
	for _, bridge_name in ipairs(bridge_names) do
		detailed_signals[bridge_name] = function(_manager, js_result)
			handle_script_message(bridge_name, js_result)
		end
	end

	local ok_sig = pcall(function()
		ucm.on_script_message_received = detailed_signals
	end)
	if not ok_sig then
		Logger.warn(LOG, "Detailed GObject signal connection failed for '%s' — " ..
			"bridge handlers may not receive messages. Check lgi version.", app_name)
	end

	-- ── Create the WebView ──
	local webview = WebKit2.WebView({
		user_content_manager = ucm,
		visible              = true,
	})

	-- Load the inline HTML (base_uri nil = no file:// origin).
	webview:load_html(html, nil)

	-- ── Window lifecycle: close → hide (don't destroy, allow re-show) ──
	window.on_destroy = function()
		Logger.debug(LOG, "GTK window '%s' destroyed.", app_name)
		_gtk_windows[app_name] = nil
		_windows[app_name] = nil
	end

	-- Use delete-event to hide instead of destroy (allows bring_to_front later).
	window.on_delete_event = function()
		Logger.debug(LOG, "GTK window '%s' delete-event — hiding.", app_name)
		window:hide()
		if _windows[app_name] then
			_windows[app_name].visible = false
		end
		return true  -- stop other handlers (prevent destroy)
	end

	-- ── Assemble and show ──
	window:add(webview)
	window:show_all()

	-- ── Track native references ──
	_gtk_windows[app_name] = {
		window  = window,
		webview = webview,
	}

	Logger.success(LOG, "GTK window '%s' created (%dx%d).", app_name, geometry.width, geometry.height)

	-- Pump GTK events: if the daemon has a luv event loop, integrate.
	pcall(function()
		local event_loop = require("adapters.event_loop")
		if event_loop and event_loop.add_idle_handler then
			event_loop.add_idle_handler(function()
				if _gtk_windows[app_name] then
					local ctx = GLib.MainContext.default()
					if ctx then ctx:iteration(false) end
				end
			end)
		end
	end)
end

--- Destroys a GTK window (Linux only).
--- @param app_name string The app name.
function M._destroy_gtk_window(app_name)
	if not _gtk_available or not _lgi then return end
	local wref = _gtk_windows[app_name]
	if not wref or not wref.window then return end
	pcall(function() wref.window:destroy() end)
	_gtk_windows[app_name] = nil
	Logger.debug(LOG, "GTK window '%s' destroyed.", app_name)
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
	pcall(function()
		wref.window:present()
		if not wref.window.visible then
			wref.window:show_all()
		end
	end)
	Logger.debug(LOG, "GTK window '%s' focused.", app_name)
end


-- =========================================
-- =========================================
-- ======= 8/ Initialisation ===============
-- =========================================
-- =========================================

--- Initialises the webview manager. Probes for GTK availability.
function M.init()
	_gtk_available = _probe_gtk()
	Logger.info(LOG, "WebView manager initialised (GTK available: %s).", tostring(_gtk_available))
end

-- Auto-init on module load so the GTK probe runs once.
M.init()

return M
