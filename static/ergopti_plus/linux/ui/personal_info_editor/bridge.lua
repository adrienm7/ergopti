--- ui/personal_info_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Personal Info Editor
--- Handles JS->Lua messages from _shared/ui/personal_info_editor/.
--- Bridge name: "hsPersonalInfo"
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")
M.bridge_name = "hsPersonalInfo"

local Json = require("json")
local Logger = require("logger.shim")
local LOG = "bridge.hsPersonalInfo"
local APP_NAME = "personal_info_editor"
local _opening = nil

local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

--- Rechecks the exact page around native calls without trusting any JS source blob.
local function opening_current(owner, state, context)
	if _opening ~= owner or not owner
		or type(context) ~= "table" or context.app_name ~= APP_NAME or context.epoch ~= owner.epoch
		or dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager") ~= owner.dynamic
		or dependency(state, "webview_manager", "ui.webview_manager") ~= owner.host
		or owner.host.current_epoch ~= owner.current_epoch or owner.host.page_current ~= owner.page_current
		or type(owner.current_epoch) ~= "function" or type(owner.page_current) ~= "function" then return false end
	local read, epoch = pcall(owner.current_epoch, APP_NAME)
	if not read or epoch ~= owner.epoch or _opening ~= owner then return false end
	local called, current = pcall(owner.page_current, APP_NAME, owner.epoch)
	return called and current == true and _opening == owner and owner.host.current_epoch == owner.current_epoch
		and owner.host.page_current == owner.page_current
end

local function notify_refused(state)
	if type(state.notify_error) == "function" then pcall(state.notify_error, "dialog.personal_info.save_failed") end
end


local function close_page(state, context)
	if type(context) == "table" and type(context.close_owned_window) == "function" then
		return context.close_owned_window() == true
	end
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	return manager and type(manager.hide) == "function"
		and manager.hide(APP_NAME) == true
end

local function push_init(state, payload, current)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.eval_js) ~= "function" or current and not current() then return false end
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" or current and not current() then return false end
	local ok_push, pushed = pcall(manager.eval_js, APP_NAME,
		"if(window.initData) window.initData(" .. encoded .. ")")
	return ok_push and pushed == true and (not current or current())
end

--- Builds the initial personal info payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, captured)
	local dynamic = dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager")
	if not dynamic or type(dynamic.get_info) ~= "function" then return nil end
	local info = captured and captured.info or dynamic.get_info()
	if type(info) ~= "table" then return nil end
	local letters = captured and captured.letters or type(dynamic.get_letters) == "function" and dynamic.get_letters() or {}
	local trigger = captured and captured.trigger or type(dynamic.get_trigger_char) == "function" and dynamic.get_trigger_char() or ""
	local reverse = {}
	for alias, field in pairs(letters) do reverse[field] = alias end
	local fields = {}
	for _, key in ipairs(TableUtil.sorted_keys(info)) do
		local alias = reverse[key]
		fields[#fields + 1] = {
			key = key,
			label = key,
			value = tostring(info[key] or ""),
			hint = alias and ("(@" .. alias .. trigger .. ")") or "",
		}
	end
	local i18n = dependency(state, "i18n", "infra.i18n")
	local function translated(key)
		return i18n and type(i18n.get) == "function" and i18n.get(key) or key
	end
	return {
		fields = fields,
		strings = {
			["editor.personal_info.window_title"] = translated("editor.personal_info.window_title"),
			["common.save"] = translated("common.save"),
			["common.cancel"] = translated("common.cancel"),
		},
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state, context)
	state = type(state) == "table" and state or {}
	if type(payload) ~= "table" then return nil end
	local action = payload.action
	if action == "ready" then
		local captured, current, candidate
		if type(context) == "table" and context.epoch ~= nil then
			local dynamic = dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager")
			local host = dependency(state, "webview_manager", "ui.webview_manager")
			if type(host) ~= "table" or type(dynamic) ~= "table" or type(dynamic.capture_info_edit) ~= "function" then
				return { pushed = false }
			end
			if context.app_name ~= APP_NAME or type(context.epoch) ~= "number" or context.epoch <= 0
				or context.epoch % 1 ~= 0 or type(host.current_epoch) ~= "function" then return { pushed = false } end
			local previous = _opening
			local checked, epoch = pcall(host.current_epoch, APP_NAME)
			if not checked or epoch ~= context.epoch or _opening ~= previous then return { pushed = false } end
			local owner = { dynamic = dynamic, host = host, epoch = context.epoch,
				current_epoch = host.current_epoch, page_current = host.page_current }
			_opening = owner
			current = function() return opening_current(owner, state, context) end
			if not current() then return { pushed = false } end
			local called, receipt, info, letters, trigger = pcall(dynamic.capture_info_edit)
			if not called or type(receipt) ~= "table" or type(info) ~= "table" or type(letters) ~= "table"
				or type(trigger) ~= "string" or not current() then return { pushed = false } end
			candidate = { owner = owner, receipt = receipt }
			captured = { info = info, letters = letters, trigger = trigger }
		end
		local data = _build_initial_payload(state, captured)
		local pushed = data ~= nil and push_init(state, data, current)
		if pushed and candidate and current() then candidate.owner.receipt = candidate.receipt end
		if not pushed then Logger.error(LOG, "Personal-info initial data could not reach the page.") end
		return { pushed = pushed, data = data }
	end
	if action == "save" then
		local dynamic = dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager")
		local saved, receipt, current, owner = false, nil, nil, nil
		if type(context) == "table" and context.epoch ~= nil then
			owner = _opening
			current = function() return opening_current(owner, state, context) end
			if not current() or owner.receipt == nil then
				if current() then notify_refused(state) end
				return { saved = false, reloaded = false, closed = false }
			end
			receipt = owner.receipt
		end
		if type(payload.values) == "table" and dynamic and type(dynamic.save_info) == "function" then
			local ok_save, committed, next_receipt = pcall(dynamic.save_info, payload.values, receipt, current)
			saved = ok_save and committed == true
			if saved and owner and current() then owner.receipt = type(next_receipt) == "table" and next_receipt or nil end
			if not ok_save then Logger.error(LOG, "Personal-info persistence raised: %s.", tostring(committed)) end
		end
		if not saved then
			Logger.error(LOG, "Personal information was not committed; editor remains open.")
			if not current or current() then notify_refused(state) end
			return { saved = false, reloaded = false, closed = false }
		end
		if current and not current() then return { saved = true, reloaded = false, closed = false } end
		local ok_reload, _mapping_count, reload_committed = false, nil, false
		if state.config and type(state.config.reload) == "function" then
			ok_reload, _mapping_count, reload_committed = pcall(state.config.reload)
		end
		local reloaded = ok_reload and reload_committed == true
		if not reloaded then
			Logger.error(LOG, "Personal information was saved but the hotstring catalogue did not reload.")
			return { saved = true, reloaded = false, closed = false }
		end
		if type(state.on_config_changed) == "function" then pcall(state.on_config_changed) end
		local closed = (not current or current()) and close_page(state, context)
		if not closed then Logger.error(LOG, "Personal-info editor close was refused after save.") end
		return { saved = true, reloaded = true, closed = closed }
	end
	if action == "cancel" then
		return { cancelled = true, closed = close_page(state, context) }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

--- Revokes only the exact closed native page's retained source.
--- @param epoch number Closed native page identity.
function M.on_window_closed(epoch)
	if _opening and _opening.epoch == epoch then _opening = nil end
end

M._build_initial_payload = _build_initial_payload

return M
