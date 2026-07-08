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
--- 1. Singleton — opening it twice brings the existing window to the front
---    instead of stacking duplicates.
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
local Logger     = require("lib.logger")
local i18n       = require("lib.i18n")
local Paths      = require("lib.paths")

local LOG = "action_picker"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil

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

--- Open (or focus) the action picker.
--- @param opts table { title, label, current, actions = {{id,label,category}},
---   allow_native (bool), native_label }.
--- @param on_confirm function Invoked with the chosen action id on a pick.
function M.open(opts, on_confirm)
	opts = type(opts) == "table" and opts or {}

	if _webview then
		Logger.debug(LOG, "Action picker already open, bringing to front…")
		ui_builder.force_focus(_webview)
		return
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "action_picker_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return
	end
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
		if not _webview then return end
		local ok_enc, js = pcall(hs.json.encode, payload)
		if ok_enc and js then
			pcall(function() _webview:evaluateJavaScript("init(" .. js .. ")") end)
		end
	end

	_usercontent:setCallback(function(msg)
		if type(msg) ~= "table" then return end
		local body = msg.body
		if type(body) ~= "table" then return end
		if body.action == "ready" then
			push_init()
		elseif body.action == "cancel" then
			M.close()
		elseif body.action == "confirm" then
			local id = type(body.id) == "string" and body.id or "none"
			M.close()
			if type(on_confirm) == "function" then
				pcall(on_confirm, id)
			end
		end
	end)

	local geo = ui_builder.get_app_geometry("action_picker")
	if not geo then return end
	_webview = ui_builder.show_webview({
		frame         = ui_builder.get_centered_frame(geo.width, geo.height),
		title         = opts.title or i18n.get("dialog.action_picker.label"),
		style_masks   = { "titled", "closable", "utility" },
		usercontent   = _usercontent,
		assets_dir    = ASSETS_DIR,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				push_init()
			end
			return true
		end,
		on_close      = function()
			_webview     = nil
			_usercontent = nil
		end,
	})
	Logger.info(LOG, "Action picker opened (%d item(s)).", #payload.items)
end

--- Close and destroy the picker window.
function M.close()
	if _webview and type(_webview.delete) == "function" then
		pcall(function() _webview:delete() end)
	end
	_webview     = nil
	_usercontent = nil
end

return M
