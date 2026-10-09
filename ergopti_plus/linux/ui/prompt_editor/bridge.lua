--- ui/prompt_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: LLM Prompt Editor
--- DESCRIPTION:
--- Owns one context-bound session for _shared/ui/prompt_editor/. The page emits
--- ready/save/cancel and receives init({...}); persistence remains the caller's
--- responsibility so menu profile transactions stay the single source of truth.
--- ==============================================================================

local M = {}
M.bridge_name = "prompt_bridge"

local Json = require("json")
local Logger = require("logger.shim")

local APP_NAME = "prompt_editor"
local LOG = "bridge.prompt_editor"

local _session_serial = 0
local _active_session = nil

local function dependency(state, field, module_name)
	if type(state) == "table" and type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

local function translated(key)
	local ok, i18n = pcall(require, "infra.i18n")
	return ok and type(i18n.get) == "function" and i18n.get(key) or key
end

local function trim(value)
	return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function next_profile_id()
	return string.format("user_%d_%d", os.time(), _session_serial)
end

local function message_matches(payload, session, context)
	return _active_session == session
		and type(payload) == "table"
		and payload.edit_id == session.edit_id
		and payload.epoch == session.epoch
		and (type(context) ~= "table" or context.epoch == nil
			or context.epoch == session.window_epoch)
end

local function close_session(session, state, context)
	if _active_session ~= session then return false end
	local closed = false
	if type(context) == "table" and type(context.close_owned_window) == "function" then
		closed = context.close_owned_window() == true
	else
		local manager = dependency(state, "webview_manager", "ui.webview_manager")
		closed = manager and type(manager.hide) == "function"
			and manager.hide(APP_NAME) == true
	end
	if not closed then
		Logger.error(LOG, "Prompt editor close refused; session %d retained.", session.epoch)
		return false
	end
	_active_session = nil
	Logger.info(LOG, "Prompt editor session %d closed.", session.epoch)
	return true
end

local function push_init(session, state, context)
	if _active_session ~= session
			or (type(context) == "table" and context.epoch ~= nil
				and context.epoch ~= session.window_epoch) then
		return false, nil
	end
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.eval_js) ~= "function" then return false, nil end
	local ok_json, encoded = pcall(Json.encode, session.payload)
	if not ok_json or type(encoded) ~= "string" then return false, nil end
	local ok_push, pushed = pcall(manager.eval_js, APP_NAME,
		"if(window.init) window.init(" .. encoded .. ")")
	return ok_push and pushed == true, session.payload
end

local function new_session(existing, on_save, opts)
	opts = type(opts) == "table" and opts or {}
	_session_serial = _session_serial + 1
	local seeded = type(existing) == "table"
	local is_edit = seeded and opts.as_new ~= true
	local edit_id = is_edit and type(existing.id) == "string" and existing.id or ""
	local requested_id = trim(opts.profile_id)
	local profile_id = edit_id ~= "" and edit_id
		or (requested_id and requested_id:match("^user_[%w_%-]+$") and requested_id)
		or next_profile_id()
	local prompt = seeded and type(existing.system_single) == "string"
		and existing.system_single or translated("prompt_editor.placeholder_prompt")
	return {
		epoch = _session_serial,
		edit_id = edit_id,
		profile_id = profile_id,
		system_multi_template = seeded
			and type(existing.system_multi_template) == "string"
			and existing.system_multi_template or nil,
		on_save = on_save,
		settled = false,
		saving = false,
		window_epoch = nil,
		payload = {
			edit_id = edit_id,
			epoch = _session_serial,
			title = is_edit and translated("prompt_editor.title_edit")
				or translated("prompt_editor.title_new"),
			name = seeded and type(existing.label) == "string" and existing.label or "",
			mode = seeded and existing.batch == true and "batch" or "parallel",
			prompt = prompt,
		},
	}
end

