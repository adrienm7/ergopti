--- modules/llm/prediction_engine.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine (Linux)
--- DESCRIPTION:
--- Debounces ordinary typing, handles explicit and word-end triggers, applies
--- privacy gates, and presents parsed Ollama completions for an explicit user
--- commit. Model output never reaches the focused application before acceptance,
--- except for the tone actions, which the user fires on a selection precisely
--- to have it replaced (llm/tone.lua). The screen actions (llm/vision.lua) offer
--- answers to what is on the screen through the same tooltip and acceptance.
--- The translation action (llm/translate.lua) offers the selection translated;
--- accepting it replaces the selection the way a tone step does.
--- Live mode (llm_live_prompt_toggle) redirects the automatic typing trigger to
--- a chosen prompt, so a rewrite prompt shows the sentence translated or
--- rewritten as it is typed; Tab accepts it. It owns no second pipeline.
--- The AI agent (llm/agent.lua) offers actions as candidates of the same
--- tooltip: System 2 reads the selection, a typed command or, in the automatic
--- mode, the sentence System 1 flagged after a typing pause. Accepting one runs
--- its connector (modules/llm/agent_connectors.lua); nothing is typed.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local HttpBridge = require("infra.llm_bridge")
local PromptBuilder = require("llm.prompt_builder")
local ProfileSelector = require("llm.profile_selector")
local Parser = require("llm.parser")
local Rewrite = require("llm.rewrite")
local PromptAction = require("llm.prompt_action")
local Tone = require("llm.tone")
local Vision = require("llm.vision")
local Translate = require("llm.translate")
local Agent = require("llm.agent")
local Settings = require("modules.llm.settings")
local TriggerSettings = require("modules.llm.trigger_settings")
local DisplaySettings = require("modules.llm.display_settings")
local ProfileSettings = require("modules.llm.profile_settings")
local VisionRequest = require("modules.llm.vision_request")
local LocalModelOffer = require("modules.llm.local_model_offer")
local LocalModelPolicy = require("llm.local_model_policy")
local Translation = require("modules.llm.translation")
local AgentSettings = require("modules.llm.agent_settings")
local AgentConnectors = require("modules.llm.agent_connectors")
local AgentLearning = require("modules.llm.agent_learning")
local NavigationSettings = require("modules.llm.navigation_settings")
local TimerScheduler = require("adapters.timer_scheduler")
local Inference = require("modules.llm.inference")
local Monotonic = require("infra.monotonic")
local i18n = require("infra.i18n")
local Base64 = require("compat.base64")
local Json = require("json")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "modules.llm.prediction_engine"

local _enabled = true
local _predicting = false
local _engine = nil
local _keyboard_hook = nil
local _overlay = nil
local _apply_prediction = nil
local _on_output = nil
local _on_offer = nil
local _offer_notified = false
local _suggestions = {}
local _suggestion_context = nil
local _pending_trigger = nil
local _scheduler = TimerScheduler
local _triggers = { "//", ";;", "--" }
local _max_tokens = nil
local _scope_owner = nil
local _enable_admission = nil
local _enable_generation = 0
local _runtime_app_epoch = 0
local _runtime_closed = false
local _runtime_owner, _runtime_request = nil, nil
local retire_runtime_request, stop_runtime_app
local _request_epoch = 0

-- Injected by init(): whether the daemon is paused, and how a manual request
-- tells the user it was refused (a desktop notification in the daemon).
local function NEVER_PAUSED() return false end
local _is_paused = NEVER_PAUSED
local _notify = nil

-- Injected by init() for the tone actions: how the selection is read, how it is
-- replaced (typed over, then selected back), and which window has the focus.
local _read_selection = nil
local _replace_selection = nil
local _focus_id = nil

-- The tone actions' state. The generation drops a stale answer: a newer tone
-- step, typing, a cancel or a pause make the one in flight obsolete. The memory
-- ties the rewrite left selected to its original text (llm/tone.lua).
local _tone_generation = 0
local _tone_memory = nil
local _tone_timer = nil

-- Injected by init() for the screen actions: how the screen is captured
-- (adapters/screen_capture.lua in the daemon).
local _capture_screen = nil

-- The screen actions' state. The generation drops a stale capture or reading:
-- a newer screen action, typing, Escape or a pause make it obsolete. The flow
-- holds the capture and the vision request in flight, until the answers are
-- requested; from then on they are an ordinary offer (_request_epoch).
local _vision_generation = 0
local _vision_flow = nil
-- Whether the session was already told that screenshots go out unscaled
local _vision_unscaled_logged = false

