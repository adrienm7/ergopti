--- ui/permission_dialog/init.lua

--- ==============================================================================
--- MODULE: Permission Dialog
--- DESCRIPTION:
--- The window that walks the user through one macOS privacy grant: the app
--- icon, what to allow and why, numbered steps, and two buttons, "Open
--- Settings" (the exact pane again) and "Later".
---
--- FEATURES & RATIONALE:
--- 1. A window, not a banner: the Accessibility wait used to print its
---    instructions as one long single-line banner along the Dock. It could not
---    be clicked, read as noise, and packed three steps into one sentence. The
---    dialog is a titled window with the chrome every ErgoptiPlus window has.
--- 2. Never blocks: a webview window answers through a script bridge, so the
---    boot and the grant poll keep running while it is open. A blocking modal
---    would park the main runloop, and the non-blocking alert sheet cannot be
---    closed by its owner once the grant arrives.
--- 3. One owner: at most one dialog exists. Showing the same permission again
---    raises the open window instead of stacking a copy; showing another
---    permission replaces it.
--- 4. Closed by its owner: the caller closes it as soon as its poll sees the
---    grant, so nobody has to dismiss a dialog about a permission already given.
--- 5. Names the entry macOS lists: the grant belongs to the running runtime,
---    listed as "Hammerspoon", so the steps name it and give its bundle path for
---    the + button. The icon shown is that runtime's own icon, the one beside
---    the switch in the list.
--- ==============================================================================

local M = {}

local hs         = hs
local Logger     = require("infra.logger")
local i18n       = require("infra.i18n")
local ui_builder = require("ui.ui_builder")

local LOG = "permission_dialog"

-- Script message handler the page posts its button actions to.
M.BRIDGE = "permission_dialog_bridge"

-- Permissions this dialog explains; each owns the locale keys under its prefix.
M.KINDS = {
	accessibility = { prefix = "permission_dialog.accessibility" },
}

-- Gap between the dialog and the left edge of the screen. System Settings
-- opens centered with its switches on the right of the list, so a dialog on
-- the left leaves them uncovered while it floats above the Settings window.
local SCREEN_MARGIN = 40

-- The open dialog: { kind, webview, usercontent, open_settings }, or nil.
local _session = nil




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Checks a show request before any side effect.
--- @param spec table Show request.
local function validate(spec)
	if type(spec) ~= "table" then error("permission_dialog.show: spec must be a table", 3) end
	if M.KINDS[spec.kind] == nil then
		error("permission_dialog.show: unknown permission kind " .. tostring(spec.kind), 3)
	end
	if type(spec.open_settings) ~= "function" then
		error("permission_dialog.show: open_settings must be a function", 3)
	end
	if type(spec.bundle_path) ~= "string" or spec.bundle_path == "" then
		error("permission_dialog.show: bundle_path must be a non-empty string", 3)
	end
end

--- Escapes text for an HTML text node or a double-quoted attribute.
--- @param text string Raw text.
--- @return string escaped
local function escape_html(text)
	return (tostring(text):gsub("[&<>\"']", {
		["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\""] = "&quot;", ["'"] = "&#39;",
	}))
end

--- Returns the running app's icon as a data URL, the icon macOS shows beside
--- the switch to turn on.
--- @return string|nil url Nil when the icon cannot be encoded.
local function app_icon_url()
	local ok, url = pcall(function()
		local image = hs.image.imageFromName("NSApplicationIcon")
		return image and image:encodeAsURLString() or nil
	end)
	if not ok or type(url) ~= "string" or url == "" then
		Logger.warn(LOG, "App icon unavailable for the permission dialog: %s.", tostring(url))
		return nil
	end
	return url
end

--- Resolves every translated string of one dialog.
--- @param kind string Permission kind.
--- @param bundle_path string Path of the runtime the grant belongs to.
--- @return table content { window_title, title, body, steps, open_label, later_label }
function M.content(kind, bundle_path)
	local prefix = M.KINDS[kind].prefix
	return {
		window_title = i18n.get("permission_dialog.window_title"),
		title        = i18n.get(prefix .. ".title"),
		body         = i18n.get(prefix .. ".body"),
		steps        = {
			i18n.get(prefix .. ".step_opened"),
			i18n.get(prefix .. ".step_toggle"),
			i18n.format("permission_dialog.step_add", bundle_path),
		},
		open_label   = i18n.get("permission_dialog.open_settings"),
		later_label  = i18n.get("common.later"),
	}
end

