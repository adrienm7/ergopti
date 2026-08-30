--- ui/action_picker/init.lua

--- ==============================================================================
--- MODULE: Action Picker UI
--- DESCRIPTION:
--- Webview-based, searchable, categorised action chooser. Replaces the native
--- hs.chooser used to assign an action to a gesture / shortcut slot, rendering
--- the shared frontend at _shared/ui/action_picker/ so the AHK and Hammerspoon
--- drivers show an identical picker.
---
--- FEATURES & RATIONALE:
--- 1. Singleton replacement — a second target supersedes the prior window and
---    bridge, so a queued message can never confirm against the prior callback.
--- 2. Caller-agnostic — M.open(opts, on_confirm) takes a pre-built, categorised
---    action list ({id,label,category}); the catalogue is assembled by the caller
---    (it already knows the ordered names + labels), so this module is reusable by
---    any slot type.
--- 3. The page reports the chosen id back through the action_picker_bridge
---    usercontent channel; the host invokes on_confirm(id) and closes.
--- ==============================================================================

local M = {}

local hs         = hs
local ui_builder = require("ui.ui_builder")
local Logger     = require("infra.logger")
local i18n       = require("infra.i18n")
local Paths      = require("infra.paths")

local LOG = "action_picker"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil
local _session_serial = 0
local _active_session = nil

-- Window geometry is resolved at open time from the shared manifest
-- (ui_builder.get_app_geometry → _shared/ui/apps.manifest.json, SSoT). No local
-- width/height constant: hardcoding here is what caused the cross-driver drift.

-- The frontend lives in the cross-driver _shared/ui/ tree (shared with the
-- Windows WebView2 host); both drivers resolve it through Paths.shared.
local ASSETS_DIR = (Paths.shared("ui/action_picker") or "") .. "/"





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Closes one exact picker session without letting a stale close affect its successor.
--- @param session table Session identity.
--- @return boolean closed Whether this session still owned the window.
local function close_session(session)
	if _active_session ~= session then return false end
	local webview = session.webview
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Action picker close refused; owned WebView has no delete method.")
			return false
		end
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		if not ok then
			-- ui_builder may deliver on_close synchronously before native deletion
			-- raises. Restore the exact session so replacement and callback retries
			-- cannot escape the still-ambiguous native owner.
			_active_session = session
			_webview = webview
			_usercontent = session.usercontent
			Logger.error(LOG, "Action picker close did not commit; exact WebView retained: %s.",
				tostring(err))
			return false
		end
	end
	if _active_session == session then
		_active_session = nil
		_webview = nil
		_usercontent = nil
	end
	return true
end

--- Open the action picker for a new target, replacing any prior target.
--- @param opts table { title, label, current, actions = {{id,label,category}},
---   allow_native (bool), native_label }.
--- @param on_confirm function Invoked with the chosen action id on a pick. An
---   explicit false return refuses settlement and keeps the picker retryable.
--- @return boolean opened
function M.open(opts, on_confirm)
	opts = type(opts) == "table" and opts or {}

	if _active_session then
		Logger.debug(LOG, "Replacing the open action picker with the new target…")
		if close_session(_active_session) ~= true then
			Logger.warn(LOG, "Action picker replacement refused; prior native owner retained.")
			return false
		end
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "action_picker_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return false
	end
	_session_serial = _session_serial + 1
	local session = {
		epoch = _session_serial,
		on_confirm = on_confirm,
		settled = false,
		settling = false,
		usercontent = uc,
		webview = nil,
	}
	_active_session = session
	_usercontent = uc

	local payload = {
		title             = opts.title or "",
		label             = opts.label or i18n.get("dialog.action_picker.label"),
		current           = opts.current or "none",
		allowNative       = opts.allow_native == true,
		nativeLabel       = opts.native_label or "",
		noneLabel         = i18n.get("dialog.action_picker.disabled"),
		searchPlaceholder = i18n.get("dialog.action_picker.search"),
		noResults         = i18n.get("dialog.action_picker.no_results"),
		cancelLabel       = i18n.get("button.cancel"),
		items             = opts.items or {},
	}

	local function push_init()
		if _active_session ~= session or not session.webview then return end
		local ok_enc, js = pcall(hs.json.encode, payload)
		if ok_enc and js then
			pcall(function() session.webview:evaluateJavaScript("init(" .. js .. ")") end)
		end
	end

	uc:setCallback(function(msg)
		if _active_session ~= session then return end
		if type(msg) ~= "table" then return end
		local body = msg.body
		if type(body) ~= "table" then return end
		if body.action == "ready" then
			push_init()
		elseif body.action == "cancel" then
			close_session(session)
		elseif body.action == "confirm" then
			if session.settled then
				close_session(session)
				return
			end
			if session.settling then return end
			local id = type(body.id) == "string" and body.id or "none"
			local callback = session.on_confirm
			session.settling = true
			local callback_ok, callback_result = Logger.callback(
				LOG, "Action picker confirmation", callback, id)
			session.settling = false
			if not callback_ok then return end
			if callback_result == false then
				Logger.warn(LOG, "Action picker confirmation was refused; keeping the picker open.")
				return
			end
			session.settled = true
			close_session(session)
		end
	end)

	local geo = ui_builder.get_app_geometry("action_picker")
	if not geo then
		close_session(session)
		return false
	end
	local webview = ui_builder.show_webview({
		frame         = ui_builder.get_centered_frame(geo.width, geo.height),
		title         = opts.title or i18n.get("dialog.action_picker.label"),
		style_masks   = { "titled", "closable", "utility" },
		usercontent   = uc,
		assets_dir    = ASSETS_DIR,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				push_init()
			end
			return true
		end,
		on_close      = function()
			if _active_session == session then
				_active_session = nil
				_webview = nil
				_usercontent = nil
			end
		end,
	})
	if _active_session ~= session then
		if webview and type(webview.delete) == "function" then
			pcall(function() webview:delete() end)
		end
		return false
	end
	if not webview then
		close_session(session)
		return false
	end
	session.webview = webview
	_webview = webview
	Logger.info(LOG, "Action picker opened (%d item(s)).", #payload.items)
	return true
end

--- Close and destroy the picker window.
--- @return boolean committed
function M.close()
	if not _active_session then return true end
	return close_session(_active_session)
end

return M
