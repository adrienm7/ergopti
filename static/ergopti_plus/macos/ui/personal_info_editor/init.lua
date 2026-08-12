--- ui/personal_info_editor/init.lua

--- ==============================================================================
--- MODULE: Personal Information Editor UI
--- DESCRIPTION:
--- Standalone WKWebView form for editing the user's personal information. Loads
--- the shared frontend from _shared/ui/personal_info_editor/ so the AHK and
--- Hammerspoon drivers render an identical window, and talks to it over the same
--- usercontent message bridge every other editor uses (no more local HTTP server
--- / browser tab — the field inputs work fine inside the WKWebView, as proven by
--- the hotstring and paths editors).
---
--- FEATURES & RATIONALE:
--- 1. Shared frontend — resolved through Paths.shared so both drivers share it.
--- 2. Message bridge — initData injects {fields, strings}; the page posts
---    {action} messages (ready/save/cancel) back through the "hsPersonalInfo"
---    usercontent handler.
--- 3. Singleton — a second open focuses the existing window.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local i18n   = require("infra.i18n")
local Paths  = require("infra.paths")

local LOG   = "personal_info_editor"

-- Absolute path to the shared frontend assets (index.html, script.js, style.css).
local ASSETS_DIR = (Paths.shared("ui/personal_info_editor") or "") .. "/"

-- Field definitions for the form. Keys match the preferences table.
local FIELDS = {
	{ key = "first_name",             label = i18n.get("personal_info.field_firstname") },
	{ key = "last_name",              label = "Nom" },
	{ key = "date_of_birth",          label = "Date de naissance" },
	{ key = "email_address",          label = "E-mail" },
	{ key = "work_email_address",     label = "E-mail professionnel" },
	{ key = "phone_number",           label = i18n.get("personal_info.field_phone_digits") },
	{ key = "phone_number_clean",     label = i18n.get("personal_info.field_phone_formatted") },
	{ key = "street_address",         label = "Adresse" },
	{ key = "postal_code",            label = "Code postal" },
	{ key = "city",                   label = "Ville" },
	{ key = "country",                label = "Pays" },
	{ key = "iban",                   label = "IBAN" },
	{ key = "bic",                    label = "BIC" },
	{ key = "credit_card",            label = i18n.get("personal_info.field_credit_card") },
	{ key = "social_security_number", label = i18n.get("personal_info.field_ssn") },
}

-- WebView state (singleton).
local _webview     = nil
local _usercontent = nil
local _save_cb     = nil
local _current     = {}





-- ============================
-- ============================
-- ======= 1/ Internals =======
-- ============================
-- ============================

--- Closes and cleans up the editor webview.
local function close_webview()
	if _webview then
		pcall(function() _webview:delete() end)
		_webview     = nil
		_usercontent = nil
	end
end

--- Builds the ordered field list (key/label/value) for the frontend.
--- @param current_info table The current personal-information map.
--- @return table
local function build_fields(current_info)
	local fields = {}
	for _, f in ipairs(FIELDS) do
		fields[#fields + 1] = {
			key   = f.key,
			label = f.label,
			value = tostring(current_info[f.key] or ""),
		}
	end
	return fields
end

--- Injects window.initData({fields, strings}) into the page.
local function inject_init_data()
	if not _webview then return end
	local payload = {
		fields  = build_fields(_current),
		strings = {
			["editor.personal_info.window_title"] = i18n.get("editor.personal_info.window_title"),
			["common.save"]                       = i18n.get("common.save"),
			["common.cancel"]                     = i18n.get("common.cancel"),
		},
	}
	local ok_enc, json = pcall(hs.json.encode, payload)
	if not ok_enc or not json then
		Logger.error(LOG, "Failed to encode initData payload.")
		return
	end
	pcall(function()
		_webview:evaluateJavaScript("if(window.initData) window.initData(" .. json .. ")")
	end)
end

--- Handles an incoming message from the JavaScript frontend.
--- @param body table The decoded message body ({action, …}).
local function handle_message(body)
	if type(body) ~= "table" then return end
	local action = body.action
	Logger.debug(LOG, "usercontent message received: action='%s'.", tostring(action))

	if action == "ready" then
		inject_init_data()
	elseif action == "save" then
		local values = type(body.values) == "table" and body.values or {}
		if type(_save_cb) ~= "function" then
			Logger.error(LOG, "Personal info save refused because no save callback is registered.")
			return
		end
		local ok, committed = xpcall(function() return _save_cb(values) end, debug.traceback)
		if not ok or committed ~= true then
			Logger.error(LOG, "Personal info save callback did not commit (result: %s).",
				tostring(committed))
			return
		end
		close_webview()
	elseif action == "cancel" then
		close_webview()
	end
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Closes the editor and releases its resources.
function M.close()
	close_webview()
end

--- Opens the editor as a standalone WKWebView window.
--- @param current_info table Current data used to populate form fields.
--- @param save_callback function Returns true after committing the edited {key=value} map.
function M.open(current_info, save_callback)
	_current = type(current_info) == "table" and current_info or {}
	_save_cb = save_callback

	-- Singleton — focus the existing window instead of opening a second one.
	if _webview then
		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if ok_ui and ui_builder then
			ui_builder.force_focus(_webview)
		else
			pcall(function() _webview:bringToFront() end)
		end
		return
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsPersonalInfo")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return
	end
	_usercontent = uc
	_usercontent:setCallback(function(message)
		if message and type(message.body) == "table" then
			handle_message(message.body)
		end
	end)

	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or not ui_builder then
		Logger.error(LOG, "Failed to load ui_builder module.")
		return
	end

	local masks       = hs.webview.windowMasks
	local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)

	local screen = hs.screen.mainScreen()
	local sf     = screen and type(screen.frame) == "function" and screen:frame() or { w = 1440, h = 900 }
	-- Manifest is the SSoT max; clamp to a screen fraction so the window fits on
	-- small displays. See _shared/ui/apps.manifest.json (personal_info_editor).
	local geo    = ui_builder.get_app_geometry("personal_info_editor")
	if not geo then return end
	local win_w  = math.min(geo.width, math.floor((sf.w or 1440) * 0.5))
	local win_h  = math.min(geo.height, math.floor((sf.h or 900) * 0.85))

	_webview = ui_builder.show_webview({
		frame         = ui_builder.get_centered_frame(win_w, win_h),
		title         = i18n.get("editor.personal_info.window_title"),
		style_masks   = style_masks,
		usercontent   = _usercontent,
		assets_dir    = ASSETS_DIR,
		on_close      = function()
			_webview     = nil
			_usercontent = nil
		end,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				hs.timer.doAfter(0.05, inject_init_data)
			end
			return true
		end,
	})
	Logger.info(LOG, "Personal info editor shown via WebView.")
end

return M
