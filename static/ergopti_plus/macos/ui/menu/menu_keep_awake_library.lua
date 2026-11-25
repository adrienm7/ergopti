--- ui/menu/menu_keep_awake_library.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Library Window (macOS)
--- DESCRIPTION:
--- Opens _shared/ui/keep_awake_library (bridge "hsKeepAwake") from the
--- « Anti-veille » menu row and hands its messages to the shared library host
--- (_shared/shortcuts/engine/keep_awake_library_host.lua) with the macOS
--- ports: the page push through the WebView, screencapture's selection for
--- « Ajouter un bouton… », the launcher's vision worker to convert an image
--- file, and the native open and save panels.
---
--- FEATURES & RATIONALE:
--- 1. One window: a second open focuses it; a message of a window that is no
---    longer the open one is ignored.
--- 2. No OS call here: the channel and style come from
---    core/ui/adapters/webview_channel.lua, the panels from file_panel.lua,
---    the window from ui_builder.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.logger")
local Paths = require("core.fs.engine.paths")

local M = {}

local LOG = "ui.menu.keep_awake_library"

local LibraryHost = require("shortcuts.engine.keep_awake_library_host")
local APP_ID = LibraryHost.APP_ID
local BRIDGE = LibraryHost.BRIDGE
local ASSETS_DIR = (Paths.shared("ui/" .. APP_ID) or "") .. "/"

local _webview, _channel, _host = nil, nil, nil

--- Calls a page function with a JSON payload.
--- @param view userdata The window's WebView.
--- @param function_name string
--- @param payload table
local function push(view, function_name, payload)
	if view == nil or view ~= _webview then return end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok then
		Logger.error(LOG, "Could not encode the %s library-window payload.", function_name)
		return
	end
	view:evaluateJavaScript("if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
end

--- Closes the window and forgets its host.
local function close()
	local view, channel = _webview, _channel
	_webview, _channel, _host = nil, nil, nil
	if view then pcall(function() view:delete() end) end
	if channel then pcall(function() channel:setCallback(nil) end) end
end

--- The shared library host for one open window.
--- @param view userdata
--- @return table host
local function host_for(view)
	local i18n = require("core.i18n.engine.i18n")
	local FileSystem = require("core.fs.adapters.file_system")
	local Panel = require("core.ui.adapters.file_panel")
	local Mode = require("modules.shortcuts.actions.auto_click")
	local Capture = require("modules.shortcuts.actions.ocr_capture")
	return LibraryHost.new({
		library = Mode.library(),
		os_name = "macos", separator = "/",
		push = function(function_name, payload) push(view, function_name, payload) end,
		translate = function(key) return i18n.get(key) end,
		capture_region = Capture.select_region,
		convert_image = function(callback)
			local source = Panel.choose_file(i18n.get("keepawake.library.import_image"), "images")
			if not source then return callback(nil, "cancelled") end
			local Vision = Mode.vision()
			local out = Vision.new_capture_path()
			Vision.import_image(source, out, function(answer, reason)
				if not answer then return callback(nil, reason) end
				callback(out)
			end)
		end,
		save_path = function(default_name) return Panel.save_file(i18n.get("keepawake.library.export"), default_name) end,
		open_path = function() return Panel.choose_file(i18n.get("keepawake.library.import"), "preset") end,
		read_file = function(path)
			local body, status = FileSystem.read_with_status(path)
			if status ~= "ok" then return nil end
			return body
		end,
		write_file = function(path, bytes) return FileSystem.write(path, bytes) == true end,
		remove_file = function(path) FileSystem.remove_exact(path) end,
		close = close,
	})
end

--- Opens the window, or focuses the open one (the « Anti-veille » menu row).
--- @return boolean opened
function M.open()
	local ui_builder = require("core.ui.ui.builder")
	if _webview then
		ui_builder.force_focus(_webview, false, { is_current = function() return _webview ~= nil end })
		return true
	end
	local Channel = require("core.ui.adapters.webview_channel")
	local channel, refusal = Channel.new(BRIDGE)
	if not channel then
		Logger.error(LOG, "The library window channel could not be created: %s.", tostring(refusal))
		return false
	end
	local geo = ui_builder.get_app_geometry("keep_awake_library")
	if not geo then return false end
	local candidate = nil
	channel:setCallback(function(message)
		if candidate == nil or candidate ~= _webview or _host == nil then return end
		if message and type(message.body) == "table" then _host.on_message(message.body) end
	end)
	_channel = channel
	local view = ui_builder.show_webview({
		delete_on_close = true,
		frame = ui_builder.get_app_frame(geo),
		app_id = APP_ID,
		style_masks = Channel.resizable_style(),
		usercontent = channel,
		assets_dir = ASSETS_DIR,
		on_close = function()
			if _webview == candidate then _webview, _channel, _host = nil, nil, nil end
		end,
		on_navigation = function() return true end,
		on_webview_created = function(owned)
			if _webview ~= nil then return false end
			candidate = owned
			_webview = owned
			_host = host_for(owned)
			return true
		end,
		is_current = function() return candidate ~= nil and _webview == candidate end,
	})
	if view == nil or view ~= candidate then
		Logger.error(LOG, "The library window could not be created.")
		close()
		return false
	end
	Logger.info(LOG, "Anti-sleep library window opened.")
	return true
end

--- The open window, for ui/window_toggle (nil when closed).
--- @return userdata|nil
function M.window() return _webview end

return M
