--- modules/ui/webview_manager.lua

--- ==============================================================================
--- MODULE: WebView Manager (Linux)
--- DESCRIPTION:
--- Manages the lifecycle of WebKitGTK-based webview windows. Registers bridge
--- handlers for JS↔Lua communication, loads shared HTML/UI apps via
--- webkit_host.lua, and routes messages from the JS host_bridge.js to the
--- appropriate bridge handler module.
---
--- This module is PURE LUA — the actual GTK/WebKit2GTK rendering requires
--- lgi/GObject introspection which is only available on Linux. All bridge
--- handler logic is testable on any platform.
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
local LOG = "modules.ui.webview_manager"

-- webkit_host provides HTML building and bridge name registry.
local webkit_host = require("ui.webkit_host")


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
	Logger.success(LOG, "GTK/WebKit2GTK available via lgi — webview rendering enabled.")
	return true
end


-- =========================================
-- =========================================
-- ======= 2/ Bridge Handler Registry ======
-- =========================================
-- =========================================

--- Resolves the driver root from this module's location.
--- @return string Absolute path to the linux driver root.
local function _driver_root()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	return (src:match("^(.*)[/\\\\]modules[/\\\\]ui[/\\\\]webview_manager%.lua$")
		or src:match("^(.*)[/\\\\]modules[/\\\\]ui$")
		or "."):gsub("\\", "/")
end

--- Loads a bridge handler module by pcall-requiring it.
--- @param app_name string The app directory name (also the handler module name suffix).
--- @return table|nil The handler module, or nil if not found.
local function _load_handler(app_name)
	local module_name = "modules.ui.bridge_handlers." .. app_name .. "_bridge"
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
-- ======= 6/ GTK-specific Operations ======
-- =========================================
-- =========================================

--- Creates a GTK WebKit2 window (Linux only, requires lgi).
--- @param app_name string The app name.
--- @param html string The HTML string to load.
--- @param handler table|nil The bridge handler module.
function M._create_gtk_window(app_name, html, handler)
	if not _gtk_available then return end
	-- The actual GTK window creation requires lgi.WebKit2 and is only
	-- executable on a Linux machine with the proper GObject bindings.
	-- This stub is here for the API contract; the real implementation
	-- lives in a native entry point or a companion script.
	Logger.info(LOG, "_create_gtk_window: stub — GTK window for '%s' would load %d bytes.",
		app_name, #(html or ""))
end

--- Destroys a GTK window (Linux only).
--- @param app_name string The app name.
function M._destroy_gtk_window(app_name)
	if not _gtk_available then return end
	Logger.info(LOG, "_destroy_gtk_window: stub — GTK window for '%s' would close.", app_name)
end

--- Focuses a GTK window (Linux only).
--- @param app_name string The app name.
function M._focus_gtk_window(app_name)
	if not _gtk_available then return end
	Logger.info(LOG, "_focus_gtk_window: stub — GTK window for '%s' would focus.", app_name)
end


-- =========================================
-- =========================================
-- ======= 7/ Initialisation ===============
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
