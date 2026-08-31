--- ui/personal_info_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Personal Info Editor
--- Handles JS->Lua messages from _shared/ui/personal_info_editor/.
--- Bridge name: "hsPersonalInfo"
--- ==============================================================================

local M = {}
M.bridge_name = "hsPersonalInfo"

local Json = require("json")
local Logger = require("logger.shim")
local LOG = "bridge.hsPersonalInfo"
local APP_NAME = "personal_info_editor"

local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

local function close_page(state, context)
	if type(context) == "table" and type(context.close_owned_window) == "function" then
		return context.close_owned_window() == true
	end
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	return manager and type(manager.hide) == "function"
		and manager.hide(APP_NAME) == true
end

local function push_init(state, payload)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.eval_js) ~= "function" then return false end
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" then return false end
	local ok_push, pushed = pcall(manager.eval_js, APP_NAME,
		"if(window.initData) window.initData(" .. encoded .. ")")
	return ok_push and pushed == true
end

--- Builds the initial personal info payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local dynamic = dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager")
	if not dynamic or type(dynamic.get_info) ~= "function" then return nil end
	local info = dynamic.get_info()
	if type(info) ~= "table" then return nil end
	local letters = type(dynamic.get_letters) == "function" and dynamic.get_letters() or {}
	local trigger = type(dynamic.get_trigger_char) == "function" and dynamic.get_trigger_char() or ""
	local reverse = {}
	for alias, field in pairs(letters) do reverse[field] = alias end
	local keys = {}
	for key in pairs(info) do keys[#keys + 1] = key end
	table.sort(keys)
	local fields = {}
	for _, key in ipairs(keys) do
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
		local data = _build_initial_payload(state)
		local pushed = data ~= nil and push_init(state, data)
		if not pushed then Logger.error(LOG, "Personal-info initial data could not reach the page.") end
		return { pushed = pushed, data = data }
	end
	if action == "save" then
		local dynamic = dependency(state, "dyn_hotstrings", "modules.dynamic_hotstrings.manager")
		local saved = false
		if type(payload.values) == "table" and dynamic and type(dynamic.save_info) == "function" then
			local ok_save, committed = pcall(dynamic.save_info, payload.values)
			saved = ok_save and committed == true
			if not ok_save then Logger.error(LOG, "Personal-info persistence raised: %s.", tostring(committed)) end
		end
		if not saved then
			Logger.error(LOG, "Personal information was not committed; editor remains open.")
			return { saved = false, reloaded = false, closed = false }
		end
		local ok_reload, reload_result = false, nil
		if state.config and type(state.config.reload) == "function" then
			ok_reload, reload_result = pcall(state.config.reload)
		end
		local reloaded = ok_reload and reload_result ~= false
		if not reloaded then
			Logger.error(LOG, "Personal information was saved but the hotstring catalogue did not reload.")
			return { saved = true, reloaded = false, closed = false }
		end
		if type(state.on_config_changed) == "function" then pcall(state.on_config_changed) end
		local closed = close_page(state, context)
		if not closed then Logger.error(LOG, "Personal-info editor close was refused after save.") end
		return { saved = true, reloaded = true, closed = closed }
	end
	if action == "cancel" then
		return { cancelled = true, closed = close_page(state, context) }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

M._build_initial_payload = _build_initial_payload

return M
