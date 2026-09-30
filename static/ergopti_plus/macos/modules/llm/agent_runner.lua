--- modules/llm/agent_runner.lua

--- ==============================================================================
--- MODULE: AI Agent (macOS)
--- DESCRIPTION:
--- Runs the AI agent: System 2 turns a text into at most three actions of the
--- closed schema of agent.json (a calendar event, a reminder, a mail draft, one
--- of the user's Shortcuts), offered as the prediction tooltip's candidates;
--- accepting one hands it to its connector (modules/llm/agent_connectors.lua).
--- Nothing is typed and nothing runs without that acceptance.
---
--- FEATURES & RATIONALE:
--- 1. Three sources: the selection (llm_agent_selection), a command typed in a
---    dialog (llm_agent_command), and, in the automatic mode, the sentence being
---    typed, once System 1 judged it likely enough to imply an action.
--- 2. Settings: llm.agent_system1 / llm.agent_system2 name a backend like the
---    vision actions ("local" or a provider of api_providers.json, optionally
---    "|model"), llm.agent_mode is "off", "action" or "auto", and
---    llm.agent_disabled_apps lists the applications the automatic mode ignores.
---    The keymap bridge sets them; the AI menu reads and resets them like its
---    other native settings.
--- 3. Refusals first: a paused script refuses with the notice of
---    llm_generate_prediction, then the agent's own (mode off, no usable System
---    2), before anything is read. The agent never uses the AI menu's
---    prediction backend: the AI switched off or that backend not ready refuses
---    nothing. A secure field refuses like the tone actions.
--- 4. One transport per system, each behind one function taking the backend and
---    its payload, so a new request format plugs in there. A chat backend gets
---    a plain chat body built by llm/vision.lua (the local server, a chat
---    provider) or a Backboard message. System 1 has a second kind: Jev, asked
---    its choice question through a decisions provider (TypeSafe's System One
---    protocol) or through Backboard with a "typesafe/" model. Neither the text
---    nor the answer is ever logged.
--- 5. Supersession by generation: a newer run, or a keystroke for the
---    automatic mode, drops the answers still in flight. The automatic mode is
---    not held back by an automatic next-word prediction: its actions replace
---    that tooltip.
--- 6. Learning: an accepted automatic suggestion lowers the threshold of its
---    intent in that application, a dismissed one raises it
---    (modules/llm/agent_learning.lua).
---
--- The pure logic (prompts, triage, validation, labels) is shared:
--- _shared/lua/llm/agent.lua, configured by _shared/modules/llm/agent.json.
--- ==============================================================================

local M = {}

local Agent          = require("llm.agent")
local Vision         = require("llm.vision")
local Rewrite        = require("llm.rewrite")
local Formats        = require("llm.remote_formats")
local ProviderUses   = require("modules.llm.provider_uses")
local Logger         = require("infra.logger")
local i18n           = require("infra.i18n")
local Paths          = require("infra.paths")
local Manifest       = require("infra.manifest_reader")
local FileSystem     = require("adapters.file_system")
local JsonCodec      = require("adapters.json_codec")
local WindowInfo     = require("adapters.window_info")
local SystemInfo     = require("adapters.system_info")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.agent_runner"

-- What the engine's shared answer seams log this flow as
local LABEL = "AI agent"

-- The Backboard model prefix of Jev: such a System 1 asks Jev's questions
local JEV_BACKBOARD_PREFIX = "typesafe/"

-- The notice of a paused script, shared with llm_generate_prediction
local PAUSED_KEY = "llm.manual_prediction.paused"

M.MODE_OFF    = "off"
M.MODE_ACTION = "action"
M.MODE_AUTO   = "auto"
local MODES = Agent.MODES
for _, mode in ipairs({ M.MODE_OFF, M.MODE_ACTION, M.MODE_AUTO }) do
	assert(MODES[mode], "the shared agent modes lack '" .. mode .. "'")
end

-- The runtime keys of the settings, as the preference owner names them
local SETTING_KEYS = {
	llm_agent_system1       = "llm.agent_system1",
	llm_agent_system2       = "llm.agent_system2",
	llm_agent_mode          = "llm.agent_mode",
	llm_agent_disabled_apps = "llm.agent_disabled_apps",
}

-- The Shortcuts list is read again after this many seconds
M.TOOLS_MAX_AGE_SEC = 600

-- English weekday names, by os.date's wday (1 = Sunday)
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

-- The done notice of each action type
local DONE_KEYS = {
	calendar = "llm.agent.done_calendar",
	reminder = "llm.agent.done_reminder",
	mail     = "llm.agent.done_mail",
	shortcut = "llm.agent.done_shortcut",
}

local _config = nil
local _settings = nil

-- Generation of the current run; a callback of an older one is stale
local _generation = 0

-- Generation of the typing the automatic mode watches; a keystroke advances it
local _typing_generation = 0
local _pause_timer = nil
local _typed = nil
local _last_triaged = nil

