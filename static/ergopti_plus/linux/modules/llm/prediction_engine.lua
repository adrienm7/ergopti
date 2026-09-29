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
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local HttpBridge = require("infra.llm_bridge")
local PromptBuilder = require("llm.prompt_builder")
local ProfileSelector = require("llm.profile_selector")
local Parser = require("llm.parser")
local Rewrite = require("llm.rewrite")
local PromptAction = require("llm.prompt_action")
local Tone = require("llm.tone")
local Vision = require("llm.vision")
local Settings = require("modules.llm.settings")
local TriggerSettings = require("modules.llm.trigger_settings")
local DisplaySettings = require("modules.llm.display_settings")
local ProfileSettings = require("modules.llm.profile_settings")
local VisionRequest = require("modules.llm.vision_request")
local NavigationSettings = require("modules.llm.navigation_settings")
local TimerScheduler = require("adapters.timer_scheduler")
local Inference = require("modules.llm.inference")
local Monotonic = require("infra.monotonic")
local i18n = require("infra.i18n")
local Base64 = require("compat.base64")

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

-- The screen actions, each with the capture mode it runs, and their notices
local VISION_ACTIONS = { llm_screen_region = "region", llm_screen_full = "full" }
local VISION_NO_MODEL_KEY = "llm.vision.no_model"
local VISION_READ_FAILED_KEY = "llm.vision.read_failed"
local VISION_CAPTURE_FAILED_KEY = "llm.vision.capture_failed"

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