-- Page style: system font and colours, light and dark, buttons laid out as in
-- a native alert (default action on the right).
local STYLE = table.concat({
	":root{color-scheme:light dark}",
	"html,body{margin:0;height:100%}",
	"body{font:13px -apple-system,BlinkMacSystemFont,sans-serif;background:Canvas;color:CanvasText;",
	"-webkit-user-select:none;cursor:default;display:flex;flex-direction:column;box-sizing:border-box;padding:20px 22px 18px}",
	".head{display:flex;gap:16px;align-items:flex-start}",
	".icon{width:64px;height:64px;flex:none}",
	"h1{font-size:14px;font-weight:600;margin:4px 0 6px}",
	"p{margin:0;line-height:1.45;opacity:.85}",
	"ol{margin:14px 0 0 80px;padding:0 0 0 18px;line-height:1.45}",
	"li{margin:0 0 8px}",
	"code{font:12px ui-monospace,Menlo,monospace;-webkit-user-select:text;word-break:break-all}",
	".buttons{margin-top:auto;display:flex;justify-content:flex-end;gap:10px;padding-top:14px}",
	"button{font:13px -apple-system,sans-serif;min-width:96px;padding:4px 14px;border-radius:6px;",
	"border:1px solid rgba(128,128,128,.35);background:ButtonFace;color:ButtonText}",
	"button.default{background:AccentColor;color:AccentColorText;border-color:transparent}",
}, "")

