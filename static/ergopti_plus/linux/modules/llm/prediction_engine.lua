--- modules/llm/prediction_engine.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine (Linux)
--- DESCRIPTION:
--- Debounces ordinary typing, handles explicit and word-end triggers, applies
--- privacy gates, and presents parsed Ollama completions for an explicit user
--- commit. Model output never reaches the focused application before acceptance.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local HttpBridge = require("infra.llm_bridge")
local PromptBuilder = require("llm.prompt_builder")
local ProfileSelector = require("llm.profile_selector")
local Parser = require("llm.parser")
local Settings = require("modules.llm.settings")
local TriggerSettings = require("modules.llm.trigger_settings")
local DisplaySettings = require("modules.llm.display_settings")
local ProfileSettings = require("modules.llm.profile_settings")
local NavigationSettings = require("modules.llm.navigation_settings")
local TimerScheduler = require("adapters.timer_scheduler")

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
local _max_context_chars = nil
local _max_tokens = nil
local _request_epoch = 0

local function get_ollama()
	local ok, module = pcall(require, "modules.llm.api_ollama")
	return ok and module or nil
end

local function get_profiles()
	local ok, module = pcall(require, "modules.llm.profiles")
	return ok and module or nil
end

local function get_secure_field_detector()
	local ok, module = pcall(require, "adapters.secure_field_detector")
	return ok and module or nil
end

local function max_context_chars()
	return _max_context_chars
		or Settings.get("context_length")
		or HttpBridge.DEFAULT_CONTEXT_LENGTH
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
	_pending_trigger = _scheduler.after(math.max(0, tonumber(delay_ms) or 0) / 1000, function()
		_pending_trigger = nil
		M.predict(context, captured)
	end)
	Logger.debug(LOG, "%s prediction scheduled in %d ms.", reason, math.max(0, tonumber(delay_ms) or 0))
	return _pending_trigger ~= nil
end

--- Initialises the engine and its explicit side-effect seams.
--- @param opts table|nil
function M.init(opts)
	local options = type(opts) == "table" and opts or {}
	_engine = options.engine
	_keyboard_hook = options.keyboard_hook
	_overlay = type(options.overlay) == "table" and options.overlay or nil
	_apply_prediction = type(options.apply_prediction) == "function" and options.apply_prediction or nil
	_on_output = type(options.on_output) == "function" and options.on_output or nil
	_on_offer = type(options.on_offer) == "function" and options.on_offer or nil
	_offer_notified = false
	if type(options.triggers) == "table" then _triggers = options.triggers end
	if type(options.max_context) == "number" then _max_context_chars = options.max_context end
	if _pending_trigger then _scheduler.cancel(_pending_trigger) end
	_scheduler = type(options.scheduler) == "table" and options.scheduler or TimerScheduler
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
	if not _enabled then return end
	if type(ch) ~= "string" or type(buffer) ~= "string" then return end
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
	if not _enabled or TriggerSettings.get("after_hotstring") ~= true then return false end
	if _predicting or #_suggestions > 0 then M.dismiss() end
	return schedule(context, output_context, 0, "Hotstring-expiry")
end

local function resolve_system_prompt(profile, params, count)
	local resolved = ProfileSelector.resolve_system_prompt(profile, {
		context = params.context,
		tail = params.context_tail,
		min_words = params.min_words,
		max_words = params.max_words,
		n = count,
		language = params.language,
	})
	return resolved and resolved.system or nil
end

