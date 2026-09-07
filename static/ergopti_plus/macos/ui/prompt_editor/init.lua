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
		javascript_failures = {},
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
	if _active_window ~= window or window.closing then return false end
	window.rollback_pending = true
	local webview = window.webview
	local context = _active_context
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Prompt editor close refused; owned WebView has no delete method.")
			return false
		end
		window.closing = true
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		window.closing = false
		if not ok then
			-- Retain the exact retired session until an explicit native cleanup retry
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
	if _active_context ~= context or not window or not window.webview or window.rollback_pending then return false end
	local function current()
		return _active_context == context and _active_window == window and not window.rollback_pending
	end
	local function report(category)
		if context.javascript_failures[category] then return end
		context.javascript_failures[category] = true
		Logger.error(LOG, "Prompt editor JavaScript %s (window=%d, context=%d); repeats suppressed for this context.",
			category, window.epoch, context.epoch)
	end
	local ok_enc, js_data = pcall(hs.json.encode, context.payload)
	if not ok_enc or type(js_data) ~= "string" then report("encoding failed"); return false end
	if not current() then return false end
	local execution_failed = false
	local ok_eval, result = pcall(function()
		return window.webview:evaluateJavaScript("init(" .. js_data .. ")", function(_, script_error)
			if script_error ~= nil then
				execution_failed = true
				report("execution failed")
			end
		end)
	end)
	if not ok_eval then report("submission raised"); return false end
	if result ~= window.webview then report("submission refused"); return false end
	return current() and not execution_failed
end

--- Opens the Prompt Editor window.
--- @param existing table|nil An existing profile to edit, or nil for a new one.
--- @param on_save function Callback invoked when the user clicks "Save". An
---   explicit false return refuses settlement and keeps the editor retryable.
--- @return boolean opened
function M.open(existing, on_save)
	local context = new_context(existing, on_save)
	if _active_window then
		if _active_window.rollback_pending == true then
			if close_window(_active_window) ~= true then
				Logger.warn(LOG, "Prompt editor replacement refused; candidate cleanup remains pending.")
				return false
			end
		else
			local window = _active_window
			_active_context = context
			Logger.debug(LOG, "Rebinding the open prompt editor to '%s' (epoch=%d).",
				context.edit_id, context.epoch)
			if _active_window ~= window or _active_context ~= context or window.rollback_pending then return false end
			if window.webview then
				if not push_context(context) then return false end
				ui_builder.force_focus(window.webview)
			end
			return true
		end
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "prompt_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return false
	end

	_window_serial = _window_serial + 1
	local window = {
		epoch = _window_serial,
		rollback_pending = false,
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
		if window.rollback_pending or active.settled then
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
			if window.closing then return end
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
			-- A synchronous on_close can retire the candidate before the factory
			-- returns it. Re-publish it as rollback-only ownership so it cannot be
			-- rebound to a new editing context when native deletion is ambiguous.
			window.webview = webview
			window.rollback_pending = true
			_active_window = window
			_active_context = context
			_webview = webview
			_usercontent = window.usercontent
			if close_window(window) ~= true then
				Logger.error(LOG, "Prompt editor reentrant candidate cleanup remains pending.")
			end
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