-- The user's Shortcuts: nil until listed once
local _tools = nil
local _tools_at = nil
local _tools_waiters = nil

-- Injected for tests: the wall clock and the owner that persists the mode
local _clock = os.time
local _mode_persister = nil




-- =====================================
-- =====================================
-- ======= 1/ Configuration ============
-- =====================================
-- =====================================

--- Returns the decoded _shared/modules/llm/agent.json, read once. A missing or
--- malformed file is a broken install and raises.
--- @return table config
function M.config()
	if _config then return _config end
	local path = Paths.shared_llm_path("agent.json")
	local raw = path and FileSystem.read(path) or nil
	if type(raw) ~= "string" then error("agent_runner: _shared/modules/llm/agent.json is unreadable") end
	local config, decode_error = JsonCodec.decode(raw)
	if type(config) ~= "table" then
		error("agent_runner: agent.json is not valid JSON: " .. tostring(decode_error))
	end
	for _, key in ipairs({ "system1", "system2", "actions", "source_kinds", "default_models", "learning" }) do
		if type(config[key]) ~= "table" then error("agent_runner: agent.json field '" .. key .. "' must be a table") end
	end
	if type(config.max_tools) ~= "number" or config.max_tools < 0 then
		error("agent_runner: agent.json field 'max_tools' must be a number")
	end
	_config = config
	return _config
end

--- Returns the settings, the manifest defaults until the bridge sets them.
--- @return table settings
local function settings()
	if _settings then return _settings end
	_settings = {}
	for key, path in pairs(SETTING_KEYS) do _settings[key] = Manifest.default_for(path) end
	return _settings
end

--- Clones a list of application descriptors.
--- @param apps table
--- @return table
local function clone_apps(apps)
	local out = {}
	for index, app in ipairs(apps) do
		local copy = {}
		for key, value in pairs(app) do copy[key] = value end
		out[index] = copy
	end
	return out
end




-- =====================================
-- =====================================
-- ======= 2/ Internal Helpers =========
-- =====================================
-- =====================================

--- Shows a notice of the agent.
--- @param key string Locale key.
--- @param ... any Values of its {1}, {2}, … placeholders.
local function show_notice(key, ...)
	local text = i18n.format(key, ...)
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local ok_show, shown = false, nil
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.show) == "function" then
		ok_show, shown = pcall(tooltip.show, text, true, true)
	end
	if not ok_show or shown ~= true then
		Logger.warn(LOG, "Agent notice '%s' was not shown: %s.", key, tostring(shown))
	end
end

--- Loads a module the agent calls at dispatch time.
--- @param name string Module name.
--- @param method string Function the module must expose.
--- @return table|nil module The module, or nil after logging why it is unavailable.
local function dependency(name, method)
	local ok, module = pcall(require, name)
	if not ok or type(module) ~= "table" or type(module[method]) ~= "function" then
		Logger.error(LOG, "Agent impossible: '%s.%s' is unavailable (%s).", name, method, tostring(module))
		return nil
	end
	return module
end

--- Tells whether a callback still belongs to the current run.
--- @param generation number
--- @param stage string What the callback delivers, for the log.
--- @return boolean current
local function is_current(generation, stage)
	if generation == _generation then return true end
	Logger.info(LOG, "Agent %s dropped: a newer request superseded it.", stage)
	return false
end

--- Tells whether the script is paused.
--- @return boolean paused
local function is_paused()
	local control = package.loaded["modules.shortcuts.script_control"]
	return type(control) == "table" and type(control.is_paused) == "function" and control.is_paused() == true
end

--- Resolves a System setting to where its requests go.
--- @param value string The setting: "" (off), "<backend>" or "<backend>|<model>".
--- @param use string|nil provider_uses.SYSTEM1 or SYSTEM2 (the default).
--- @return table|nil backend { kind = "local"|"remote", provider, format, model }.
--- @return string|nil reason "off", "invalid", "no_model" or the provider's refusal
---         ("unknown_provider", "unsupported", "no_entry", "missing_token").
function M.resolve_backend(value, use)
	use = use or ProviderUses.SYSTEM2
	if value == nil or value == "" then return nil, "off" end
	local parsed = Vision.parse(value)
	if not parsed then return nil, "invalid" end
	local Remote = require("modules.llm.api_remote")
	local model = Agent.resolve_model(parsed, M.config(), { providers = Remote.PROVIDERS })
	if not model then return nil, "no_model" end
	if parsed.backend == Vision.LOCAL_BACKEND then
		return { kind = "local", format = "ollama", model = model, backend = parsed.backend }
	end
	local ready, reason = Remote.provider_status(parsed.backend, use)
	if not ready then return nil, tostring(reason) end
	return { kind = "remote", provider = parsed.backend, format = Remote.provider_format(parsed.backend),
		model = model, backend = parsed.backend }
end

