--- ui/action_picker/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Action Picker
--- Handles JS→Lua messages from _shared/ui/action_picker/.
--- Bridge name: "action_picker_bridge"
---
--- THE PROTOCOL THIS SPEAKS IS THE PAGE'S, NOT AN INVENTED ONE.
--- This handler used to answer "execute" and "search" and return three
--- hardcoded French labels. The page posts neither: it sends
--- {action="confirm", id=…} on a pick, {action="cancel"} on dismiss, and
--- "ready" once. Nothing on either side matched, so the picker did nothing on
--- Linux — and it also never received init(…), so it rendered empty. A bridge
--- answering messages that are never sent looks implemented from both ends.
---
--- THE HOST→PAGE PUSH. init(data) must be evaluated IN the webview after the
--- page reports "ready", and a bridge handler is given only (payload, state) —
--- no webview reference. The channel is webview_manager.eval_js(app, js), which
--- addresses the window by app name rather than handing the handler a webview it
--- could then keep past the window's life.
---
--- The require is deliberately lazy: this module is loaded BY the manager, so a
--- top-level require would be a cycle. Resolving it at push time also means a
--- handler exercised from a test without a GTK stack degrades to "no live
--- webview" instead of failing to load at all.
--- ==============================================================================

local M = {}
local ProgramProviderPicker = require("program_provider_picker")
M.bridge_name = "action_picker_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.action_picker"

local _session_serial = 0
local _active_session = nil

-- Forward declarations (defined before on_message for scoping).
local _handle_json, _handle_table

