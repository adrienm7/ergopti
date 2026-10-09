--- modules/llm/agent_settings.lua

--- ==============================================================================
--- MODULE: AI Agent Settings (Linux)
--- DESCRIPTION:
--- Loads _shared/modules/llm/agent.json and owns the agent's four settings:
--- llm.agent_system1 and llm.agent_system2 (the backend of each system, "" when
--- off), llm.agent_mode ("off", "action" or "auto") and llm.agent_disabled_apps
--- (the applications the automatic mode never looks at). The logic itself is
--- the shared _shared/lua/llm/agent.lua; this module reads the file, the
--- settings, and resolves where a system's request goes.
---
--- FEATURES & RATIONALE:
--- 1. A system's backend is written like the llm_vision parameter: "local" (the
---    local Ollama server) or a provider of api_providers.json, optionally
---    followed by |model. It is parsed by llm/vision.lua and its model resolved
---    by agent.resolve_model: agent.json's default for the local server, the
---    provider's default_model of api_providers.json otherwise; a backend
---    without a default and without a model counts as not configured.
--- 2. The settings are read and written through infra/llm_preferences like
---    every other llm.* setting, sparsely against the manifest's defaults.
--- 3. A remote backend reuses the key the user stored for that provider
---    (vision_request.entry_for), with the system's model.
--- 4. Each system lists only the providers that serve it (api_remote.serves):
---    System 1 also offers the decisions providers (Jev), which are no chat
---    model; System 2 chats, so it never names one. A stored value naming a
---    provider its system cannot use reads as not configured.
--- 5. The local context of a System 2 request (now, weekday, time zone) is read
---    here from the system clock and the system time zone, never guessed.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Json = require("json")
local Vision = require("llm.vision")
local Agent = require("llm.agent")
local Manifest = require("infra.manifest_reader")

local LOG = "modules.llm.agent_settings"

-- The shared file this module reads, relative to _shared/
local CONFIG_FILE = "modules/llm/agent.json"

-- The setting of each system
M.SYSTEM_PATHS = { system1 = "llm.agent_system1", system2 = "llm.agent_system2" }
-- What each system asks of a provider (api_remote.serves)
local SYSTEM_USES = { system1 = "system1", system2 = "chat" }
local MODE_PATH = "llm.agent_mode"
local DISABLED_APPS_PATH = "llm.agent_disabled_apps"

-- The agent's modes, in menu order
M.MODES = { "off", "action", "auto" }
local KNOWN_MODES = Agent.MODES

-- English weekday names by os.date("*t").wday: the prompt is English, and
-- os.date("%A") would follow LC_TIME
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

-- Where the system names its time zone: an IANA name after this prefix of the
-- /etc/localtime link, or alone in /etc/timezone (Debian)
local ZONEINFO_MARKER = "zoneinfo/"

-- The decoded agent.json, loaded once
local _config = nil
-- The settings read so far, by path
local _values = {}




-- =========================================
-- =========================================
-- ======= 1/ agent.json ===================
-- =========================================
-- =========================================

--- Reports whether a value is a number within [min, max].
--- @return boolean
local function number_in(value, min, max)
	return type(value) == "number" and value == value and value >= min and value <= max
end

--- Parses agent.json. Exposed for tests.
--- @param text string|nil The file's content.
--- @return table|nil config, string|nil reason
function M.parse_config(text)
	local root = type(text) == "string" and Json.decode(text) or nil
	if type(root) ~= "table" then return nil, "agent.json is missing or not JSON" end
	if type(root.intents) ~= "table" or #root.intents == 0 then return nil, "agent.json has no intents" end
	if type(root.default_models) ~= "table" then return nil, "agent.json has no default_models" end
	local s1, s2 = root.system1, root.system2
	if type(s1) ~= "table" or type(s1.prompt) ~= "string" or s1.prompt == ""
		or not number_in(s1.pause_ms, 0, 60000) or not number_in(s1.min_chars, 1, 10000)
		or not number_in(s1.max_tokens, 1, 100000) or not number_in(s1.threshold, 0, 1) then
		return nil, "agent.json system1 is invalid"
	end
	if type(s2) ~= "table" or type(s2.prompt) ~= "string" or s2.prompt == ""
		or type(s2.tag) ~= "string" or s2.tag == "" or type(s2.user_prefix) ~= "string"
		or not number_in(s2.max_actions, 1, 100) or not number_in(s2.max_tokens, 1, 100000) then
		return nil, "agent.json system2 is invalid"
	end
	for _, key in ipairs({ "actions", "source_kinds", "learning", "ics" }) do
		if type(root[key]) ~= "table" then return nil, "agent.json has no " .. key end
	end
	local learning = root.learning
	if not number_in(learning.step, 0, 1) or not number_in(learning.min_threshold, 0, 1)
		or not number_in(learning.max_threshold, learning.min_threshold, 1) then
		return nil, "agent.json learning is invalid"
	end
	if not number_in(root.default_duration_minutes, 1, 100000) or not number_in(root.max_tools, 0, 1000) then
		return nil, "agent.json default_duration_minutes or max_tools is invalid"
	end
	if type(root.ics.prodid) ~= "string" or root.ics.prodid == "" then return nil, "agent.json has no ics.prodid" end
	return root, nil