--- Builds the page of one dialog.
--- @param content table Translated strings from M.content.
--- @param bundle_path string Path quoted in the + step.
--- @param icon_url string|nil Data URL of the app icon.
--- @return string html
function M.render(content, bundle_path, icon_url)
	local steps = {}
	for index, step in ipairs(content.steps) do
		local text = escape_html(step)
		-- The path is the one fragment the user copies; it is set apart as code.
		if index == #content.steps then
			local quoted = escape_html(bundle_path)
			local at = text:find(quoted, 1, true)
			if at ~= nil then
				text = text:sub(1, at - 1) .. "<code>" .. quoted .. "</code>" .. text:sub(at + #quoted)
			end
		end
		steps[#steps + 1] = "<li>" .. text .. "</li>"
	end
	local icon = icon_url and ('<img class="icon" alt="" src="' .. escape_html(icon_url) .. '">') or ""
	return table.concat({
		"<!doctype html><html><head><meta charset=\"utf-8\"><style>", STYLE, "</style></head><body>",
		"<div class=\"head\">", icon, "<div><h1>", escape_html(content.title), "</h1><p>",
		escape_html(content.body), "</p></div></div>",
		"<ol>", table.concat(steps), "</ol>",
		"<div class=\"buttons\"><button id=\"later\">", escape_html(content.later_label),
		"</button><button id=\"open\" class=\"default\">", escape_html(content.open_label),
		"</button></div>",
		"<script>",
		"function send(a){try{window.webkit.messageHandlers.", M.BRIDGE,
		".postMessage({action:a});}catch(e){}}",
		"document.getElementById('open').onclick=function(){send('open_settings');};",
		"document.getElementById('later').onclick=function(){send('later');};",
		"document.addEventListener('keydown',function(e){",
		"if(e.key==='Enter'){send('open_settings');}else if(e.key==='Escape'){send('later');}});",
		"</script></body></html>",
	})
end

--- Places the dialog on the left of the main screen, vertically centered.
--- @param geometry table Manifest geometry { width, height }.
--- @return table frame { x, y, w, h }
local function dialog_frame(geometry)
	local frame = ui_builder.get_centered_frame(geometry.width, geometry.height)
	local ok, screen_frame = pcall(function() return hs.screen.mainScreen():frame() end)
	if ok and type(screen_frame) == "table" and type(screen_frame.x) == "number" then
		frame.x = screen_frame.x + SCREEN_MARGIN
	end
	return frame
end

--- Raises the open window of a session.
--- @param session table The open dialog.
--- @return boolean raised
local function raise(session)
	local ok, err = pcall(function()
		session.webview:show()
		session.webview:bringToFront(true)
	end)
	if not ok then
		Logger.warn(LOG, "The %s permission dialog could not be raised: %s.", session.kind, tostring(err))
		return false
	end
	Logger.info(LOG, "The %s permission dialog was already open; raised it.", session.kind)
	return true
end

--- Runs one button action of the page.
--- @param session table The dialog that received it.
--- @param action any Action name posted by the page.
local function on_action(session, action)
	if _session ~= session then return end
	if action == "open_settings" then
		Logger.info(LOG, "Reopening the %s Settings pane from the permission dialog.", session.kind)
		local ok, opened = pcall(session.open_settings)
		if not ok or opened ~= true then
			Logger.error(LOG, "The %s Settings pane could not be opened: %s.", session.kind, tostring(opened))
		end
	elseif action == "later" then
		Logger.info(LOG, "The %s permission dialog was dismissed for later.", session.kind)
		M.close(session.kind)
	else
		Logger.warn(LOG, "The permission dialog ignored an unknown action: %s.", tostring(action))
	end
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Shows the dialog of one permission, or raises it when it is already open.
--- Never blocks: the call returns as soon as the window is on screen.
--- @param spec table { kind = a key of M.KINDS,
---        open_settings = fn() -> boolean (reopens the exact pane),
---        bundle_path = string (runtime the grant belongs to) }.
--- @return boolean shown True when the dialog of this kind is open.
function M.show(spec)
	validate(spec)
	if _session ~= nil and _session.kind == spec.kind then
		raise(_session)
		return true
	end
	if _session ~= nil and M.close(_session.kind) ~= true then
		Logger.error(LOG, "The %s permission dialog could not replace the open one.", spec.kind)
		return false
	end

	Logger.start(LOG, "Opening the %s permission dialog…", spec.kind)
	local geometry = ui_builder.get_app_geometry("permission_dialog")
	if geometry == nil then
		Logger.error(LOG, "The %s permission dialog has no geometry in the apps manifest.", spec.kind)
		return false
	end
	local ok_uc, usercontent = pcall(hs.webview.usercontent.new, M.BRIDGE)
	if not ok_uc or usercontent == nil then
		Logger.error(LOG, "The permission dialog bridge could not be created: %s.", tostring(usercontent))
		return false
	end
	local session = { kind = spec.kind, usercontent = usercontent, open_settings = spec.open_settings }
	usercontent:setCallback(function(message)
		local body = type(message) == "table" and message.body or nil
		on_action(session, type(body) == "table" and body.action or nil)
	end)

	local content = M.content(spec.kind, spec.bundle_path)
	_session = session
	local built, webview = xpcall(ui_builder.show_webview, debug.traceback, {
		frame         = dialog_frame(geometry),
		title         = content.window_title,
		usercontent   = usercontent,
		html_string   = M.render(content, spec.bundle_path, app_icon_url()),
		inject_i18n   = false,
		on_close      = function()
			if _session == session then
				_session = nil
				Logger.info(LOG, "The %s permission dialog was closed by the user.", session.kind)
			end
		end,
	})
	if not built or webview == nil then
		-- A raise here must not leave an owner without a window: every later
		-- request would then "raise" nothing instead of opening the dialog.
		if _session == session then _session = nil end
		Logger.error(LOG, "The %s permission dialog window could not be created: %s.", spec.kind,
			tostring(built and "no window" or webview))
		return false
	end
	session.webview = webview
	if _session ~= session then
		-- The window closed while it was being built; keep no reference to it.
		Logger.warn(LOG, "The %s permission dialog closed while opening.", spec.kind)
		return false
	end
	Logger.success(LOG, "The %s permission dialog is open.", spec.kind)
	return true
end

--- Closes the dialog. With a kind, only the dialog of that permission closes.
--- @param kind string|nil Permission kind, or nil for whichever is open.
--- @return boolean closed True when no matching dialog remains open.
function M.close(kind)
	local session = _session
	if session == nil or (kind ~= nil and session.kind ~= kind) then return true end
	_session = nil
	local webview = session.webview
	if webview == nil then return true end
	local ok, err = pcall(function() webview:delete() end)
	if not ok then
		Logger.error(LOG, "The %s permission dialog could not be closed: %s.", session.kind, tostring(err))
		return false
	end
	Logger.info(LOG, "The %s permission dialog closed.", session.kind)
	return true
end

--- Shows the Accessibility dialog for the boot wait. Never raises and never
--- blocks: the wait keeps polling whatever happens here, with the Settings
--- pane already open, so a dialog failure costs the steps, not the boot.
--- @param permission table Accessibility permission adapter
---        { bundle_path(), open_settings() }.
--- @return function close Closes the dialog; the wait calls it on the grant.
function M.guide_accessibility(permission)
	local function close_dialog()
		local ok, err = xpcall(M.close, debug.traceback, "accessibility")
		if not ok then Logger.error(LOG, "The Accessibility dialog close raised: %s.", tostring(err)) end
	end
	local ok, shown = xpcall(function()
		local bundle_path, path_err = permission.bundle_path()
		if bundle_path == nil then
			Logger.error(LOG, "The Accessibility dialog cannot name the app: %s.", tostring(path_err))
			return false
		end
		return M.show({
			kind          = "accessibility",
			open_settings = permission.open_settings,
			bundle_path   = bundle_path,
		})
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "The Accessibility dialog raised while opening: %s.", tostring(shown))
	elseif shown ~= true then
		Logger.warn(LOG, "The Accessibility dialog is not shown; the Settings pane and the macOS prompt remain.")
	end
	return close_dialog
end

--- Reports whether a dialog is open.
--- @param kind string|nil Permission kind, or nil for any.
--- @return boolean
function M.is_open(kind)
	if _session == nil then return false end
	return kind == nil or _session.kind == kind
end

return M
