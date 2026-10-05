--- ui/onboarding/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Onboarding Wizard (Linux)
--- DESCRIPTION:
--- Implements the action protocol emitted by _shared/ui/onboarding/script.js.
--- The page answers with manifest paths and values; the shared
--- onboarding_answers contract validates them against the generated catalogue
--- and they reach config.toml in one versioned batch, after which the daemon
--- restarts so every module starts from the file. The Tap-Holds page's checked
--- keys are imported into the chosen folder's tap_hold.toml by the tap-hold
--- writer, which also switches the feature on there. A key whose recommended
--- hold enters the navigation layer brings Ergopti's recommended layer along
--- (keymap.layer_preset) when the folder has no layers.toml of its own.
--- ==============================================================================

local M = {}
M.bridge_name = "hsOnboarding"
M.ACTIONS = {
	ready = true,
	previewLocale = true,
	localeSelected = true,
	pickConfigDir = true,
	resolveMetricsPath = true,
	loadExistingConfig = true,
	finish = true,
	registerGesturesAuto = true,
	registerGesturesManual = true,
}

local Json = require("json")
local Logger = require("logger.shim")
local Paths = require("infra.paths")
local TomlCodec = require("toml_codec")
local Answers = require("onboarding_answers")
local ConfigDirPicker = require("ui.config_dir_picker")
local LOG = "bridge.onboarding"
local APP_NAME = "onboarding"
-- The catalogue platform this host reads and the id the config migration
-- registry knows this driver by.
local CATALOGUE_DRIVER = "linux"
local MIGRATION_DRIVER = "linux"
local CONFIG_FILE = "config.toml"
-- Brand-less window title; webview_manager prefixes the product name.
local WINDOW_TITLE_KEY = "onboarding.window_title"

-- The generated catalogue of this driver, loaded by the first use.
local _catalogue = nil

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

--- Retitles the wizard window from a locale's strings. WebKitGTK never mirrors
--- document.title onto the GtkWindow, so the title stayed in the static English
--- label whatever language the user picked.
--- @param state table Daemon state and optional test-injected authorities.
--- @param strings table|nil Locale strings.
--- @return boolean true when the live window was retitled.
local function retitle(state, strings)
	local manager = webview(state)
	local label = type(strings) == "table" and strings[WINDOW_TITLE_KEY] or nil
	if not manager or type(manager.set_title) ~= "function" or type(label) ~= "string" then
		return false
	end
	local ok, applied = pcall(manager.set_title, APP_NAME, label)
	return ok and applied == true
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

--- Reads one shipped data file of the shared tree.
--- @param relative string Path under _shared/.
--- @return string|nil content
local function read_shared(relative)
	local path = Paths.shared(relative)
	local fh = path and io.open(path, "r") or nil
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

local function locale_strings(code)
	local raw = read_shared("data/locales/" .. tostring(code) .. ".json")
	if not raw then
		Logger.error(LOG, "Onboarding locale '%s' is unreadable.", tostring(code))
		return nil
	end
	local ok, strings = pcall(Json.decode, raw)
	if not ok or type(strings) ~= "table" then
		Logger.error(LOG, "Onboarding locale '%s' is invalid.", tostring(code))
		return nil
	end
	return strings
end

--- The wizard catalogue of this driver, read once from the generated file.
--- Raises when it is missing or malformed: nothing can be asked or validated.
--- @return table index From onboarding_answers.load.
local function catalogue()
	if _catalogue then return _catalogue end
	local text = read_shared(Answers.CATALOGUE_PATH)
	if not text then error("the onboarding catalogue is unreadable") end
	_catalogue = Answers.load(text, CATALOGUE_DRIVER)
	return _catalogue
end

--- The configured value of every wizard path of a decoded config.toml. The
--- wizard reads the file on a re-run, so the unused-key cleanup marks what it
--- takes through the same projection.
--- @param decoded table Decoded config.toml.
--- @param mark function|nil mark(...segments) for each key present and read.
--- @return table values `{ [path] = value }`.
function M.config_values(decoded, mark)
	return Answers.current_values(catalogue(), decoded, mark)
end

--- The wizard values of the tap_hold.toml beside a config.toml: the Tap-Holds
--- switch and each key configured there, which the page keeps as they are.
--- @param state table Daemon state and optional test-injected authorities.
--- @param path string Absolute config.toml path.
--- @return table|nil values nil when the tap-hold file cannot be read.
local function tap_hold_values_of(state, path)
	local writer = dependency(state, "tap_hold_writer", "platform.remap.tap_hold_writer")
	local loader = dependency(state, "tap_hold_loader", "platform.remap.tap_hold_loader")
	if not writer or not loader then
		Logger.error(LOG, "The tap-hold keys in force cannot be read: the tap-hold owner is unavailable.")
		return nil
	end
	local folder = assert(path:match("^(.*)/[^/]*$"), "a config.toml path names its folder")
	local ok, report, err = pcall(loader.key_report, Paths.shared("tap_hold/defaults.toml"),
		folder .. "/" .. writer.FILE_NAME)
	if not ok or not report then
		Logger.error(LOG, "The tap-hold keys in force could not be read: %s.", tostring(ok and err or report))
		return nil
	end
	return Answers.tap_hold_values(catalogue(), report)
