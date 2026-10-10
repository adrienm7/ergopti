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
local ProgramProviderPicker = require("program_provider_picker")
local PresentationPrepareOwner = rawget(ui_builder, "prepare_app_presentation")
local PresentationFieldsOwner = rawget(ui_builder, "presentation_fields")
local PresentationCurrentOwner = rawget(ui_builder, "presentation_current")
local PresentationShowOwner = rawget(ui_builder, "show_webview")
local PresentationGeometryOwner = rawget(ui_builder, "get_app_geometry")
local PresentationFrameOwner = rawget(ui_builder, "get_centered_frame")

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
	if session.closing then return false end
	local webview = session.webview
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Action picker close refused; owned WebView has no delete method.")
			return false
		end
		session.closing = true
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		session.closing = false
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
		ProgramProviderPicker.close(session.providers)
		_active_session = nil
		_webview = nil
		_usercontent = nil
	end
	return true
end

--- Open the action picker for a new target, replacing any prior target.
--- @param opts table { title, label, current, items, allow_native (bool),
---   native_label, send_vocabulary, parameter_strings, prompt_choices,
---   default_count, vision_choices, language_choices, edit_current_label }; the
---   last seven come from
---   ShortcutUtils.picker_parameter_fields and turn the page's editor on.
--- @param on_confirm function Invoked with the chosen action id, and the value the
---   page's editor collected for it, if any, on a pick. An explicit false return
---   refuses settlement and keeps the picker retryable.
--- @return boolean opened
function M.open(opts, on_confirm)
	opts = type(opts) == "table" and opts or {}
	local presentation_id = rawget(opts, "presentation_id")
	local presentation_receipt, presentation_title, presentation_label, presentation_live
	local replacement_serial
	if presentation_id ~= nil then
		if getmetatable(opts) ~= nil or type(presentation_id) ~= "string"
			or not presentation_id:match("^[a-z][a-z0-9_]*$")
			or rawget(opts, "title") ~= nil or rawget(opts, "label") ~= nil then return false end
		local function owners_live()
			return getmetatable(opts) == nil and rawget(opts, "presentation_id") == presentation_id
				and rawget(opts, "title") == nil and rawget(opts, "label") == nil
				and getmetatable(ui_builder) == nil and rawget(package.loaded, "ui.ui_builder") == ui_builder
				and rawget(ui_builder, "prepare_app_presentation") == PresentationPrepareOwner
				and rawget(ui_builder, "presentation_fields") == PresentationFieldsOwner
				and rawget(ui_builder, "presentation_current") == PresentationCurrentOwner
				and rawget(ui_builder, "show_webview") == PresentationShowOwner
				and rawget(ui_builder, "get_app_geometry") == PresentationGeometryOwner
				and rawget(ui_builder, "get_centered_frame") == PresentationFrameOwner
				and type(PresentationPrepareOwner) == "function" and type(PresentationFieldsOwner) == "function"
				and type(PresentationCurrentOwner) == "function" and type(PresentationShowOwner) == "function"
				and type(PresentationGeometryOwner) == "function" and type(PresentationFrameOwner) == "function"
		end
		if not owners_live() then return false end
		local previous, serial = _active_session, _session_serial
		presentation_receipt = PresentationPrepareOwner("action_picker", presentation_id)
		if presentation_receipt == nil or not owners_live() or _active_session ~= previous
			or _session_serial ~= serial then return false end
		presentation_live = function()
			return owners_live() and PresentationCurrentOwner(presentation_receipt) == true
		end
		if not presentation_live() then return false end
		presentation_title, presentation_label = PresentationFieldsOwner(presentation_receipt)
		if type(presentation_title) ~= "string" or type(presentation_label) ~= "string"
			or not presentation_live() or _active_session ~= previous or _session_serial ~= serial then return false end
		replacement_serial = serial
	end

	if _active_session then
		Logger.debug(LOG, "Replacing the open action picker with the new target…")
		if close_session(_active_session) ~= true then
			Logger.warn(LOG, "Action picker replacement refused; prior native owner retained.")
			return false
		end
	end

	if presentation_live and (not presentation_live() or _active_session ~= nil
		or _session_serial ~= replacement_serial) then return false end
	local ok_uc, uc = pcall(hs.webview.usercontent.new, "action_picker_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return false
	end
	if presentation_live and (not presentation_live() or _active_session ~= nil
		or _session_serial ~= replacement_serial) then return false end
	_session_serial = _session_serial + 1
	local session = {
		epoch = _session_serial,
		on_confirm = on_confirm,
		settled = false,
		settling = false,
		usercontent = uc,
		webview = nil,
		providers = { packet = { unavailable = true } },
	}
	_active_session = session
	_usercontent = uc
	local adapter_ok, adapter = pcall(require, "adapters.program_providers")
	session.providers = ProgramProviderPicker.capture(adapter_ok and adapter or nil)
	if _active_session ~= session then
		ProgramProviderPicker.close(session.providers)
		return false
	end

	if presentation_live and not presentation_live() then
		close_session(session)
		return false
	end
	local payload = {
		title             = presentation_title or opts.title or "",
		label             = presentation_label or opts.label or i18n.get("dialog.action_picker.label"),
		current           = opts.current or "none",
		allowNative       = opts.allow_native == true,
		nativeLabel       = opts.native_label or "",
		noneLabel         = i18n.get("dialog.action_picker.disabled"),
		searchPlaceholder = i18n.get("dialog.action_picker.search"),
		noResults         = i18n.get("dialog.action_picker.no_results"),
		cancelLabel       = i18n.get("button.cancel"),
		items             = opts.items or {},
		-- The page's own editor for send_text / send_key / send_shortcut; "hs"
		-- makes Command the portable "primary" modifier of a captured shortcut.
		platform          = "hs",
		sendVocabulary    = opts.send_vocabulary,
		parameterStrings  = opts.parameter_strings,
		-- The llm_prompt editor's choices and the count a binding without its own uses
		promptChoices     = opts.prompt_choices,
		defaultCount      = opts.default_count,
		-- The llm_vision editor's backends, each with its default vision model
		visionChoices     = opts.vision_choices,
		-- The llm_language editor's target languages, the interface language first
		languageChoices   = opts.language_choices,
		editCurrentLabel  = opts.edit_current_label,
		programProviders = session.providers.packet,
		programProviderStrings = ProgramProviderPicker.strings(i18n.get),
	}

	local function push_init()
		if _active_session ~= session or not session.webview then return end
		if presentation_live and not presentation_live() then
			close_session(session)
			return
		end
		local target = session.webview
		local ok_enc, js = pcall(hs.json.encode, payload)
		if presentation_live and (not presentation_live() or _active_session ~= session
			or session.webview ~= target) then
			if _active_session == session then close_session(session) end
			return
		end
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
			session.settling = true
			local id = type(body.id) == "string" and body.id or "none"
			-- A value the page's editor collected travels with the pick.
			local admitted, parameter = ProgramProviderPicker.confirm(session.providers, id, body)
			if _active_session ~= session then
				session.settling = false
				return
			end
			if not admitted then
				session.settling = false
				if _active_session == session and session.webview then
					pcall(function() session.webview:evaluateJavaScript("programProviderRefused()") end)
				end
				return
			end
			local callback = session.on_confirm
			local callback_ok, callback_result = Logger.callback(
				LOG, "Action picker confirmation", callback, id, parameter)
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
	local native_options = {
		frame         = ui_builder.get_centered_frame(geo.width, geo.height),
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
			-- Native deletion can report on_close synchronously and then throw.
			-- Only the acknowledged caller may retire choices in that interval.
			if session.closing then return end
			if _active_session == session then
				ProgramProviderPicker.close(session.providers)
				_active_session = nil
				_webview = nil
				_usercontent = nil
			end
		end,
	}
	if presentation_live then
		if not presentation_live() or _active_session ~= session then
			if _active_session == session then close_session(session) end
			return false
		end
		native_options.app_id = "action_picker"
		native_options.presentation_id = presentation_id
		native_options.presentation_receipt = presentation_receipt
		native_options.is_current = function()
			return _active_session == session and not session.closing and presentation_live()
		end
	else
		native_options.title = opts.title or i18n.get("dialog.action_picker.label")
	end
	local webview
	if presentation_live then
		webview = PresentationShowOwner(native_options)
	else
		webview = ui_builder.show_webview(native_options)
	end
	if _active_session ~= session then
		if webview and type(webview.delete) == "function" then
			-- on_close may run synchronously while the factory is still returning.
			-- Re-publish the exact candidate so a refused rollback remains retryable
			-- and blocks any successor picker.
			session.webview = webview
			_active_session = session
			_webview = webview
			_usercontent = session.usercontent
			if close_session(session) ~= true then
				Logger.error(LOG, "Action picker reentrant candidate cleanup remains pending.")
			end
		end
		return false
	end
	if not webview then
		close_session(session)
		return false
	end
	session.webview = webview
	_webview = webview
	local automation_ok, automation = pcall(require, "adapters.apple_shortcuts_native")
	ProgramProviderPicker.capture_automation(session.providers, automation_ok and automation or nil, function(packet)
		if _active_session ~= session or session.closing or not session.webview then return end
		payload.automationProviders = packet
		local encoded, data = pcall(hs.json.encode, packet)
		if encoded and type(data) == "string" then
			pcall(function() session.webview:evaluateJavaScript("updateAutomationProviders(" .. data .. ")") end)
		end
	end)
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
