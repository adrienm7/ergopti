--- ui/prompt_editor/init.lua

--- ==============================================================================
--- MODULE: Prompt Editor UI
--- DESCRIPTION:
--- Provides a clean webview-based interface for users to create and edit
--- custom LLM prompt profiles. Employs a content-editable block to visually
--- render the "{context}" token as a chip.
--- 
--- FEATURES & RATIONALE:
--- 1. Singleton Context: Reopening reuses the native window but publishes a new
---    immutable target epoch, so stale page messages cannot save or close a newer
---    profile context.
--- 2. Space Teleportation & Focus: Leverages the UI builder to natively teleport the window to the active macOS space and grant it focus, while allowing other apps to overlap it when clicked.
--- 3. Centralized Creation: Window properties are managed via the ui_builder factory.
--- ==============================================================================

local M = {}

local hs         = hs
local ui_builder = require("ui.ui_builder")
local Logger     = require("infra.logger")
local i18n       = require("infra.i18n")
local Paths      = require("infra.paths")

local LOG = "prompt_editor"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil
local _context_serial = 0
local _active_context = nil
local _window_serial = 0
local _active_window = nil

-- Window geometry is resolved at open time from the shared manifest
-- (ui_builder.get_app_geometry → _shared/ui/apps.manifest.json, SSoT). No local
-- width/height constant: hardcoding here is what caused the cross-driver drift.

-- The frontend (index.html / script.js / style.css) lives in the cross-driver
-- _shared/ui/ tree so the Windows WebView2 host renders the identical UI; both
-- drivers resolve it through Paths.shared. This init.lua stays macOS-specific.
local ASSETS_DIR = (Paths.shared("ui/prompt_editor") or "") .. "/"





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Allocates one immutable target and form projection.
--- @param existing table|nil Existing profile.
--- @param on_save function|nil Save callback.
--- @return table context Context identity and payload.
local function new_context(existing, on_save)
	_context_serial = _context_serial + 1
	local is_edit = type(existing) == "table"
	local edit_id = is_edit and type(existing.id) == "string" and existing.id or ""
	local profile_id = edit_id ~= "" and edit_id
		or ("custom_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
	return {
		edit_id = edit_id,
		epoch = _context_serial,
		on_save = on_save,
		profile_id = profile_id,
		settled = false,
		saving = false,
		payload = {
			edit_id = edit_id,
			epoch = _context_serial,
			title = is_edit and i18n.get("prompt_editor.title_edit")
				or i18n.get("prompt_editor.title_new"),
			name = is_edit and type(existing.label) == "string" and existing.label or "",
			mode = is_edit and existing.batch == true and "batch" or "parallel",
			prompt = is_edit and type(existing.raw_prompt) == "string" and existing.raw_prompt
				or i18n.get("prompt_editor.placeholder_prompt"),
		},
	}
end

--- Tests whether a page message belongs to the active target.
--- @param body table Bridge payload.
--- @param context table Context identity.
--- @return boolean
local function message_matches(body, context)
	return _active_context == context
		and body.edit_id == context.edit_id
		and body.epoch == context.epoch
end

--- Closes one exact native window session.
--- @param window table Window identity.
--- @return boolean closed Whether the session was current.
local function close_window(window)
	if _active_window ~= window then return false end
	local webview = window.webview
	local context = _active_context
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Prompt editor close refused; owned WebView has no delete method.")
			return false
		end
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		if not ok then
			-- A synchronous on_close may clear module state before native deletion
			-- raises. Restore the exact window and settled context for a close-only retry.
			_active_window = window
			_active_context = context
			_webview = webview
			_usercontent = window.usercontent
			Logger.error(LOG, "Prompt editor close did not commit; exact WebView retained: %s.",
				tostring(err))
			return false
		end
	end
	if _active_window == window then
		_active_window = nil
		_active_context = nil
		_webview = nil
		_usercontent = nil
	end
	Logger.info(LOG, "Prompt editor closed.")
	return true
end

--- Pushes a context only while it remains the active target of the active window.
--- @param context table Context identity.
--- @return boolean published Whether the payload reached the webview boundary.
local function push_context(context)
	local window = _active_window
	if _active_context ~= context or not window or not window.webview then return false end
	local ok_enc, js_data = pcall(hs.json.encode, context.payload)
	if not ok_enc or not js_data then return false end
	local ok_eval = pcall(function()
		window.webview:evaluateJavaScript("init(" .. js_data .. ")")
	end)
	return ok_eval
end

--- Opens the Prompt Editor window.
--- @param existing table|nil An existing profile to edit, or nil for a new one.
--- @param on_save function Callback invoked when the user clicks "Save". An
---   explicit false return refuses settlement and keeps the editor retryable.
--- @return boolean opened
function M.open(existing, on_save)
	local context = new_context(existing, on_save)
	if _active_window then
		_active_context = context
		Logger.debug(LOG, "Rebinding the open prompt editor to '%s' (epoch=%d).",
			context.edit_id, context.epoch)
		if _active_window.webview then
			push_context(context)
			ui_builder.force_focus(_active_window.webview)
		end
		return true
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "prompt_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return false
	end

	_window_serial = _window_serial + 1
	local window = {
		epoch = _window_serial,
		usercontent = uc,
		webview = nil,
	}
	_active_window = window
	_active_context = context
	_usercontent = uc
	uc:setCallback(function(msg)
		if _active_window ~= window then return end
		if type(msg) ~= "table" then return end
		local body = msg.body
		if type(body) ~= "table" then return end
		local active = _active_context
		if not active or not message_matches(body, active) then return end
		if active.settled then
			if body.action == "cancel" or body.action == "save" then close_window(window) end
			return
		end

		if body.action == "cancel" then
			active.settled = true
			close_window(window)
		elseif body.action == "save" then
			if active.saving then return end
			local callback = active.on_save
			active.saving = true
			local callback_ok, callback_result = Logger.callback(
				LOG, "Prompt editor save", callback, {
					id = active.profile_id,
					label = type(body.name) == "string" and body.name
						or i18n.get("prompt_editor.default_label"),
					batch = body.batch == true,
					raw_prompt = type(body.prompt) == "string" and body.prompt or "",
				})
			active.saving = false
			if not callback_ok then return end
			if callback_result == false then
				Logger.warn(LOG, "Prompt editor save was refused; keeping the editor open.")
				return
			end
			active.settled = true
			if _active_context == active then close_window(window) end
		end
	end)

	local geo = ui_builder.get_app_geometry("prompt_editor")
	if not geo then
		close_window(window)
		return false
	end
	local webview = ui_builder.show_webview({
		frame         = ui_builder.get_centered_frame(geo.width, geo.height),
		title         = context.payload.title,
		style_masks   = {"titled", "closable", "utility"},
		usercontent   = uc,
		assets_dir    = ASSETS_DIR,
		on_navigation = function(action)
			if action == "didFinishNavigation" and _active_window == window then
				push_context(_active_context)
			end
			return true
		end,
		on_close      = function()
			if _active_window == window then
				_active_window = nil
				_active_context = nil
				_webview = nil
				_usercontent = nil
			end
		end
	})
	if _active_window ~= window then
		if webview and type(webview.delete) == "function" then
			pcall(function() webview:delete() end)
		end
		return false
	end
	if not webview then
		close_window(window)
		return false
	end
	window.webview = webview
	_webview = webview
	Logger.info(LOG, "Prompt editor opened successfully.")
	return true
end

--- Closes and destroys the Prompt Editor window.
--- @return boolean committed
function M.close()
	if not _active_window then return true end
	return close_window(_active_window)
end

return M