end

--- The configured value of every wizard path in a config file and in the
--- tap-hold file beside it.
--- @param state table Daemon state and optional test-injected authorities.
--- @param path string Absolute config.toml path.
--- @return table|nil values Empty for absent files, nil when one is unreadable.
local function values_of(state, path)
	local values = {}
	local fh, err, code = io.open(path, "r")
	if fh then
		local raw = fh:read("*a")
		fh:close()
		local ok, parsed = pcall(TomlCodec.decode, raw)
		if not ok or type(parsed) ~= "table" then
			Logger.error(LOG, "The configuration in force could not be decoded.")
			return nil
		end
		values = M.config_values(parsed)
	elseif code ~= 2 then
		Logger.error(LOG, "The configuration in force could not be read: %s.", tostring(err))
		return nil
	end
	local tap_holds = tap_hold_values_of(state, path)
	if not tap_holds then return nil end
	for key, value in pairs(tap_holds) do values[key] = value end
	return values
end

local function build_init_data(state)
	local i18n = dependency(state, "i18n", "infra.i18n")
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	if not i18n or not config_paths then return nil end
	local ok_catalogue, catalogue_error = pcall(catalogue)
	if not ok_catalogue then
		Logger.error(LOG, "The onboarding catalogue is unavailable: %s.", tostring(catalogue_error))
		return nil
	end

	local current_locale = i18n.get_locale()
	local strings = locale_strings(current_locale)
	local current_dir = config_paths.get_config_dir()
	local default_dir = config_paths.default_config_dir()
	local values = values_of(state, config_paths.config(CONFIG_FILE))
	if not strings or not values then return nil end
	return {
		platform = CATALOGUE_DRIVER,
		locale = current_locale,
		strings = strings,
		default_config_dir = default_dir,
		config_dir = current_dir ~= default_dir and current_dir or "",
		-- The consent text names the metrics store.
		metrics_path = config_paths.metrics_path(),
		system_layout = type(state.layout) == "string" and state.layout or "",
		locales = require("_generated.locale_table"),
		current = values,
	}
end

local normalize_config_dir = ConfigDirPicker.normalize

--- Tells the user what the wizard could not save, as the other hosts' dialogs
--- do; a refused commit leaves the window open for a retry.
--- @param state table Daemon state.
--- @param key string Locale key of the message.
local function report_failure(state, key)
	if type(state.notify_error) ~= "function" then
		Logger.error(LOG, "Onboarding failure '%s' has no notifier to reach the user.", key)
		return
	end
	local ok, err = pcall(state.notify_error, key)
	if not ok then
		Logger.error(LOG, "Onboarding failure '%s' could not be shown: %s.", key, tostring(err))
	end
end

local function call_confirmed(label, fn)
	local ok, result, detail = pcall(fn)
	if ok and result ~= false and result ~= nil then return true end
	Logger.error(LOG, "Onboarding %s failed: %s.", label,
		tostring(ok and detail or result or "operation was not confirmed"))
	return false
end

--- Restores the language and the folder the wizard changed before a failed write.
--- @param authorities table
--- @param snapshot table
local function restore_snapshot(authorities, snapshot)
	local function rollback(label, fn)
		if not call_confirmed("rollback for " .. label, fn) then
			Logger.error(LOG, "Onboarding rollback debt remains for %s.", label)
		end
	end
	rollback("config directory", function()
		return authorities.config_paths.set_config_dir(snapshot.config_dir)
	end)
	rollback("locale", function() return authorities.i18n.set_locale(snapshot.locale) end)
end

--- Versions a config.toml the wizard is about to write: the boot migration ran
--- on the folder the daemon started with, and the wizard may target another.
--- @param path string Destination config.toml.
--- @return boolean writable
--- @return string|nil detail
local function prepare_destination(path)
	local ConfigMigrate = require("config_migrate")
	local result = ConfigMigrate.boot({
		path          = path,
		driver        = MIGRATION_DRIVER,
		registry_path = Paths.shared(ConfigMigrate.REGISTRY_PATH),
	})
	if result.read_only then return false, result.detail end
	return true
end

