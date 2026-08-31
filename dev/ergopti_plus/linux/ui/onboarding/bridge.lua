--- ui/onboarding/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Onboarding Wizard (Linux)
--- DESCRIPTION:
--- Implements the action protocol emitted by _shared/ui/onboarding/script.js
--- and commits its answers through the Linux runtime authorities.
--- ==============================================================================

local M = {}
M.bridge_name = "hsOnboarding"
M.ACTIONS = {
	ready = true,
	previewLocale = true,
	localeSelected = true,
	pickConfigDir = true,
	loadExistingConfig = true,
	finish = true,
	registerGesturesAuto = true,
	registerGesturesManual = true,
}

local Json = require("json")
local Logger = require("logger.shim")
local Paths = require("infra.paths")
local TomlCodec = require("toml_codec")
local LOG = "bridge.onboarding"
local APP_NAME = "onboarding"

local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

local function webview(state)
	return dependency(state, "webview_manager", "ui.webview_manager")
end

local function push(state, function_name, payload)
	local manager = webview(state)
	if not manager or type(manager.eval_js) ~= "function" then return false end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "Could not encode the %s onboarding payload.", function_name)
		return false
	end
	local pushed, accepted = pcall(manager.eval_js, APP_NAME,
		"if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
	return pushed and accepted == true
end

local function locale_available(i18n, code)
	if not i18n or type(i18n.list_locales) ~= "function" or type(code) ~= "string" then
		return false
	end
	for _, available in ipairs(i18n.list_locales()) do
		if available == code then return true end
	end
	return false
end

local function locale_strings(code, config_paths)
	local locale_path = Paths.shared("data/locales/" .. code .. ".json")
	local fh = locale_path and io.open(locale_path, "r") or nil
	if not fh then
		Logger.error(LOG, "Onboarding locale '%s' is unreadable.", tostring(code))
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, strings = pcall(Json.decode, raw)
	if not ok or type(strings) ~= "table" then
		Logger.error(LOG, "Onboarding locale '%s' is invalid.", tostring(code))
		return nil
	end
	local warning = strings["dialog.metrics.enable_warning"]
	if type(warning) == "string" then
		local metrics_path = config_paths.data("metrics.sqlite")
		strings["dialog.metrics.enable_warning_formatted"] = warning:gsub("{1}", function()
			return metrics_path
		end)
	end
	return strings
end

local function all_hotstrings_enabled(config)
	if not config or type(config.get_categories) ~= "function"
		or type(config.is_group_enabled) ~= "function" then return false end
	for id in pairs(config.get_categories() or {}) do
		if not config.is_group_enabled(id) then return false end
	end
	return true
end

local function build_init_data(state)
	local i18n = dependency(state, "i18n", "infra.i18n")
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	local magic_key = dependency(state, "magic_key", "modules.hotstrings.magic_key")
	if not i18n or not config_paths or not magic_key then return nil end

	local current_locale = i18n.get_locale()
	local current_dir = config_paths.get_config_dir()
	local default_dir = config_paths.default_config_dir()
	local keylogger = state.keylogger
	local gestures = state.gestures
	return {
		locale = current_locale,
		strings = locale_strings(current_locale, config_paths) or {},
		default_config_dir = default_dir,
		system_layout = type(state.layout) == "string" and state.layout or "",
		platform = "linux",
		locales = require("_generated.locale_table"),
		answers = {
			locale = current_locale,
			use_ergopti = all_hotstrings_enabled(state.config),
			magic_key = magic_key.get(),
			config_dir = current_dir ~= default_dir and current_dir or "",
			use_metrics = type(keylogger) == "table" and type(keylogger.is_enabled) == "function"
				and keylogger.is_enabled() or false,
			use_gestures = type(gestures) == "table" and type(gestures.is_enabled) == "function"
				and gestures.is_enabled() or false,
		},
	}
end

local function normalize_config_dir(config_paths, value)
	if value == nil or value == "" then return config_paths.default_config_dir() end
	if type(value) ~= "string" then return nil end
	local normalized = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
	if normalized == "" then return config_paths.default_config_dir() end
	if normalized:sub(1, 1) ~= "/" then return nil end
	return normalized
end

local function canonical_bool(section, key, fallback)
	if type(section) ~= "table" or section[key] == nil then return fallback end
	return section[key] == true or section[key] == "true"
end

local function answers_from_config(parsed, config_dir)
	if type(parsed) ~= "table" then return { config_dir = config_dir } end
	local hotstrings = type(parsed.hotstrings) == "table" and parsed.hotstrings or {}
	local metrics = type(parsed.metrics) == "table" and parsed.metrics or {}
	local gestures = type(parsed.gestures) == "table" and parsed.gestures or {}
	return {
		config_dir = config_dir,
		use_ergopti = canonical_bool(hotstrings, "enabled", true),
		magic_key = type(hotstrings.trigger_char) == "string" and hotstrings.trigger_char or nil,
		use_metrics = canonical_bool(metrics, "enabled", false),
		use_gestures = canonical_bool(gestures, "enabled", false),
	}
end

local function category_snapshot(config)
	local snapshot = {}
	for id in pairs(config.get_categories() or {}) do
		snapshot[id] = config.is_group_enabled(id) == true
	end
	return snapshot
end

local function call_confirmed(label, fn)
	local ok, result, detail = pcall(fn)
	if ok and result ~= false and result ~= nil then return true end
	Logger.error(LOG, "Onboarding %s failed: %s.", label,
		tostring(ok and detail or result or "operation was not confirmed"))
	return false
end

local function restore_snapshot(state, authorities, snapshot)
	local function rollback(label, fn)
		if not call_confirmed("rollback for " .. label, fn) then
			Logger.error(LOG, "Onboarding rollback debt remains for %s.", label)
		end
	end

	rollback("config directory", function()
		return authorities.config_paths.set_config_dir(snapshot.config_dir)
	end)
	rollback("locale", function() return authorities.i18n.set_locale(snapshot.locale) end)
	rollback("gestures", function() return state.gestures.set_enabled(snapshot.gestures) end)
	rollback("metrics", function() return state.keylogger.set_enabled(snapshot.metrics) end)
	rollback("magic key", function()
		if snapshot.magic_custom then return authorities.magic_key.set(snapshot.magic_key) end
		return authorities.magic_key.reset()
	end)
	for id, enabled in pairs(snapshot.categories) do
		rollback("hotstring category " .. id, function()
			if enabled then return state.config.enable_group(id) end
			return state.config.disable_group(id)
		end)
	end
end

local function validate_finish(state, authorities, answers)
	if type(answers) ~= "table" then return false, "answers are missing" end
	if type(answers.use_ergopti) ~= "boolean" or type(answers.use_metrics) ~= "boolean"
		or type(answers.use_gestures) ~= "boolean" then
		return false, "feature choices must be booleans"
	end
	if not locale_available(authorities.i18n, answers.locale) then return false, "locale is invalid" end
	if not authorities.magic_key.validate(answers.magic_key) then return false, "magic key is invalid" end
	if not normalize_config_dir(authorities.config_paths, answers.config_dir) then
		return false, "configuration directory must be absolute"
	end
	local required = {
		{ state.config, "get_categories" }, { state.config, "is_group_enabled" },
		{ state.config, "enable_all" }, { state.config, "disable_all" },
		{ state.config, "enable_group" }, { state.config, "disable_group" },
		{ state.keylogger, "is_enabled" }, { state.keylogger, "set_enabled" },
		{ state.gestures, "is_enabled" }, { state.gestures, "set_enabled" },
	}
	for _, port in ipairs(required) do
		if type(port[1]) ~= "table" or type(port[1][port[2]]) ~= "function" then
			return false, "daemon port " .. port[2] .. " is unavailable"
		end
	end
	return true
end

local function finish(state, answers)
	local authorities = {
		i18n = dependency(state, "i18n", "infra.i18n"),
		config_paths = dependency(state, "config_paths", "infra.config_paths"),
		magic_key = dependency(state, "magic_key", "modules.hotstrings.magic_key"),
		writer = dependency(state, "writer", "toml_codec.writer"),
	}
	if not authorities.i18n or not authorities.config_paths or not authorities.magic_key
		or not authorities.writer or type(authorities.writer.batch_write) ~= "function" then
		Logger.error(LOG, "Onboarding finish refused — a persistence authority is unavailable.")
		return { done = false }
	end
	local valid, reason = validate_finish(state, authorities, answers)
	if not valid then
		Logger.error(LOG, "Onboarding finish refused — %s.", tostring(reason))
		return { done = false }
	end

	local snapshot = {
		categories = category_snapshot(state.config),
		magic_key = authorities.magic_key.get(),
		magic_custom = authorities.magic_key.is_customised(),
		metrics = state.keylogger.is_enabled(),
		gestures = state.gestures.is_enabled(),
		locale = authorities.i18n.get_locale(),
		config_dir = authorities.config_paths.get_config_dir(),
	}
	local target_dir = normalize_config_dir(authorities.config_paths, answers.config_dir)
	local operations = {
		{ "hotstring state", function()
			if answers.use_ergopti then return state.config.enable_all() end
			return state.config.disable_all()
		end },
		{ "magic key", function() return authorities.magic_key.set(answers.magic_key) end },
		{ "metrics state", function() return state.keylogger.set_enabled(answers.use_metrics) end },
		{ "gesture state", function() return state.gestures.set_enabled(answers.use_gestures) end },
		{ "locale", function() return authorities.i18n.set_locale(answers.locale) end },
		{ "config directory", function() return authorities.config_paths.set_config_dir(target_dir) end },
	}
	for _, operation in ipairs(operations) do
		if not call_confirmed(operation[1], operation[2]) then
			restore_snapshot(state, authorities, snapshot)
			return { done = false }
		end
	end

	local write_call_ok, wrote, write_err = pcall(authorities.writer.batch_write,
		target_dir .. "/config.toml", {
			{ section = "hotstrings", key = "enabled", value = answers.use_ergopti },
			{ section = "hotstrings", key = "trigger_char", value = answers.magic_key },
			{ section = "metrics", key = "enabled", value = answers.use_metrics },
			{ section = "gestures", key = "enabled", value = answers.use_gestures },
			{ section = "script", key = "onboarding_done", value = true },
		})
	if not write_call_ok or wrote ~= true then
		Logger.error(LOG, "Onboarding config write failed: %s.",
			tostring(write_call_ok and write_err or wrote))
		restore_snapshot(state, authorities, snapshot)
		return { done = false }
	end

	if type(state.on_config_changed) == "function" then
		local notified, notify_err = pcall(state.on_config_changed)
		if not notified then Logger.error(LOG, "Onboarding menu refresh failed: %s.", tostring(notify_err)) end
	end
	local manager = webview(state)
	if manager and type(manager.hide) == "function" then pcall(manager.hide, APP_NAME) end
	Logger.success(LOG, "Onboarding answers committed.")
	return { done = true }
end

local function pick_config_dir(state, current)
	local shell = dependency(state, "shell", "adapters.shell_runner")
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	local i18n = dependency(state, "i18n", "infra.i18n")
	if not shell or not config_paths then return { picked = false } end
	local seed = normalize_config_dir(config_paths, current) or config_paths.get_config_dir()
	local title = i18n and i18n.get("dialog.config_folder.select_title") or "Select configuration folder"
	local chosen = nil
	if shell.has_command("zenity") then
		chosen = shell.exec_line("zenity --file-selection --directory --title=" .. shell.quote(title)
			.. " --filename=" .. shell.quote(seed .. "/") .. " 2>/dev/null")
	elseif shell.has_command("kdialog") then
		chosen = shell.exec_line("kdialog --getexistingdirectory " .. shell.quote(seed)
			.. " --title " .. shell.quote(title) .. " 2>/dev/null")
	end
	local normalized = chosen and normalize_config_dir(config_paths, chosen) or nil
	if not normalized then return { picked = false } end
	push(state, "setConfigDir", normalized)
	return { picked = true, path = normalized }
end

--- Handles an incoming JS message.
--- @param payload any String or action table from host_bridge.js.
--- @param state table Daemon state and optional test-injected authorities.
--- @return table|nil Diagnostic response; the page receives pushes through eval_js.
function M.on_message(payload, state)
	state = type(state) == "table" and state or {}
	if type(payload) ~= "table" then
		local ok, decoded = pcall(Json.decode, tostring(payload))
		if not ok or type(decoded) ~= "table" then return nil end
		payload = decoded
	end

	local action = payload.action
	if action == "ready" then
		local data = build_init_data(state)
		if not data then return { pushed = false } end
		return { pushed = push(state, "initData", data), data = data }
	elseif action == "previewLocale" then
		local i18n = dependency(state, "i18n", "infra.i18n")
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		if not locale_available(i18n, payload.locale) then return { pushed = false } end
		local strings = locale_strings(payload.locale, config_paths)
		return { pushed = strings ~= nil and push(state, "applyStrings", {
			locale = payload.locale, strings = strings,
		}) }
	elseif action == "localeSelected" then
		local i18n = dependency(state, "i18n", "infra.i18n")
		return { accepted = locale_available(i18n, payload.locale) }
	elseif action == "pickConfigDir" then
		return pick_config_dir(state, payload.current)
	elseif action == "loadExistingConfig" then
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		local chosen = config_paths and normalize_config_dir(config_paths, payload.config_dir) or nil
		if not chosen then return { loaded = false } end
		local fh = io.open(chosen .. "/config.toml", "r")
		if not fh then return { loaded = false } end
		local raw = fh:read("*a")
		fh:close()
		local ok, parsed = pcall(TomlCodec.decode, raw)
		if not ok or type(parsed) ~= "table" then return { loaded = false } end
		local answers = answers_from_config(parsed,
			chosen ~= config_paths.default_config_dir() and chosen or "")
		return { loaded = push(state, "applyExistingAnswers", answers), answers = answers }
	elseif action == "finish" then
		return finish(state, payload.answers)
	elseif action == "registerGesturesAuto" or action == "registerGesturesManual" then
		-- These controls are hidden when initData.platform is Linux. Recognising
		-- them still keeps the shared action vocabulary exhaustive and fail-closed.
		return { supported = false }
	end

	Logger.debug(LOG, "Unknown onboarding action: %s", tostring(action))
	return nil
end

M._answers_from_config = answers_from_config
M._build_init_data = build_init_data

return M