-- Live mode (llm_live_prompt_toggle and the AI menu's live submenu): nil when
-- off, else { profile_id, num_predictions } the automatic typing trigger runs
-- with instead of the menu's. Never persisted: off at every start.
local _live = nil
-- The decoded live.json, loaded on the first activation
local _live_config = nil
-- Injected by init(): told after every live transition, so the tray redraws
-- its live submenu's check marks.
local _on_live_change = nil

-- Injected by init() for the AI agent: the focused window's application and
-- title (the request's context), a native text dialog (llm_agent_command), the
-- clock and the system time zone.
local _focused_window = nil
local _ask_text = nil
local function SYSTEM_CLOCK() return os.time() end
local _now = SYSTEM_CLOCK
local _timezone = AgentSettings.timezone
-- The automatic mode's state. The pause timer runs after every keystroke; the
-- generation, bumped by every keystroke, drops a stale triage; the triage in
-- flight is withdrawn by the next keystroke. The sentences already triaged are
-- never triaged again (a ring of the last AGENT_TRIAGED_MEMORY).
local _agent_timer = nil
local _agent_generation = 0
local _model_consent_owner = nil
local _modal_resync_owner = nil
local _enable_modal_resync_owner = nil
local _agent_triage = nil
local _agent_triaged = {}
-- The application the user last typed in, for the menu's exclusion row
local _agent_last_app = nil
-- Arms the automatic mode's pause timer; defined in the agent section below,
-- declared here so on_char, above it, binds this local and not a nil global.
local arm_agent

-- The reasons a manual request is refused, each with the locale key of the
-- notice that tells the user. manual_refusal checks them in this order: a pause
-- outranks everything, then the AI switch, then the backend, then the typed
-- context. Windows and macOS declare the same four
-- (tools/test/test-manual-prediction-refusals-single-source.cjs).
local MANUAL_REFUSAL_KEYS = {
	paused            = "llm.manual_prediction.paused",
	disabled          = "llm.manual_prediction.disabled",
	backend_not_ready = "llm.manual_prediction.backend_not_ready",
	empty_context     = "llm.manual_prediction.empty_context",
}

-- The notice of a prompt action whose binding names a prompt that no longer
-- exists (a deleted custom prompt). Kept apart from MANUAL_REFUSAL_KEYS, which
-- the three drivers declare identically.
local UNKNOWN_PROMPT_KEY = "llm.prompt_prediction.unknown_prompt"

-- The screen actions, each with the capture mode it runs and the vision.json
-- list of answers it offers, in that order; and their notices
local VISION_ACTIONS = {
	llm_screen_region = { mode = "region", answers = "answers" },
	llm_screen_full   = { mode = "full", answers = "answers" },
	llm_screen_error  = { mode = "region", answers = "error_answers" },
}
local VISION_NO_MODEL_KEY = "llm.vision.no_model"
local VISION_READ_FAILED_KEY = "llm.vision.read_failed"
local VISION_CAPTURE_FAILED_KEY = "llm.vision.capture_failed"

-- The translation action and its notices
local TRANSLATE_ACTION = "llm_translate_selection"
local TRANSLATE_NO_SELECTION_KEY = "llm.translate.no_selection"
local TRANSLATE_FAILED_KEY = "llm.translate.failed"

-- The agent's actions, their notices, and the notice of each connector's success
local AGENT_SELECTION_ACTION = "llm_agent_selection"
local AGENT_COMMAND_ACTION = "llm_agent_command"
local AGENT_AUTO_ACTION = "llm_agent_auto_toggle"
local AGENT_KEYS = {
	off = "llm.agent.off_notice",
	no_system1 = "llm.agent.no_system1",
	no_system2 = "llm.agent.no_system2",
	no_selection = "llm.agent.no_selection",
	no_action = "llm.agent.no_action",
	failed = "llm.agent.failed",
	connector_failed = "llm.agent.connector_failed",
	auto_on = "llm.agent.auto_on",
	auto_off = "llm.agent.auto_off",
}
local AGENT_DONE_KEYS = {
	calendar = "llm.agent.done_calendar",
	reminder = "llm.agent.done_reminder",
	mail = "llm.agent.done_mail",
	shortcut = "llm.agent.done_shortcut",
}
-- How many triaged sentences the automatic mode remembers
local AGENT_TRIAGED_MEMORY = 32
-- What the request's context names a time zone the system does not give
local UNKNOWN_TIMEZONE = "unknown"

-- The live mode's action, its notices and its shipped timing
local LIVE_ACTION = "llm_live_prompt_toggle"
local LIVE_ON_KEY = "llm.live.on"
local LIVE_OFF_KEY = "llm.live.off"
local LIVE_CONFIG_FILE = "modules/llm/live.json"

-- The ready-made prompt actions: one per built-in profile, named after it
-- (tools/test/test-llm-prompt-actions-single-source.cjs pins the catalogue side).
local PRESET_ACTION_PREFIX = "llm_predict_"

-- The tone actions, one per direction and flavour: llm_tone_more_formal,
-- llm_tone_more_familiar and their _cycle variants, which wrap around at the
-- ends of the ladder instead of stopping with the direction's notice.
local TONE_ACTION_PREFIX = "llm_tone_"
local TONE_CYCLE_SUFFIX = "_cycle"
local TONE_DIRECTIONS = {
	{ name = "more_formal", direction = Tone.MORE_FORMAL, end_key = "llm.tone.most_formal" },
	{ name = "more_familiar", direction = Tone.MORE_FAMILIAR, end_key = "llm.tone.most_familiar" },
}

local function get_ollama()
	local ok, module = pcall(require, "modules.llm.api_ollama")
	return ok and module or nil
end

local function get_remote()
	local ok, module = pcall(require, "modules.llm.api_remote")
	return ok and module or nil
end

local function get_api_entries()
	local ok, module = pcall(require, "modules.llm.api_entries")
	return ok and module or nil
end

-- Which backend answers: "ollama" (local) or "api" (a remote provider). The
-- manifest declares the key and its default for every driver.
local BACKEND_KEY = "llm.models.selected"
local BACKENDS = { ollama = true, api = true }

-- The backend module serving the request in flight, so dismiss cancels it.
local _inflight_backend = nil
-- When each backend was last sent a request, and the timer holding one back
-- until its minimum interval has passed.
local _last_request_ms = {}
local _rate_timer = nil
local _clock_ms = Monotonic.now_ms

local function get_profiles()
	local ok, module = pcall(require, "modules.llm.profiles")
	return ok and module or nil
end

local function get_secure_field_detector()
	local ok, module = pcall(require, "adapters.secure_field_detector")
	return ok and module or nil
end

-- The stored setting is the only source: an in-memory override set at boot
-- once shadowed the menu's choice for the whole session.
local function max_context_chars()
	return Settings.get("context_length") or HttpBridge.DEFAULT_CONTEXT_LENGTH
end

local function _is_secure_context()
	local secure_enabled = TriggerSettings.get("secure_filter_enabled")
	local url_enabled = TriggerSettings.get("url_bar_filter_enabled")
	if secure_enabled == nil then secure_enabled = HttpBridge.DEFAULT_DISABLE_PASSWORD_FIELDS end
	if url_enabled == nil then url_enabled = HttpBridge.DEFAULT_DISABLE_URL_BARS end
	if not secure_enabled and not url_enabled then return false end

	local detector = get_secure_field_detector()
	if not detector then return secure_enabled == true or url_enabled == true end
	if secure_enabled then
		local ok, secure = pcall(detector.isSecureField)
		if not ok or secure then return true end
	end
	if url_enabled then
		local ok_app, app_id = pcall(function()
			local lifecycle = require("adapters.process_lifecycle")
			return lifecycle and lifecycle.getForegroundApp and lifecycle.getForegroundApp()
		end)
		if not ok_app or type(app_id) ~= "string" or app_id == "" then return true end
		local ok_url, is_url = pcall(detector.isUrlBar, app_id)
		if not ok_url or is_url then return true end
	end
	return false
end

local function hide_overlay()
	if _overlay and type(_overlay.hide) == "function" then _overlay.hide() end
end

local function clear_offer()
	hide_overlay()
	_suggestions = {}
	_suggestion_context = nil
	_offer_notified = false
end

local function show_candidates(candidates, meta)
	_suggestions = type(candidates) == "table" and candidates or {}
	if #_suggestions > 0 and not _offer_notified then
		_offer_notified = true
		if _on_offer then
			local ok, err = pcall(_on_offer, _suggestion_context)
			if not ok then Logger.warn(LOG, "Prediction offer observer failed: %s", tostring(err)) end
		end
	end
	if not _overlay or type(_overlay.show) ~= "function" then return #_suggestions > 0 end
	return _overlay.show(_suggestions, meta) == true
end

local function context_without_trigger(context, input_chars)
	local count = math.max(0, math.floor(tonumber(input_chars) or 0))
	if count == 0 or count > #context then return context, 0 end
	return context:sub(1, #context - count), count
end

local function append_unique(target, candidate, extra_deletes)
	if type(candidate) ~= "table" or type(candidate.to_type) ~= "string"
		or candidate.to_type == "" then return false end
	candidate.deletes = math.max(0, math.floor(tonumber(candidate.deletes) or 0))
		+ math.max(0, math.floor(tonumber(extra_deletes) or 0))
	for _, existing in ipairs(target) do
		if existing.deletes == candidate.deletes and existing.to_type == candidate.to_type then return false end
	end
	target[#target + 1] = candidate
	return true
end

local function is_boundary_char(ch)
	local boundaries = " \t\n\r.,;:!?" .. "\194\160" .. "\226\128\175"
	return type(ch) == "string" and ch ~= "" and boundaries:find(ch, 1, true) ~= nil
end

local function ends_word(buffer, ch)
	if not is_boundary_char(ch) then return false end
	local prefix = buffer:sub(1, #buffer - #ch)
	local previous = prefix:match("([%z\1-\127\194-\244][\128-\191]*)$")
	return previous ~= nil and not is_boundary_char(previous)
end

--- Parses live.json. Exposed for tests.
--- @param text string|nil The file's content.
--- @return table|nil config { debounce_ms, min_words }, string|nil reason
function M.parse_live_config(text)
	local ok, root = pcall(function() return type(text) == "string" and Json.decode(text) or nil end)
	if not ok or type(root) ~= "table" then return nil, "live.json is missing or not JSON" end
	for _, key in ipairs({ "debounce_ms", "min_words" }) do
		local value = root[key]
		if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
			return nil, "live.json " .. key .. " is not a non-negative integer"
		end
	end
	return { debounce_ms = root.debounce_ms, min_words = root.min_words }, nil
end

--- The shipped live.json. A missing or malformed file is an installation
--- fault: live mode refuses to start, and the reason is logged.
--- @return table|nil config
local function live_config()
	if _live_config then return _live_config end
	local path = require("infra.paths").shared(LIVE_CONFIG_FILE)
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	if fh then fh:close() end
	local config, reason = M.parse_live_config(text)
	if not config then
		Logger.error(LOG, "Live mode unavailable: %s.", tostring(reason))
		return nil
	end
	_live_config = config
	return _live_config
end

--- The request a live keystroke runs, resolved when its timer fires: the live
--- prompt by exact id, its count, and live.json's minimum word count. A prompt
--- deleted while live mode ran turns live mode off, never falls back.
--- @return table|nil override for predict(), nil when live mode is off.
--- Resolves a binding profile at dispatch without mutating menu settings.
--- @param prompt table Parsed binding receipt.
--- @return table|nil profile
local function binding_profile(prompt)
	if prompt.translation_target == nil then return ProfileSettings.resolve_id(prompt.profile_id) end
	local data = Translation.data()
	if not data then return nil end
	return Translate.prediction_profile(prompt.translation_target, data.config, data.names, require("infra.i18n").get_locale())
end

local function live_override()
	if not _live then return nil end
	-- Loaded when live mode started, which refuses without it: never nil here.
	local config = live_config()
	local profile = binding_profile(_live)
	if not profile then
		Logger.warn(LOG, "Live mode stopped: the prompt '%s' no longer exists.", _live.profile_id)
		M.stop_live("prompt deleted", false)
		return nil
	end
	return {
		profile = profile,
		num_predictions = _live.num_predictions,
		min_words = config.min_words,
		live = true,
	}
end

local function schedule(context, output_context, delay_ms, reason, live)
	if type(context) ~= "string" or context == "" then return false end
	if _pending_trigger then _scheduler.cancel(_pending_trigger) end
	local captured = {
		app_id = type(output_context) == "table" and output_context.app_id or nil,
		input_chars = type(output_context) == "table" and output_context.input_chars or 0,
		-- Typing asked for nothing (no trigger typed, no live prompt): the
		-- automatic agent may replace this offer.
		automatic = not live and not (type(output_context) == "table" and output_context.explicit == true),
	}
	local handle = _scheduler.after(math.max(0, tonumber(delay_ms) or 0) / 1000, function()
		if _runtime_closed or _scope_owner then return end
		_pending_trigger = nil
		if not live then
			M.predict(context, captured)
			return
		end
		-- A pause or the AI switch turn live mode off; checked again here, since
		-- the timer may have been armed just before.
		if _is_paused() or not _enabled then return end
		local override = live_override()
		if override then M.predict(context, captured, override) end
	end)
	if type(handle) ~= "table" or handle.armed ~= true then
		_pending_trigger = nil
		Logger.error(LOG, "%s prediction could not be scheduled: timer unavailable.", reason)
		return false
	end
	_pending_trigger = handle
	Logger.debug(LOG, "%s prediction scheduled in %d ms.", reason, math.max(0, tonumber(delay_ms) or 0))
	return true
end

local function advance_request_epoch(resync_owner)
	_request_epoch = _request_epoch + 1
	local owner = _model_consent_owner
	if not owner then return end
	if owner == resync_owner and owner == _modal_resync_owner and not owner.reset_claimed then
		owner.reset_claimed = true
		owner.epoch = _request_epoch
		owner.vision_generation = _vision_generation
		owner.agent_generation = _agent_generation
		owner.tone_generation = _tone_generation
	else
		_model_consent_owner = nil
	end
end

--- Initialises the engine and its explicit side-effect seams.
--- @param opts table|nil
function M.init(opts)
	if _runtime_closed or _scope_owner then return false end
	if stop_runtime_app and not stop_runtime_app() then return false end
	if _runtime_closed or _scope_owner then return false end
	_runtime_owner = nil
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	if _runtime_closed or _scope_owner then return false end
	_enable_generation = _enable_generation + 1
	local options = type(opts) == "table" and opts or {}
	_engine = options.engine
	_keyboard_hook = options.keyboard_hook
	_overlay = type(options.overlay) == "table" and options.overlay or nil
	_apply_prediction = type(options.apply_prediction) == "function" and options.apply_prediction or nil
	_on_output = type(options.on_output) == "function" and options.on_output or nil
	_on_offer = type(options.on_offer) == "function" and options.on_offer or nil
	_is_paused = type(options.is_paused) == "function" and options.is_paused or NEVER_PAUSED
	_notify = type(options.notify) == "function" and options.notify or nil
	_read_selection = type(options.read_selection) == "function" and options.read_selection or nil
	_replace_selection = type(options.replace_selection) == "function" and options.replace_selection or nil
	_focus_id = type(options.focus_id) == "function" and options.focus_id or nil
	_capture_screen = type(options.capture_screen) == "function" and options.capture_screen or nil
	_on_live_change = type(options.on_live_change) == "function" and options.on_live_change or nil
	_focused_window = type(options.focused_window) == "function" and options.focused_window or nil
	_ask_text = type(options.ask_text) == "function" and options.ask_text or nil
	_now = type(options.now) == "function" and options.now or SYSTEM_CLOCK
	_timezone = type(options.timezone) == "function" and options.timezone or AgentSettings.timezone
	-- Live mode is a session state: every start begins with it off.
	_live = nil
	M.drop_vision("engine initialised")
	if _tone_timer then _scheduler.cancel(_tone_timer) end
	_tone_timer = nil
	_tone_generation = _tone_generation + 1
	_tone_memory = nil
	_offer_notified = false
	if type(options.triggers) == "table" then _triggers = options.triggers end
	if _pending_trigger then _scheduler.cancel(_pending_trigger) end
	M.drop_agent_triage("engine initialised")
	_agent_triaged = {}
	_agent_last_app = nil
	_scheduler = type(options.scheduler) == "table" and options.scheduler or TimerScheduler
	-- The pacing clock must be the scheduler's: a test's virtual timers would
	-- otherwise be measured against real time.
	_clock_ms = type(options.clock_ms) == "function" and options.clock_ms or Monotonic.now_ms
	_last_request_ms = {}
	_pending_trigger = nil
	advance_request_epoch()
	_predicting = false
	clear_offer()

	local profiles = get_profiles()
	if profiles then
		profiles.init({ port = HttpBridge.OLLAMA_DEFAULT_PORT })
		if _runtime_closed or _scope_owner then return false end
		if type(profiles.is_enabled) == "function" then
			local enabled = profiles.is_enabled()
			if _runtime_closed or _scope_owner then return false end
			_enabled = enabled
		end
	end
	Logger.success(LOG, "Prediction engine initialised (triggers=%d, max_context=%d).",
		#_triggers, max_context_chars())
end

--- Processes one physical character after the hotstring buffer recorded it.
function M.on_char(ch, buffer, output_context)
	if _runtime_closed or _scope_owner then return false end
	if type(ch) ~= "string" or type(buffer) ~= "string" then return end
	-- A keystroke withdraws the agent's triage in flight and restarts its pause.
	-- The agent does not depend on the AI menu's switch: it runs with it off.
	M.drop_agent_triage("typing")
	if not _enabled then
		-- Typing over an agent's offer dismisses it.
		if _predicting or #_suggestions > 0 then M.dismiss() end
		arm_agent(buffer, output_context)
		return
	end
	-- Typing replaced the selection a tone step was about to rewrite.
	M.drop_tone("typing")
	-- The user went on typing: the screen answers would be dismissed at once.
	M.drop_vision("typing")
	if _predicting or #_suggestions > 0 then M.dismiss() end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	arm_agent(buffer, output_context)
	for _, trigger in ipairs(_triggers) do
		if buffer:sub(-#trigger) == trigger then
			local delay_ms = TriggerSettings.get("debounce_ms")
			schedule(buffer, {
				app_id = type(output_context) == "table" and output_context.app_id or nil,
				input_chars = #trigger,
				explicit = true,
			}, delay_ms, "Explicit-trigger")
			return
		end
	end
	-- While a hotstring preview is on screen, the AI tooltip waits for it to go:
	-- always in live mode, whose tooltip would otherwise cover it at every
	-- keystroke; with the "after a hotstring" setting otherwise.
	if type(output_context) == "table" and output_context.hotstring_preview_visible == true
		and (_live or TriggerSettings.get("after_hotstring") == true) then return end
	if _live then
		-- The live prompt, count and debounce replace the menu's; a new keystroke
		-- has already withdrawn the request in flight above.
		local config = live_config()
		if config then schedule(buffer, output_context, config.debounce_ms, "Live", true) end
		return
	end
	local immediate = TriggerSettings.get("instant_on_word_end") == true and ends_word(buffer, ch)
	schedule(buffer, output_context, immediate and 0 or TriggerSettings.get("debounce_ms"),
		immediate and "Word-end" or "Inactivity")
end

--- Fires immediately after the current hotstring preview expires.
--- @param context string
--- @param output_context table|nil
--- @return boolean
function M.on_hotstring_expired(context, output_context)
	if _runtime_closed or _scope_owner then return false end
	-- The automatic agent held its pause back while the preview was shown
	-- (on_char), with the AI menu's switch on or off.
	arm_agent(context, output_context)
	if not _enabled then return false end
	-- Live mode held its request back while the preview was shown (on_char).
	if not _live and TriggerSettings.get("after_hotstring") ~= true then return false end
	if _predicting or #_suggestions > 0 then M.dismiss() end
	if _live then return schedule(context, output_context, 0, "Live hotstring-expiry", true) end
	return schedule(context, output_context, 0, "Hotstring-expiry")
end

-- What {max_words} reads when the user chose no maximum (0). The built-in
-- prompts are English, and Windows writes the same word; a literal 0 asked the
-- model for "between 3 and 0 words".
local UNLIMITED_WORDS = "unlimited"

--- The locale the model falls back to when the text's language is ambiguous:
--- the interface's, as on macOS, not always French.
--- @return string
local function prompt_language()
	local ok, I18n = pcall(require, "infra.i18n")
	local locale = ok and type(I18n.get_locale) == "function" and I18n.get_locale() or nil
	if type(locale) == "string" and locale ~= "" then return locale end
	return require("infra.manifest_reader").default_for("script.locale")
end

--- The profile's name as the menu shows it, for the suggestions' info bar:
--- a user profile's own label, a built-in's translated name. The bar showed
--- the internal id, so a custom prompt read "user_1727…_3".
--- @param profile table
--- @return string
local function profile_display_name(profile)
	-- User profile ids are "user_…" by construction (profile_settings).
	if (profile.id == "translate" or tostring(profile.id):match("^user_")) and type(profile.label) == "string" and profile.label ~= "" then
		return profile.label
	end
	local ok, I18n = pcall(require, "infra.i18n")
	local key = "llm.profile." .. tostring(profile.id) .. ".label"
	local label = ok and type(I18n.get) == "function" and I18n.get(key) or nil
	if type(label) ~= "string" or label == "" or label == key then return tostring(profile.id) end
	-- The menu's long form is "●○○ Basic — Simple prediction"; the bar keeps
	-- the name.
	return (label:gsub("%s+—.*$", ""))
end

local function resolve_system_prompt(profile, params, count)
	-- The context is left empty here and sent once, by build_messages.
	local max_words = tonumber(params.max_words) or 0
	local resolved = ProfileSelector.resolve_system_prompt(profile, {
		context = "",
		tail = "",
		min_words = params.min_words,
		max_words = max_words > 0 and max_words or UNLIMITED_WORDS,
		n = count,
		language = params.language,
	})
	return resolved and resolved.system or nil
end

--- Starts a prediction from the given context buffer.
---
--- A rewrite profile (llm/rewrite.lua) asks for the current sentence rewritten,
--- whatever triggered the request: its tail is that sentence, the context is
--- widened to hold all of it when the menu's cap would cut it, and its token
--- budget grows with it. The parser then erases exactly that span.
--- @param context string
--- @param output_context table|nil
--- @param override table|nil { profile, num_predictions?, min_words?, live? } for
---   a request that names its own prompt: that profile and count (and live
---   mode's minimum word count), instead of the menu's profile (and its
---   automatic choice), count and minimum, which stay unchanged. `live` marks
---   the offer as live mode's, the one Tab accepts.
--- @return string|nil refusal A MANUAL_REFUSAL_KEYS reason the user should be
---   told, when the request was refused for one.
function M.predict(context, output_context, override)
	if _runtime_closed or _scope_owner then return false end
	if _predicting or type(context) ~= "string" or context == "" then return end
	if _is_secure_context() then
		Logger.debug(LOG, "Prediction suppressed: secure field or excluded context.")
		return
	end

	local backend, target, model = M.resolve_backend()
	if not backend then return end

	local clean_context, trigger_chars = context_without_trigger(context,
		type(output_context) == "table" and output_context.input_chars or 0)
	local requested = override and override.num_predictions or ProfileSettings.get("num_predictions") or 1
	local profile = override and override.profile or ProfileSettings.resolve(model)
	if not profile then Logger.error(LOG, "Prediction profile catalogue is unavailable."); return end
	local params = PromptBuilder.build_params(clean_context, {
		max_words = Settings.get("max_words"),
		min_words = override and override.min_words or Settings.get("min_words"),
		num_predictions = requested,
		temperature = Settings.get("temperature"),
		auto_raise_temp = Settings.get("auto_raise_temp"),
		language = prompt_language(),
		context_window_chars = max_context_chars(),
	})
	local rewrite = Rewrite.is_rewrite_profile(profile)
	if rewrite then
		local sentence = Rewrite.sentence_span(clean_context)
		if sentence == "" then
			Logger.debug(LOG, "Rewrite suppressed: no sentence is being typed.")
			return "empty_context"
		end
		-- Both are suffixes of the typed text, so the longer one holds the other.
		if #sentence > #params.context then params.context = sentence end
		params.context_tail = Rewrite.sentence_span(params.context)
		params.max_tokens = Rewrite.max_tokens(params.context_tail)
	end
	local is_batch = profile.batch == true and requested > 1
	local base_temperature = Settings.get("temperature")
	local auto_raise = Settings.get("auto_raise_temp") == true
	local system_prompt = resolve_system_prompt(profile, params, is_batch and requested or 1)
	-- Empty is valid: the raw profile is its context alone, sent as the user turn.
	if type(system_prompt) ~= "string" then
		Logger.error(LOG, "Prediction profile '%s' has no usable system prompt.", tostring(profile.id))
		return
	end

	local messages = PromptBuilder.build_messages(system_prompt, params.context, params.context_tail)
	local candidates = {}
	local request_index = 0
	local meta = {
		model = model,
		profile = profile_display_name(profile),
		loading = true,
		validation_modifiers = NavigationSettings.get(),
	}
	_suggestion_context = {
		app_id = type(output_context) == "table" and output_context.app_id or nil,
		input_chars = trigger_chars,
		model = model,
		profile = profile.id,
		live = override ~= nil and override.live == true,
		automatic = type(output_context) == "table" and output_context.automatic == true,
	}
	_offer_notified = false
	_predicting = true
	advance_request_epoch()
	local epoch = _request_epoch
	show_candidates({}, meta)
	Logger.info(LOG, "Sending %sprediction request (backend=%s, model=%s, profile=%s, count=%d, context=%d chars).",
		_suggestion_context.live and "live " or "", M.get_backend(), model, tostring(profile.id), requested,
		#params.context)

	local function parse_response(raw, batch, extra_deletes)
		local parsed = {}
		for _, block in ipairs(batch and Parser.split_blocks(raw) or { raw }) do
			local candidate = Parser.process_prediction(params.context, params.context_tail, block, {
				min_words = params.min_words,
				max_words = params.max_words,
			})
			append_unique(parsed, candidate, extra_deletes)
		end
		return parsed
	end

	local function publish(partial)
		local visible = {}
		for index, candidate in ipairs(candidates) do visible[index] = candidate end
		if partial then append_unique(visible, partial, 0) end
		meta.loading = _predicting
		if #visible > 0 or meta.loading then show_candidates(visible, meta) end
	end

	local dispatch
	dispatch = function()
		if _runtime_closed or _scope_owner or epoch ~= _request_epoch then return end
		local kind = M.get_backend()
		local now = _clock_ms()
		local wait_ms = (_last_request_ms[kind] or -math.huge) + Inference.min_interval_ms(kind) - now
		if wait_ms > 0 then
			_rate_timer = _scheduler.after(wait_ms / 1000, function()
				if _runtime_closed or _scope_owner then return end
				_rate_timer = nil
				dispatch()
			end)
			if type(_rate_timer) ~= "table" or _rate_timer.armed ~= true then
				_rate_timer = nil
				_predicting = false
				meta.loading = false
				Logger.error(LOG, "Prediction could not be paced: timer unavailable.")
				-- The variants already received stay on offer.
				if #candidates > 0 then publish() else clear_offer() end
			end
			return
		end
		_last_request_ms[kind] = now
		request_index = request_index + 1
		local think_filter = Parser.new_thinking_filter()
		local streamed = ""
		-- The backend serves one request at a time: sending would silently
		-- cancel the agent's request on it, so that one is withdrawn first.
		if _agent_triage and _agent_triage.chat.module == backend then
			M.drop_agent_triage("a prediction needs the backend")
		end
		_inflight_backend = backend
		backend.chat(target, model, messages, {
			stream = DisplaySettings.get("streaming") == true,
			-- A batch asks once, at the builder's temperature. Sequential variants
			-- each start from the user's own temperature and, when "raise the
			-- temperature" is on, get a little warmer so they differ. Warming the
			-- builder's already-raised value heated them twice, and warming with
			-- the switch off made the switch do nothing.
			temperature = is_batch and params.temperature
				or (auto_raise and Inference.variant_temperature(base_temperature, request_index))
				or base_temperature,
			-- A rewrite's budget follows its sentence; the continuation override
			-- would truncate it and erase text it could not retype.
			max_tokens = (rewrite and params.max_tokens or _max_tokens or params.max_tokens)
				* (is_batch and requested or 1),
			-- Decided from the prompt, as macOS does: one continuation, unless the
			-- prompt asks for the two-line correction format or a batch. By id, a
			-- user's copy of "basic" never got the single-line stops.
			line_mode = not is_batch and not system_prompt:find("TAIL_CORRECTED", 1, true),
		}, function(delta)
			if _runtime_closed or _scope_owner or epoch ~= _request_epoch then return end
			streamed = streamed .. think_filter:feed(delta)
			if DisplaySettings.get("streaming") ~= true then return end
			if requested > 1 and DisplaySettings.get("streaming_multi") ~= true then return end
			local partials = parse_response(streamed, is_batch, trigger_chars)
			publish(partials[#partials])
		end, function(full_text, err)
			if _runtime_closed or _scope_owner or epoch ~= _request_epoch then return end
			if err then
				_predicting = false
				meta.loading = false
				if err ~= "cancelled" then Logger.warn(LOG, "Prediction failed: %s", err) end
				if #candidates > 0 then publish() else clear_offer() end
				return
			end
			local clean = Parser.strip_thinking(full_text)
			for _, candidate in ipairs(parse_response(clean, is_batch, trigger_chars)) do
				append_unique(candidates, candidate, 0)
			end
			Logger.info(LOG, "Prediction request complete: %d chars, %d candidates.", #clean, #candidates)
			if not is_batch and request_index < requested then
				-- Shown now: the next variant may wait for the backend's interval.
				if #candidates > 0 and DisplaySettings.get("streaming_multi") == true then publish() end
				dispatch()
				return
			end
			_predicting = false
			meta.loading = false
			if #candidates > 0 then publish() else clear_offer() end
		end)
	end
	dispatch()
end

--- Decides why a manual prediction request cannot run, if it cannot.
--- @return string|nil reason A key of MANUAL_REFUSAL_KEYS, or nil when ready.
--- @return string context The typing buffer the prediction would complete.
local function manual_refusal()
	if _is_paused() then return "paused", "" end
	if not _enabled then return "disabled", "" end
	if not M.get_prediction_model() then
		return "backend_not_ready", ""
	end
	local buffer = _engine and type(_engine.current_buffer) == "function" and _engine:current_buffer() or ""
	if type(buffer) ~= "string" or buffer == "" then return "empty_context", "" end
	return nil, buffer
end

--- Shows the user a notice about a request that did not run.
--- @param key string Locale key of the notice.
--- @param reason string What the log names the refusal.
local function show_notice(key, reason)
	if not _notify then
		Logger.error(LOG, "No notice surface injected — the '%s' refusal is only logged.", reason)
	elseif _notify(i18n.get(key)) ~= true then
		Logger.warn(LOG, "The '%s' refusal notice was not shown.", reason)
	end
end

--- Runs a prediction now from the whole typing buffer, with the menu's prompt
--- or with the one a binding names. A chord pressed on purpose, so every
--- refusal is logged at INFO and shown as a notification, as the other two
--- drivers do.
--- @param output_context table|nil { app_id } for the metrics.
--- @param prompt table|nil prompt_action.parse() output, nil for the menu's prompt.
--- @return boolean requested True when predict() was started.
local function run_manual(output_context, prompt)
	if _runtime_closed or _scope_owner then return false end
	local reason, context = manual_refusal()
	if reason then
		Logger.info(LOG, "Manual prediction refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	local override = nil
	if prompt then
		-- By exact id: a deleted prompt is refused, never replaced by another.
		local profile = binding_profile(prompt)
		if not profile then
			Logger.warn(LOG, "Prompt prediction refused: the prompt '%s' no longer exists.", prompt.profile_id)
			show_notice(UNKNOWN_PROMPT_KEY, "unknown_prompt")
			return false
		end
		override = { profile = profile, num_predictions = prompt.num_predictions }
	end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting or #_suggestions > 0 then M.dismiss() end
	Logger.info(LOG, "Manual prediction requested (%d context byte(s), prompt %s).", #context,
		override and override.profile.id or "from the menu")
	local refusal = M.predict(context, output_context, override)
	if type(refusal) == "string" then
		Logger.info(LOG, "Manual prediction refused (%s).", refusal)
		show_notice(MANUAL_REFUSAL_KEYS[refusal], refusal)
		return false
	end
	return true
end

--- Runs a prediction now from the whole typing buffer: the llm_generate_prediction
--- action. Automatic triggers wait for typing; this one is a chord pressed on
--- purpose.
--- @param output_context table|nil { app_id } for the metrics; nil lets the
---   daemon's observers fall back to the focused application.
--- @return boolean requested True when predict() was started.
function M.trigger_now(output_context)
	return run_manual(output_context, nil)
end

--- Runs a prediction now with the prompt a binding names: the
--- llm_prompt_prediction action and its ready-made llm_predict_<id> presets.
--- The profile and count apply to this request only; the menu's stay as they are.
--- @param value string The binding's parameter, "<profile_id>" or "<profile_id>|<count>".
--- @param output_context table|nil { app_id } for the metrics.
--- @return boolean requested True when predict() was started.
function M.trigger_prompt(value, output_context)
	if _runtime_closed or _scope_owner then return false end
	local prompt, err = PromptAction.parse(value)
	if not prompt then
		Logger.warn(LOG, "Prompt prediction refused: invalid parameter '%s' (%s).", tostring(value), err)
		return false
	end
	return run_manual(output_context, prompt)
end

--- Shows the user a notice about a live mode transition.
--- @param text string The translated notice.
--- @param what string What the log names the notice.
local function announce(text, what)
	if not _notify then
		Logger.error(LOG, "No notice surface injected — the '%s' notice is only logged.", what)
	elseif _notify(text) ~= true then
		Logger.warn(LOG, "The '%s' notice was not shown.", what)
	end
end

--- Tells the tray that live mode changed, so its submenu redraws.
local function live_changed()
	if not _on_live_change then return end
	local ok, err = pcall(_on_live_change, M.get_live())
	if not ok then Logger.warn(LOG, "Live mode observer failed: %s", tostring(err)) end
end

--- Live mode's state, for the menu and the tests.
--- @return table|nil { profile_id, num_predictions? } nil when off; a nil
---   count means the menu's, read at every request.
function M.get_live()
	if not _live then return nil end
	return { profile_id = _live.profile_id, num_predictions = _live.num_predictions,
		translation_target = _live.translation_target }
end

--- Turns live mode off, withdrawing its request and its offer. The menu's
--- prediction takes over again at the next keystroke, unchanged.
--- @param reason string What the log names the cause.
--- @param notice boolean Tell the user (an explicit toggle); a pause or the AI
---   switch turn it off silently.
--- @return boolean stopped False when live mode was already off.
function M.stop_live(reason, notice)
	if not _live then return false end
	local profile_id = _live.profile_id
	_live = nil
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _suggestion_context and _suggestion_context.live then M.dismiss() end
	Logger.info(LOG, "Live mode off (%s; prompt %s).", tostring(reason), profile_id)
	if notice then announce(i18n.get(LIVE_OFF_KEY), "live off") end
	live_changed()
	return true
end

--- Turns live mode on with a prompt, refused like a manual prediction.
--- @param prompt table { profile_id, num_predictions? } prompt_action.parse() output.
--- @param source string What the log names the origin.
--- @return boolean started
local function start_live(prompt, source)
	if _runtime_closed or _scope_owner then return false end
	-- Live mode needs no text yet: it waits for typing.
	local reason = manual_refusal()
	if reason == "empty_context" then reason = nil end
	if reason then
		Logger.info(LOG, "Live mode refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	-- By exact id: a deleted prompt is refused, never replaced by another.
	local profile = binding_profile(prompt)
	if not profile then
		Logger.warn(LOG, "Live mode refused: the prompt '%s' no longer exists.", prompt.profile_id)
		show_notice(UNKNOWN_PROMPT_KEY, "unknown_prompt")
		return false
	end
	if not live_config() then return false end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting or #_suggestions > 0 then M.dismiss() end
	_live = { profile_id = profile.id, num_predictions = prompt.num_predictions,
		translation_target = prompt.translation_target }
	Logger.info(LOG, "Live mode on from %s (prompt %s, count %s).", source, profile.id,
		prompt.num_predictions and tostring(prompt.num_predictions) or "from the menu")
	local count = prompt.num_predictions or ProfileSettings.get("num_predictions") or 1
	local template = i18n.get(LIVE_ON_KEY)
	local at = template:find("{1}", 1, true)
	local label = ProfileSettings.menu_label(profile, count)
	announce(at and (template:sub(1, at - 1) .. label .. template:sub(at + 3)) or template, "live on")
	live_changed()
	return true
end

--- The llm_live_prompt_toggle action: turns live mode on with the binding's
--- prompt and count, or off when it is on, whatever the binding's parameter.
--- @param value string The binding's parameter, "<profile_id>" or "<profile_id>|<count>".
--- @return boolean changed True when live mode was turned on or off.
function M.toggle_live(value)
	if _runtime_closed or _scope_owner then return false end
	if _live then return M.stop_live("toggled off", true) end
	local prompt, err = PromptAction.parse(value)
	if not prompt then
		Logger.warn(LOG, "Live mode refused: invalid parameter '%s' (%s).", tostring(value), err)
		return false
	end
	return start_live(prompt, "a binding")
end

--- The AI menu's live submenu: a prompt id turns live mode on with it and the
--- menu's count, nil turns it off.
--- @param profile_id string|nil
--- @return boolean applied
function M.set_live(profile_id)
	if _runtime_closed or _scope_owner then return false end
	if profile_id == nil then
		if not _live then return true end
		return M.stop_live("menu", true)
	end
	if _live and _live.profile_id == profile_id and _live.num_predictions == nil then return true end
	return start_live({ profile_id = profile_id }, "the menu")
end

--- Told by the daemon after every pause transition: a pause turns live mode off.
--- @param paused boolean
function M.on_pause_change(paused)
	local retired = not paused or stop_runtime_app()
	_enable_generation = _enable_generation + 1
	if _enable_admission then _enable_admission.cancel() end
	if paused then M.stop_live("Ergopti+ paused", false) end
	return retired
end

--- The catalogue actions this engine answers, for the gesture executor's
--- daemon-injected handlers (modules/shortcuts/action_handlers.lua). The
--- presets follow the built-in profiles, so a new profile needs no code here.
--- @return table { [action_id] = function(binding, parameter) }
function M.action_handlers()
	local handlers = {
		llm_generate_prediction = function() return M.trigger_now() end,
		llm_prompt_prediction = function(_, parameter) return M.trigger_prompt(parameter) end,
		llm_translate_context = function(_, parameter)
			if not Translation.is_valid(parameter) then return false end
			return M.trigger_prompt(PromptAction.format("translate", 1, parameter))
		end,
		[LIVE_ACTION] = function(_, parameter) return M.toggle_live(parameter) end,
	}
	for _, profile in ipairs(ProfileSettings.list_built_in()) do
		local value = PromptAction.format(profile.id)
		handlers[PRESET_ACTION_PREFIX .. profile.id] = function() return M.trigger_prompt(value) end
	end
	for action in pairs(VISION_ACTIONS) do
		handlers[action] = function(_, parameter) return M.read_screen(action, parameter) end
	end
	handlers[TRANSLATE_ACTION] = function(_, parameter) return M.translate_selection(parameter) end
	handlers[AGENT_SELECTION_ACTION] = function() return M.agent_selection() end
	handlers[AGENT_COMMAND_ACTION] = function() return M.agent_command() end
	handlers[AGENT_AUTO_ACTION] = function() return M.toggle_agent_auto() end
	for _, step in ipairs(TONE_DIRECTIONS) do
		for _, cycle in ipairs({ false, true }) do
			handlers[TONE_ACTION_PREFIX .. step.name .. (cycle and TONE_CYCLE_SUFFIX or "")] = function()
				return M.shift_tone(step.direction, cycle)
			end
		end
	end
	return handlers
end

--- Drops the tone step in flight, if any: its answer will be ignored. For an
--- event after which the selection it would replace may be gone (typing, a
--- click, Backspace, Escape). Called on every keystroke, so it logs only when a
--- step was actually waiting for its pacing timer.
--- @param reason string What the log names the cause.
function M.drop_tone(reason)
	if _tone_timer then
		_scheduler.cancel(_tone_timer)
		_tone_timer = nil
		Logger.debug(LOG, "Paced tone step dropped (%s).", tostring(reason))
	end
	_tone_generation = _tone_generation + 1
end

--- The focused window's identity, "" when unknown.
--- @return string
local function current_focus()
	if not _focus_id then return "" end
	local ok, id = pcall(_focus_id)
	return (ok and type(id) == "string") and id or ""
end

--- Replaces the selection with a tone step's rewrite, when that is still safe.
--- @param generation integer The step's generation.
--- @param plan table The tone.plan() result.
--- @param focus string The focused window's identity when the step was sent.
--- @param full_text string|nil The model's answer.
--- @param err string|nil The backend's error.
local function finish_tone(generation, plan, focus, full_text, err)
	if _runtime_closed or _scope_owner then return end
	if generation ~= _tone_generation then
		Logger.debug(LOG, "Tone answer ignored: a newer step or an edit superseded it.")
		return
	end
	-- The step is settled: a late second callback finds no current generation.
	_tone_generation = _tone_generation + 1
	if _is_paused() or not _enabled then
		Logger.info(LOG, "Tone answer dropped: the AI was paused or switched off while it ran.")
		return
	end
	if err then
		if err ~= "cancelled" then Logger.warn(LOG, "Tone rewrite failed: %s", tostring(err)) end
		return
	end
	local text = Tone.extract(Parser.strip_thinking(full_text or ""))
	if not text then
		Logger.warn(LOG, "Tone rewrite dropped: the answer holds no REWRITE line (%d chars).", #(full_text or ""))
		return
	end
	-- Compared, not trusted: typing into another window would put the rewrite
	-- where the user never selected anything. An identity the desktop cannot
	-- tell (GNOME and KDE under Wayland) reads "" on both ends; typing, clicks
	-- and Escape still drop the step there.
	-- The identities hold window titles, which are private: never logged.
	if current_focus() ~= focus then
		Logger.info(LOG, "Tone rewrite dropped: another window took the focus while it ran.")
		return
	end
	local ok, replaced = pcall(_replace_selection, text)
	if not ok or replaced ~= true then
		Logger.error(LOG, "Tone rewrite could not replace the selection: %s",
			ok and "injection refused" or tostring(replaced))
		return
	end
	_tone_memory = Tone.remember(plan, text)
	Logger.info(LOG, "Selection rewritten to %s (%d byte(s)).", plan.profile_id, #text)
	if _on_output then
		-- No context: the daemon attributes the output to the focused application.
		local observed, observe_err = pcall(_on_output, text, nil)
		if not observed then Logger.warn(LOG, "Tone output observer failed: %s", tostring(observe_err)) end
	end
end

--- Rewrites the selection one register along the tone ladder and replaces it,
--- leaving the rewrite selected: the llm_tone_more_formal / _familiar actions
--- and their _cycle variants. One request, never shown as a suggestion. A new
--- step while one is waiting supersedes it.
--- @param direction number Tone.MORE_FORMAL or Tone.MORE_FAMILIAR.
--- @param cycle boolean Wrap around at the ends of the ladder.
--- @return boolean requested True when the rewrite request was started.
function M.shift_tone(direction, cycle)
	if _runtime_closed or _scope_owner then return false end
	local step = nil
	for _, candidate in ipairs(TONE_DIRECTIONS) do
		if candidate.direction == direction then step = candidate end
	end
	if not step then error("shift_tone: direction must be Tone.MORE_FORMAL or Tone.MORE_FAMILIAR") end
	if not _read_selection or not _replace_selection then
		Logger.error(LOG, "Tone step refused: no selection surface was injected.")
		return false
	end
	-- Checked before the selection is read: a refused step sends no copy chord.
	-- The selection is the text, so an empty typing buffer refuses nothing; it
	-- is checked last, after every reason that does.
	local reason = manual_refusal()
	if reason == "empty_context" then reason = nil end
	if reason then
		Logger.info(LOG, "Tone step refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	if _is_secure_context() then
		Logger.debug(LOG, "Tone step suppressed: secure field or excluded context.")
		return false
	end
	M.drop_tone("superseded")
	local read_ok, selection, read_err = _read_selection()
	if not read_ok then
		if read_err == "no_selection" then
			Logger.info(LOG, "Tone step ignored: nothing is selected.")
		else
			Logger.warn(LOG, "Tone step ignored: the selection could not be read (%s).", tostring(read_err))
		end
		return false
	end
	local plan, why = Tone.plan(selection, _tone_memory, direction, cycle == true)
	if not plan then
		if why == "end_of_ladder" then
			Logger.info(LOG, "Tone step refused: already at the end of the ladder.")
			show_notice(step.end_key, why)
		else
			Logger.info(LOG, "Tone step ignored: the selection is blank.")
		end
		return false
	end
	-- By exact id, like a prompt action: a missing ladder profile is a broken
	-- catalogue, never replaced by another prompt.
	local profile = ProfileSettings.resolve_id(plan.profile_id)
	if not profile then
		Logger.error(LOG, "Tone step refused: the built-in prompt '%s' is missing.", plan.profile_id)
		return false
	end
	local backend, target, model = M.resolve_backend()
	if not backend then return false end
	local system_prompt = resolve_system_prompt(profile, {
		min_words = Settings.get("min_words"),
		max_words = Settings.get("max_words"),
		language = prompt_language(),
	}, 1)
	if type(system_prompt) ~= "string" or system_prompt == "" then
		Logger.error(LOG, "Tone prompt '%s' has no usable system prompt.", plan.profile_id)
		return false
	end
	-- The backends serve one request at a time: a prediction in flight or on
	-- offer is withdrawn, or its callback would never come and block the next.
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting or #_suggestions > 0 then M.dismiss() end

	local messages = PromptBuilder.build_messages(system_prompt, plan.source, plan.source)
	local generation = _tone_generation
	local focus = current_focus()
	local request_opts = {
		stream = false,
		verify_local_model = verify_local_model == true,
		temperature = Settings.get("temperature"),
		max_tokens = Rewrite.max_tokens(plan.source),
		line_mode = true,
	}
	Logger.info(LOG, "Sending tone rewrite (backend=%s, model=%s, profile=%s, %d byte(s)).",
		M.get_backend(), model, plan.profile_id, #plan.source)

	local send
	send = function()
		if _runtime_closed or _scope_owner or generation ~= _tone_generation then return end
		local kind = M.get_backend()
		local now = _clock_ms()
		local wait_ms = (_last_request_ms[kind] or -math.huge) + Inference.min_interval_ms(kind) - now
		if wait_ms > 0 then
			_tone_timer = _scheduler.after(wait_ms / 1000, function()
				_tone_timer = nil
				send()
			end)
			if type(_tone_timer) ~= "table" or _tone_timer.armed ~= true then
				_tone_timer = nil
				Logger.error(LOG, "Tone rewrite could not be paced: timer unavailable.")
			end
			return
		end
		_last_request_ms[kind] = now
		-- Not the prediction's _inflight_backend: a dropped step is left to finish
		-- and ignored, and the next request on that backend cancels it anyway.
		backend.chat(target, model, messages, request_opts, nil, function(full_text, err)
			finish_tone(generation, plan, focus, full_text, err)
		end)
	end
	send()
	return true
end

--- Deletes a capture's image and its private directory. A file that is still
--- there afterwards is an error: the screenshot may show private messages.
--- @param capture table { path, dir }
local function discard_capture(capture)
	for _, path in ipairs({ capture.path, capture.dir }) do
		local removed, err = os.remove(path)
		if not removed then
			local left = io.open(path, "rb")
			if left then
				left:close()
				Logger.error(LOG, "A screenshot file could not be deleted: %s", tostring(err))
			end
		end
	end
end

--- Drops the screen action in flight, if any: its capture is stopped and
--- deleted and its vision request withdrawn. Answers already requested belong
--- to the offer and go with dismiss(). Called on every keystroke, so it logs
--- only when a screen action was actually running.
--- @param reason string What the log names the cause.
function M.drop_vision(reason)
	_vision_generation = _vision_generation + 1
	local flow = _vision_flow
	if not flow then return end
	_vision_flow = nil
	if flow.capture then
		local stopped, err = pcall(flow.capture.cancel)
		if not stopped then Logger.error(LOG, "The screen capture could not be stopped: %s", tostring(err)) end
		discard_capture(flow.capture)
	end
	if flow.reading and VisionRequest.cancel() ~= true then
		Logger.error(LOG, "The vision request could not be withdrawn.")
	end
	if flow.shown then clear_offer() end
	Logger.info(LOG, "Screen reading dropped (%s).", tostring(reason))
end

--- Whether a screen flow is still the current one.
--- @param flow table
--- @return boolean
local function vision_current(flow)
	return _vision_flow == flow and flow.generation == _vision_generation
end

--- Opens an offer that one-off requests on the AI menu's text backend fill
--- (the screen answers, the translation): the tooltip says something is coming,
--- and a newer action, typing, Escape or a dismiss supersede it through
--- _request_epoch. The backends serve one request at a time, so a prediction
--- pending, in flight or on offer is withdrawn first.
--- @param action string The catalogue action, for the metrics.
--- @param label string The tooltip's info bar.
--- @param model string The text model.
--- @param focus string|nil The focused window's identity, for an offer whose
---   acceptance replaces the selection; nil for one typed at the caret.
--- @return integer epoch The offer's _request_epoch.
--- @return table meta The tooltip's metadata, loading until the offer settles.
local function open_offer(action, label, model, focus)
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting or #_suggestions > 0 then M.dismiss() end
	local meta = {
		model = model,
		profile = label,
		loading = true,
		validation_modifiers = NavigationSettings.get(),
	}
	_suggestion_context = { app_id = nil, input_chars = 0, model = model, profile = action, focus = focus }
	_offer_notified = false
	_predicting = true
	advance_request_epoch()
	show_candidates({}, meta)
	return _request_epoch, meta
end

--- Sends one request of an offer once the backend's minimum interval allows
--- it, through the offer's pacing timer. Nothing is sent once the offer is
--- superseded or the configuration is being changed.
--- @param epoch integer The offer's _request_epoch.
--- @param what string What the log names the request.
--- @param send function Called when the request may go.
--- @param on_unpaced function Called when the pacing timer could not be armed.
--- @param kind string|nil The backend kind ("ollama" or "api") the request goes
---   to; nil for the AI menu's.
local function send_paced(epoch, what, send, on_unpaced, kind)
	if _runtime_closed or _scope_owner or epoch ~= _request_epoch then return end
	kind = kind or M.get_backend()
	local now = _clock_ms()
	local wait_ms = (_last_request_ms[kind] or -math.huge) + Inference.min_interval_ms(kind) - now
	if wait_ms > 0 then
		_rate_timer = _scheduler.after(wait_ms / 1000, function()
			if _runtime_closed or _scope_owner then return end
			_rate_timer = nil
			send_paced(epoch, what, send, on_unpaced, kind)
		end)
		if type(_rate_timer) ~= "table" or _rate_timer.armed ~= true then
			_rate_timer = nil
			Logger.error(LOG, "%s could not be paced: timer unavailable.", what)
			on_unpaced()
		end
		return
	end
	_last_request_ms[kind] = now
	send()
end

--- The request options of an offer's one-off request: chat mode, no streaming.
--- @param max_tokens integer
--- @return table
local function offer_request_opts(max_tokens, verify_local_model)
	return {
		stream = false,
		verify_local_model = verify_local_model == true,
		temperature = Settings.get("temperature"),
		max_tokens = max_tokens,
		-- Multi-line answers: the single-line stops would cut them.
		line_mode = false,
	}
end

local function offer_missing_model(failure, require_enabled)
	if not LocalModelPolicy.is_missing(failure) then return false end
	local owner = {
		epoch = _request_epoch, vision_generation = _vision_generation,
		agent_generation = _agent_generation, tone_generation = _tone_generation,
		base_url = failure.base_url, reset_claimed = false,
	}
	_model_consent_owner = owner
	local function current()
		local paused, origin = _is_paused(), M.get_base_url()
		return _model_consent_owner == owner and _scope_owner == nil and not _runtime_closed and not paused
			and (not require_enabled or _enabled)
			and owner.epoch == _request_epoch and owner.vision_generation == _vision_generation
			and owner.agent_generation == _agent_generation and owner.tone_generation == _tone_generation
			and owner.base_url == origin
	end
	local function observer(stage, receipt)
		if stage == "before" then
			if type(receipt) == "table" and receipt.ok == true and current() then
				_modal_resync_owner = owner
			else
				_modal_resync_owner = nil
				_model_consent_owner = nil
			end
		elseif stage == "after" then
			_modal_resync_owner = nil
			if type(receipt) ~= "table" or receipt.ok ~= true or not current() then _model_consent_owner = nil end
		elseif stage == "refused" then
			_modal_resync_owner = nil
			_model_consent_owner = nil
		end
	end
	local ok, handled = pcall(LocalModelOffer.handle, failure, { current = current, modal_observer = observer })
	_modal_resync_owner = nil
	if _model_consent_owner == owner then _model_consent_owner = nil end
	if not ok then Logger.warn(LOG, "Missing-model offer failed: %s.", tostring(handled)) end
	return ok and handled == true
end

--- Asks the AI menu's text backend for each answer of the screen action's list
--- (vision.json answers or error_answers) in turn and offers them as the
--- tooltip's candidates, in that order. Accepting one types it at the caret;
--- nothing is typed otherwise.
--- @param spec table The screen action's request (read_screen).
--- @param screen string The vision model's transcription.
local function request_screen_answers(spec, screen)
	local config = spec.config
	local answers = spec.answers
	local backend, target, model = M.resolve_backend()
	if not backend then
		clear_offer()
		show_notice(MANUAL_REFUSAL_KEYS.backend_not_ready, "backend_not_ready")
		return
	end
	local language = prompt_language()
	local candidates = {}
	local index = 0
	local epoch, meta = open_offer(spec.action, spec.label, model, nil)
	Logger.info(LOG, "Requesting %d screen answer(s) (backend=%s, model=%s).", #answers, M.get_backend(), model)

	local function publish()
		local visible = {}
		for position, candidate in ipairs(candidates) do visible[position] = candidate end
		meta.loading = _predicting
		show_candidates(visible, meta)
	end

	local function settle()
		_predicting = false
		_inflight_backend = nil
		meta.loading = false
		if #candidates == 0 then
			clear_offer()
			Logger.warn(LOG, "Screen reading produced no answer.")
			show_notice(VISION_READ_FAILED_KEY, "read_failed")
			return
		end
		Logger.info(LOG, "Screen answers on offer: %d of %d.", #candidates, #answers)
		publish()
	end

	local dispatch
	dispatch = function()
		index = index + 1
		local answer = answers[index]
		local messages = {
			{ role = "system", content = Vision.fill_language(answer.prompt, language) },
			{ role = "user", content = Vision.answer_user_text(screen) },
		}
		_inflight_backend = backend
		backend.chat(target, model, messages, offer_request_opts(config.answer_max_tokens, true), nil, function(full_text, err)
			if _runtime_closed or _scope_owner then return end
			if epoch ~= _request_epoch then
				Logger.info(LOG, "Screen answer '%s' ignored: a newer action or an edit superseded it.", answer.id)
				return
			end
			if err then
				if not _is_paused() and _enabled and LocalModelPolicy.is_missing(err) then
					_predicting, _inflight_backend = false, nil
					meta.loading = false
					clear_offer()
					offer_missing_model(err, true)
					return
				end
				Logger.warn(LOG, "Screen answer '%s' failed: %s", answer.id, tostring(err))
			else
				local text = Vision.extract(Parser.strip_thinking(full_text or ""), config.answer_tag)
				if text then
					candidates[#candidates + 1] = { deletes = 0, to_type = text }
				else
					Logger.warn(LOG, "Screen answer '%s' dropped: no %s block (%d chars).",
						answer.id, config.answer_tag, #(full_text or ""))
				end
			end
			if index < #answers then
				-- Shown now: the next answer may wait for the backend's interval.
				if #candidates > 0 then publish() end
				send_paced(epoch, "Screen answers", dispatch, settle)
				return
			end
			settle()
		end)
	end
	send_paced(epoch, "Screen answers", dispatch, settle)
end

--- Reads the vision model's transcription and asks for the answers.
--- @param flow table The screen flow.
--- @param spec table The screen action's request.
--- @param text string|nil The vision model's answer.
--- @param err string|nil The transport's or the provider's error.
local function finish_screen_read(flow, spec, text, err)
	if _runtime_closed or _scope_owner then return end
	if not vision_current(flow) then
		Logger.info(LOG, "Screen transcription ignored: a newer action or an edit superseded it.")
		return
	end
	_vision_flow = nil
	flow.reading = false
	if err then
		Logger.warn(LOG, "Vision request failed: %s", tostring(err))
		clear_offer()
		if not _is_paused() and _enabled and offer_missing_model(err, true) then return end
		show_notice(VISION_READ_FAILED_KEY, "read_failed")
		return
	end
	if _is_paused() or not _enabled then
		Logger.info(LOG, "Screen transcription dropped: the AI was paused or switched off while it ran.")
		clear_offer()
		return
	end
	-- The transcription is what the user's screen shows: only its size is logged.
	local screen = Vision.extract(Parser.strip_thinking(text or ""), spec.config.screen_tag)
	if not screen then
		Logger.warn(LOG, "Vision answer dropped: no %s block (%d chars).", spec.config.screen_tag, #(text or ""))
		clear_offer()
		show_notice(VISION_READ_FAILED_KEY, "read_failed")
		return
	end
	Logger.info(LOG, "Screen read (%d byte(s) of transcription).", #screen)
	request_screen_answers(spec, screen)
end

--- Sends a finished capture to the vision model, then deletes it.
--- @param flow table The screen flow.
--- @param spec table The screen action's request.
--- @param outcome table screen_capture outcome { status, scaled, reason }.
local function finish_capture(flow, spec, outcome)
	local capture = flow.capture
	if _runtime_closed or _scope_owner or not vision_current(flow) then
		discard_capture(capture)
		Logger.info(LOG, "Screen capture ignored: a newer action or an edit superseded it.")
		return
	end
	flow.capture = nil
	if type(outcome) ~= "table" or outcome.status ~= "ok" then
		discard_capture(capture)
		_vision_flow = nil
		if type(outcome) == "table" and outcome.status == "cancelled" then
			Logger.info(LOG, "Screen reading cancelled: no region was captured.")
			return
		end
		Logger.warn(LOG, "Screen capture failed: %s", tostring(type(outcome) == "table" and outcome.reason or outcome))
		show_notice(VISION_CAPTURE_FAILED_KEY, "capture_failed")
		return
	end
	if outcome.scaled ~= true and not _vision_unscaled_logged then
		_vision_unscaled_logged = true
		Logger.info(LOG, "Screenshots are sent at their full size: install ImageMagick to downscale them.")
	end
	local handle = io.open(capture.path, "rb")
	local image = handle and handle:read("*a") or nil
	if handle then handle:close() end
	discard_capture(capture)
	if type(image) ~= "string" or image == "" then
		_vision_flow = nil
		Logger.error(LOG, "Screen capture reported success but its image is unreadable.")
		show_notice(VISION_CAPTURE_FAILED_KEY, "capture_failed")
		return
	end
	if _is_paused() or not _enabled then
		_vision_flow = nil
		Logger.info(LOG, "Screen capture dropped: the AI was paused or switched off meanwhile.")
		return
	end
	local config = spec.config
	local body = Vision.build_request(spec.target.format, {
		model = spec.model,
		system = config.read_prompt,
		text = Vision.READ_USER_TEXT,
		image = Base64.encode(image),
		mime = config.image_mime,
		max_tokens = config.read_max_tokens,
	})
	flow.reading = true
	-- The tooltip says something is coming: reading a screen takes seconds.
	flow.shown = true
	_suggestion_context = nil
	show_candidates({}, {
		model = spec.model,
		profile = spec.label,
		loading = true,
		validation_modifiers = NavigationSettings.get(),
	})
	Logger.info(LOG, "Screen captured (%d byte(s)); sending it to %s.", #image, spec.backend)
	VisionRequest.send(spec.target, body, function(text, err) finish_screen_read(flow, spec, text, err) end)
end

--- Answers what is on the screen: the llm_screen_region, llm_screen_full and
--- llm_screen_error actions. A vision model transcribes a private screenshot,
--- then the AI menu's text backend drafts the action's answers of vision.json
--- (answers, or error_answers for llm_screen_error), offered in the tooltip.
--- A new screen action supersedes the one in flight.
--- @param action string A key of VISION_ACTIONS.
--- @param value string The binding's parameter, "<backend>" or "<backend>|<model>".
--- @return boolean started True when the capture was started.
function M.read_screen(action, value)
	if _runtime_closed or _scope_owner then return false end
	local screen_action = VISION_ACTIONS[action]
	if not screen_action then error("read_screen: unknown screen action '" .. tostring(action) .. "'") end
	local mode = screen_action.mode
	-- Every refusal comes before the capture: nothing is captured for nothing.
	-- The screen is the context, so an empty typing buffer refuses nothing.
	local reason = manual_refusal()
	if reason == "empty_context" then reason = nil end
	if reason then
		Logger.info(LOG, "Screen reading refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	local parsed, parse_err = Vision.parse(value)
	if not parsed then
		Logger.warn(LOG, "Screen reading refused: invalid parameter '%s' (%s).", tostring(value), parse_err)
		return false
	end
	local config = VisionRequest.config()
	if not config then return false end
	local model = Vision.resolve_model(parsed, config)
	if not model then
		Logger.info(LOG, "Screen reading refused: '%s' has no default vision model and the binding names none.",
			parsed.backend)
		show_notice(VISION_NO_MODEL_KEY, "no_model")
		return false
	end
	local target, target_err = VisionRequest.resolve_target(parsed.backend, model)
	if not target then
		Logger.warn(LOG, "Screen reading refused: %s.", tostring(target_err))
		show_notice(MANUAL_REFUSAL_KEYS.backend_not_ready, "backend_not_ready")
		return false
	end
	if not _capture_screen then
		Logger.error(LOG, "Screen reading refused: no capture surface was injected.")
		return false
	end
	M.drop_vision("superseded")
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting or #_suggestions > 0 then M.dismiss() end

	local spec = {
		action = action,
		label = i18n.get("sg_actions." .. action),
		backend = parsed.backend,
		model = model,
		target = target,
		config = config,
		answers = config[screen_action.answers],
	}
	local flow = { generation = _vision_generation }
	_vision_flow = flow
	Logger.info(LOG, "Screen reading requested (action=%s, mode=%s, backend=%s, model=%s).",
		action, mode, parsed.backend, model)
	local started, handle, capture_err = pcall(_capture_screen, mode, config.max_image_edge, function(outcome)
		-- A capture that finished before the handle came back is taken up below.
		if not flow.capture then flow.early = outcome; return end
		finish_capture(flow, spec, outcome)
	end)
	if not started or type(handle) ~= "table" then
		if _vision_flow == flow then _vision_flow = nil end
		Logger.error(LOG, "Screen capture could not start: %s", tostring(started and capture_err or handle))
		show_notice(VISION_CAPTURE_FAILED_KEY, "capture_failed")
		return false
	end
	flow.capture = handle
	if flow.early then finish_capture(flow, spec, flow.early) end
	return true
end

--- Offers the translation of a translate request's answer, or tells the user
--- it failed. The selection and the translation are the user's text: only
--- their sizes are logged.
--- @param epoch integer The offer's _request_epoch.
--- @param meta table The tooltip's metadata.
--- @param config table Decoded translate.json.
--- @param full_text string|nil The model's answer.
--- @param err string|nil The backend's error.
local function finish_translation(epoch, meta, config, full_text, err)
	if _runtime_closed or _scope_owner then return end
	if epoch ~= _request_epoch then
		Logger.info(LOG, "Translation ignored: a newer action or an edit superseded it.")
		return
	end
	_predicting = false
	_inflight_backend = nil
	meta.loading = false
	if _is_paused() or not _enabled then
		Logger.info(LOG, "Translation dropped: the AI was paused or switched off while it ran.")
		clear_offer()
		return
	end
	if err then
		Logger.warn(LOG, "Translation failed: %s", tostring(err))
		clear_offer()
		show_notice(TRANSLATE_FAILED_KEY, "failed")
		return
	end
	local text = Translate.extract(config, Parser.strip_thinking(full_text or ""))
	if not text then
		Logger.warn(LOG, "Translation dropped: no %s block (%d chars).", config.tag, #(full_text or ""))
		clear_offer()
		show_notice(TRANSLATE_FAILED_KEY, "failed")
		return
	end
	Logger.info(LOG, "Translation on offer (%d byte(s)).", #text)
	-- Accepting it replaces the selection instead of typing at the caret.
	show_candidates({ { deletes = 0, to_type = text, replaces_selection = true } }, meta)
end

--- Translates the selection: the llm_translate_selection action. The AI menu's
--- text backend translates it into the binding's language, the translation is
--- offered as one candidate, and accepting it replaces the selection, left
--- selected as a tone step leaves it. Escape, a dismiss or typing leave the
--- text untouched; a newer trigger supersedes the one in flight.
--- @param value string The binding's parameter, "ui" or a locale code.
--- @return boolean requested True when the translation request was started.
function M.translate_selection(value)
	if _runtime_closed or _scope_owner then return false end
	if not _read_selection or not _replace_selection then
		Logger.error(LOG, "Translation refused: no selection surface was injected.")
		return false
	end
	-- Checked before the selection is read: a refused request sends no copy
	-- chord. The selection is the text, so an empty typing buffer refuses nothing.
	local reason = manual_refusal()
	if reason == "empty_context" then reason = nil end
	if reason then
		Logger.info(LOG, "Translation refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	local data = Translation.data()
	if not data then return false end
	local config = data.config
	local target = Translate.parse(value, config, data.names)
	if not target then
		Logger.warn(LOG, "Translation refused: invalid parameter '%s'.", tostring(value))
		return false
	end
	local code = Translate.target_locale(target, config, prompt_language())
	local language = Translate.resolve_language(target, config, data.names, prompt_language())
	if not language then
		Logger.error(LOG, "Translation refused: the locale '%s' has no native name.", tostring(code))
		return false
	end
	if _is_secure_context() then
		Logger.debug(LOG, "Translation suppressed: secure field or excluded context.")
		return false
	end
	local read_ok, selection, read_err = _read_selection()
	if not read_ok or type(selection) ~= "string" or not selection:find("%S") then
		if read_ok or read_err == "no_selection" then
			Logger.info(LOG, "Translation refused: nothing is selected.")
			show_notice(TRANSLATE_NO_SELECTION_KEY, "no_selection")
		else
			Logger.warn(LOG, "Translation ignored: the selection could not be read (%s).", tostring(read_err))
		end
		return false
	end
	local backend, backend_target, model = M.resolve_backend()
	if not backend then
		Logger.info(LOG, "Translation refused (backend_not_ready).")
		show_notice(MANUAL_REFUSAL_KEYS.backend_not_ready, "backend_not_ready")
		return false
	end
	-- One offer at a time: a screen reading in flight would replace this one,
	-- and a tone step would rewrite the text being translated.
	M.drop_vision("superseded")
	M.drop_tone("superseded")
	local epoch, meta = open_offer(TRANSLATE_ACTION, i18n.get("sg_actions." .. TRANSLATE_ACTION), model,
		current_focus())
	local messages = {
		{ role = "system", content = Translate.system_prompt(config, language) },
		{ role = "user", content = Translate.user_text(config, selection) },
	}
	Logger.info(LOG, "Sending translation (backend=%s, model=%s, target=%s, %d byte(s)).",
		M.get_backend(), model, code, #selection)
	send_paced(epoch, "Translation", function()
		_inflight_backend = backend
		backend.chat(backend_target, model, messages, offer_request_opts(config.max_tokens), nil,
			function(full_text, err) finish_translation(epoch, meta, config, full_text, err) end)
	end, function()
		_predicting = false
		clear_offer()
		show_notice(TRANSLATE_FAILED_KEY, "failed")
	end)
	return true
end

--- Fills the {1}, {2}… of a translated template with plain values: a value is
--- data, never a pattern replacement.
--- @param template string
--- @param args table Array of values.
--- @return string
local function fill_args(template, args)
	return (template:gsub("{(%d+)}", function(index)
		local value = args[tonumber(index)]
		if value == nil then return nil end
		return tostring(value)
	end))
end

--- The focused window's application name and title, "" when unknown. Both are
--- private: sent in the agent's prompt, never logged.
--- @return table { app, title }
local function focused_window()
	if not _focused_window then return { app = "", title = "" } end
	local ok, info = pcall(_focused_window)
	if not ok or type(info) ~= "table" then return { app = "", title = "" } end
	return {
		app = type(info.app) == "string" and info.app or "",
		title = type(info.title) == "string" and info.title or "",
	}
end

--- Counts the code points of a UTF-8 text.
--- @param text string
--- @return integer
local function code_points(text)
	local _, count = text:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return count
end

--- The state a Jev System 1 reads: the application, then the sentence.
--- @param app string The focused application, "" when unknown.
--- @param sentence string
--- @return string
local function jev_state(app, sentence)
	return "App: " .. app .. "\nText: " .. sentence
end

--- The System 1 transport: triages one sentence. A chat backend reads the
--- triage prompt; a Jev System 1 (a decisions provider, or a TypeSafe model
--- through Backboard: chat.decision) answers the typed question of
--- agent.jev_questions() instead. A new backend kind plugs in here and nowhere
--- else. on_done(triage, err) is called once, unless the request is withdrawn
--- (drop_agent_triage).
--- @param chat table AgentSettings.chat_target() output.
--- @param config table Decoded agent.json.
--- @param sentence string The sentence being typed.
--- @param ctx table { app, tools }
--- @param on_done function
local function system1_transport(chat, config, sentence, ctx, on_done)
	if chat.decision then
		chat.module.decide(chat.target, jev_state(ctx.app, sentence), Agent.jev_questions(config),
			function(answers, err)
				if err then on_done(nil, err) return end
				on_done(Agent.parse_jev_answers(config, answers), nil)
			end)
		return
	end
	local messages = {
		{ role = "system", content = Agent.system1_prompt(config, ctx) },
		{ role = "user", content = sentence },
	}
	chat.module.chat(chat.target, chat.model, messages, offer_request_opts(config.system1.max_tokens, true), nil,
		function(full_text, err)
			if err then on_done(nil, err) return end
			on_done(Agent.parse_system1(config, Parser.strip_thinking(full_text or "")), nil)
		end)
end

--- Sends one System 2 request for actions. A new backend kind plugs in here
--- and nowhere else. on_done(raw, err) is called once, unless the request is
--- cancelled.
--- @param chat table AgentSettings.chat_target() output.
--- @param payload table { system, user, max_tokens }
--- @param on_done function
local function send_system2(chat, payload, on_done)
	chat.module.chat(chat.target, chat.model, {
		{ role = "system", content = payload.system },
		{ role = "user", content = payload.user },
	}, offer_request_opts(payload.max_tokens, true), nil, on_done)
end

--- The System 2 transport of an offer the user asked for: its backend is the
--- offer's, so dismissing the offer cancels it.
--- @param chat table AgentSettings.chat_target() output.
--- @param payload table { system, user, max_tokens }
--- @param on_done function
local function system2_transport(chat, payload, on_done)
	_inflight_backend = chat.module
	send_system2(chat, payload, on_done)
end

--- Tells the user why an agent action cannot run, if it cannot: the pause,
--- then the agent's mode. The agent uses neither the AI menu's switch nor its
--- backend, so neither refuses anything here.
--- @param what string What the log names the action.
--- @return boolean refused
local function agent_refused(what)
	if _is_paused() then
		Logger.info(LOG, "%s refused (paused).", what)
		show_notice(MANUAL_REFUSAL_KEYS.paused, "paused")
		return true
	end
	if AgentSettings.get_mode() == "off" then
		Logger.info(LOG, "%s refused: the agent is off.", what)
		show_notice(AGENT_KEYS.off, "agent_off")
		return true
	end
	return false
end

--- System 2's chat target and agent.json, or nil after telling the user why:
--- off, no model, a provider without a stored key or that cannot chat all
--- mean that no System 2 is configured.
--- @param what string What the log names the action.
--- @return table|nil chat, table|nil config
local function system2_chat(what)
	local config = AgentSettings.config()
	if not config then return nil end
	local chat, reason = AgentSettings.chat_target("system2")
	if chat then return chat, config end
	if reason == "off" or reason == "no_model" then
		Logger.info(LOG, "%s refused: no System 2 is configured (%s).", what, reason)
	else
		Logger.warn(LOG, "%s refused: System 2 cannot answer (%s).", what, tostring(reason))
	end
	show_notice(AGENT_KEYS.no_system2, "no_system2")
	return nil
end

--- Carries out an accepted action and tells the user how it went.
--- @param config table Decoded agent.json.
--- @param action table A validated action.
--- @return boolean accepted Always true: the connector owns the outcome.
local function run_connector(config, action)
	Logger.info(LOG, "Agent action accepted: %s.", action.type)
	AgentConnectors.run(config, action, function(ok, reason)
		if ok then
			Logger.info(LOG, "Agent %s action done.", action.type)
			local arg = action.type == "shortcut" and action.name or action.title
			announce(fill_args(i18n.get(AGENT_DONE_KEYS[action.type]), { arg }), "agent " .. action.type .. " done")
			return
		end
		Logger.error(LOG, "Agent %s action failed: %s", action.type, tostring(reason))
		show_notice(AGENT_KEYS.connector_failed, "connector_failed")
	end)
	return true
end

--- Reads the actions of a System 2 answer and logs the refused ones.
--- @param config table Decoded agent.json.
--- @param tools table The tool names the request offered.
--- @param full_text string|nil The model's answer.
--- @return table|nil actions Nil when the answer holds no readable block.
--- @return table rejected
local function read_actions(config, tools, full_text)
	local actions, rejected = Agent.parse_actions(config, Parser.strip_thinking(full_text or ""), Json.decode,
		{ tools = tools, is_null = Json.is_null })
	-- The reasons name fields and rules, never the user's text.
	for _, reason in ipairs(rejected) do Logger.info(LOG, "Agent action refused: %s.", tostring(reason)) end
	if not actions then
		Logger.warn(LOG, "Agent answer dropped: no readable %s block (%d chars).", config.system2.tag, #(full_text or ""))
	end
	return actions, rejected
end

--- Shows validated actions as the tooltip's candidates, each accepted on its own.
--- @param meta table The tooltip's metadata.
--- @param config table Decoded agent.json.
--- @param actions table Validated actions.
--- @param rejected table The refused ones' reasons, for the log.
local function offer_actions(meta, config, actions, rejected)
	local candidates = {}
	for index, action in ipairs(actions) do
		local key, args = Agent.label(action)
		candidates[index] = {
			deletes = 0,
			to_type = fill_args(i18n.get(key), args),
			-- Accepting runs the connector; nothing is typed.
			on_accept = function() return run_connector(config, action) end,
		}
	end
	Logger.info(LOG, "Agent actions on offer: %d (%d refused).", #candidates, #rejected)
	show_candidates(candidates, meta)
end

--- Offers the actions of a System 2 answer the user asked for, or tells the
--- user why none is offered.
--- @param epoch integer The offer's _request_epoch.
--- @param meta table The tooltip's metadata.
--- @param config table Decoded agent.json.
--- @param tools table The tool names the request offered.
--- @param full_text string|nil The model's answer.
--- @param err string|nil The backend's error.
local function finish_agent(epoch, meta, config, tools, full_text, err)
	if _runtime_closed or _scope_owner then return end
	if epoch ~= _request_epoch then
		Logger.info(LOG, "Agent answer ignored: a newer action or an edit superseded it.")
		return
	end
	_predicting = false
	_inflight_backend = nil
	meta.loading = false
	local function fail(key, reason)
		clear_offer()
		show_notice(key, reason)
	end
	if _is_paused() then
		Logger.info(LOG, "Agent answer dropped: Ergopti+ was paused while it ran.")
		clear_offer()
		return
	end
	if err then
		Logger.warn(LOG, "Agent request failed: %s", tostring(err))
		clear_offer()
		if offer_missing_model(err, false) then return end
		return fail(AGENT_KEYS.failed, "failed")
	end
	local actions, rejected = read_actions(config, tools, full_text)
	if not actions then return fail(AGENT_KEYS.failed, "failed") end
	if #actions == 0 then
		Logger.info(LOG, "Agent answer holds no action.")
		return fail(AGENT_KEYS.no_action, "no_action")
	end
	offer_actions(meta, config, actions, rejected)
end

--- The System 2 request for a text: its prompt with the local context, and
--- the text as the user turn.
--- @param source string "selection", "command" or "typing".
--- @param text string The source text.
--- @param config table Decoded agent.json.
--- @param window table { app, title }
--- @param tools table The tool names offered.
--- @return table payload { system, user, max_tokens }
local function system2_payload(source, text, config, window, tools)
	local time = AgentSettings.time_context(_now())
	local ok_zone, zone = pcall(_timezone)
	local ctx = {
		source = source, app = window.app, window = window.title, now = time.now, weekday = time.weekday,
		timezone = (ok_zone and type(zone) == "string" and zone ~= "") and zone or UNKNOWN_TIMEZONE,
		language = prompt_language(), tools = tools,
	}
	return {
		system = Agent.system2_prompt(config, ctx),
		user = Agent.system2_user_text(config, text),
		max_tokens = config.system2.max_tokens,
	}
end

--- Asks System 2 for the actions a text the user handed over implies and
--- offers them in the tooltip, each accepted on its own. A newer action,
--- typing or Escape supersede it; a stale answer is dropped.
--- @param source string "selection" or "command".
--- @param text string The source text.
--- @param opts table { chat, config, window? }
--- @return boolean requested
local function run_agent(source, text, opts)
	local config, chat = opts.config, opts.chat
	local window = opts.window or focused_window()
	local tools = AgentConnectors.tools(config)
	local payload = system2_payload(source, text, config, window, tools)
	local action = source == "selection" and AGENT_SELECTION_ACTION or AGENT_COMMAND_ACTION
	-- One offer at a time: a screen reading or a tone step in flight would
	-- replace or rewrite what the actions are made from.
	M.drop_vision("superseded")
	M.drop_tone("superseded")
	local epoch, meta = open_offer(action, i18n.get("sg_actions." .. action), chat.model, current_focus())
	_suggestion_context.agent = { source = source, config = config }
	-- The text, the window and the answer are the user's: only sizes are logged.
	Logger.info(LOG, "Sending agent request (source=%s, backend=%s, model=%s, %d byte(s), %d tool(s)).",
		source, chat.backend, chat.model, #text, #tools)
	send_paced(epoch, "Agent request", function()
		system2_transport(chat, payload, function(full_text, err)
			finish_agent(epoch, meta, config, tools, full_text, err)
		end)
	end, function()
		_predicting = false
		clear_offer()
		show_notice(AGENT_KEYS.failed, "failed")
	end, chat.kind)
	return true
end

--- "What can I do with this?": the llm_agent_selection action. System 2 reads
--- the selection and its actions are offered in the tooltip.
--- @return boolean requested True when the request was started.
function M.agent_selection()
	if _runtime_closed or _scope_owner then return false end
	if not _read_selection then
		Logger.error(LOG, "Agent selection refused: no selection surface was injected.")
		return false
	end
	-- Checked before the selection is read: a refused request sends no copy chord.
	if agent_refused("Agent selection") then return false end
	local chat, config = system2_chat("Agent selection")
	if not chat then return false end
	if _is_secure_context() then
		Logger.debug(LOG, "Agent selection suppressed: secure field or excluded context.")
		return false
	end
	local window = focused_window()
	local read_ok, selection, read_err = _read_selection()
	if not read_ok or type(selection) ~= "string" or not selection:find("%S") then
		if read_ok or read_err == "no_selection" then
			Logger.info(LOG, "Agent selection refused: nothing is selected.")
			show_notice(AGENT_KEYS.no_selection, "no_selection")
		else
			Logger.warn(LOG, "Agent selection ignored: the selection could not be read (%s).", tostring(read_err))
		end
		return false
	end
	return run_agent("selection", selection, { chat = chat, config = config, window = window })
end

--- The llm_agent_command action: System 2 reads a command the user types in a
--- dialog. Cancelling it, or confirming nothing, does nothing.
--- @return boolean requested True when the request was started.
function M.agent_command()
	if _runtime_closed or _scope_owner then return false end
	if not _ask_text then
		Logger.error(LOG, "Agent command refused: no text dialog was injected.")
		return false
	end
	if agent_refused("Agent command") then return false end
	local chat, config = system2_chat("Agent command")
	if not chat then return false end
	if _is_secure_context() then
		Logger.debug(LOG, "Agent command suppressed: secure field or excluded context.")
		return false
	end
	-- Read before the dialog takes the focus: the context is where the user was.
	local window = focused_window()
	local ok, text = pcall(_ask_text, i18n.get("dialog.agent.command_title"), i18n.get("dialog.agent.command_prompt"))
	if not ok then
		Logger.error(LOG, "Agent command dialog failed: %s", tostring(text))
		return false
	end
	if type(text) ~= "string" or not text:find("%S") then
		Logger.info(LOG, "Agent command cancelled: nothing was typed.")
		return false
	end
	return run_agent("command", text, { chat = chat, config = config, window = window })
end

--- Changes the agent's mode, from the menu or the toggle action. The automatic
--- mode needs a System 1 and a System 2 that can answer (configured, and a
--- stored key for a provider): without them it is refused with a notice and
--- the mode stays as it was.
--- @param mode string "off", "action" or "auto"
--- @return boolean applied
function M.set_agent_mode(mode)
	if _runtime_closed or _scope_owner then return false end
	if mode == "auto" then
		local system1, reason1 = AgentSettings.chat_target("system1")
		if not system1 then
			Logger.info(LOG, "Automatic agent refused: System 1 cannot answer (%s).", tostring(reason1))
			show_notice(AGENT_KEYS.no_system1, "no_system1")
			return false
		end
		local system2, reason2 = AgentSettings.chat_target("system2")
		if not system2 then
			Logger.info(LOG, "Automatic agent refused: System 2 cannot answer (%s).", tostring(reason2))
			show_notice(AGENT_KEYS.no_system2, "no_system2")
			return false
		end
	end
	local previous = AgentSettings.get_mode()
	if previous == mode then return true end
	if not AgentSettings.set_mode(mode) then return false end
	if mode ~= "auto" then M.drop_agent_triage("automatic mode off") end
	if mode == "auto" then
		announce(i18n.get(AGENT_KEYS.auto_on), "agent auto on")
	elseif previous == "auto" then
		announce(i18n.get(AGENT_KEYS.auto_off), "agent auto off")
	end
	return true
end

--- The llm_agent_auto_toggle action: the automatic mode on or off ("auto" <->
--- "action"; from "off" it turns the automatic mode on).
--- @return boolean changed
function M.toggle_agent_auto()
	if _runtime_closed or _scope_owner then return false end
	return M.set_agent_mode(AgentSettings.get_mode() == "auto" and "action" or "auto")
end

--- The application the user last typed in, for the menu's exclusion row.
--- @return string|nil
function M.get_agent_last_app()
	return _agent_last_app
end

--- Withdraws the automatic mode's pause, its wait for a backend and its
--- request in flight (the triage, or System 2's), if any, and makes any answer
--- to come stale. Called on every keystroke, so it logs only when a request
--- was actually in flight.
--- @param reason string What the log names the cause.
function M.drop_agent_triage(reason)
	_agent_generation = _agent_generation + 1
	if _agent_timer then
		_scheduler.cancel(_agent_timer)
		_agent_timer = nil
	end
	local triage = _agent_triage
	if not triage then return end
	_agent_triage = nil
	if triage.chat.module.cancel() ~= true then Logger.error(LOG, "The agent's request could not be withdrawn.") end
	Logger.info(LOG, "Agent request withdrawn (%s).", tostring(reason))
end

--- Reports whether the automatic agent must stay away: live mode, a screen
--- reading, a tone step, a pause, another mode, or an offer in flight or on
--- screen that is not typing's own automatic prediction. That prediction does
--- not block it: it comes before the agent's pause is over, and the agent's
--- actions replace it when they arrive. The AI menu's switch plays no part.
--- @return boolean
local function agent_blocked()
	local offer = _predicting or #_suggestions > 0
	local automatic_prediction = _suggestion_context ~= nil and _suggestion_context.automatic == true
	return _live ~= nil or (offer and not automatic_prediction) or _vision_flow ~= nil or _tone_timer ~= nil
		or _is_paused() or AgentSettings.get_mode() ~= "auto"
end

--- Remembers a triaged sentence, forgetting the oldest beyond the memory.
--- @param sentence string
local function remember_triaged(sentence)
	_agent_triaged[#_agent_triaged + 1] = sentence
	if #_agent_triaged > AGENT_TRIAGED_MEMORY then table.remove(_agent_triaged, 1) end
end

--- Reports whether a sentence was already triaged.
--- @param sentence string
--- @return boolean
local function already_triaged(sentence)
	for _, seen in ipairs(_agent_triaged) do if seen == sentence then return true end end
	return false
end

--- Sends one request of the automatic mode once its backend is free and its
--- minimum interval has passed. The backends serve one request at a time, and
--- the automatic prediction usually holds the same one when the pause ends:
--- sending would cancel it, so the agent waits on its own timer, which the
--- next keystroke withdraws (drop_agent_triage).
--- @param generation integer The keystroke generation the request belongs to.
--- @param chat table The system's chat target.
--- @param what string What the log names the request.
--- @param send function Called when the request may go.
local function send_when_free(generation, chat, what, send)
	if _runtime_closed or _scope_owner or generation ~= _agent_generation then return end
	local interval = Inference.min_interval_ms(chat.kind)
	local wait_ms = (_last_request_ms[chat.kind] or -math.huge) + interval - _clock_ms()
	local busy = type(chat.module.is_active) == "function" and chat.module.is_active() == true
	if wait_ms > 0 or busy then
		local delay_ms = math.max(wait_ms, busy and interval or 0)
		Logger.debug(LOG, "%s waits %d ms for its backend.", what, delay_ms)
		_agent_timer = _scheduler.after(delay_ms / 1000, function()
			_agent_timer = nil
			send_when_free(generation, chat, what, send)
		end)
		if type(_agent_timer) ~= "table" or _agent_timer.armed ~= true then
			_agent_timer = nil
			Logger.error(LOG, "%s could not wait for its backend: timer unavailable.", what)
		end
		return
	end
	_last_request_ms[chat.kind] = _clock_ms()
	send()
end

--- Asks System 2 for the actions of the sentence System 1 flagged, showing
--- nothing meanwhile. The actions are offered only if they arrive for the same
--- sentence (no keystroke since) while nothing but typing's automatic
--- prediction has the screen: they replace that prediction. The automatic
--- mode stays silent otherwise: the user asked for nothing.
--- @param generation integer The keystroke generation of the sentence.
--- @param sentence string
--- @param opts table { chat, config, window, tools, auto = { app, intent } }
local function auto_system2(generation, sentence, opts)
	local chat, config, tools = opts.chat, opts.config, opts.tools
	local payload = system2_payload("typing", sentence, config, opts.window, tools)
	send_when_free(generation, chat, "Agent request", function()
		if agent_blocked() then
			Logger.info(LOG, "Agent request not sent: another tooltip or request has the screen.")
			return
		end
		local state = { chat = chat }
		_agent_triage = state
		-- The sentence, the window and the answer are the user's: only sizes are logged.
		Logger.info(LOG, "Sending agent request (source=typing, backend=%s, model=%s, %d byte(s), %d tool(s)).",
			chat.backend, chat.model, #sentence, #tools)
		send_system2(chat, payload, function(full_text, err)
			if _runtime_closed or _scope_owner then return end
			if _agent_triage ~= state or generation ~= _agent_generation then
				Logger.info(LOG, "Agent answer ignored: typing superseded it.")
				return
			end
			_agent_triage = nil
			if err then
				if not _is_paused() then LocalModelOffer.handle(err, { automatic = true }) end
				Logger.warn(LOG, "Agent request failed: %s", tostring(err))
				return
			end
			if agent_blocked() then
				Logger.info(LOG, "Agent actions not shown: another tooltip or request has the screen.")
				return
			end
			local actions, rejected = read_actions(config, tools, full_text)
			if not actions then return end
			if #actions == 0 then
				Logger.info(LOG, "Agent answer holds no action.")
				return
			end
			if _predicting or #_suggestions > 0 then
				Logger.info(LOG, "Agent actions replace the automatic prediction.")
			end
			-- open_offer withdraws the prediction on screen, pending or in flight.
			local _, meta = open_offer(AGENT_AUTO_ACTION, i18n.get("menu.agent.title"), chat.model, current_focus())
			_suggestion_context.app_id = opts.auto.app
			_suggestion_context.agent = { source = "typing", auto = opts.auto, config = config }
			_predicting = false
			meta.loading = false
			offer_actions(meta, config, actions, rejected)
		end)
	end)
end

--- The automatic mode's pause elapsed: triages the current sentence with
--- System 1 and, above the learnt threshold of its intent in this application,
--- asks System 2 for the actions.
--- @param generation integer The keystroke generation the pause belongs to.
--- @param buffer string The typing buffer.
--- @param app string|nil The application typed in.
local function agent_pause_elapsed(generation, buffer, app)
	if _runtime_closed or _scope_owner or generation ~= _agent_generation or agent_blocked() then return end
	if AgentSettings.is_app_disabled(app) then
		Logger.debug(LOG, "Agent triage skipped: the application is excluded.")
		return
	end
	local config = AgentSettings.config()
	if not config then return end
	-- Trimmed: a space typed after the sentence does not make it a new one.
	local sentence = Rewrite.sentence_span(buffer):match("^%s*(.-)%s*$")
	if code_points(sentence) < config.system1.min_chars or already_triaged(sentence) then return end
	if _is_secure_context() then
		Logger.debug(LOG, "Agent triage suppressed: secure field or excluded context.")
		return
	end
	local system1, reason1 = AgentSettings.chat_target("system1")
	local system2, reason2 = AgentSettings.chat_target("system2")
	if not system1 or not system2 then
		Logger.debug(LOG, "Agent triage skipped: System 1 (%s) or System 2 (%s) cannot answer.",
			tostring(reason1 or "ready"), tostring(reason2 or "ready"))
		return
	end
	local window = focused_window()
	local tools = AgentConnectors.tools(config)
	send_when_free(generation, system1, "Agent triage", function()
		if agent_blocked() then
			Logger.info(LOG, "Agent triage not sent: another tooltip or request has the screen.")
			return
		end
		remember_triaged(sentence)
		local triage_state = { chat = system1 }
		_agent_triage = triage_state
		Logger.info(LOG, "Agent triage sent (backend=%s, model=%s, %s, %d char(s)).", system1.backend,
			system1.model, system1.decision and "Jev decision" or "chat", code_points(sentence))
		system1_transport(system1, config, sentence, { app = window.app, tools = tools }, function(triage, err)
			if _runtime_closed or _scope_owner then return end
			if _agent_triage ~= triage_state or generation ~= _agent_generation then
				Logger.info(LOG, "Agent triage ignored: typing superseded it.")
				return
			end
			_agent_triage = nil
			if err then
				if not _is_paused() then LocalModelOffer.handle(err, { automatic = true }) end
				Logger.warn(LOG, "Agent triage failed: %s", tostring(err))
				return
			end
			if not triage then
				Logger.info(LOG, "Agent triage unreadable.")
				return
			end
			local threshold = AgentLearning.threshold(config, app, triage.intent)
			if not Agent.should_act(triage, threshold) then
				Logger.info(LOG, "Agent triage: %s at %.2f, below %.2f.", triage.intent, triage.probability, threshold)
				return
			end
			if agent_blocked() then
				Logger.info(LOG, "Agent triage not followed: another tooltip or request has the screen.")
				return
			end
			Logger.info(LOG, "Agent triage: %s at %.2f (threshold %.2f); asking System 2.", triage.intent,
				triage.probability, threshold)
			auto_system2(generation, sentence, { chat = system2, config = config, window = window, tools = tools,
				auto = { app = app, intent = triage.intent } })
		end)
	end)
end

--- Arms the automatic mode's pause after a keystroke. Nothing while live mode
--- runs or a hotstring preview is on screen: on_hotstring_expired re-arms it.
--- @param buffer string The typing buffer.
--- @param output_context table|nil { app_id, hotstring_preview_visible }
arm_agent = function(buffer, output_context)
	local app = type(output_context) == "table" and output_context.app_id or nil
	if type(app) == "string" and app ~= "" then _agent_last_app = app end
	if _live or type(buffer) ~= "string" or buffer == "" then return end
	if type(output_context) == "table" and output_context.hotstring_preview_visible == true then return end
	if AgentSettings.get_mode() ~= "auto" then return end
	local config = AgentSettings.config()
	if not config then return end
	if _agent_timer then _scheduler.cancel(_agent_timer) end
	local generation = _agent_generation
	_agent_timer = _scheduler.after(config.system1.pause_ms / 1000, function()
		_agent_timer = nil
		agent_pause_elapsed(generation, buffer, app)
	end)
	if type(_agent_timer) ~= "table" or _agent_timer.armed ~= true then
		_agent_timer = nil
		Logger.error(LOG, "The agent's typing pause could not be armed: timer unavailable.")
	end
end

--- Cancels pending and in-flight work and shows nothing, leaving the hotstring
--- buffer alone. For edits the caller has already applied to that buffer:
--- Backspace and Escape update it precisely, and a reset here undid the edit.
function M.withdraw(resync_owner)
	if _scope_owner then return false end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	-- Backspace, Escape, a desync or a blocked capture: the selection a tone
	-- step was about to rewrite may be gone, and Escape cancels a screen action.
	M.drop_tone("withdrawn")
	M.drop_vision("withdrawn")
	M.drop_agent_triage("withdrawn")
	M.dismiss(resync_owner)
end


--- Cancels pending/in-flight work and discards the current engine buffer.
function M.cancel()
	if _scope_owner then return false end
	-- Only the one reset bracketed by this enable dialog's native restoration
	-- may continue its unchanged receipt. Every other cancellation still revokes it.
	if _enable_modal_resync_owner then _enable_modal_resync_owner.claim() end
	if retire_runtime_request and not retire_runtime_request() then return false end
	_enable_generation = _enable_generation + 1
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	M.withdraw(_modal_resync_owner)
	if _engine and type(_engine.reset) == "function" then _engine:reset() end
end

--- Dismisses in-flight and visible suggestions without changing the buffer.
function M.dismiss(resync_owner)
	if _scope_owner then return false end
	-- An automatic suggestion on screen that goes without acceptance (Escape,
	-- typing over it) raises its intent's threshold in that application.
	local agent = _suggestion_context and _suggestion_context.agent or nil
	if agent and agent.auto and #_suggestions > 0 then
		AgentLearning.record(agent.config, agent.auto.app, agent.auto.intent, false)
	end
	advance_request_epoch(resync_owner)
	if _rate_timer then _scheduler.cancel(_rate_timer); _rate_timer = nil end
	if _predicting and _inflight_backend then _inflight_backend.cancel() end
	_inflight_backend = nil
	_predicting = false
	clear_offer()
end


--- Accepts one displayed prediction after the daemon commits its physical edit.
--- @param index integer
--- @return boolean
function M.accept(index)
	if _runtime_closed or _scope_owner then return false end
	local candidate = _suggestions[tonumber(index)]
	if not candidate then return false end
	local ok, committed
	if candidate.on_accept then
		-- An agent action: its connector runs, nothing is typed.
		ok, committed = pcall(candidate.on_accept)
		if ok and committed == true then
			local agent = _suggestion_context and _suggestion_context.agent or nil
			if agent and agent.auto then AgentLearning.record(agent.config, agent.auto.app, agent.auto.intent, true) end
			clear_offer()
			return true
		end
	elseif candidate.replaces_selection then
		-- A translation replaces the selection it was made from, left selected as
		-- a tone step leaves it. Compared like a tone step's focus: in another
		-- window the text would land where nothing was selected.
		if not _replace_selection then return false end
		local focus = _suggestion_context and _suggestion_context.focus or ""
		if current_focus() ~= focus then
			Logger.info(LOG, "Translation not inserted: another window has the focus.")
			return false
		end
		ok, committed = pcall(_replace_selection, candidate.to_type)
	else
		if type(_apply_prediction) ~= "function" then return false end
		ok, committed = pcall(_apply_prediction, candidate, _suggestion_context)
	end
	if not ok or committed ~= true then
		Logger.error(LOG, "Prediction acceptance failed: %s", ok and "commit refused" or tostring(committed))
		return false
	end
	if _on_output then
		local observed, observe_err = pcall(_on_output, candidate.to_type, _suggestion_context)
		if not observed then Logger.warn(LOG, "Prediction output observer failed: %s", tostring(observe_err)) end
	end
	clear_offer()
	-- The accepted text is not asked about again until the user types.
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _engine and type(_engine.reset) == "function" then _engine:reset() end
	return true
end

function M.select(index)
	if _runtime_closed or _scope_owner then return false end
	if not _suggestions[tonumber(index)] then return false end
	if _overlay and type(_overlay.select) == "function" then return _overlay.select(tonumber(index)) == true end
	return true
end

--- Whether an offer is on screen: suggestions exist and the tooltip, when this
--- daemon has one, presents them. Its logical state, not its window's: the
--- window maps asynchronously, and the digit must not type meanwhile. Hidden
--- by any path (a pause, a focus change), it presents nothing.
local function offer_visible()
	if #_suggestions == 0 then return false end
	if _overlay and type(_overlay.is_showing) == "function" then return _overlay.is_showing() == true end
	return true
end

-- Step of each arrow through the offered predictions: Up and Left to the
-- previous one, Down and Right to the next, as the shared menu.llm.nav_label
-- (↑/← and ↓/→) and the macOS ARROW_NAVIGATION_DELTA say.
local ARROW_NAVIGATION_DELTA = {
	[EvdevCodes.KEY_UP] = -1,
	[EvdevCodes.KEY_LEFT] = -1,
	[EvdevCodes.KEY_DOWN] = 1,
	[EvdevCodes.KEY_RIGHT] = 1,
}

-- Step of each side of the Shift+Tab chord, as the Windows and macOS tooltip
-- footers say (⇧G + Tab, ⇧D + Tab): the left Shift to the previous prediction,
-- the right one to the next, whatever the navigation modifiers are.
local SHIFT_TAB_NAVIGATION_DELTA = { left = -1, right = 1 }

--- The step of a Shift+Tab chord: Tab with one Shift and no other modifier.
--- @param detail table { code, mods, shift_side }
--- @return integer|nil The step, nil for any other key or chord.
local function shift_tab_step(detail)
	if detail.code ~= EvdevCodes.KEY_TAB then return nil end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	if not mods.shift then return nil end
	for name, held in pairs(mods) do
		if held and name ~= "shift" then return nil end
	end
	return SHIFT_TAB_NAVIGATION_DELTA[detail.shift_side]
end

--- Consumes the chords of the offer on screen: the navigation chord (an arrow
--- with the navigation modifiers, or Shift+Tab on either side) and the
--- validation chord (a digit with the validation modifiers), each exact and
--- bare by default.
---
--- The navigation chord moves the active prediction while several are shown.
--- A digit that numbers a shown prediction is the instruction to insert it,
--- never text, even when the insertion fails. Any other chord, an arrow over a
--- single prediction, and a digit beyond the predictions on offer (5 with
--- three shown) reach the application, as on Windows and macOS
--- (llm-tooltip-chords-consumed).
--- @param detail table { key, code, mods }
--- @return boolean True when the key was the chord and must not reach the app.
function M.handle_shortcut(detail)
	if _runtime_closed or _scope_owner then return false end
	if type(detail) ~= "table" or not offer_visible() then return false end
	local navigation = ARROW_NAVIGATION_DELTA[detail.code]
	if navigation then
		if #_suggestions < 2 or not (_overlay and type(_overlay.move) == "function")
			or not NavigationSettings.matches_navigation(detail.mods) then return false end
		_overlay.move(navigation)
		return true
	end
	local shift_tab = shift_tab_step(detail)
	if shift_tab then
		if #_suggestions < 2 or not (_overlay and type(_overlay.move) == "function") then return false end
		_overlay.move(shift_tab)
		return true
	end
	-- Tab accepts live mode's rewrite or runs the selected agent action, and
	-- only while that tooltip is on screen: another offer, a modified key or no
	-- offer leave Tab to the application.
	local agent_offer = _suggestion_context ~= nil and _suggestion_context.agent ~= nil
	if detail.code == EvdevCodes.KEY_TAB then
		if not (_suggestion_context and (_suggestion_context.live or agent_offer)) then return false end
		for _, held in pairs(type(detail.mods) == "table" and detail.mods or {}) do
			if held then return false end
		end
		local index = 1
		if agent_offer and _overlay and type(_overlay.active_index) == "function" then
			index = tonumber(_overlay.active_index()) or 1
		end
		if not M.accept(index) then
			Logger.warn(LOG, "The offer could not be accepted — Tab is swallowed, nothing typed.")
		end
		return true
	end
	if not NavigationSettings.matches(detail.mods) then return false end
	-- A digit-row key numbers its slot whatever the chord makes it type, so
	-- Shift+1 is slot 1, not "!". Another key typing a digit (the keypad with
	-- NumLock on) numbers the slot of that digit.
	local index = EvdevCodes.DIGIT_ROW_SLOT[detail.code]
	if not index then
		local key = tostring(detail.key or detail.char or "")
		local digit = key:match("^([0-9])$") or key:match("^[Kk][Pp]_?([0-9])$")
		if not digit then return false end
		index = digit == "0" and 10 or tonumber(digit)
	end
	if not _suggestions[index] then return false end
	if not M.accept(index) then
		Logger.warn(LOG, "Prediction %d could not be inserted — the key is swallowed, nothing typed.", index)
	end
	return true
end

function M.has_suggestions() return #_suggestions > 0 end

function M.get_suggestions()
	local copy = {}
	for index, candidate in ipairs(_suggestions) do copy[index] = candidate end
	return copy
end

function M.is_enabled() return _enabled end

--- The real master/backend/scope revision observed by retained display commands.
--- @return integer revision Monotonic native admission revision.
function M.streaming_revision() return _enable_generation end


-- ========================================
-- ======= 6/ Owned Runtime Repair =========
-- ========================================

--- Retires the exact disabled enable ticket while preserving a promoted app lease.
--- @return boolean acknowledged Physical request cleanup has settled.
retire_runtime_request = function()
	local request = _runtime_request
	if not request then return true end
	if request:cancel() ~= true then return false end
	if _runtime_request == request then _runtime_request = nil end
	return _runtime_request == nil
end
--- Revokes the app epoch and retains exact request/service cleanup debt.
--- @return boolean acknowledged Every owned native runtime resource has retired.
stop_runtime_app = function()
	_runtime_app_epoch = _runtime_app_epoch + 1
	local owner = _runtime_owner
	local retired = retire_runtime_request()
	local stopped = not owner or owner.controller:stop_app() == true
	return retired and stopped and _runtime_owner == owner
		and (not owner or not owner.controller:has_debt())
end
--- Stops only this app's Ollama service for pause, scope or app shutdown.
--- @return boolean acknowledged Actual process/group/timer/HTTP retirement.
function M.stop_runtime() return stop_runtime_app() end
--- Permanently revokes this daemon's AI runtime authority before native teardown.
--- @return boolean acknowledged Physical runtime cleanup has settled.
function M.shutdown_runtime()
	_runtime_closed = true
	_enable_generation = _enable_generation + 1
	-- Revoke ordinary probe/download authority before a native stop can reenter.
	local probe_closed = not _enable_admission or _enable_admission.cancel() == true
	local download_closed = M.cancel_model_download() == true
	local runtime_closed = stop_runtime_app()
	return probe_closed and download_closed and runtime_closed
end
--- Reports retained runtime repair or app-service cleanup ownership.
--- @return boolean pending
function M.runtime_pending()
	return (_runtime_request ~= nil and not _runtime_request:is_settled())
		or (_runtime_owner ~= nil and _runtime_owner.controller:has_debt())
end
--- Builds native composition lazily and classifies construction refusal.
--- @return table|nil owner
--- @return string|nil reason
local function runtime_owner()
	if _runtime_owner then return _runtime_owner end
	local engine = { backend_key = BACKEND_KEY }
	--- Captures native lexical revisions after potentially reentrant readers.
	--- @return table state Current engine admission and app lifetime.
	function engine.state()
		local backend, model, origin = M.get_backend(), M.get_current_model(), M.get_base_url()
		local paused = _is_paused()
		return { backend=backend, model=model, origin=origin, revision=_enable_generation,
			app_epoch=_runtime_app_epoch, enabled=_enabled, paused=paused, blocked=_runtime_closed or _scope_owner ~= nil }
	end
	--- Admits a conditional preference publication with final lexical guards.
	--- @param revision integer Originating enable admission revision.
	--- @param app_epoch integer Originating application lifetime.
	--- @param enabled boolean Expected current native enable state.
	--- @param observe_source function Captured source reader ending in cheap owner checks.
	--- @return boolean admitted
	function engine.admit_write(revision, app_epoch, enabled, observe_source)
		local paused = _is_paused()
		if paused or type(observe_source) ~= "function" then return false end
		local observed = observe_source()
		return observed == true and not _runtime_closed and _scope_owner == nil and _enabled == enabled
			and revision == _enable_generation and app_epoch == _runtime_app_epoch
	end
	--- Publishes native enable only after the existing profile writer ACK.
	--- @param revision integer Exact originating engine admission revision.
	--- @param app_epoch integer Exact originating application lifetime.
	--- @return boolean acknowledged
	function engine.publish_enabled(revision, app_epoch)
		local paused = _is_paused()
		if paused or _runtime_closed or _scope_owner or _enabled or revision ~= _enable_generation
			or app_epoch ~= _runtime_app_epoch then return false end
		_enabled = true
		return true
	end
	--- Restores only the originating native gate after conditional profile compensation.
	--- @param revision integer Exact originating native admission revision.
	--- @param app_epoch integer Exact originating application lifetime.
	--- @return boolean acknowledged
	function engine.restore_disabled(revision, app_epoch)
		local paused = _is_paused()
		if paused or _runtime_closed or _scope_owner or revision ~= _enable_generation
			or app_epoch ~= _runtime_app_epoch then return false end
		_enabled = false
		return true
	end
	local ok, owner, reason = pcall(function()
		return require("modules.llm.runtime_factory").new(engine, get_profiles())
	end)
	if ok and owner then
		if _runtime_closed or _scope_owner then return nil, "runtime_cancelled" end
		_runtime_owner = owner
		return owner
	end
	Logger.error(LOG, "Local Ollama runtime construction refused: %s.", tostring(ok and reason or owner))
	return nil, "runtime_composition_unavailable"
end

--- Requests a fresh local receipt before the existing consent owner publishes.
--- API activation does not depend on a local Ollama installation or server.
--- @param on_changed function|nil Menu refresh after acknowledged publication.
--- @return boolean dispatched
function M.enable(on_changed)
	if _runtime_closed or _scope_owner then return false end
	if _enabled then return true end
	if M.runtime_pending() then return false end
	if _enable_admission and _enable_admission.pending() then return false end
	local Preferences = require("infra.llm_preferences")
	local modal_generation_offset = 0
	local function snapshot()
		local values, source = Preferences.get_many({ BACKEND_KEY, "llm.models.ollama", "llm.enabled" })
		local backend = M.get_backend()
		return {
			backend = backend, model = values["llm.models.ollama"], origin = M.get_base_url(),
			generation = Preferences.generation() + _enable_generation
				- modal_generation_offset, source = source,
			enabled = values["llm.enabled"], paused = _is_paused(),
			blocked = _scope_owner ~= nil or not Preferences.admit() or _enabled ~= values["llm.enabled"]
				or (backend == "ollama" and M.get_current_model() ~= values["llm.models.ollama"])
				or _runtime_closed,
		}
	end
	_enable_admission = require("modules.llm.enable_admission").new({
		snapshot = snapshot,
		commit = function(source)
			local revision, app_epoch = _enable_generation, _runtime_app_epoch
			local function admit()
				return not _runtime_closed and _scope_owner == nil and not _enabled
					and revision == _enable_generation and app_epoch == _runtime_app_epoch
			end
			local profiles = get_profiles()
			if not admit() or not profiles or type(profiles.enable) ~= "function"
				or profiles.enable(source, admit) ~= true or not admit() then
				Logger.error(LOG, "Prediction engine enable was not persisted - keeping the current state.")
				return false
			end
			_enabled = true
			Logger.info(LOG, "Prediction engine enabled after current admission.")
			return true
		end,
		reject = function(origin, _, _, captured, current, cleanup_only)
			local Servers = require("modules.llm.local_servers")
			local Entries = require("modules.llm.api_entries")
			local Discovery = require("llm.local_server_discovery")
			local I18n = require("infra.i18n")
			local replacements = {}
			local function current_cached()
				return not cleanup_only and current() and not Servers.is_stale() and not Servers.is_sweeping()
			end
			-- The Models menu owns discovery. A refused enable consumes only its
			-- current cached verdicts, never treating logical publication as proof
			-- that the HTTP owner's process and native handles have retired.
			if current_cached() then
				for _, id in ipairs(Servers.detected()) do
					local verdict = Servers.result(id)
					local server = Servers.servers()[id]
					local model = verdict and verdict.models and verdict.models[1]
					local receipt = verdict and Servers.capture(id)
					if server and verdict and verdict.status == Discovery.STATUS_UP and model
						and receipt and Servers.is_current(receipt, model) then
						local values = { server.label, model,
							require("llm.local_server_menu").host_of(verdict.base_url) }
						replacements[#replacements + 1] = {
							label = (I18n.get("llm.unreachable.use_server"):gsub("{(%d+)}",
								function(index) return tostring(values[tonumber(index)] or "") end)),
							value = { id = id, model = model, receipt = receipt },
						}
					end
				end
			end
			local runtime_choices, runtime_note = {}, nil
			if not cleanup_only and current() and require('llm.runtime_repair').loopback_origin(origin) then
				local runtime = runtime_owner()
				if not runtime then runtime_note = I18n.get("ollama.runtime_repair_failed") end
				local ok, resolved = pcall(function() return runtime and runtime.resolve() end)
				if current() and ok and type(resolved)=='table'
					and (resolved.status=='installed' or resolved.status=='missing') then
					local token={}
					local action=resolved.status=='installed' and 'start' or 'download'
					runtime_choices[token]=action
					replacements[#replacements+1]={value=token,label=I18n.get(action=='download'
						and 'ollama.offer_download' or 'ollama.runtime_start')}
					if action=='download' then runtime_note=I18n.get('ollama.offer_body') end
				end
			end
			local continuation = { claimed = false }
			function continuation.claim()
				if continuation.claimed or not current() then return false end
				continuation.claimed = true
				modal_generation_offset = modal_generation_offset + 1
				return true
			end
			local function modal_observer(stage, receipt)
				if stage == "before" then
					if type(receipt) ~= "table" or receipt.ok ~= true or not current() then return false end
					_enable_modal_resync_owner = continuation
				elseif stage == "after" or stage == "refused" then
					_enable_modal_resync_owner = nil
					if stage == "refused" or type(receipt) ~= "table" or receipt.ok ~= true then return false end
					return current()
				end
				return true
			end
			local shown, _, retry, replacement = pcall(require("ui.llm_enable_refusal").show,
				origin, replacements, modal_observer, runtime_note)
			_enable_modal_resync_owner = nil
			if not shown then
				Logger.error(LOG, "The local AI refusal dialog failed: %s.", tostring(_))
				return nil
			end
			local runtime_action = replacement and runtime_choices[replacement]
			if runtime_action and not cleanup_only and current() then
				if _enable_admission.cancel() ~= true or not current() then return nil end
				local handle=_runtime_owner.source.capture()
				if not handle or not current() then return nil end
				local owner = _runtime_owner
				-- Reserve teardown admission before any constructor can reenter.
				-- This frame never acknowledges an unknown/unfinished acquisition.
				local frame = { acquiring = true, cancelled = false, epoch = _runtime_app_epoch }
				function frame:is_settled()
					if self.acquiring or not self.operation or not self.settled then return false end
					local called, settled = pcall(self.settled, self.operation)
					return called and settled == true
				end
				function frame:cancel()
					self.cancelled = true
					if self.acquiring or not self.operation or not self.retire then return false end
					local called, retired = pcall(self.retire, self.operation)
					return called and retired == true and self:is_settled()
				end
				_runtime_request = frame
				local called, request = pcall(owner.controller.start, owner.controller, handle, runtime_action, true, function(result)
					if type(result) == "table" and result.ok == true and not frame.cancelled
						and _runtime_request == frame and _runtime_owner == owner
						and frame.epoch == _runtime_app_epoch and type(on_changed) == "function" then on_changed() end
				end)
				frame.acquiring = false
				if not called or type(request) ~= "table" or type(request.cancel) ~= "function"
					or type(request.is_settled) ~= "function" or type(request.on_result) ~= "function" then
					Logger.error(LOG, "Local Ollama repair construction is unknown; its exact acquisition frame remains retained.")
					return nil
				end
				frame.operation, frame.retire, frame.settled = request, request.cancel, request.is_settled
				if frame.cancelled or frame.epoch ~= _runtime_app_epoch or _runtime_owner ~= owner then frame:cancel() end
				request:on_result(function(result)
					if type(result) ~= "table" or result.ok ~= false or result.error == "runtime_cancelled" then return end
					Logger.error(LOG, "Local Ollama repair refused; its native cleanup owner remains retained until acknowledgment: %s.", tostring(result.error))
					if owner.source.diagnostic_current(handle) then
						local delivered = require("adapters.notifier").send(I18n.get("ollama.runtime_repair_failed"), {
							title = I18n.get("ollama.fail_title"), level = "error",
						})
						if delivered ~= true then Logger.warn(LOG, "The local Ollama failure notice was not delivered.") end
					end
				end)
				return nil
			end
			if replacement and current_cached() then
				local selection_revision = _enable_generation
				local preference_revision = Preferences.generation()
				local result = Servers.apply(replacement.receipt, { model = replacement.model }, current_cached)
				if not result or not result.saved or not result.entry then return nil end
				local source = Entries.capture_source()
				local function selection_current(phase)
					local values, live_source = Preferences.get_many({ BACKEND_KEY, "llm.models.ollama", "llm.enabled" })
					local active = Entries.active()
					-- Only the backend owner's second admission observes its one revision
					-- advance. A reset or preference rewrite during dismissal cannot borrow
					-- that advance, even when the resulting source bytes happen to match.
					local expected_revision = selection_revision + (phase == "after" and 1 or 0)
					return not _is_paused() and M.can_configure_local_servers() and not _enabled
						and _enable_generation == expected_revision and Preferences.generation() == preference_revision
						and values["llm.enabled"] == false and values[BACKEND_KEY] == captured.backend
						and values["llm.models.ollama"] == captured.model
						and live_source.status == captured.source.status and live_source.content == captured.source.content
						and source ~= nil and Entries.source_is_current(source)
						and active ~= nil and active.id == result.entry.id and active.model == replacement.model
				end
				if selection_current() and M.set_backend("api", selection_current) == true then
					if M.enable() ~= true then
						Logger.warn(LOG, "The replacement backend was selected; AI enable was refused.")
					end
				else
					Logger.warn(LOG, "The replacement server was saved; its backend selection was refused.")
				end
				if type(on_changed) == "function" then on_changed() end
			end
			return retry == true and "retry" or nil
		end,
		changed = on_changed,
	})
	local dispatched = _enable_admission.enable()
	-- A refused synchronous probe can open the repair dialog before returning.
	-- Its explicit replacement may already have acknowledged API enable through
	-- the same preference owner; report that actual enabled state to the caller.
	return dispatched == true or _enabled == true
end

function M.disable()
	if _runtime_closed or _scope_owner then return false end
	if not retire_runtime_request() then return false end
	_enable_generation = _enable_generation + 1
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	local profiles = get_profiles()
	if not profiles or type(profiles.disable) ~= "function" or profiles.disable() ~= true then
		Logger.error(LOG, "Prediction engine disable was not persisted - keeping the current state.")
		return false
	end
	_enabled = false
	M.stop_live("AI switched off", false)
	M.cancel()
	Logger.info(LOG, "Prediction engine disabled.")
	return true
end

function M.toggle(on_changed)
	if _enabled or (_enable_admission and _enable_admission.pending()) then return M.disable() end
	return M.enable(on_changed)
end

function M.is_predicting() return _predicting or _pending_trigger ~= nil end
function M.get_trigger_setting(name) return TriggerSettings.get(name) end
function M.set_trigger_setting(name, value) return TriggerSettings.set(name, value) end
function M.get_triggers() return _triggers end

function M.set_triggers(triggers)
	if _runtime_closed or _scope_owner then return false end
	if type(triggers) ~= "table" then return false end
	local accepted = {}
	for _, trigger in ipairs(triggers) do
		if type(trigger) == "string" and trigger ~= "" then accepted[#accepted + 1] = trigger end
	end
	if #accepted == 0 then return false end
	_triggers = accepted
	Logger.info(LOG, "Triggers: %d configured.", #_triggers)
	return true
end

--- Whether a stored backend choice is one this build runs.
--- @param kind any
--- @return boolean
function M.is_backend(kind)
	return BACKENDS[kind] == true
end

--- The selected backend: "ollama" or "api". A stored backend this build no
--- longer runs (a retired provider id) is an outdated entry: warned once and
--- read as the manifest default, never a raise on the menu or typing path.
--- @return string
function M.get_backend()
	local value = require("infra.llm_preferences").get(BACKEND_KEY)
	if value ~= nil and not BACKENDS[value] then
		-- The cleanup's spelling (mark_config_read), so the entry is named once.
		ConfigOutdated.report(BACKEND_KEY, ConfigOutdated.REFUSED, Logger)
		value = nil
	end
	if value == nil then value = require("infra.manifest_reader").default_for(BACKEND_KEY) end
	assert(BACKENDS[value], "the manifest default prediction backend is not one this build runs")
	return value
end

--- Current admission for local-server configuration, including master OFF.
--- The existing preference transaction owns the backend mutation separately.
--- @return boolean
function M.can_configure_local_servers()
	local paused = _is_paused()
	return not paused and _scope_owner == nil and not _runtime_closed
end

--- Selects the backend.
--- @param kind string "ollama" or "api"
--- @param admit function|nil Receives "before" or "after" the owner's revision advance.
--- @return boolean
function M.set_backend(kind, admit)
	local function admitted(phase)
		if admit == nil then return true end
		if type(admit) ~= "function" then return false end
		local ok, value = pcall(admit, phase)
		return ok and value == true
	end
	local initial_revision, initial_epoch = _enable_generation, _runtime_app_epoch
	if _runtime_closed or _scope_owner or not admitted("before") then return false end
	if _runtime_closed or _scope_owner or initial_revision ~= _enable_generation
		or initial_epoch ~= _runtime_app_epoch then return false end
	if not BACKENDS[kind] then return false end
	if not retire_runtime_request() then return false end
	if kind ~= M.get_backend() and not stop_runtime_app() then return false end
	_enable_generation = _enable_generation + 1
	local revision, app_epoch = _enable_generation, _runtime_app_epoch
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	M.dismiss()
	if _runtime_closed or _scope_owner or not admitted("after") then return false end
	local function current()
		return not _runtime_closed and _scope_owner == nil
			and revision == _enable_generation and app_epoch == _runtime_app_epoch
	end
	if not current() then return false end
	if require("infra.llm_preferences").set_many({ [BACKEND_KEY] = kind }, nil, current) ~= true
		or not current() then return false end
	Logger.info(LOG, "Prediction backend set to '%s'.", kind)
	return true
end

--- The module, target and model a prediction would be sent with.
--- @param quiet boolean Do not log why the backend cannot answer.
--- @return table|nil backend, any target, string|nil model
local function backend_target(quiet)
	local function refuse(...)
		if not quiet then Logger.warn(LOG, ...) end
		return nil
	end
	if M.get_backend() == "api" then
		local remote, entries = get_remote(), get_api_entries()
		local entry = entries and entries.active() or nil
		if not remote or not entry then
			return refuse("predict(): the API backend is selected but no API entry is — add one in the AI menu.")
		end
		local provider = remote.provider(entry.provider)
		if provider and not remote.serves(entry.provider, "chat") then
			return refuse("predict(): API entry '%s' is no chat model (the agent's System 1 only).", entry.id)
		end
		local model = entry.model ~= "" and entry.model or (provider and provider.default_model) or nil
		if not model or model == "" then return refuse("predict(): API entry '%s' names no model.", entry.id) end
		return remote, entry, model
	end
	local ollama, profiles = get_ollama(), get_profiles()
	local model = profiles and profiles.get_current_model()
	if not ollama then return refuse("predict(): Ollama API not available.") end
	if not model then return refuse("predict(): No model selected - run Ollama and refresh models.") end
	return ollama, profiles.get_base_url() or HttpBridge.resolve_base_url() or "", model
end

--- The module, target and model a prediction is sent with, or nil when the
--- selected backend cannot answer (reason logged).
--- @return table|nil backend, any target, string|nil model
function M.resolve_backend()
	return backend_target(false)
end

--- The model the next prediction goes to, whichever backend serves it. The
--- menu resolves the automatic profile against it: resolving against the
--- Ollama model while an API answered showed one profile and used another.
--- @return string|nil
function M.get_prediction_model()
	local _, _, model = backend_target(true)
	return model
end

function M.get_models()
	local profiles = get_profiles()
	return profiles and type(profiles.get_models) == "function" and profiles.get_models() or {}
end

function M.get_current_model()
	local profiles = get_profiles()
	return profiles and type(profiles.get_current_model) == "function" and profiles.get_current_model() or nil
end

function M.set_model(model_name)
	if _runtime_closed or _scope_owner then return false end
	if not retire_runtime_request() then return false end
	_enable_generation = _enable_generation + 1
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	local revision, app_epoch = _enable_generation, _runtime_app_epoch
	local function current()
		return not _runtime_closed and _scope_owner == nil
			and revision == _enable_generation and app_epoch == _runtime_app_epoch
	end
	local _, source = require("infra.llm_preferences").get_many({ "llm.models.ollama" })
	local profiles = get_profiles()
	return current() and profiles and type(profiles.set_model) == "function"
		and profiles.set_model(model_name, source, current) == true and current() or false
end

function M.refresh_models()
	if _runtime_closed or _scope_owner then return false end
	local profiles = get_profiles()
	if profiles and type(profiles.refresh_models) == "function" then return profiles.refresh_models() end
	return nil
end

function M.get_base_url()
	local profiles = get_profiles()
	return profiles and type(profiles.get_base_url) == "function" and profiles.get_base_url() or nil
end

--- Downloads one Ollama model asynchronously, then selects the installed tag.
--- @param model_tag string
--- @param label string
--- @param on_done function|nil
--- @return boolean
function M.download_model(model_tag, label, on_done)
	if _runtime_closed or _scope_owner then return false end
	local revision, app_epoch = _enable_generation, _runtime_app_epoch
	local function current()
		return not _runtime_closed and _scope_owner == nil
			and revision == _enable_generation and app_epoch == _runtime_app_epoch
	end
	local base_url = M.get_base_url()
	local ok_download, Download = pcall(require, "modules.llm.model_download")
	if not current() or not base_url or not ok_download or type(Download.start) ~= "function" then return false end
	return Download.start(base_url, model_tag, label, function(succeeded, tag)
		if not current() then return end
		if succeeded then
			M.refresh_models()
			if not M.set_model(tag) then succeeded = false end
		end
		if _runtime_closed or _scope_owner then return end
		if type(on_done) == "function" then on_done(succeeded, tag) end
	end, current)
end

--- Cancels a model pull owned by this engine.
--- @return boolean
function M.cancel_model_download()
	local ok_download, Download = pcall(require, "modules.llm.model_download")
	return not ok_download or type(Download.shutdown) ~= "function" or Download.shutdown() == true
end

function M.get_max_tokens() return _max_tokens or PromptBuilder.DEFAULT_MAX_TOKENS end

function M.set_max_tokens(value)
	local tokens = tonumber(value)
	if not tokens or tokens < 1 then return false end
	_max_tokens = math.floor(tokens)
	return true
end

function M.get_temperature()
	return Settings.get("temperature") or HttpBridge.DEFAULT_TEMPERATURE
end

function M.set_temperature(value) return Settings.set("temperature", tonumber(value)) end
function M.get_max_context() return max_context_chars() end

function M.set_max_context(value)
	return Settings.set("context_length", value)
end

function M.get_stop_sequences() return {} end

--- Compatibility query retained for UI bridges: Linux suggestions are explicit.
function M.is_auto_inject() return false end

--- Acquires the prediction gate before scope cancellation or publication.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire_configuration(owner)
	if _runtime_closed or _scope_owner or type(owner) ~= "table" then return false end
	_scope_owner = owner
	_runtime_app_epoch = _runtime_app_epoch + 1
	_enable_generation = _enable_generation + 1
	return true
end

--- Releases only the settled transaction's prediction admission.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release_configuration(owner)
	if _scope_owner ~= owner or owner.pending() then return false end
	_scope_owner = nil
	return true
end

--- Cancels native work before taking a reversible preference snapshot.
--- Completed cancellations are intentionally not replayed: a remote prompt may
--- already have been billed. Refusals retain ownership for an explicit retry.
--- @param owner table Admission identity.
--- @return boolean quiescent
function M.quiesce_configuration(owner)
	if _scope_owner ~= owner then return false end
	if not stop_runtime_app() then return false end
	if _enable_admission and _enable_admission.cancel() ~= true then return false end
	if _pending_trigger then
		if _scheduler.cancel(_pending_trigger) ~= true then return false end
		_pending_trigger = nil
	end
	if _rate_timer then
		if _scheduler.cancel(_rate_timer) ~= true then return false end
		_rate_timer = nil
	end
	if _tone_timer then
		if _scheduler.cancel(_tone_timer) ~= true then return false end
		_tone_timer = nil
	end
	_tone_generation = _tone_generation + 1
	M.drop_vision("configuration change")
	M.drop_agent_triage("configuration change")
	-- Backend connectivity probes share these owners, even when the prediction
	-- engine did not start them. Model downloads have a separate HTTP owner.
	local backends = { get_ollama(), get_remote() }
	if #backends ~= 2 then return false end
	for _, backend in ipairs(backends) do if backend.cancel() ~= true then return false end end
	_inflight_backend = nil
	advance_request_epoch()
	_predicting = false
	if _overlay and _overlay.hide() ~= true then return false end
	_suggestions, _suggestion_context, _offer_notified = {}, nil, false
	return true
end

--- Captures only a quiescent gate; cancelled external work is not reversible.
--- @param owner table Admission identity.
--- @return table|nil snapshot
function M.configuration_snapshot(owner)
	if _scope_owner ~= owner or _predicting or _pending_trigger or _rate_timer or _tone_timer
		or _inflight_backend or _vision_flow or _agent_timer or _agent_triage
		or (_enable_admission and _enable_admission.pending()) or M.runtime_pending() then return nil end
	return { enabled = _enabled }
end

--- Applies the desired prediction gate without inference or buffer edits.
--- @param owner table Admission identity.
--- @param snapshot table Desired enabled state.
--- @return boolean applied
function M.apply_configuration(owner, snapshot)
	if _runtime_closed or _scope_owner ~= owner or type(snapshot.enabled) ~= "boolean" then return false end
	if not M.quiesce_configuration(owner) then return false end
	_enabled = snapshot.enabled
	if not _enabled then M.stop_live("AI switched off", false) end
	return _enabled == snapshot.enabled
end

return M
