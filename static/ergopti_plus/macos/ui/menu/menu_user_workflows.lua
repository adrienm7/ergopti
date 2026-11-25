--- ui/menu/menu_user_workflows.lua

--- ==============================================================================
--- MODULE: User Workflows Window (macOS)
--- DESCRIPTION:
--- Opens _shared/ui/user_workflows (bridge "hsWorkflows") from the Shortcuts
--- menu row and hands its messages to the shared editor host
--- (_shared/shortcuts/engine/workflows/editor_host.lua) with the macOS ports:
--- the page push through the WebView, the native open and save panels, and
--- the parameterless actions of the gesture registry.
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

local LOG = "ui.menu.user_workflows"
local EditorHost = require("shortcuts.engine.workflows.editor_host")
local APP_ID = EditorHost.APP_ID
local BRIDGE = EditorHost.BRIDGE
local ASSETS_DIR = (Paths.shared("ui/" .. APP_ID) or "") .. "/"

local _webview, _channel, _host = nil, nil, nil

--- The parameterless action ids of the registry.
--- @return table
local function action_ids()
	local Actions = require("gestures.engine.actions")
	local ids = {}
	for _, id in ipairs(Actions.get_sg_names()) do
		if Actions.get_action_parameter_spec(id) == nil then ids[#ids + 1] = id end
	end
	return ids
end

--- Calls a page function with a JSON payload.
--- @param view userdata The window's WebView.
--- @param function_name string
--- @param payload table
local function push(view, function_name, payload)
	if view == nil or view ~= _webview then return end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok then
		Logger.error(LOG, "Could not encode the %s workflow-editor payload.", function_name)
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

--- The shared editor host for one open window.
--- @param view userdata
--- @return table host
local function host_for(view)
	local i18n = require("core.i18n.engine.i18n")
	local FileSystem = require("core.fs.adapters.file_system")
	local Panel = require("core.ui.adapters.file_panel")
	return require("shortcuts.engine.workflows.editor_host").new({
		workflows = require("modules.shortcuts.workflows"),
		push = function(function_name, payload) push(view, function_name, payload) end,
		translate = function(key) return i18n.get(key) end,
		action_ids = action_ids,
		save_path = function(default_name) return Panel.save_file(i18n.get("workflows.editor.export"), default_name) end,
		open_path = function(kind)
			return Panel.choose_file(i18n.get(kind == "png" and "workflows.editor.add_image" or "workflows.editor.import"),
				kind == "png" and "png" or "workflows")
		end,
		read_file = function(path)
			local body, status = FileSystem.read_with_status(path)
			if status ~= "ok" then return nil end
			return body
		end,
		write_file = function(path, text) return FileSystem.write(path, text) == true end,
		close = close,
	})
end

--- Opens the window, or focuses the open one (the Shortcuts menu row).
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
		Logger.error(LOG, "The workflow editor channel could not be created: %s.", tostring(refusal))
		return false
	end
	local geo = ui_builder.get_app_geometry("user_workflows")
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
			if _webview == candidate then
				require("modules.shortcuts.workflows").abort_all()
				_webview, _channel, _host = nil, nil, nil
			end
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
		Logger.error(LOG, "The workflow editor window could not be created.")
		close()
		return false
	end
	Logger.info(LOG, "Workflow editor opened.")
	return true
end

--- The open window, for ui/window_toggle (nil when closed).
--- @return userdata|nil
function M.window() return _webview end

return M