--- Tells whether a System setting names a backend with a model.
--- @param value string The setting.
--- @return boolean configured
local function is_configured(value)
	if value == nil or value == "" then return false end
	local parsed = Vision.parse(value)
	if not parsed then return false end
	local Remote = require("modules.llm.api_remote")
	return Agent.resolve_model(parsed, M.config(), { providers = Remote.PROVIDERS }) ~= nil
end

--- Posts one plain chat request to a backend.
--- @param backend table What resolve_backend returned.
--- @param payload table { system, text, max_tokens }.
--- @param on_text function Receives the answer.
--- @param on_fail function Receives a short reason, and { model } when the local
---        server does not hold the model (modules/llm/local_model_offer.lua).
local function chat(backend, payload, on_text, on_fail, use)
	if backend.format == "backboard" then
		local Remote = dependency("modules.llm.api_remote", "request_backboard")
		if not Remote then return on_fail("the remote backend is unavailable") end
		Remote.request_backboard(backend.provider, {
			model = backend.model, system = payload.system, text = payload.text,
		}, function(answer)
			local text = Formats.backboard_text(answer)
			if type(text) ~= "string" or text == "" then return on_fail("empty_answer") end
			on_text(text)
		end, on_fail, use)
		return
	end
	if not ProviderUses.format_serves(backend.format, ProviderUses.SYSTEM2) and backend.kind ~= "local" then
		return on_fail("a " .. tostring(backend.format) .. " provider is not a chat model")
	end
	local body = Vision.build_request(backend.format, {
		model = backend.model, system = payload.system, text = payload.text, max_tokens = payload.max_tokens,
	})
	if backend.kind == "local" then
		local Ollama = dependency("modules.llm.api_ollama", "request_chat")
		if not Ollama then return on_fail("the local backend is unavailable") end
		Ollama.request_chat(body, on_text, on_fail)
		return
	end
	local Remote = dependency("modules.llm.api_remote", "request_chat")
	if not Remote then return on_fail("the remote backend is unavailable") end
	Remote.request_chat(backend.provider, backend.model, body, on_text, on_fail, use)
end

--- Decodes a JSON text, raising on an invalid one (what the shared parsers expect).
--- @param text string
--- @return any value
local function decode_json(text)
	-- A chat answer is plain text: refused here, not reported by the codec
	if type(text) ~= "string" or not text:match("^%s*[%[{]") then error("not a JSON text") end
	local value, decode_error = JsonCodec.decode(text)
	if decode_error then error(decode_error) end
	return value
end

--- Names the top-level keys of a decoded answer, never its values.
--- @param value any
--- @return string keys
local function top_level_keys(value)
	if type(value) ~= "table" then return type(value) end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)
	return table.concat(keys, ", ")
end

--- The state Jev's questions are about: the application and the sentence.
--- @param sentence string
--- @param ctx table { app }.
--- @return string state
local function jev_state(sentence, ctx)
	return "App: " .. tostring(ctx.app or "") .. "\nText: " .. sentence
end