--- Handles a JSON string payload (shared — no duplicated JSON parsing).
local function _handle_json(payload_str, state, context)
	local ok, data = pcall(function()
		local json_mod = require("json")
		return json_mod.decode(payload_str)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return _handle_table(data, state, context)
end

--- Builds the payload the page's init(data) expects.
---
--- The shape is the page's contract, not this driver's: title/label/
--- searchPlaceholder/cancelLabel/noneLabel strings, `current` (the id already
--- bound), `allowNative`, and an ordered `items` list of
--- {type="heading",level,text} / {type="action",id,label,disabled?,hint?}.
--- Every string comes from i18n — the three hardcoded French labels this
--- handler used to return were not translations of anything, they were invented
--- here.
---
--- The items are the gestures manager's picker items, built from the generated
--- catalogue: the same order and headings the other two drivers show. They used
--- to be a flat, alphabetical list of a hard-coded 42-id table, with no heading
--- at all and 38 of the actions this driver runs missing.
--- @param opts table|nil { title, label, current, allow_native, native_label,
---   items, send_vocabulary, parameter_strings, prompt_choices, vision_choices,
---   language_choices, default_count, edit_current_label }, every field optional.
--- @return table Payload for init(data).
function M.build_init_payload(opts)
	local o = type(opts) == "table" and opts or {}
	local i18n = require("infra.i18n")

	local items = type(o.items) == "table" and o.items or nil
	if not items then
		items = {}
		local ok_actions, Actions = pcall(require, "modules.gestures.manager")
		if not ok_actions or type(Actions.get_picker_items) ~= "function" then
			Logger.error(LOG, "Cannot build the action catalogue: the gestures action registry is unavailable.")
		else
			items = Actions.get_picker_items()
		end
	end

	-- The same keys macOS uses (macos/ui/action_picker/init.lua), so the two
	-- hosts show the same words rather than two translations of one idea.
	return {
		title             = o.title or "",
		label             = o.label or i18n.get("dialog.action_picker.label"),
		current           = o.current or "none",
		allowNative       = o.allow_native == true,
		nativeLabel       = o.native_label or "",
		noneLabel         = i18n.get("dialog.action_picker.disabled"),
		searchPlaceholder = i18n.get("dialog.action_picker.search"),
		noResults         = i18n.get("dialog.action_picker.no_results"),
		cancelLabel       = i18n.get("button.cancel"),
		items             = items,
		-- The page's own editor for send_text / send_key / send_shortcut, from
		-- the gestures manager's get_picker_parameter_fields; without them every
		-- action confirms at once and the zenity prompt asks.
		platform          = "linux",
		sendVocabulary    = o.send_vocabulary,
		parameterStrings  = o.parameter_strings,
		-- The llm_prompt editor's choices and the "edit the current action"
		-- button, from the same get_picker_parameter_fields.
		promptChoices     = o.prompt_choices,
		-- The llm_vision editor's backends: { value, label, defaultModel }.
		visionChoices     = o.vision_choices,
		-- The llm_language editor's target languages: { value, label }, "ui" first.
		languageChoices   = o.language_choices,
		defaultCount      = o.default_count,
		editCurrentLabel  = o.edit_current_label,
		programProviders = _active_session and _active_session.providers.packet or nil,
		programProviderStrings = ProgramProviderPicker.strings(i18n.get),
	}
end

--- Options for the next init(…) push, set by whoever opens the picker.
--- Same shape as build_init_payload's argument; nil means "every default".
--- Module state rather than a parameter because the opener and the "ready"
--- message are two separate trips through the bridge, and only the second one
--- knows the page exists.
M.pending_opts = nil

--- Clears one exact picker session only after its owned page closes.
--- @param session table Session identity.
--- @param context table|nil Routed page context with an epoch-bound close method.
--- @return boolean closed
local function close_session(session, context)
	if _active_session ~= session then return false end
	local closed = false
	if type(context) == "table" and type(context.close_owned_window) == "function" then
		closed = context.close_owned_window() == true
	else
		local ok_manager, Manager = pcall(require, "ui.webview_manager")
		closed = ok_manager and type(Manager.hide) == "function"
			and Manager.hide("action_picker") == true
	end
	if not closed then
		Logger.error(LOG, "Action picker close refused; exact session %s retained.",
			tostring(session.epoch))
		return false
	end
	_active_session = nil
	ProgramProviderPicker.close(session.providers)
	M.pending_opts = nil
	return true
end

--- Opens a picker session for one binding target.
--- @param opts table Picker payload options.
--- @param on_confirm function Called with the selected action id, the daemon state
---   and the value the page's editor collected for it, if any.
--- @param on_cancel function|nil Called after a cancellation request.
--- @return boolean opened
function M.open(opts, on_confirm, on_cancel)
	if type(on_confirm) ~= "function" then
		Logger.error(LOG, "Action picker requires a confirmation callback.")
		return false
	end
	local ok_manager, Manager = pcall(require, "ui.webview_manager")
	if not ok_manager or type(Manager.show) ~= "function"
		or type(Manager.hide) ~= "function" then
		Logger.error(LOG, "Action picker cannot open: webview manager is unavailable.")
		return false
	end

	if _active_session then
		local visible = type(Manager.is_visible) == "function"
			and Manager.is_visible("action_picker") == true
		if visible and Manager.hide("action_picker") ~= true then
			Logger.error(LOG, "Action picker replacement refused; prior session retained.")
			return false
		end
		ProgramProviderPicker.close(_active_session.providers)
		_active_session = nil
		M.pending_opts = nil
	end

	_session_serial = _session_serial + 1
	local session = {
		epoch = _session_serial,
		on_confirm = on_confirm,
		on_cancel = on_cancel,
		settling = false,
		providers = { packet = { unavailable = true } },
	}
	_active_session = session
	local adapter_ok, adapter = pcall(require, "adapters.program_providers")
	session.providers = ProgramProviderPicker.capture(adapter_ok and adapter or nil)
	if _active_session ~= session then
		ProgramProviderPicker.close(session.providers)
		return false
	end
	M.pending_opts = type(opts) == "table" and opts or {}
	if Manager.show("action_picker") ~= true then
		ProgramProviderPicker.close(session.providers)
		_active_session = nil
		M.pending_opts = nil
		Logger.error(LOG, "Action picker native window could not be opened.")
		return false
	end
	Logger.info(LOG, "Action picker session %d opened.", session.epoch)
	return true
end

function M.is_open()
	return _active_session ~= nil
end

--- Pushes init(<payload>) into the live picker page.
---
--- Called on "ready" and only on "ready": evaluating init() before the page has
--- defined it is a silent no-op in the webview, which is exactly the failure this
--- whole handler was written to stop having.
--- @return boolean True when the push was handed to WebKit.
local function _push_init()
	-- The same JSON module _handle_json decodes with. dkjson is the webview
	-- manager's optional dependency and is absent on a plain Lua host, so
	-- encoding through it made the push fail everywhere the decode half worked.
	local ok_json, json_mod = pcall(require, "json")
	if not ok_json or type(json_mod.encode) ~= "function" then
		Logger.error(LOG, "Cannot push init(): the shared json module is unavailable — the page stays empty.")
		return false
	end
	local ok_payload, encoded = pcall(function()
		return json_mod.encode(M.build_init_payload(M.pending_opts))
	end)
	if not ok_payload or type(encoded) ~= "string" then
		Logger.error(LOG, "Cannot push init(): payload encoding failed (%s).", tostring(encoded))
		return false
	end

	local ok_mgr, Manager = pcall(require, "ui.webview_manager")
	if not ok_mgr or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push init(): webview_manager.eval_js is unavailable.")
		return false
	end

	local pushed = Manager.eval_js("action_picker", "init(" .. encoded .. ")")
	if pushed then
		Logger.success(LOG, "Action picker initialised (%d byte(s) of payload).", #encoded)
	else
		-- The page said "ready", so a missing webview here means the window went
		-- away between the two trips. Warn rather than error: nothing is broken,
		-- but a START with no SUCCESS must not be left unexplained in the log.
		Logger.warn(LOG, "Action picker reported ready but its window is gone — init() not pushed.")
	end
	return pushed
end

--- Handles a structured table payload — the page's real protocol.
local function _handle_table(data, state, context)
	local action = data.action

	if action == "confirm" then
		-- The id is what the user picked; "none" and "__native__" are the two
		-- specials the page prepends and are passed through unchanged so the
		-- caller decides what they mean.
		Logger.info(LOG, "Action picker confirmed: %s", tostring(data.id))
		local session = _active_session
		if session then
			if session.settling then return nil end
			session.settling = true
			local id = type(data.id) == "string" and data.id or "none"
			-- A value the page's editor collected travels with the pick.
			local admitted, parameter = ProgramProviderPicker.confirm(session.providers, id, data)
			if _active_session ~= session then
				session.settling = false
				return nil
			end
			if not admitted then
				session.settling = false
				local ok_manager, manager = pcall(require, "ui.webview_manager")
				if ok_manager and type(manager.eval_js) == "function" and _active_session == session then
					manager.eval_js("action_picker", "programProviderRefused()")
				end
				return nil
			end
			local ok_callback, accepted = pcall(session.on_confirm, id, state, parameter)
			session.settling = false
			if not ok_callback then
				Logger.error(LOG, "Action picker confirmation callback failed: %s", tostring(accepted))
				return nil
			end
			if accepted == false then
				Logger.warn(LOG, "Action picker confirmation was refused; keeping the session open.")
				return nil
			end
			close_session(session, context)
		elseif type(M.on_confirm) == "function" then
			pcall(M.on_confirm, data.id, state)
		end
		return nil
	end

	if action == "cancel" then
		Logger.info(LOG, "Action picker cancelled.")
		local session = _active_session
		if session then
			if type(session.on_cancel) == "function" then
				pcall(session.on_cancel, state)
			end
			close_session(session, context)
		elseif type(M.on_cancel) == "function" then
			pcall(M.on_cancel, state)
		end
		return nil
	end

	if action == "ready" then
		Logger.start(LOG, "Action picker UI ready — pushing init()…")
		_push_init()
		return nil
	end

	Logger.warn(LOG, "Unknown action from the picker page: %s", tostring(action))
	return nil
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS (if any).
function M.on_message(payload, state, context)
	if type(payload) == "string" then
		-- "ready" arrives as a bare string from the page's own post({action:…})
		-- only after JSON encoding, so the bare form is the host_bridge fallback.
		if payload == "ready" then
			Logger.start(LOG, "Action picker UI ready — pushing init()…")
			_push_init()
			return nil
		end
		return _handle_json(payload, state, context)
	end

	if type(payload) == "table" then
		return _handle_table(payload, state, context)
	end

	Logger.warn(LOG, "Unknown payload type: %s", type(payload))
	return nil
end

return M
