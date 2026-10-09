--- ui/layout_manager/init.lua

--- ==============================================================================
--- MODULE: Layout Manager Window (macOS host)
--- DESCRIPTION:
--- Hosts the shared layout manager page (_shared/ui/layout_manager) in a
--- WKWebView: the "Manage layouts…" row of the keyboard-layout submenu opens
--- it, and it lists, installs, updates, uninstalls and selects the layouts of
--- the registry through modules/keymap/layout_registry.lua.
---
--- FEATURES & RATIONALE:
--- 1. The message rules and the page state are shared with Linux
---    (_shared/lua/layouts/manager_bridge.lua): an allowlist of actions, each
---    checked against the catalogue or the installed layouts before it runs.
--- 2. Singleton: a second open focuses the existing window. Only the exact
---    window this module created may receive pushes or close, so a late
---    callback of a closed window never writes into its successor.
--- 3. Nothing here runs on the typing path; every operation is asynchronous.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local DeferredWork  = require("infra.deferred_work")
local i18n          = require("infra.i18n")
local Paths         = require("infra.paths")
local FileSystem    = require("adapters.file_system")
local Json          = require("json")
local ManagerBridge = require("layouts.manager_bridge")

local LOG = "layout_manager"

-- Name of the page's message handler (_shared/ui/host_bridge.js catalogue).
local BRIDGE_NAME = "layout_manager_bridge"
-- Every string the page shows, declared next to it.
local STRINGS_FILE = "ui/layout_manager/strings.json"

-- The exact window this module created, and its message channel.
local _webview = nil
local _usercontent = nil
local _controller = nil





-- ================================
-- ================================
-- ======= 1/ Page plumbing =======
-- ================================
-- ================================

--- The translated strings the page shows.
--- @return table key -> text
local function page_strings()
	local path = Paths.shared(STRINGS_FILE)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local strings = {}
	if not ok or type(doc) ~= "table" or type(doc.keys) ~= "table" then
		Logger.error(LOG, "The layout manager strings list %s is unreadable.", tostring(path))
		return strings
	end
	for _, key in ipairs(doc.keys) do strings[key] = i18n.get(key) end
	return strings
end

--- Evaluates window.<function_name>(payload) in the exact window.
--- @param view any The window the push is meant for.
--- @param function_name string
--- @param payload table
--- @return boolean pushed
local function push_to(view, function_name, payload)
	if view == nil or view ~= _webview then return false end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "The layout manager %s payload could not be encoded.", function_name)
		return false
	end
	local submitted = pcall(function()
		view:evaluateJavaScript("if(window." .. function_name .. ")window." .. function_name .. "(" .. encoded .. ")")
	end)
	if not submitted then Logger.error(LOG, "The layout manager %s push was refused.", function_name) end
	return submitted
end

--- Closes the window this module created.
local function close_window()
	local view = _webview
	_webview, _usercontent, _controller = nil, nil, nil
	if view ~= nil then
		local ok, err = pcall(function() view:delete() end)
		if not ok then Logger.error(LOG, "The layout manager window did not close: %s.", tostring(err)) end
	end
end

--- The controller of one window, bound to that exact window.
--- @param view any
--- @return table
local function controller_for(view)
	local controller = ManagerBridge.new({
		registry = require("modules.keymap.layout_registry"),
		push = function(function_name, payload) return push_to(view, function_name, payload) end,
		strings = page_strings,
		open_url = function(url)
			local ok, ui_builder = pcall(require, "ui.ui_builder")
			if ok then ui_builder.open_http_url(url) end
		end,
		close = function()
			if view == _webview then close_window() end
		end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
	local on_message = controller.on_message
	local ready = false
	controller.on_message = function(payload)
		local is_ready = type(payload) == "table" and payload.action == "ready"
		if is_ready then
			if ready then return false end
			-- Native navigation and page readiness both target this exact window.
			ready = true
		end
		local ok, result = pcall(on_message, payload)
		if not ok then
			if is_ready then ready = false end
			error(result, 0)
		end
		return result
	end
	return controller
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the layout manager, or focuses it when it is already open.
--- @return boolean opened
function M.open()
	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui then
		Logger.error(LOG, "The layout manager cannot open: ui_builder is unavailable.")
		return false
	end
	if _webview ~= nil then
		ui_builder.force_focus(_webview, false)
		return true
	end
	Logger.start(LOG, "Opening the layout manager…")
	local ok_uc, uc = pcall(hs.webview.usercontent.new, BRIDGE_NAME)
	if not ok_uc or not uc then
		Logger.error(LOG, "The layout manager message channel could not be created.")
		return false
	end
	local geo = ui_builder.get_app_geometry("layout_manager")
	if not geo then return false end
	local candidate = nil
	uc:setCallback(function(message)
		if candidate == nil or candidate ~= _webview or _controller == nil then return end
		if message and type(message.body) == "table" then _controller.on_message(message.body) end
	end)
	local masks = hs.webview.windowMasks
	local view = ui_builder.show_webview({
		frame = ui_builder.get_centered_frame(geo.width, geo.height),
		title = i18n.get("layout_manager.window_title"),
		style_masks = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8),
		usercontent = uc,
		assets_dir = (Paths.shared("ui/layout_manager") or "") .. "/",
		on_close = function()
			if candidate ~= nil and candidate == _webview then
				_webview, _usercontent, _controller = nil, nil, nil
			end
		end,
		on_navigation = function(action)
			if action == "didFinishNavigation" and candidate ~= nil and candidate == _webview and _controller then
				DeferredWork.after(0.05, function()
					if candidate == _webview and _controller then _controller.on_message({ action = "ready" }) end
				end, "layout_manager.navigation")
			end
			return true
		end,
		on_webview_created = function(owned)
			if _webview ~= nil then return false end
			candidate = owned
			_webview, _usercontent = owned, uc
			_controller = controller_for(owned)
			return true
		end,
		is_current = function() return candidate ~= nil and candidate == _webview end,
	})
	if view == nil or view ~= candidate then
		_webview, _usercontent, _controller = nil, nil, nil
		Logger.error(LOG, "The layout manager window could not be created.")
		return false
	end
	Logger.success(LOG, "Layout manager opened.")
	return true
end

--- Builds the "Manage layouts…" menu command.
--- @return function
function M.menu_command()
	return function()
		DeferredWork.after(0.05, M.open, "layout_manager.open")
	end
end

-- Test seams: the controller factory and the exact-window push.
M._controller_for = controller_for
M._page_strings = page_strings

return M