--- Tells whether a System 1 backend asks Jev's questions rather than a chat prompt.
--- @param backend table What resolve_backend returned.
--- @return boolean jev
function M.is_jev_backend(backend)
	if type(backend) ~= "table" then return false end
	if backend.format == "decisions" then return true end
	return backend.format == "backboard" and type(backend.model) == "string"
		and backend.model:sub(1, #JEV_BACKBOARD_PREFIX) == JEV_BACKBOARD_PREFIX
end

--- Asks Jev its triage question, through a decisions provider or Backboard.
--- @param backend table What resolve_backend returned.
--- @param sentence string The sentence being typed.
--- @param ctx table { app }.
--- @param on_triage function Receives { intent, probability }, or nil when unreadable.
local function jev_triage(backend, sentence, ctx, on_triage)
	local config = M.config()
	local questions = Agent.jev_questions(config)
	local state = jev_state(sentence, ctx)
	local function on_fail(reason)
		Logger.warn(LOG, "System 1 (Jev) gave no answer (%s).", tostring(reason))
		on_triage(nil)
	end
	local Remote
	if backend.format == "decisions" then
		Remote = dependency("modules.llm.api_remote", "request_decisions")
		if not Remote then return on_fail("the remote backend is unavailable") end
		Remote.request_decisions(backend.provider, backend.model, state, questions, function(answers)
			on_triage(Agent.parse_jev_answers(config, answers))
		end, on_fail)
		return
	end
	Remote = dependency("modules.llm.api_remote", "request_backboard")
	if not Remote then return on_fail("the remote backend is unavailable") end
	Remote.request_backboard(backend.provider, {
		model = backend.model, system = "", text = state, questions = questions,
	}, function(answer)
		local answers, where = Formats.backboard_decision_answers(answer, decode_json)
		if not answers then
			-- Where Backboard puts Jev's answers is not documented: the keys tell
			-- where to look, the values are never logged
			Logger.warn(LOG, "System 1 (Jev through Backboard): no answers in the reply (top-level keys: %s).",
				top_level_keys(answer))
			on_triage(nil)
			return
		end
		Logger.info(LOG, "System 1 (Jev through Backboard): answers read from '%s'.", tostring(where))
		on_triage(Agent.parse_jev_answers(config, answers))
	end, on_fail, ProviderUses.SYSTEM1)
end

--- The System 1 transport: triages a sentence, with a chat prompt or, for
--- Jev (a decisions provider, or Backboard with a "typesafe/" model), its
--- choice question.
--- @param backend table What resolve_backend returned.
--- @param sentence string The sentence being typed.
--- @param ctx table { app, tools }.
--- @param on_triage function Receives { intent, probability }, or nil when unreadable.
function M.system1_transport(backend, sentence, ctx, on_triage)
	if M.is_jev_backend(backend) then return jev_triage(backend, sentence, ctx, on_triage) end
	local config = M.config()
	chat(backend, {
		system = Agent.system1_prompt(config, ctx), text = sentence, max_tokens = config.system1.max_tokens,
	}, function(raw)
		on_triage(Agent.parse_system1(config, raw))
	end, function(reason, detail)
		Logger.warn(LOG, "System 1 gave no answer (%s).", tostring(reason))
		local Offer = require("modules.llm.local_model_offer")
		-- System 1 triages what is being typed: a notification, never a dialog
		if Offer.is_missing(reason, detail) then Offer.offer(detail.model, { automatic = true }) end
		on_triage(nil)
	end, ProviderUses.SYSTEM1)
end

--- The System 2 transport: asks for the actions of a text. A new System 2
--- backend plugs in here.
--- @param backend table What resolve_backend returned.
--- @param payload table { system, text, max_tokens }.
--- @param on_raw function Receives the raw answer.
--- @param on_fail function Receives a short reason.
function M.system2_transport(backend, payload, on_raw, on_fail)
	chat(backend, payload, on_raw, on_fail, ProviderUses.SYSTEM2)
end

--- Calls back with the user's Shortcuts, read again when older than
--- TOOLS_MAX_AGE_SEC (or when `force`). A list that cannot be read leaves the
--- previous one, or none.
--- @param force boolean|nil Read the list again whatever its age.
--- @param on_ready function|nil Receives the list.
function M.refresh_tools(force, on_ready)
	local fresh = _tools ~= nil and _tools_at ~= nil and TimerScheduler.now() - _tools_at < M.TOOLS_MAX_AGE_SEC
	if fresh and force ~= true then
		if on_ready then on_ready(_tools) end
		return
	end
	if _tools_waiters then
		if on_ready then _tools_waiters[#_tools_waiters + 1] = on_ready end
		return
	end
	_tools_waiters = { on_ready }
	local Connectors = require("modules.llm.agent_connectors")
	Connectors.list_tools(M.config().max_tools, function(names)
		if names then
			_tools, _tools_at = names, TimerScheduler.now()
		else
			Logger.warn(LOG, "The Shortcuts list could not be read; keeping %d tool(s).", _tools and #_tools or 0)
			_tools = _tools or {}
			_tools_at = TimerScheduler.now()
		end
		local waiters = _tools_waiters or {}
		_tools_waiters = nil
		for _, waiter in ipairs(waiters) do
			local ok, err = xpcall(waiter, debug.traceback, _tools)
			if not ok then Logger.error(LOG, "A Shortcuts list consumer raised: %s.", tostring(err)) end
		end
	end)
end

--- The context the prompts name: the moment, the time zone, the interface
--- language, the application and window the text comes from, the tools.
--- @param source string "selection", "command" or "typing".
--- @param focus table WindowInfo of the source window.
--- @param tools table The user's Shortcuts.
--- @return table ctx
local function build_context(source, focus, tools)
	local now = _clock()
	return {
		source = source,
		app = focus.appId or "",
		window = focus.windowTitle or "",
		now = os.date("%Y-%m-%dT%H:%M", now),
		weekday = WEEKDAYS[os.date("*t", now).wday],
		timezone = SystemInfo.time_zone() or os.date("%z", now),
		language = require("modules.llm.profiles").prompt_language(),
		tools = tools,
	}
end

--- Shows the outcome of a connector.
--- @param action table The action it carried out.
--- @param ok boolean
--- @param detail table|nil
local function report_connector(action, ok, detail)
	if ok then
		Logger.info(LOG, "Agent action '%s' carried out.", action.type)
		if action.type == "calendar" or action.type == "reminder" then
			show_notice(DONE_KEYS[action.type], action.title)
		elseif action.type == "shortcut" then
			show_notice(DONE_KEYS.shortcut, action.name)
		else
			show_notice(DONE_KEYS.mail)
		end
		return
	end
	local reason = type(detail) == "table" and detail.reason or tostring(detail)
	Logger.error(LOG, "Agent action '%s' failed: %s.", action.type, tostring(reason))
	if type(detail) == "table" and detail.permission then
		show_notice("llm.agent.permission_needed", detail.permission)
		local Connectors = require("modules.llm.agent_connectors")
		if not Connectors.open_automation_settings() then
			Logger.error(LOG, "The Automation settings could not be opened.")
		end
		return
	end
	show_notice("llm.agent.connector_failed")
end

--- Carries out an accepted action.
--- @param action table The validated action.
--- @param learning table|nil { app, intent } of an automatic suggestion.
--- @return boolean started
local function accept(action, learning)
	if learning then
		require("modules.llm.agent_learning").record(M.config(), learning.app, learning.intent, true)
	end
	local Connectors = require("modules.llm.agent_connectors")
	Logger.info(LOG, "Agent action '%s' accepted.", action.type)
	local started = Connectors.run(action, function(ok, detail) report_connector(action, ok, detail) end)
	return started == true
end

--- Offers the actions of a System 2 answer.
--- @param generation number The run.
--- @param engine table The prediction engine.
--- @param session number|nil The surface, nil when the automatic mode opens it now.
--- @param raw string The answer.
--- @param tools table The tools the prompt named.
--- @param learning table|nil { app, intent } of an automatic suggestion.
local function offer_actions(generation, engine, session, raw, tools, learning)
	local config = M.config()
	local actions, rejected = Agent.parse_actions(config, raw, decode_json, { tools = tools })
	for _, reason in ipairs(rejected) do Logger.warn(LOG, "Agent action refused: %s.", tostring(reason)) end
	if actions == nil then
		Logger.warn(LOG, "Agent failed: the answer holds no %s block (%d char(s)).", config.system2.tag, #tostring(raw))
		if session then engine.close_answer_surface(session) end
		if not learning then show_notice("llm.agent.failed") end
		return
	end
	if #actions == 0 then
		Logger.info(LOG, "Agent found no action (%d refused).", #rejected)
		if session then engine.close_answer_surface(session) end
		if not learning then show_notice("llm.agent.no_action") end
		return
	end
	if not session then
		-- The automatic mode stays silent until it has something to offer
		session = engine.open_answer_surface(LABEL)
		if not session then
			Logger.warn(LOG, "Agent suggestions dropped: the prediction tooltip could not be opened.")
			return
		end
	end
	local labels, handlers = {}, {}
	for index, action in ipairs(actions) do
		local key, args = Agent.label(action)
		labels[index] = i18n.format(key, table.unpack(args))
		handlers[index] = function() return accept(action, learning) end
	end
	local on_dismiss = nil
	if learning then
		on_dismiss = function()
			require("modules.llm.agent_learning").record(config, learning.app, learning.intent, false)
		end
	end
	if not engine.show_answers(session, labels, #labels, handlers, on_dismiss) then
		Logger.info(LOG, "Agent suggestions dropped: their tooltip was dismissed or replaced.")
		return
	end
	Logger.info(LOG, "Agent run %d offers %d action(s) (%d refused).", generation, #actions, #rejected)
end

--- Sends the System 2 request of a text and offers its actions.
--- @param generation number The run.
--- @param source string "selection", "command" or "typing".
--- @param text string The source text.
--- @param focus table WindowInfo of the source window.
--- @param backend table System 2's backend.
--- @param learning table|nil { app, intent, is_current, blocked } of an automatic
---        suggestion: whether its typing is still current, and why it must not
---        show now (nil when it may).
local function run_agent(generation, source, text, focus, backend, learning)
	M.refresh_tools(false, function(tools)
		if not is_current(generation, "tools") then return end
		local engine = dependency("modules.llm.prediction_engine", "open_answer_surface")
		if not engine then return end
		local session = nil
		if not learning then
			session = engine.open_answer_surface(LABEL)
			if not session then
				Logger.warn(LOG, "Agent stopped: the prediction tooltip could not be opened.")
				return
			end
		end
		local config = M.config()
		local ctx = build_context(source, focus, tools)
		--- Tells whether the answer still belongs to this run and, for an
		--- automatic suggestion, to the typing it was made for.
		local function still_current()
			if not is_current(generation, "answer") then return false end
			if learning and not learning.is_current() then
				Logger.info(LOG, "Agent suggestion dropped: the user typed since.")
				return false
			end
			local blocker = learning and learning.blocked() or nil
			if blocker then
				Logger.info(LOG, "Agent suggestion dropped (%s).", blocker)
				return false
			end
			return true
		end
		local function on_raw(raw)
			if not still_current() then return end
			offer_actions(generation, engine, session, raw, tools, learning)
		end
		local function on_fail(reason, detail)
			if not still_current() then return end
			Logger.warn(LOG, "Agent failed: System 2 gave no answer (%s).", tostring(reason))
			if session then engine.close_answer_surface(session) end
			local Offer = require("modules.llm.local_model_offer")
			if Offer.is_missing(reason, detail) then
				-- Named, with its Download button, instead of the vague failure
				Offer.offer(detail.model, { automatic = learning ~= nil })
				return
			end
			if not learning then show_notice("llm.agent.failed") end
		end
		M.system2_transport(backend, {
			system = Agent.system2_prompt(config, ctx),
			text = Agent.system2_user_text(config, text),
			max_tokens = config.system2.max_tokens,
		}, on_raw, on_fail)
		Logger.info(LOG, "Agent run %d requested (%s, backend '%s', model %s, %d byte(s), %d tool(s)).",
			generation, source, backend.backend, backend.model, #text, #tools)
	end)
end

--- The refusals every action shares, before anything is read. The agent never
--- uses the AI menu's prediction backend: that menu off, or its backend not
--- ready, refuses nothing here.
--- @return table|nil backend System 2's backend, nil after the refusal was shown.
local function admit()
	local engine = dependency("modules.llm.prediction_engine", "is_focus_blocked")
	if not engine then return nil end
	if is_paused() then
		Logger.info(LOG, "Agent refused: the script is paused.")
		show_notice(PAUSED_KEY)
		return nil
	end
	if settings().llm_agent_mode == M.MODE_OFF then
		Logger.info(LOG, "Agent refused: its mode is off.")
		show_notice("llm.agent.off_notice")
		return nil
	end
	local backend, reason = M.resolve_backend(settings().llm_agent_system2, ProviderUses.SYSTEM2)
	if not backend then
		-- Not chosen, not a chat model, or no API entry or key for its provider
		Logger.info(LOG, "Agent refused: System 2 is not usable (%s).", tostring(reason))
		show_notice("llm.agent.no_system2")
		return nil
	end
	if engine.is_focus_blocked({}) then
		Logger.info(LOG, "Agent refused: the focused field or window refuses AI text.")
		return nil
	end
	return backend
end




-- =====================================
-- =====================================
-- ======= 3/ Settings =================
-- =====================================
-- =====================================

--- Sets System 1's backend.
--- @param value string "" (off), "<backend>" or "<backend>|<model>".
--- @return boolean applied
function M.set_system1(value)
	if type(value) ~= "string" or (value ~= "" and not Vision.parse(value)) then
		Logger.error(LOG, "System 1 setting refused: '%s' is not a backend.", tostring(value))
		return false
	end
	settings().llm_agent_system1 = value
	Logger.debug(LOG, "System 1: '%s'.", value)
	return true
end

--- Sets System 2's backend.
--- @param value string "" (off), "<backend>" or "<backend>|<model>".
--- @return boolean applied
function M.set_system2(value)
	if type(value) ~= "string" or (value ~= "" and not Vision.parse(value)) then
		Logger.error(LOG, "System 2 setting refused: '%s' is not a backend.", tostring(value))
		return false
	end
	settings().llm_agent_system2 = value
	Logger.debug(LOG, "System 2: '%s'.", value)
	return true
end

--- Sets the mode.
--- @param value string "off", "action" or "auto".
--- @return boolean applied
function M.set_mode(value)
	if not MODES[value] then
		Logger.error(LOG, "Agent mode refused: '%s' is not a mode.", tostring(value))
		return false
	end
	settings().llm_agent_mode = value
	if value ~= M.MODE_AUTO then M.cancel_typing("mode " .. value) end
	Logger.debug(LOG, "Agent mode: '%s'.", value)
	return true
end

--- Sets the applications the automatic mode ignores.
--- @param apps table Descriptors { name, bundleID, appPath }.
--- @return boolean applied
function M.set_disabled_apps(apps)
	if type(apps) ~= "table" then
		Logger.error(LOG, "Agent excluded applications refused: not a list.")
		return false
	end
	for _, app in ipairs(apps) do
		if type(app) ~= "table" then
			Logger.error(LOG, "Agent excluded applications refused: an entry is not an application.")
			return false
		end
	end
	settings().llm_agent_disabled_apps = clone_apps(apps)
	Logger.debug(LOG, "Agent excluded applications: %d.", #apps)
	return true
end

--- Reads one setting as the preference owner names it.
--- @param key string "llm_agent_system1", "llm_agent_system2", "llm_agent_mode" or "llm_agent_disabled_apps".
--- @return boolean found
--- @return any value
function M.get_runtime_setting(key)
	if SETTING_KEYS[key] == nil then return false, nil end
	local value = settings()[key]
	if key == "llm_agent_disabled_apps" then value = clone_apps(value) end
	return true, value
end

--- Registers the owner that persists a mode change an action asks for (the AI
--- menu's setting transaction).
--- @param persister function|nil fn(mode) -> boolean committed.
function M.set_mode_persister(persister)
	if persister ~= nil and type(persister) ~= "function" then
		error("agent_runner.set_mode_persister: a function or nil is required")
	end
	_mode_persister = persister
	Logger.debug(LOG, "Agent mode persister %s.", persister and "registered" or "cleared")
end

--- Tells whether a System setting names a backend with a model.
--- @param value string The setting.
--- @return boolean configured
function M.is_configured(value)
	return is_configured(value)
end




-- =====================================
-- =====================================
-- ======= 4/ Actions ==================
-- =====================================
-- =====================================

--- The llm_agent_selection action: the actions the selection implies.
--- @param parent string|nil Stable action parent of the text actions.
--- @return boolean started True when the selection is being read.
function M.run_selection(parent)
	local backend = admit()
	if not backend then return false end
	local Text = dependency("modules.shortcuts.actions.text", "read_copied_selection")
	if not Text then return false end
	local focus = WindowInfo.getFocused()
	local previous = _generation
	_generation = previous + 1
	local generation = _generation
	local started = Text.read_copied_selection(parent, function(selection)
		if not is_current(generation, "selection") then return end
		if type(selection) ~= "string" or selection:match("^%s*$") then
			Logger.info(LOG, "Agent refused: the selection holds no text.")
			show_notice("llm.agent.no_selection")
			return
		end
		run_agent(generation, "selection", selection, focus, backend, nil)
	end, function()
		if not is_current(generation, "selection") then return end
		Logger.info(LOG, "Agent refused: nothing is selected.")
		show_notice("llm.agent.no_selection")
	end)
	if not started then
		if _generation == generation then _generation = previous end
		Logger.info(LOG, "Agent ignored: the selection cannot be read now.")
		return false
	end
	Logger.info(LOG, "Agent run %d started on the selection.", generation)
	return true
end

--- The llm_agent_command action: the actions a command typed in a dialog asks for.
--- @return boolean started True when the dialog is about to open.
function M.run_command()
	local backend = admit()
	if not backend then return false end
	local focus = WindowInfo.getFocused()
	_generation = _generation + 1
	local generation = _generation
	-- A modal dialog must not open inside the event tap that dispatched the action
	local _, committed = TimerScheduler.after(0, function()
		if not is_current(generation, "command") then return end
		local dialog = dependency("infra.dialog_util", "text_prompt")
		if not dialog then return end
		local ok_label = i18n.get("button.ok")
		local ok, button, typed = pcall(dialog.text_prompt, i18n.get("dialog.agent.command_title"),
			i18n.get("dialog.agent.command_prompt"), "", ok_label, i18n.get("common.cancel"))
		if not ok then
			Logger.error(LOG, "Agent command dialog raised: %s.", tostring(button))
			return
		end
		if button ~= ok_label or type(typed) ~= "string" or typed:match("^%s*$") then
			Logger.info(LOG, "Agent command cancelled.")
			return
		end
		if not is_current(generation, "command") then return end
		run_agent(generation, "command", typed:match("^%s*(.-)%s*$"), focus, backend, nil)
	end)
	if committed ~= true then
		Logger.error(LOG, "Agent command dialog could not be scheduled.")
		return false
	end
	Logger.info(LOG, "Agent run %d waits for a command.", generation)
	return true
end

--- The llm_agent_auto_toggle action: the automatic mode on (from "off" or
--- "action") or back to "action". Turning it on needs System 1.
--- @return boolean changed True when the mode changed.
function M.toggle_auto()
	local current = settings().llm_agent_mode
	local target = current == M.MODE_AUTO and M.MODE_ACTION or M.MODE_AUTO
	if target == M.MODE_AUTO and not is_configured(settings().llm_agent_system1) then
		Logger.info(LOG, "Automatic mode refused: System 1 is not chosen.")
		show_notice("llm.agent.no_system1")
		return false
	end
	local committed
	if _mode_persister then
		local ok, result = xpcall(_mode_persister, debug.traceback, target)
		committed = ok and result == true
		if not ok then Logger.error(LOG, "Agent mode persister raised: %s.", tostring(result)) end
	else
		Logger.warn(LOG, "Agent mode changed without a persister: the change lasts this session only.")
		committed = M.set_mode(target)
	end
	if not committed then
		Logger.error(LOG, "Agent mode '%s' could not be applied.", target)
		return false
	end
	Logger.info(LOG, "Agent mode: '%s' -> '%s'.", tostring(current), target)
	show_notice(target == M.MODE_AUTO and "llm.agent.auto_on" or "llm.agent.auto_off")
	return true
end




-- =====================================
-- =====================================
-- ======= 5/ Automatic mode ===========
-- =====================================
-- =====================================

--- Stops the pause timer and drops the automatic requests in flight.
--- @param reason string Why, for the log.
function M.cancel_typing(reason)
	_typing_generation = _typing_generation + 1
	if _pause_timer then
		TimerScheduler.cancel(_pause_timer)
		_pause_timer = nil
		Logger.debug(LOG, "Agent pause timer cancelled (%s).", tostring(reason))
	end
end

--- Counts the code points of a text.
--- @param text string
--- @return number
local function length(text)
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

--- Tells why the automatic mode must not look at the typing now, or nil.
--- @return string|nil reason
local function auto_blocker()
	local s = settings()
	if s.llm_agent_mode ~= M.MODE_AUTO then return "mode" end
	if is_paused() then return "paused" end
	local engine = package.loaded["modules.llm.prediction_engine"]
	if type(engine) ~= "table" then return "no engine" end
	if engine.get_live_prompt() ~= nil then return "live mode" end
	-- An automatic next-word prediction shows before the typing pause ends: it
	-- holds nothing back, the agent's actions replace it. Anything the user
	-- asked for (an explicit prediction, an answer, the agent's own offer) does.
	local activity = engine.ai_activity()
	if activity == "explicit" then return "AI action in flight or shown" end
	if engine.is_visible() and activity ~= "automatic" then return "AI tooltip shown" end
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_hotstring_visible) == "function"
		and tooltip.is_hotstring_visible() == true then
		return "hotstring tooltip shown"
	end
	if engine.is_focus_blocked(s.llm_agent_disabled_apps) then return "excluded field or application" end
	return nil
end

--- Triages the sentence typed before the pause.
--- @param typing number The typing generation the pause belongs to.
local function on_pause(typing)
	_pause_timer = nil
	if typing ~= _typing_generation or type(_typed) ~= "string" then return end
	local blocker = auto_blocker()
	if blocker then
		Logger.debug(LOG, "Agent triage skipped (%s).", blocker)
		return
	end
	local config = M.config()
	local sentence = Rewrite.sentence_span(_typed):match("^(.-)%s*$")
	if length(sentence) < config.system1.min_chars then return end
	if sentence == _last_triaged then
		Logger.debug(LOG, "Agent triage skipped: this sentence was already triaged.")
		return
	end
	local system1, reason1 = M.resolve_backend(settings().llm_agent_system1, ProviderUses.SYSTEM1)
	local system2, reason2 = M.resolve_backend(settings().llm_agent_system2, ProviderUses.SYSTEM2)
	if not system1 or not system2 then
		Logger.debug(LOG, "Agent triage skipped: System 1 (%s) or System 2 (%s) is not usable.",
			tostring(reason1 or "ok"), tostring(reason2 or "ok"))
		return
	end
	_last_triaged = sentence
	local focus = WindowInfo.getFocused()
	local app = focus.appId or ""
	M.refresh_tools(false, function(tools)
		if typing ~= _typing_generation then return end
		Logger.info(LOG, "Agent triage requested (%d char(s), app '%s').", length(sentence), app)
		M.system1_transport(system1, sentence, { app = app, tools = tools }, function(triage)
			if typing ~= _typing_generation then
				Logger.info(LOG, "Agent triage dropped: the user typed since.")
				return
			end
			if not triage then
				Logger.warn(LOG, "Agent triage unreadable.")
				return
			end
			local threshold = require("modules.llm.agent_learning").threshold(config, app, triage.intent)
			if not Agent.should_act(triage, threshold) then
				Logger.info(LOG, "Agent triage: '%s' at %.2f, under %.2f — nothing to suggest.",
					triage.intent, triage.probability, threshold)
				return
			end
			if auto_blocker() then return end
			Logger.info(LOG, "Agent triage: '%s' at %.2f (threshold %.2f) — asking System 2.",
				triage.intent, triage.probability, threshold)
			_generation = _generation + 1
			local generation = _generation
			local watched = typing
			run_agent(generation, "typing", sentence, focus, system2, { app = app, intent = triage.intent,
				is_current = function() return watched == _typing_generation end, blocked = auto_blocker })
		end)
	end)
end

--- Watches the typing for the automatic mode: every keystroke drops the
--- automatic requests in flight and waits for the next pause.
--- @param buffer string|nil The typed text.
function M.observe_typing(buffer)
	if settings().llm_agent_mode ~= M.MODE_AUTO then
		if _pause_timer then M.cancel_typing("mode") end
		return
	end
	M.cancel_typing("keystroke")
	_typed = buffer
	if type(buffer) ~= "string" or #buffer < M.config().system1.min_chars then return end
	local typing = _typing_generation
	local handle, committed = TimerScheduler.after(M.config().system1.pause_ms / 1000, function()
		on_pause(typing)
	end)
	if committed ~= true then
		Logger.error(LOG, "Agent pause timer could not be armed.")
		return
	end
	_pause_timer = handle
end




-- =====================================
-- =====================================
-- ======= 6/ Lifecycle ================
-- =====================================
-- =====================================

--- Drops every run in flight and the cached files, for tests and a fresh start.
function M.reset()
	_generation = _generation + 1
	M.cancel_typing("reset")
	_config, _settings, _typed, _last_triaged = nil, nil, nil, nil
	_tools, _tools_at, _tools_waiters = nil, nil, nil
	Logger.debug(LOG, "Agent generation advanced to %d.", _generation)
end

--- Replaces the wall clock, for tests.
--- @param clock function|nil fn() -> epoch seconds; nil restores os.time.
function M.set_clock(clock)
	if clock ~= nil and type(clock) ~= "function" then error("agent_runner.set_clock: a function or nil is required") end
	_clock = clock or os.time
end

return M