end

--- The shipped agent.json. A missing or malformed file is an installation
--- fault: the agent refuses to run, and the reason is logged.
--- @return table|nil config
function M.config()
	if _config then return _config end
	local path = require("infra.paths").shared(CONFIG_FILE)
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	if fh then fh:close() end
	local config, reason = M.parse_config(text)
	if not config then
		Logger.error(LOG, "AI agent unavailable: %s.", tostring(reason))
		return nil
	end
	_config = config
	return _config
end




-- =========================================
-- =========================================
-- ======= 2/ Settings =====================
-- =========================================
-- =========================================

--- Reads one agent setting, the manifest's default when absent. Cached: the
--- automatic mode asks at every keystroke, and config.toml changes only through
--- the setters below or a configuration transaction (reload_configuration).
--- @param path string
--- @return any
local function read(path)
	if _values[path] ~= nil then return _values[path] end
	local value = require("infra.llm_preferences").get(path, Manifest.default_for(path))
	_values[path] = value
	return value
end

--- Stores one agent setting and its cached value.
--- @param path string
--- @param value any
--- @return boolean saved
local function write(path, value)
	if require("infra.llm_preferences").set(path, value) ~= true then return false end
	_values[path] = value
	return true
end

--- Names a stored value this build no longer accepts (a retired mode, a spec
--- today's grammar refuses): an outdated entry, warned once with the cleanup's
--- own words, read as off and offered by « Nettoyer config.toml ».
--- @param path string
local function report_invalid(path)
	ConfigOutdated.report(path, ConfigOutdated.REFUSED, Logger)
end

--- Reports whether a system setting value is valid: "" (off) or a backend spec.
--- @param value any
--- @return boolean
function M.is_valid_spec(value)
	return value == "" or (type(value) == "string" and Vision.is_valid(value))
end

--- The stored backend of a system, "" when off or invalid.
--- @param system string "system1" or "system2".
--- @return string
function M.get_spec(system)
	local path = M.SYSTEM_PATHS[system]
	if not path then error("agent_settings: unknown system " .. tostring(system), 2) end
	local value = read(path)
	if not M.is_valid_spec(value) then
		report_invalid(path)
		return ""
	end
	return value
end

--- Reports whether a system may use a backend: the local server, or a
--- provider that serves the system. An unknown provider is left to
--- chat_target(), which names it.
--- @param system string "system1" or "system2".
--- @param backend string
--- @return boolean
local function backend_fits(system, backend)
	if backend == Vision.LOCAL_BACKEND then return true end
	local Remote = require("modules.llm.api_remote")
	return Remote.provider(backend) == nil or Remote.serves(backend, SYSTEM_USES[system])
end

--- Stores the backend of a system.
--- @param system string "system1" or "system2".
--- @param value string "" (off), "<backend>" or "<backend>|<model>".
--- @return boolean saved
function M.set_spec(system, value)
	local path = M.SYSTEM_PATHS[system]
	if not path then error("agent_settings: unknown system " .. tostring(system), 2) end
	if not M.is_valid_spec(value) then
		Logger.error(LOG, "set_spec(): '%s' is not a backend for %s — refused.", tostring(value), system)
		return false
	end
	if value ~= "" and not backend_fits(system, Vision.parse(value).backend) then
		Logger.error(LOG, "set_spec(): '%s' cannot serve %s — refused.", tostring(value), system)
		return false
	end
	if not write(path, value) then
		Logger.error(LOG, "The %s backend was not persisted.", system)
		return false
	end
	Logger.info(LOG, "Agent %s backend: %s.", system, value == "" and "off" or value)
	return true
end

--- The agent's mode, "off" when the stored one is unknown.
--- @return string "off", "action" or "auto"
function M.get_mode()
	local value = read(MODE_PATH)
	if not KNOWN_MODES[value] then
		report_invalid(MODE_PATH)
		return "off"
	end
	return value
end

--- Stores the agent's mode.
--- @param mode string "off", "action" or "auto"
--- @return boolean saved
function M.set_mode(mode)
	if not KNOWN_MODES[mode] then
		Logger.error(LOG, "set_mode(): unknown mode '%s' — refused.", tostring(mode))
		return false
	end
	if not write(MODE_PATH, mode) then
		Logger.error(LOG, "The agent mode was not persisted.")
		return false
	end
	Logger.info(LOG, "Agent mode: %s.", mode)
	return true
end

--- The applications the automatic mode ignores.
--- @return table Array of application identifiers.
function M.get_disabled_apps()
	local value = read(DISABLED_APPS_PATH)
	local list = {}
	if type(value) ~= "table" then
		report_invalid(DISABLED_APPS_PATH)
		return list
	end
	for _, app in ipairs(value) do
		if type(app) == "string" and app ~= "" then list[#list + 1] = app end
	end
	return list
end

--- Stores the applications the automatic mode ignores.
--- @param apps table Array of non-empty application identifiers.
--- @return boolean saved
function M.set_disabled_apps(apps)
	if type(apps) ~= "table" then error("agent_settings.set_disabled_apps: a list is required", 2) end
	local list, seen = {}, {}
	for _, app in ipairs(apps) do
		if type(app) ~= "string" or app == "" then
			Logger.error(LOG, "set_disabled_apps(): '%s' is not an application — refused.", tostring(app))
			return false
		end
		if not seen[app] then
			seen[app] = true
			list[#list + 1] = app
		end
	end
	if not write(DISABLED_APPS_PATH, list) then
		Logger.error(LOG, "The agent's excluded applications were not persisted.")
		return false
	end
	Logger.info(LOG, "Agent: %d excluded application(s).", #list)
	return true
end

--- Reports whether the automatic mode ignores an application.
--- @param app string|nil
--- @return boolean
function M.is_app_disabled(app)
	if type(app) ~= "string" or app == "" then return false end
	for _, disabled in ipairs(M.get_disabled_apps()) do
		if disabled == app then return true end
	end
	return false
end

--- Captures the cached settings without reading or publishing preferences.
--- @return table snapshot
function M.configuration_snapshot()
	return { values = _values }
end

--- Restores the exact cache after a refused configuration transaction.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	_values = snapshot.values
	return true
end

--- Reads the detached configuration again through this owner's rules.
--- @return boolean applied False when a stored value is invalid.
function M.reload_configuration()
	_values = {}
	local valid = M.is_valid_spec(read(M.SYSTEM_PATHS.system1)) and M.is_valid_spec(read(M.SYSTEM_PATHS.system2))
		and KNOWN_MODES[read(MODE_PATH)] == true and type(read(DISABLED_APPS_PATH)) == "table"
	return valid
end

--- Marks the agent's settings consumed by this owner (config cleanup).
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local preferences = require("infra.llm_preferences")
	-- The readers' own rules, so what they read as off is what the cleanup offers.
	for system, path in pairs(M.SYSTEM_PATHS) do
		preferences.mark_config_read(document, path, mark, function(value)
			return M.is_valid_spec(value) and (value == "" or backend_fits(system, Vision.parse(value).backend))
		end)
	end
	preferences.mark_config_read(document, MODE_PATH, mark, function(value) return KNOWN_MODES[value] == true end)
	preferences.mark_config_read(document, DISABLED_APPS_PATH, mark)
end




-- =========================================
-- =========================================
-- ======= 3/ Backends =====================
-- =========================================
-- =========================================

--- The parsed backend of a system with its model.
--- @param system string "system1" or "system2".
--- @return table|nil resolved { backend, model, spec }, string|nil reason ("off", "no_model"
---   or "wrong_use" for a provider the system cannot use)
function M.resolve(system)
	local spec = M.get_spec(system)
	if spec == "" then return nil, "off" end
	local config = M.config()
	if not config then return nil, "off" end
	local parsed = Vision.parse(spec)
	if not backend_fits(system, parsed.backend) then
		report_invalid(M.SYSTEM_PATHS[system])
		return nil, "wrong_use"
	end
	local model = Agent.resolve_model(parsed, config, M.providers_catalogue())
	if not model then return nil, "no_model" end
	return { backend = parsed.backend, model = model, spec = spec }, nil
end

--- Where a system's request goes: the module that sends it (api_ollama or
--- api_remote, whose chat() share one shape), its target and the model.
--- `decision` marks a System 1 that asks Jev its typed question
--- (api_remote.decide) instead of sending the chat triage prompt.
--- @param system string "system1" or "system2".
--- @return table|nil chat { module, target, model, kind, backend, decision }, string|nil reason
---   ("off", "no_model", "wrong_use", or why the backend cannot answer)
function M.chat_target(system)
	local resolved, reason = M.resolve(system)
	if not resolved then return nil, reason end
	if resolved.backend == Vision.LOCAL_BACKEND then
		local profiles = require("modules.llm.profiles")
		local base_url = profiles.get_base_url() or require("infra.llm_bridge").resolve_base_url()
		if type(base_url) ~= "string" or base_url == "" then return nil, "no Ollama address" end
		return { module = require("modules.llm.api_ollama"), target = base_url, model = resolved.model,
			kind = "ollama", backend = resolved.backend, decision = false }, nil
	end
	local Remote = require("modules.llm.api_remote")
	if not Remote.provider(resolved.backend) then return nil, "unknown provider " .. resolved.backend end
	local entry = require("modules.llm.vision_request").entry_for(resolved.backend)
	if not entry then return nil, "no API key is stored for " .. resolved.backend end
	-- The stored key with the system's model: api_remote sends the entry's model.
	local target = {}
	for key, value in pairs(entry) do target[key] = value end
	target.model = resolved.model
	return { module = Remote, target = target, model = resolved.model, kind = "api",
		backend = resolved.backend, decision = system == "system1" and Remote.is_decision_entry(target) }, nil
end

--- The API providers as agent.resolve_model reads them: api_providers.json's
--- providers by id, each with its default_model (the one source of provider
--- defaults), as api_remote loaded and validated them.
--- @return table { providers = { [id] = descriptor } }
function M.providers_catalogue()
	local providers = {}
	for _, provider in ipairs(require("modules.llm.api_remote").providers()) do providers[provider.id] = provider end
	return { providers = providers }
end

--- The backends a system may name, for the menu: the local server, then the
--- API providers that serve the system in catalogue order, each with the
--- model it runs by default ("" when the backend needs one named).
--- @param system string "system1" or "system2".
--- @return table Array of { value, label, defaultModel }.
function M.backend_choices(system)
	local use = SYSTEM_USES[system]
	if not use then error("agent_settings.backend_choices: unknown system " .. tostring(system), 2) end
	local VisionRequest = require("modules.llm.vision_request")
	local config = M.config()
	local catalogue = M.providers_catalogue()
	local defaults = {}
	for _, choice in ipairs(VisionRequest.backend_choices({}, use)) do
		defaults[choice.value] = config and Agent.resolve_model({ backend = choice.value }, config, catalogue) or nil
	end
	return VisionRequest.backend_choices(defaults, use)
end




-- =========================================
-- =========================================
-- ======= 4/ Local time ===================
-- =========================================
-- =========================================

--- The local time of a System 2 request.
--- @param now integer|nil Seconds since the epoch; nil for the current time.
--- @return table { now = "YYYY-MM-DDTHH:MM", weekday = English name }
function M.time_context(now)
	local stamp = now or os.time()
	local parts = os.date("*t", stamp)
	return { now = os.date("%Y-%m-%dT%H:%M", stamp), weekday = WEEKDAYS[parts.wday] }
end

--- Reads the first line of a file.
--- @param path string
--- @return string|nil
local function first_line(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local line = fh:read("*l")
	fh:close()
	return line
end

--- The system's IANA time zone name: $TZ when it names one, then
--- /etc/timezone, then the target of the /etc/localtime link.
--- @return string|nil name, nil when the system does not say.
function M.timezone()
	local tz = os.getenv("TZ")
	if type(tz) == "string" then
		tz = tz:gsub("^:", "")
		local zone = tz:match(ZONEINFO_MARKER .. "(.+)$") or tz
		if zone:match("^[%w_%+%-]+/[%w_%+%-/]+$") or zone == "UTC" then return zone end
	end
	local line = first_line("/etc/timezone")
	if line and line:match("^[%w_%+%-]+/[%w_%+%-/]+$") then return line end
	local target = require("adapters.shell_runner").exec_line("readlink -f /etc/localtime 2>/dev/null")
	local zone = type(target) == "string" and target:match(ZONEINFO_MARKER .. "(.+)$") or nil
	if zone and zone ~= "" then return zone end
	return nil
end

--- Forgets the loaded file and the cached settings (tests).
function M._reset_for_test()
	_config = nil
	_values = {}
end

return M