--- Imports the checked tap-hold keys into the chosen folder's tap_hold.toml.
--- The answers are already committed: a refused import is reported and leaves
--- that file as it was, and the daemon still restarts on the saved answers.
--- @param state table Daemon state and optional test-injected authorities.
--- @param target_dir string The configuration folder the wizard set up.
--- @param keys table The engine's key ids to import, at least one.
--- @return boolean imported
local function import_tap_holds(state, target_dir, keys)
	local writer = dependency(state, "tap_hold_writer", "platform.remap.tap_hold_writer")
	local loader = dependency(state, "tap_hold_loader", "platform.remap.tap_hold_loader")
	if not writer or not loader then
		Logger.error(LOG, "The tap-hold keys were not imported: the tap-hold writer is unavailable.")
		report_failure(state, "onboarding.error.tap_holds_import")
		return false
	end
	local ok, imported, detail = pcall(function()
		local preset = loader.preset_keys(Paths.shared("tap_hold/defaults.toml"))
		return writer.import_recommended(target_dir .. "/" .. writer.FILE_NAME, keys, preset)
	end)
	if ok and imported == true then return true end
	Logger.error(LOG, "The tap-hold keys were not imported: %s.",
		tostring(ok and detail or imported))
	report_failure(state, "onboarding.error.tap_holds_import")
	return false
end

--- Imports Ergopti's recommended navigation layer into the chosen folder when
--- an imported key's recommended hold enters it and the folder has no
--- layers.toml: an existing one is the user's and stays as it is.
--- @param state table Daemon state and optional test-injected authorities.
--- @param target_dir string The configuration folder the wizard set up.
--- @param keys table The imported tap-hold key ids.
--- @return boolean ok False when the layer was due and could not be written.
local function import_nav_layer(state, target_dir, keys)
	local loader = dependency(state, "tap_hold_loader", "platform.remap.tap_hold_loader")
	local LayerPreset = dependency(state, "layer_preset", "keymap.layer_preset")
	local ok, import, err = pcall(function()
		local shared_root = Paths.shared_root()
		local layer_id = LayerPreset.read(shared_root, TomlCodec.decode).layer_id
		local preset = loader.preset_keys(Paths.shared("tap_hold/defaults.toml"))
		local enters = false
		for _, key_id in ipairs(keys) do
			enters = enters or (type(preset[key_id]) == "table" and preset[key_id].hold_layer == layer_id)
		end
		if not enters then return { status = "not_needed" } end
		return LayerPreset.import_if_absent({ shared_root = shared_root, config_dir = target_dir,
			toml_decode = TomlCodec.decode })
	end)
	if ok and import then
		if import.status == LayerPreset.IMPORTED then
			Logger.success(LOG, "Recommended navigation layer imported into '%s'.", import.path)
		elseif import.status == LayerPreset.KEPT then
			Logger.info(LOG, "'%s' is kept: the wizard never replaces a layer file%s.", import.path,
				import.detail and (" (" .. import.detail .. ")") or "")
		end
		return true
	end
	Logger.error(LOG, "The recommended navigation layer was not imported: %s.", tostring(ok and err or import))
	report_failure(state, "onboarding.error.nav_layer_import")
	return false
end