--- Starts a prediction from the given context buffer.
--- @param context string
--- @param output_context table|nil
function M.predict(context, output_context)
	if _predicting or type(context) ~= "string" or context == "" then return end
	if _is_secure_context() then
		Logger.debug(LOG, "Prediction suppressed: secure field or excluded context.")
		return
	end

	local ollama = get_ollama()
	local profiles = get_profiles()
	local model = profiles and profiles.get_current_model()
	if not ollama then Logger.warn(LOG, "predict(): Ollama API not available."); return end
	if not model then Logger.warn(LOG, "predict(): No model selected - run Ollama and refresh models."); return end

	local clean_context, trigger_chars = context_without_trigger(context,
		type(output_context) == "table" and output_context.input_chars or 0)
	local requested = ProfileSettings.get("num_predictions") or 1
	local profile = ProfileSettings.resolve(model)
	if not profile then Logger.error(LOG, "Prediction profile catalogue is unavailable."); return end
	local params = PromptBuilder.build_params(clean_context, {
		max_words = Settings.get("max_words"),
		min_words = Settings.get("min_words"),
		num_predictions = requested,
		temperature = Settings.get("temperature"),
		auto_raise_temp = Settings.get("auto_raise_temp"),
		language = "fr",
		context_window_chars = max_context_chars(),
	})
	local is_batch = profile.batch == true and requested > 1
	local system_prompt = resolve_system_prompt(profile, params, is_batch and requested or 1)
	if type(system_prompt) ~= "string" or system_prompt == "" then
		Logger.error(LOG, "Prediction profile '%s' has no usable system prompt.", tostring(profile.id))
		return
	end

	local base_url = profiles.get_base_url() or HttpBridge.resolve_base_url() or ""
	local messages = {
		{ role = "system", content = system_prompt },
		{ role = "user", content = params.context },
	}
	local candidates = {}
	local request_index = 0
	local meta = {
		model = model,
		profile = profile.id,
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
	Logger.info(LOG, "Sending prediction request to %s (model=%s, context=%d chars).",
		base_url, model, #params.context)

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
		if epoch ~= _request_epoch then return end
		request_index = request_index + 1
		local think_filter = Parser.new_thinking_filter()
		local streamed = ""
		ollama.chat(base_url, model, messages, {
			stream = DisplaySettings.get("streaming") == true,
			temperature = params.temperature,
			max_tokens = (_max_tokens or params.max_tokens) * (is_batch and requested or 1),
			line_mode = profile.id == "raw" or profile.id == "basic",
		}, function(delta)
			if epoch ~= _request_epoch then return end
			streamed = streamed .. think_filter:feed(delta)
			if DisplaySettings.get("streaming") ~= true then return end
			if requested > 1 and DisplaySettings.get("streaming_multi") ~= true then return end
			local partials = parse_response(streamed, is_batch, trigger_chars)
			publish(partials[#partials])
		end, function(full_text, err)
			if epoch ~= _request_epoch then return end
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
			if not is_batch and request_index < requested then dispatch(); return end
			_predicting = false
			meta.loading = false
			if #candidates > 0 then publish() else clear_offer() end
		end)
	end
	dispatch()
end

--- Cancels pending/in-flight work and discards the current engine buffer.
function M.cancel()
	if _pending_trigger then _scheduler.cancel(_pending_trigger); _pending_trigger = nil end
	M.dismiss()
	if _engine and type(_engine.reset) == "function" then _engine:reset() end
end

--- Dismisses in-flight and visible suggestions without changing the buffer.
function M.dismiss()
	_request_epoch = _request_epoch + 1
	if _predicting then
		local ollama = get_ollama()
		if ollama then ollama.cancel() end
	end
	_predicting = false
	clear_offer()
end

--- Accepts one displayed prediction after the daemon commits its physical edit.
--- @param index integer
--- @return boolean
function M.accept(index)
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
	if not _suggestions[tonumber(index)] then return false end
	if _overlay and type(_overlay.select) == "function" then return _overlay.select(tonumber(index)) == true end
	return true
end

--- Consumes a configured modifier+digit validation chord when an offer exists.
--- @param detail table { key, mods }
--- @return boolean
function M.handle_shortcut(detail)
	if #_suggestions == 0 or type(detail) ~= "table" then return false end
	if not NavigationSettings.matches(detail.mods) then return false end
	local key = tostring(detail.key or detail.char or "")
	local digit = key:match("^([0-9])$") or key:match("^[Kk][Pp]_?([0-9])$")
	if not digit then return false end
	local index = digit == "0" and 10 or tonumber(digit)
	if not _suggestions[index] then return false end
	return M.accept(index)
end

function M.has_suggestions() return #_suggestions > 0 end

function M.get_suggestions()
	local copy = {}
	for index, candidate in ipairs(_suggestions) do copy[index] = candidate end
	return copy
end

function M.is_enabled() return _enabled end

function M.enable()
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
	if type(value) ~= "number" or value <= 0 then return false end
	_max_context_chars = value
	return true
end

function M.get_stop_sequences() return {} end

--- Compatibility query retained for UI bridges: Linux suggestions are explicit.
function M.is_auto_inject() return false end

return M