local function schedule(context, output_context, delay_ms, reason)
	if type(context) ~= "string" or context == "" then return false end
	if _pending_trigger then _scheduler.cancel(_pending_trigger) end
	local captured = {
		app_id = type(output_context) == "table" and output_context.app_id or nil,
		input_chars = type(output_context) == "table" and output_context.input_chars or 0,
	}
	local handle = _scheduler.after(math.max(0, tonumber(delay_ms) or 0) / 1000, function()
		if _scope_owner then return end
		_pending_trigger = nil
		M.predict(context, captured)
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

--- Initialises the engine and its explicit side-effect seams.
--- @param opts table|nil
function M.init(opts)
	if _scope_owner then return false end
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
	M.drop_vision("engine initialised")
	if _tone_timer then _scheduler.cancel(_tone_timer) end
	_tone_timer = nil
	_tone_generation = _tone_generation + 1
	_tone_memory = nil
	_offer_notified = false
	if type(options.triggers) == "table" then _triggers = options.triggers end
	if _pending_trigger then _scheduler.cancel(_pending_trigger) end
	_scheduler = type(options.scheduler) == "table" and options.scheduler or TimerScheduler
	-- The pacing clock must be the scheduler's: a test's virtual timers would
	-- otherwise be measured against real time.
	_clock_ms = type(options.clock_ms) == "function" and options.clock_ms or Monotonic.now_ms
	_last_request_ms = {}
	_pending_trigger = nil
	_request_epoch = _request_epoch + 1
	_predicting = false
	clear_offer()

	local profiles = get_profiles()
	if profiles then
		profiles.init({ port = HttpBridge.OLLAMA_DEFAULT_PORT })
		if type(profiles.is_enabled) == "function" then _enabled = profiles.is_enabled() end
	end
	Logger.success(LOG, "Prediction engine initialised (triggers=%d, max_context=%d).",
		#_triggers, max_context_chars())
end

--- Processes one physical character after the hotstring buffer recorded it.
function M.on_char(ch, buffer, output_context)
	if _scope_owner then return false end
	if not _enabled then return end
	if type(ch) ~= "string" or type(buffer) ~= "string" then return end
	-- Typing replaced the selection a tone step was about to rewrite.
	M.drop_tone("typing")
	-- The user went on typing: the screen answers would be dismissed at once.
	M.drop_vision("typing")
	if _predicting or #_suggestions > 0 then M.dismiss() end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	for _, trigger in ipairs(_triggers) do
		if buffer:sub(-#trigger) == trigger then
			local delay_ms = TriggerSettings.get("debounce_ms")
			schedule(buffer, {
				app_id = type(output_context) == "table" and output_context.app_id or nil,
				input_chars = #trigger,
			}, delay_ms, "Explicit-trigger")
			return
		end
	end
	if type(output_context) == "table" and output_context.hotstring_preview_visible == true
		and TriggerSettings.get("after_hotstring") == true then return end
	local immediate = TriggerSettings.get("instant_on_word_end") == true and ends_word(buffer, ch)
	schedule(buffer, output_context, immediate and 0 or TriggerSettings.get("debounce_ms"),
		immediate and "Word-end" or "Inactivity")
end

--- Fires immediately after the current hotstring preview expires.
--- @param context string
--- @param output_context table|nil
--- @return boolean
function M.on_hotstring_expired(context, output_context)
	if _scope_owner then return false end
	if not _enabled or TriggerSettings.get("after_hotstring") ~= true then return false end
	if _predicting or #_suggestions > 0 then M.dismiss() end
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
	if tostring(profile.id):match("^user_") and type(profile.label) == "string" and profile.label ~= "" then
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
--- @param override table|nil { profile, num_predictions? } for a request that
---   names its own prompt: that profile and count, instead of the menu's
---   profile (and its automatic choice) and count, which stay unchanged.
--- @return string|nil refusal A MANUAL_REFUSAL_KEYS reason the user should be
---   told, when the request was refused for one.
function M.predict(context, output_context, override)
	if _scope_owner then return false end
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
		min_words = Settings.get("min_words"),
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
	}
	_offer_notified = false
	_predicting = true
	_request_epoch = _request_epoch + 1
	local epoch = _request_epoch
	show_candidates({}, meta)
	Logger.info(LOG, "Sending prediction request (backend=%s, model=%s, profile=%s, count=%d, context=%d chars).",
		M.get_backend(), model, tostring(profile.id), requested, #params.context)

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
		if _scope_owner or epoch ~= _request_epoch then return end
		local kind = M.get_backend()
		local now = _clock_ms()
		local wait_ms = (_last_request_ms[kind] or -math.huge) + Inference.min_interval_ms(kind) - now
		if wait_ms > 0 then
			_rate_timer = _scheduler.after(wait_ms / 1000, function()
				if _scope_owner then return end
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
			if _scope_owner or epoch ~= _request_epoch then return end
			streamed = streamed .. think_filter:feed(delta)
			if DisplaySettings.get("streaming") ~= true then return end
			if requested > 1 and DisplaySettings.get("streaming_multi") ~= true then return end
			local partials = parse_response(streamed, is_batch, trigger_chars)
			publish(partials[#partials])
		end, function(full_text, err)
			if _scope_owner or epoch ~= _request_epoch then return end
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
				if #candidates > 0 then publish() end
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
	if _scope_owner then return false end
	local reason, context = manual_refusal()
	if reason then
		Logger.info(LOG, "Manual prediction refused (%s).", reason)
		show_notice(MANUAL_REFUSAL_KEYS[reason], reason)
		return false
	end
	local override = nil
	if prompt then
		-- By exact id: a deleted prompt is refused, never replaced by another.
		local profile = ProfileSettings.resolve_id(prompt.profile_id)
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
	if _scope_owner then return false end
	local prompt, err = PromptAction.parse(value)
	if not prompt then
		Logger.warn(LOG, "Prompt prediction refused: invalid parameter '%s' (%s).", tostring(value), err)
		return false
	end
	return run_manual(output_context, prompt)
end

--- The catalogue actions this engine answers, for the gesture executor's
--- daemon-injected handlers (modules/shortcuts/action_handlers.lua). The
--- presets follow the built-in profiles, so a new profile needs no code here.
--- @return table { [action_id] = function(binding, parameter) }
function M.action_handlers()
	local handlers = {
		llm_generate_prediction = function() return M.trigger_now() end,
		llm_prompt_prediction = function(_, parameter) return M.trigger_prompt(parameter) end,
	}
	for _, profile in ipairs(ProfileSettings.list_built_in()) do
		local value = PromptAction.format(profile.id)
		handlers[PRESET_ACTION_PREFIX .. profile.id] = function() return M.trigger_prompt(value) end
	end
	for action, mode in pairs(VISION_ACTIONS) do
		handlers[action] = function(_, parameter) return M.read_screen(mode, parameter) end
	end
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
	if _scope_owner then return end
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
	if _scope_owner then return false end
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
		temperature = Settings.get("temperature"),
		max_tokens = Rewrite.max_tokens(plan.source),
		line_mode = true,
	}
	Logger.info(LOG, "Sending tone rewrite (backend=%s, model=%s, profile=%s, %d byte(s)).",
		M.get_backend(), model, plan.profile_id, #plan.source)

	local send
	send = function()
		if _scope_owner or generation ~= _tone_generation then return end
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

--- Asks the AI menu's text backend for each answer of vision.json in turn and
--- offers them as the tooltip's candidates, in that order. Accepting one types
--- it at the caret; nothing is typed otherwise.
--- @param spec table The screen action's request (read_screen).
--- @param screen string The vision model's transcription.
local function request_screen_answers(spec, screen)
	local config = spec.config
	local backend, target, model = M.resolve_backend()
	if not backend then
		clear_offer()
		show_notice(MANUAL_REFUSAL_KEYS.backend_not_ready, "backend_not_ready")
		return
	end
	-- The backends serve one request at a time.
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	if _predicting then M.dismiss() end

	local language = prompt_language()
	local candidates = {}
	local index = 0
	local meta = {
		model = model,
		profile = spec.label,
		loading = true,
		validation_modifiers = NavigationSettings.get(),
	}
	_suggestion_context = { app_id = nil, input_chars = 0, model = model, profile = spec.action }
	_offer_notified = false
	_predicting = true
	_request_epoch = _request_epoch + 1
	local epoch = _request_epoch
	show_candidates({}, meta)
	Logger.info(LOG, "Requesting %d screen answer(s) (backend=%s, model=%s).", #config.answers, M.get_backend(), model)

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
		Logger.info(LOG, "Screen answers on offer: %d of %d.", #candidates, #config.answers)
		publish()
	end

	local dispatch
	dispatch = function()
		if _scope_owner or epoch ~= _request_epoch then return end
		local kind = M.get_backend()
		local now = _clock_ms()
		local wait_ms = (_last_request_ms[kind] or -math.huge) + Inference.min_interval_ms(kind) - now
		if wait_ms > 0 then
			_rate_timer = _scheduler.after(wait_ms / 1000, function()
				if _scope_owner then return end
				_rate_timer = nil
				dispatch()
			end)
			if type(_rate_timer) ~= "table" or _rate_timer.armed ~= true then
				_rate_timer = nil
				Logger.error(LOG, "Screen answers could not be paced: timer unavailable.")
				settle()
			end
			return
		end
		_last_request_ms[kind] = now
		index = index + 1
		local answer = config.answers[index]
		local messages = {
			{ role = "system", content = Vision.fill_language(answer.prompt, language) },
			{ role = "user", content = Vision.answer_user_text(screen) },
		}
		_inflight_backend = backend
		backend.chat(target, model, messages, {
			stream = false,
			temperature = Settings.get("temperature"),
			max_tokens = config.answer_max_tokens,
			-- Multi-line answers: the single-line stops would cut them.
			line_mode = false,
		}, nil, function(full_text, err)
			if _scope_owner then return end
			if epoch ~= _request_epoch then
				Logger.info(LOG, "Screen answer '%s' ignored: a newer action or an edit superseded it.", answer.id)
				return
			end
			if err then
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
			if index < #config.answers then
				-- Shown now: the next answer may wait for the backend's interval.
				if #candidates > 0 then publish() end
				dispatch()
				return
			end
			settle()
		end)
	end
	dispatch()
end

--- Reads the vision model's transcription and asks for the answers.
--- @param flow table The screen flow.
--- @param spec table The screen action's request.
--- @param text string|nil The vision model's answer.
--- @param err string|nil The transport's or the provider's error.
local function finish_screen_read(flow, spec, text, err)
	if _scope_owner then return end
	if not vision_current(flow) then
		Logger.info(LOG, "Screen transcription ignored: a newer action or an edit superseded it.")
		return
	end
	_vision_flow = nil
	flow.reading = false
	if err then
		Logger.warn(LOG, "Vision request failed: %s", tostring(err))
		clear_offer()
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
	if _scope_owner or not vision_current(flow) then
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

--- Answers what is on the screen: the llm_screen_region and llm_screen_full
--- actions. A vision model transcribes a private screenshot, then the AI menu's
--- text backend drafts the answers of vision.json, offered in the tooltip.
--- A new screen action supersedes the one in flight.
--- @param mode string "region" (the user draws it) or "full".
--- @param value string The binding's parameter, "<backend>" or "<backend>|<model>".
--- @return boolean started True when the capture was started.
function M.read_screen(mode, value)
	if _scope_owner then return false end
	local action = nil
	for id, action_mode in pairs(VISION_ACTIONS) do
		if action_mode == mode then action = id end
	end
	if not action then error("read_screen: mode must be \"region\" or \"full\"") end
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
	}
	local flow = { generation = _vision_generation }
	_vision_flow = flow
	Logger.info(LOG, "Screen reading requested (mode=%s, backend=%s, model=%s).", mode, parsed.backend, model)
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

--- Cancels pending and in-flight work and shows nothing, leaving the hotstring
--- buffer alone. For edits the caller has already applied to that buffer:
--- Backspace and Escape update it precisely, and a reset here undid the edit.
function M.withdraw()
	if _scope_owner then return false end
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	-- Backspace, Escape, a desync or a blocked capture: the selection a tone
	-- step was about to rewrite may be gone, and Escape cancels a screen action.
	M.drop_tone("withdrawn")
	M.drop_vision("withdrawn")
	M.dismiss()
end

--- Cancels pending/in-flight work and discards the current engine buffer.
function M.cancel()
	if _scope_owner then return false end
	M.withdraw()
	if _engine and type(_engine.reset) == "function" then _engine:reset() end
end

--- Dismisses in-flight and visible suggestions without changing the buffer.
function M.dismiss()
	if _scope_owner then return false end
	_request_epoch = _request_epoch + 1
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
	if _scope_owner then return false end
	local candidate = _suggestions[tonumber(index)]
	if not candidate or type(_apply_prediction) ~= "function" then return false end
	local ok, committed = pcall(_apply_prediction, candidate, _suggestion_context)
	if not ok or committed ~= true then
		Logger.error(LOG, "Prediction acceptance failed: %s", ok and "commit refused" or tostring(committed))
		return false
	end
	if _on_output then
		local observed, observe_err = pcall(_on_output, candidate.to_type, _suggestion_context)
		if not observed then Logger.warn(LOG, "Prediction output observer failed: %s", tostring(observe_err)) end
	end
	clear_offer()
	if _engine and type(_engine.reset) == "function" then _engine:reset() end
	return true
end

function M.select(index)
	if _scope_owner then return false end
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

--- Consumes the validation chord (a digit, with the configured modifiers —
--- none by default) while an offer is on screen.
---
--- A digit that numbers a shown prediction is the instruction to insert it,
--- never text, even when the insertion fails. A digit beyond the predictions
--- on offer (5 with three shown) is text and reaches the application, as on
--- Windows and macOS.
--- @param detail table { key, mods }
--- @return boolean True when the key was the chord and must not reach the app.
function M.handle_shortcut(detail)
	if _scope_owner then return false end
	if type(detail) ~= "table" or not offer_visible() then return false end
	if not NavigationSettings.matches(detail.mods) then return false end
	local key = tostring(detail.key or detail.char or "")
	local digit = key:match("^([0-9])$") or key:match("^[Kk][Pp]_?([0-9])$")
	if not digit then return false end
	local index = digit == "0" and 10 or tonumber(digit)
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

function M.enable()
	if _scope_owner then return false end
	local profiles = get_profiles()
	if not profiles or type(profiles.enable) ~= "function" or profiles.enable() ~= true then
		Logger.error(LOG, "Prediction engine enable was not persisted - keeping the current state.")
		return false
	end
	_enabled = true
	Logger.info(LOG, "Prediction engine enabled.")
	return true
end

function M.disable()
	if _scope_owner then return false end
	local profiles = get_profiles()
	if not profiles or type(profiles.disable) ~= "function" or profiles.disable() ~= true then
		Logger.error(LOG, "Prediction engine disable was not persisted - keeping the current state.")
		return false
	end
	_enabled = false
	M.cancel()
	Logger.info(LOG, "Prediction engine disabled.")
	return true
end

function M.toggle()
	if _enabled then return M.disable() end
	return M.enable()
end

function M.is_predicting() return _predicting or _pending_trigger ~= nil end
function M.get_trigger_setting(name) return TriggerSettings.get(name) end
function M.set_trigger_setting(name, value) return TriggerSettings.set(name, value) end
function M.get_triggers() return _triggers end

function M.set_triggers(triggers)
	if _scope_owner then return false end
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

--- The selected backend: "ollama" or "api".
--- @return string
function M.get_backend()
	local value = require("infra.llm_preferences").get(BACKEND_KEY)
	if value == nil then value = require("infra.manifest_reader").default_for(BACKEND_KEY) end
	assert(BACKENDS[value], "invalid configured prediction backend")
	return value
end

--- Selects the backend.
--- @param kind string "ollama" or "api"
--- @return boolean
function M.set_backend(kind)
	if _scope_owner then return false end
	if not BACKENDS[kind] then return false end
	M.dismiss()
	if require("infra.llm_preferences").set(BACKEND_KEY, kind) ~= true then return false end
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
		local model = entry.model ~= "" and entry.model or (provider and provider.default_model) or nil
		if not model or model == "" then return refuse("predict(): API entry '%s' names no model.", entry.label) end
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
	local profiles = get_profiles()
	return profiles and type(profiles.set_model) == "function" and profiles.set_model(model_name) == true or false
end

function M.refresh_models()
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
	local base_url = M.get_base_url()
	local ok_download, Download = pcall(require, "modules.llm.model_download")
	if not base_url or not ok_download or type(Download.start) ~= "function" then return false end
	return Download.start(base_url, model_tag, label, function(succeeded, tag)
		if succeeded then
			M.refresh_models()
			if not M.set_model(tag) then succeeded = false end
		end
		if type(on_done) == "function" then on_done(succeeded, tag) end
	end)
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
	if _scope_owner or type(owner) ~= "table" then return false end
	_scope_owner = owner
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
	-- Backend connectivity probes share these owners, even when the prediction
	-- engine did not start them. Model downloads have a separate HTTP owner.
	local backends = { get_ollama(), get_remote() }
	if #backends ~= 2 then return false end
	for _, backend in ipairs(backends) do if backend.cancel() ~= true then return false end end
	_inflight_backend = nil
	_request_epoch = _request_epoch + 1
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
		or _inflight_backend or _vision_flow then return nil end
	return { enabled = _enabled }
end

--- Applies the desired prediction gate without inference or buffer edits.
--- @param owner table Admission identity.
--- @param snapshot table Desired enabled state.
--- @return boolean applied
function M.apply_configuration(owner, snapshot)
	if _scope_owner ~= owner or type(snapshot.enabled) ~= "boolean" then return false end
	if not M.quiesce_configuration(owner) then return false end
	_enabled = snapshot.enabled
	return _enabled == snapshot.enabled
end

return M