local function finish(state, answers)
	local authorities = {
		i18n = dependency(state, "i18n", "infra.i18n"),
		config_paths = dependency(state, "config_paths", "infra.config_paths"),
		manifest = dependency(state, "manifest", "infra.manifest_reader"),
		writer = dependency(state, "writer", "toml_codec.writer"),
		prepare = type(state.prepare_destination) == "function" and state.prepare_destination
			or prepare_destination,
	}
	if not authorities.i18n or not authorities.config_paths or not authorities.manifest
		or not authorities.writer or type(authorities.writer.batch_write) ~= "function" then
		Logger.error(LOG, "Onboarding finish refused — a persistence authority is unavailable.")
		report_failure(state, "onboarding.error.write_failed")
		return { done = false }
	end
	-- The whole payload is validated before anything changes.
	if type(answers) ~= "table" then
		Logger.error(LOG, "Onboarding finish refused — answers are missing.")
		report_failure(state, "onboarding.error.invalid_answers")
		return { done = false }
	end
	local catalogue_ok, index = pcall(catalogue)
	if not catalogue_ok then
		Logger.error(LOG, "Onboarding finish refused — %s.", tostring(index))
		report_failure(state, "onboarding.error.invalid_answers")
		return { done = false }
	end
	local rows, refusal, reason_key = Answers.rows(index, answers.operations, authorities.manifest)
	local tap_hold_keys = rows and Answers.tap_hold_keys(index, answers.operations, authorities.manifest)
	local target_dir = normalize_config_dir(authorities.config_paths, answers.config_dir)
	if not rows or not locale_available(authorities.i18n, answers.locale) or not target_dir then
		Logger.error(LOG, "Onboarding finish refused — %s.",
			tostring(refusal or "the language or the configuration folder is invalid"))
		report_failure(state, reason_key or "onboarding.error.invalid_answers")
		return { done = false }
	end

	local snapshot = {
		locale = authorities.i18n.get_locale(),
		config_dir = authorities.config_paths.get_config_dir(),
	}
	for _, operation in ipairs({
		{ "locale", function() return authorities.i18n.persist_locale(answers.locale) == true end,
			"onboarding.error.locale_persist_failed" },
		{ "config directory", function() return authorities.config_paths.set_config_dir(target_dir) end,
			"paths_editor.save_failed" },
	}) do
		if not call_confirmed(operation[1], operation[2]) then
			restore_snapshot(authorities, snapshot)
			report_failure(state, operation[3])
			return { done = false }
		end
	end

	local committed, write_err = Answers.commit({
		index = index,
		operations = answers.operations,
		manifest = authorities.manifest,
		path = target_dir .. "/" .. CONFIG_FILE,
		prepare = authorities.prepare,
		write = function(path, batch) return authorities.writer.batch_write(path, batch) end,
	})
	if not committed then
		Logger.error(LOG, "Onboarding config write failed: %s.", tostring(write_err))
		restore_snapshot(authorities, snapshot)
		report_failure(state, "onboarding.error.write_failed")
		return { done = false }
	end
	Logger.success(LOG, "Onboarding answers committed (%d configuration row(s)).", #rows)
	if #tap_hold_keys > 0 and import_tap_holds(state, target_dir, tap_hold_keys) then
		import_nav_layer(state, target_dir, tap_hold_keys)
	end

	local manager = webview(state)
	if manager and type(manager.hide) == "function" then pcall(manager.hide, APP_NAME) end
	-- Every module reads config.toml when it starts, so the daemon restarts on
	-- the new file, as hs.reload() and the Windows Reload do.
	local restarted = false
	if type(state.restart) == "function" then
		local ok, result = pcall(state.restart, "the setup wizard")
		restarted = ok and result == true
	end
	if not restarted then
		Logger.error(LOG, "The daemon could not restart on the new configuration; it applies at the next start.")
		if type(state.notify_restart_required) == "function" then
			pcall(state.notify_restart_required)
		end
	end
	return { done = true, restarted = restarted }
end

local function pick_config_dir(state, current)
	local shell = dependency(state, "shell", "adapters.shell_runner")
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	local i18n = dependency(state, "i18n", "infra.i18n")
	if not shell or not config_paths then return { picked = false } end
	local normalized = ConfigDirPicker.pick(shell, config_paths, i18n, current)
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
		return { pushed = push(state, "initData", data), data = data,
			titled = retitle(state, data.strings) }
	elseif action == "previewLocale" then
		local i18n = dependency(state, "i18n", "infra.i18n")
		if not locale_available(i18n, payload.locale) then return { pushed = false } end
		local strings = locale_strings(payload.locale)
		if not strings then return { pushed = false } end
		return { pushed = push(state, "applyStrings", {
			locale = payload.locale, strings = strings,
		}), titled = retitle(state, strings) }
	elseif action == "localeSelected" then
		local i18n = dependency(state, "i18n", "infra.i18n")
		return { accepted = locale_available(i18n, payload.locale) }
	elseif action == "pickConfigDir" then
		return pick_config_dir(state, payload.current)
	elseif action == "resolveMetricsPath" then
		-- The store lives in the data directory and does not follow the chosen
		-- configuration folder; answering keeps the page on the keylogger's path.
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		if type(payload.request) ~= "number" or not config_paths then
			Logger.error(LOG, "resolveMetricsPath refused — request number or path authority missing.")
			return { pushed = false }
		end
		local path = config_paths.metrics_path()
		return { pushed = push(state, "setMetricsPath", { request = payload.request, path = path }),
			path = path }
	elseif action == "loadExistingConfig" then
		-- The pages restart from the chosen folder's config.toml: its values when
		-- it exists, the neutral ones when it does not.
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		local chosen = config_paths and normalize_config_dir(config_paths, payload.config_dir) or nil
		if not chosen or type(payload.request) ~= "number" then
			Logger.error(LOG, "loadExistingConfig refused — folder or request number invalid.")
			return { loaded = false }
		end
		local ok_values, values = pcall(values_of, state, chosen .. "/" .. CONFIG_FILE)
		if not ok_values or not values then return { loaded = false } end
		return { loaded = push(state, "applyCurrentValues", { request = payload.request, values = values }),
			values = values }
	elseif action == "finish" then
		return finish(state, payload.answers)
	elseif action == "registerGesturesAuto" or action == "registerGesturesManual" then
		-- These controls are shown on Windows only. Recognising them still keeps
		-- the shared action vocabulary exhaustive and fail-closed.
		return { supported = false }
	end

	Logger.debug(LOG, "Unknown onboarding action: %s", tostring(action))
	return nil
end

M._build_init_data = build_init_data

return M
