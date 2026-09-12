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
local DeferredWork = require("infra.deferred_work")
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
local _owner       = nil
local _serial      = 0
local _revision    = 0





-- ============================
-- ============================
-- ======= 1/ Internals =======
-- ============================
-- ============================

--- Closes and cleans up the editor webview.
--- @return boolean committed
local function close_webview()
	local owner = _owner
	if owner and owner.closing then return false end
	if owner then
		owner.retired = true
		if owner.constructing then
			owner.closed = true
			Logger.debug(LOG, "Personal editor creation cancelled before publication (session=%d).", owner.serial)
			return false
		end
		owner.closing = true
	end
	local owned = _webview
	if owned then
		local deleted = pcall(function() owned:delete() end)
		if not deleted then
			if owner then owner.closing = false end
			Logger.error(LOG, "Personal information editor close did not commit; exact WebView retained.")
			return false
		end
		if _webview == owned then _webview = nil end
	end
	local bridge = _usercontent
	if bridge then
		local released = pcall(function() bridge:setCallback(nil) end)
		if not released then
			if owner then owner.closing = false end
			Logger.error(LOG, "Personal information editor bridge release did not commit; exact controller retained.")
			return false
		end
		if _usercontent == bridge then _usercontent = nil end
	end
	if owner then owner.closing = false end
	if _owner == owner then _owner = nil end
	return true
end

--- Checks exact callback authority without exposing personal field values.
--- @param owner table Captured native session.
--- @return boolean current
local function owner_is_current(owner)
	if _owner == owner and not owner.retired and not owner.closed then return true end
	if not owner.discard_reported then
		owner.discard_reported = true
		Logger.debug(LOG, "Discarding retired personal editor callbacks (session=%d).", owner.serial)
	end
	return false
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
local function inject_init_data(owner)
	if not owner_is_current(owner) or not _webview then return end
	local revision = _revision
	local payload = {
		fields  = build_fields(_current),
		strings = {
			["editor.personal_info.window_title"] = i18n.get("editor.personal_info.window_title"),
			["common.save"]                       = i18n.get("common.save"),
			["common.cancel"]                     = i18n.get("common.cancel"),
		},
	}
	local ok_enc, json = pcall(hs.json.encode, payload)
	if not owner_is_current(owner) or _revision ~= revision then return end
	if not ok_enc or not json then
		Logger.error(LOG, "Failed to encode initData payload.")
		return
	end
	local view = _webview
	owner.javascript_failures = owner.javascript_failures or {}
	local function report(category)
		if owner.javascript_failures[category] then return end
		owner.javascript_failures[category] = true
		-- Native errors may echo personal field values, so report only fixed metadata
		Logger.error(LOG, "Personal editor JavaScript %s (session=%d); repeats suppressed.", category, owner.serial)
	end
	local submitted, result = pcall(function()
		return view:evaluateJavaScript("if(window.initData) window.initData(" .. json .. ")", function(_, script_error)
			if script_error ~= nil then report("execution failed") end
		end)
	end)
	if not submitted then report("submission raised"); return false end
	if result ~= view then report("submission refused"); return false end
	return true
end

--- Handles an incoming message from the JavaScript frontend.
--- @param body table The decoded message body ({action, …}).
local function handle_message(body, owner)
	if not owner_is_current(owner) then return end
	if type(body) ~= "table" then return end
	local revision = _revision
	local action = body.action
	Logger.debug(LOG, "usercontent message received: action='%s'.", tostring(action))
	if not owner_is_current(owner) or _revision ~= revision then return end

	if action == "ready" then
		inject_init_data(owner)
	elseif action == "save" then
		local values = type(body.values) == "table" and body.values or {}
		if type(_save_cb) ~= "function" then
			Logger.error(LOG, "Personal info save refused because no save callback is registered.")
			return
		end
		local ok, committed = xpcall(function() return _save_cb(values) end, debug.traceback)
		if not owner_is_current(owner) or _revision ~= revision then return end
		if not ok or committed ~= true then
			Logger.error(LOG, "Personal info save callback %s (session=%d; result type=%s; content withheld).",
				ok and "refused" or "raised", owner.serial, type(committed))
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
	return close_webview()
end

--- Opens the editor as a standalone WKWebView window.
--- @param current_info table Current data used to populate form fields.
--- @param save_callback function Returns true after committing the edited {key=value} map.
function M.open(current_info, save_callback)
	if _owner and (_owner.constructing or _owner.closing) then return false end
	if _owner and _owner.retired then
		if not close_webview() then return false end
	end
	_revision = _revision + 1
	_current = type(current_info) == "table" and current_info or {}
	_save_cb = save_callback
	-- Singleton — focus the existing window instead of opening a second one.
	if _webview then
		local owner, view = _owner, _webview
		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if not owner_is_current(owner) then return false end
		if ok_ui and ui_builder then
			ui_builder.force_focus(view, false, {
				is_current = function() return owner_is_current(owner) end,
			})
		else
			pcall(function() view:bringToFront() end)
		end
		return owner_is_current(owner)
	end
	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsPersonalInfo")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return false
	end
	_usercontent = uc
	_serial = _serial + 1
	local owner = { serial = _serial, constructing = true }
	_owner = owner
	local built, candidate = xpcall(function()
		uc:setCallback(function(message)
			if message and type(message.body) == "table" then
				handle_message(message.body, owner)
			end
		end)

		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if not ok_ui or not ui_builder then return nil end

		local masks       = hs.webview.windowMasks
		local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)
		local screen = hs.screen.mainScreen()
		local sf = screen and type(screen.frame) == "function" and screen:frame() or { w = 1440, h = 900 }
		-- Clamp the shared manifest dimensions to the active screen
		local geo = ui_builder.get_app_geometry("personal_info_editor")
		if not geo then return nil end
		local win_w = math.min(geo.width, math.floor((sf.w or 1440) * 0.5))
		local win_h = math.min(geo.height, math.floor((sf.h or 900) * 0.85))

		return ui_builder.show_webview({
			frame         = ui_builder.get_centered_frame(win_w, win_h),
			title         = i18n.get("editor.personal_info.window_title"),
			style_masks   = style_masks,
			usercontent   = uc,
			assets_dir    = ASSETS_DIR,
			is_current = function() return owner_is_current(owner) end,
			on_webview_created = function(created)
				_webview = created
				return owner_is_current(owner)
			end,
			on_close = function()
				owner.closed = true
				if _owner ~= owner or owner.closing or owner.constructing then return end
				_webview = nil
				close_webview()
			end,
			on_navigation = function(action)
				if action == "didFinishNavigation" and owner_is_current(owner) then
					DeferredWork.after(0.05, function() inject_init_data(owner) end, "personal_info_editor.navigation")
				end
				return true
			end,
		})
	end, debug.traceback)
	owner.constructing = false
	if not built or not candidate then
		owner.retired = true
		close_webview()
		Logger.error(LOG, "Personal info editor creation did not commit (session=%d).", owner.serial)
		return false
	end
	_webview = candidate
	if owner.closed then
		close_webview()
		return false
	end
	Logger.info(LOG, "Personal info editor shown via WebView.")
	return owner_is_current(owner)
end

return M