--- Opens a new or existing profile in the shared editor.
--- @param existing table|nil Seed profile.
--- @param on_save function Receives a detached user-profile candidate.
--- @param opts table|nil { as_new = true } clones the seed under a new identity.
--- @return boolean
function M.open(existing, on_save, opts)
	if type(on_save) ~= "function" then
		Logger.error(LOG, "Prompt editor requires a save callback.")
		return false
	end
	local manager = dependency(nil, nil, "ui.webview_manager")
	if not manager or type(manager.show) ~= "function" or type(manager.hide) ~= "function" then
		Logger.error(LOG, "Prompt editor cannot open: webview manager is unavailable.")
		return false
	end

	if _active_session then
		local visible = type(manager.is_visible) == "function"
			and manager.is_visible(APP_NAME) == true
		if visible and manager.hide(APP_NAME) ~= true then
			Logger.error(LOG, "Prompt editor replacement refused; prior session retained.")
			return false
		end
		_active_session = nil
	end

	local session = new_session(existing, on_save, opts)
	_active_session = session
	if manager.show(APP_NAME) ~= true then
		_active_session = nil
		Logger.error(LOG, "Prompt editor native window could not be opened.")
		return false
	end
	session.window_epoch = type(manager.current_epoch) == "function"
		and manager.current_epoch(APP_NAME) or nil
	Logger.info(LOG, "Prompt editor session %d opened for '%s'.",
		session.epoch, session.profile_id)
	return true
end

function M.is_open()
	return _active_session ~= nil
end

--- Handles the page's exact ready/save/cancel protocol.
--- @param payload any
--- @param state table
--- @param context table|nil
--- @return table|nil
function M.on_message(payload, state, context)
	if type(payload) ~= "table" then return nil end
	local session = _active_session
	if not session then return nil end
	local action = payload.action

	if action == "ready" then
		-- show() publishes the native page epoch before WebKit runs the document,
		-- but a synchronous test/native host may deliver ready before open() gets
		-- to read it back. The manager has already authenticated this page context,
		-- so its first lifecycle message may bind the still-empty session epoch.
		if session.window_epoch == nil and type(context) == "table"
				and type(context.epoch) == "number" then
			session.window_epoch = context.epoch
		end
		if type(context) == "table" and context.epoch ~= nil
				and context.epoch ~= session.window_epoch then
			return { pushed = false }
		end
		local pushed, data = push_init(session, state, context)
		if not pushed then Logger.error(LOG, "Prompt editor initial data could not reach the page.") end
		return { pushed = pushed, data = data }
	end

	if action ~= "save" and action ~= "cancel" then
		Logger.debug(LOG, "Unknown action: %s", tostring(action))
		return nil
	end
	if not message_matches(payload, session, context) then
		Logger.warn(LOG, "Ignoring stale prompt-editor action '%s'.", tostring(action))
		return nil
	end

	if session.settled then
		return { closed = close_session(session, state, context) }
	end
	if action == "cancel" then
		session.settled = true
		return { cancelled = true, closed = close_session(session, state, context) }
	end
	if session.saving then return { saved = false, closed = false } end

	local name = trim(payload.name)
	local prompt = trim(payload.prompt)
	if not name or name == "" or not prompt or prompt == ""
			or type(payload.batch) ~= "boolean" then
		Logger.warn(LOG, "Prompt editor save refused invalid scalar fields.")
		return { saved = false, closed = false }
	end

	session.saving = true
	local ok_save, accepted = pcall(session.on_save, {
		id = session.profile_id,
		label = name,
		system_single = prompt,
		system_multi_template = session.system_multi_template,
		batch = payload.batch == true,
	})
	session.saving = false
	if not ok_save or accepted ~= true then
		Logger.error(LOG, "Prompt editor save was refused; session remains retryable: %s.",
			tostring(accepted))
		return { saved = false, closed = false }
	end

	session.settled = true
	return { saved = true, closed = close_session(session, state, context) }
end

--- Test seam: clears process-local session ownership.
function M._reset()
	_active_session = nil
	_session_serial = 0
end

return M
