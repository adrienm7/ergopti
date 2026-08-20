--- modules/llm/prediction_engine.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine (Linux)
--- DESCRIPTION:
--- Detects trigger sequences in the typing stream, builds context prompts,
--- queries the Ollama API for streaming completions, and injects predictions
--- via the text_sender adapter. Mirrors the macOS prediction_engine.lua but
--- targets Ollama-only (no MLX/Remote).
---
--- FEATURES & RATIONALE:
--- 1. Trigger detection: watches the engine buffer for configured trigger
---    patterns (e.g. "//", ";;", "--"). When a trigger fires, the prediction
---    flow starts.
--- 2. Context building: collects the last N characters of typing context
---    (default 2000) + the trigger as the prompt. Delegates to the shared
---    prompt_builder for system message resolution.
--- 3. Streaming prediction: calls api_ollama.chat() with stream=true, injects
---    each chunk via text_sender.send() with mode="direct", and backspaces on
---    cancel or completion.
--- 4. Cancel: Backspace or Escape cancels the prediction, erases injected
---    text, and resets the engine buffer.
--- 5. App filter: predictions are suppressed for configured apps (passwords,
---    terminals) — delegates to the window_info adapter.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.llm.prediction_engine"

-- Shared LLM canonicals: Ollama port/host/temperature/context live once in
-- _shared (mirrored from defaults.json) and max_tokens in prompt_builder, so the
-- Linux engine never re-types a value that could drift from macOS/Windows.
-- Hard requires, for the same reason the parser below is one. Every value this
-- engine takes from them is either a user setting or a privacy posture, and a
-- pcall that leaves the module nil turns each of those into a literal written
-- beside it — a temperature the user did not choose, a context length they did
-- not set, and, worst, `nil and X` for the two filters, which is falsy. The
-- password-field filter therefore failed OPEN: one unloadable module and the
-- text around the caret went to the model from a password field.
local HttpBridge = require("infra.llm_bridge")
local PromptBuilder = require("llm.prompt_builder")

local ProfileSelector = nil
local ok_ps, ps_mod = pcall(require, "llm.profile_selector")
if ok_ps then ProfileSelector = ps_mod end

-- The shared response parser. Linux never loaded it, so a reasoning model's
-- <think>…</think> block was streamed straight into the user's document, one
-- delta at a time. A hard require: without it the streaming path would inject
-- thinking text, which is a correctness bug, not a missing nicety.
local Parser = require("llm.parser")

-- The two generation values the user can change. Hard require for the same
-- reason as the two above: every value it holds is a setting, and a module that
-- silently fails to load turns each into a literal written beside it.
local Settings = require("modules.llm.settings")

-- Canonical privacy posture, from defaults.json via the shared bridge. Never
-- re-typed: the same two keys drive Windows and macOS.
local _secure_field_filter_enabled = HttpBridge.DEFAULT_DISABLE_PASSWORD_FIELDS
local _url_bar_filter_enabled = HttpBridge.DEFAULT_DISABLE_URL_BARS


-- =========================================
-- =========================================
-- ======= 1/ Imports (lazy) ===============
-- =========================================
-- =========================================

--- The AT-SPI secure-field detector. Optional: on a desktop without AT-SPI the
--- adapter cannot answer, and the gate then fails CLOSED (see _is_secure_context).
local function _get_secure_field_detector()
	local ok, mod = pcall(require, "adapters.secure_field_detector")
	if ok then return mod end
	return nil
end

--- True when the current focus must not be sent to the model.
--- Fails CLOSED: if the filter is enabled but the detector cannot be loaded or
--- cannot answer, the prediction is suppressed. A privacy gate that degrades to
--- "allow" is not a gate.
--- @return boolean
local function _is_secure_context()
	if not _secure_field_filter_enabled and not _url_bar_filter_enabled then
		return false
	end

	local detector = _get_secure_field_detector()
	if not detector then
		return _secure_field_filter_enabled == true
	end

	if _secure_field_filter_enabled then
		local ok, secure = pcall(detector.isSecureField)
		if not ok then return true end
		if secure then return true end
	end

	if _url_bar_filter_enabled then
		local ok_app, app_id = pcall(function()
			local pl = require("adapters.process_lifecycle")
			return pl and pl.getForegroundApp and pl.getForegroundApp()
		end)
		if ok_app and type(app_id) == "string" and app_id ~= "" then
			local ok_secure, is_secure = pcall(detector.isSecureApp, app_id)
			if ok_secure and is_secure then return true end
		end
	end

	return false
end

local function _get_ollama()
	local ok, mod = pcall(require, "modules.llm.api_ollama")
	return ok and mod or nil
end

local function _get_profiles()
	local ok, mod = pcall(require, "modules.llm.profiles")
	return ok and mod or nil
end

local function _get_text_sender()
	local ok, mod = pcall(require, "adapters.text_sender")
	return ok and mod or nil
end


-- =========================================
-- =========================================
-- ======= 2/ State ========================
-- =========================================
-- =========================================

-- Whether the prediction engine is enabled.
local _enabled = true

-- Whether a prediction is currently in flight.
local _predicting = false

-- The engine and keyboard_hook references (set in M.init).
local _engine = nil
local _keyboard_hook = nil

-- Optional durable-output observer. The daemon supplies this so only completed
-- auto-injected text enters the keylogger; failed/cancelled streamed fragments
-- are erased and must never become phantom logical keystrokes.
local _on_output = nil

-- Current prediction result (so we can backspace on cancel).
local _predicted_text = ""

-- Trigger patterns that activate prediction.
local _triggers = { "//", ";;", "--" }

-- Maximum characters of context to send to the LLM. Single-sourced from the
-- shared canonical (defaults.json llm_context_length via linux_bridge) so all
-- three drivers send the same window; was a divergent 2000 here.
-- Read through the settings module on every use rather than captured here: the
-- user can change it from the menu while the daemon runs, and a value captured
-- at load would keep the old one until a restart.
local _max_context_chars = nil

--- How much of what the user has written the model sees.
---
--- Declared BELOW `_max_context_chars`, deliberately: a function written above
--- the local it reads does not capture it — it binds the nil global, and the
--- read then silently answers nothing. Four bugs of that shape have been fixed
--- in this driver, one of them earlier today.
---
--- Reads through the settings module rather than a value captured at load,
--- because the user can change it from the menu while the daemon runs.
--- @return number
local function max_context_chars()
	return _max_context_chars
		or Settings.get("context_length")
		or HttpBridge.DEFAULT_CONTEXT_LENGTH
end

-- Whether to auto-inject predictions (false = just show tooltip).
local _auto_inject = true

-- How many tokens a completion may run to, once the user has said. nil means
-- the shared default; see set_max_tokens for why this one is not persisted.
local _max_tokens = nil


-- =========================================
-- =========================================
-- ======= 3/ Initialisation ===============
-- =========================================
-- =========================================

--- Initialises the prediction engine with daemon state.
--- @param opts table {
---   engine          table   Hotstring engine instance.
---   keyboard_hook   table   KeyboardHook adapter.
---   triggers        table|nil  Array of trigger strings (default {"//", ";;", "--"}).
---   max_context     number|nil  Max context chars (default 2000).
---   auto_inject     boolean|nil Inject predictions immediately (default true).
---   on_output       function|nil Called with (completed_text, context) after a successful injection.
--- }
function M.init(opts)
	local options = type(opts) == "table" and opts or {}
	_engine = options.engine
	_keyboard_hook = options.keyboard_hook

	if type(options.triggers) == "table" then _triggers = options.triggers end
	if type(options.max_context) == "number" then _max_context_chars = options.max_context end
	if options.auto_inject ~= nil then _auto_inject = options.auto_inject end
	if type(options.on_output) == "function" then _on_output = options.on_output else _on_output = nil end

	-- Initialise LLM profiles with the canonical Ollama port (defaults.json
	-- llm_ollama_port via linux_bridge), never a re-typed literal.
	-- Then sync the engine's _enabled with the persisted profiles state so
	-- the menu toggle and daemon restart use the same source of truth.
	local profiles = _get_profiles()
	if profiles then
		profiles.init({ port = HttpBridge.OLLAMA_DEFAULT_PORT })
		if type(profiles.is_enabled) == "function" then
			_enabled = profiles.is_enabled()
		end
	end

	Logger.success(LOG, "Prediction engine initialised (triggers=%d, max_context=%d, auto_inject=%s).",
		#_triggers, max_context_chars(), tostring(_auto_inject))
end


-- =========================================
-- =========================================
-- ======= 4/ Trigger Detection ============
-- =========================================
-- =========================================

--- Called on every character the user types. Checks if the buffer ends with
--- a trigger pattern and starts a prediction if so.
--- @param ch       string  The character just typed.
--- @param buffer   string  The current engine buffer content.
function M.on_char(ch, buffer, output_context)
	if not _enabled or _predicting then return end
	if type(ch) ~= "string" or type(buffer) ~= "string" then return end

	-- Check if buffer ends with any trigger.
	for _, trigger in ipairs(_triggers) do
		if buffer:sub(-#trigger) == trigger then
			Logger.info(LOG, "Trigger '%s' detected — starting prediction.", trigger)
			M.predict(buffer, {
				app_id = type(output_context) == "table" and output_context.app_id or nil,
				input_chars = #trigger,
			})
			break
		end
	end
end


-- =========================================
-- =========================================
-- ======= 5/ Prediction Flow ==============
-- =========================================
-- =========================================

-- Forward declarations. The prompt builders live in section 6 (below) but are
-- called by M.predict here. Declaring the locals BEFORE predict means the later
-- `function _build_system_prompt()` / `function _build_user_context()` assign to
-- THESE locals; without it Lua (which does not hoist `local function`) would make
-- predict resolve a nil GLOBAL and crash on first call
-- (project-lua-closure-before-local-nil-global — same class as menu_karabiner).
local _build_system_prompt
local _build_user_context

--- Starts a prediction from the given context buffer.
--- @param context string The typing context (including the trigger).
--- @param output_context table|nil App and trigger metadata captured at request start.
function M.predict(context, output_context)
	if _predicting then return end

	-- Privacy gate. Linux had none at all: the text around the caret was sent to
	-- the model from password fields like any other context. The canonical posture
	-- lives in defaults.json — secure fields blocked, URL bars allowed — and this
	-- is the only driver-side decision, so it reads the same values as the other
	-- two. Unlike the keylogger's app-name list, there is no pre-existing broader
	-- filter here to narrow, so consuming the AT-SPI adapter is purely additive.
	if _is_secure_context() then
		Logger.debug(LOG, "Prediction suppressed: secure field or excluded context.")
		return
	end

	local ollama = _get_ollama()
	local profiles = _get_profiles()
	local sender = _get_text_sender()
	local model = profiles and profiles.get_current_model()

	if not ollama then
		Logger.warn(LOG, "predict(): Ollama API not available.")
		return
	end
	if not model then
		Logger.warn(LOG, "predict(): No model selected — run Ollama and refresh models.")
		return
	end

	_predicting = true
	_predicted_text = ""

	-- Prefer the profiles' resolved URL; fall back to the shared bridge's canonical
	-- host/port builder (never a re-typed localhost:11434 literal).
	local base_url = (profiles and profiles.get_base_url())
		or HttpBridge.resolve_base_url()
		or ""

	-- Build the messages payload.
	local system_prompt = _build_system_prompt()
	local user_context = _build_user_context(context)
	local messages = {
		{ role = "system", content = system_prompt },
		{ role = "user", content = user_context },
	}

	Logger.info(LOG, "Sending prediction request to %s (model=%s, context=%d chars)...",
		base_url, model, #user_context)

	-- One filter per request: it carries the "am I inside <think>" state and the
	-- withheld partial tag across the chunk callbacks below.
	local think_filter = Parser.new_thinking_filter()

	ollama.chat(
		base_url,
		model,
		messages,
		{
			stream      = true,
			-- Canonical temperature (defaults.json llm_temperature) and max_tokens
			-- (prompt_builder.DEFAULT_MAX_TOKENS) — were divergent 0.3 / 200 here.
			-- The user's setting, not the shipped constant. These two were read
			-- straight from the canonical defaults, which made them constants
			-- wearing the shape of settings: the manifest declares both as
			-- features and there was no way to change either.
			temperature = Settings.get("temperature") or HttpBridge.DEFAULT_TEMPERATURE,
			max_tokens  = PromptBuilder.DEFAULT_MAX_TOKENS,
			-- This driver has one prediction mode: a continuation injected at the
			-- caret, inline. A newline in it would break the line the user is
			-- writing, so the stop list is the one that cuts there — the same
			-- choice macOS makes for a non-batch, non-advanced request.
			line_mode   = true,
		},
		-- on_chunk: inject each delta immediately, minus any thinking block.
		-- The filter is stateful and withholds a partial tag, so a <think> split
		-- across two chunks is still caught. _predicted_text tracks what actually
		-- reached the document, because on error it is erased by that count.
		function(delta)
			local visible = think_filter:feed(delta)
			if visible == "" then return end
			_predicted_text = _predicted_text .. visible
			if _auto_inject and sender then
				pcall(function() sender.send(visible, { mode = "direct" }) end)
			end
		end,
		-- on_done: log the result.
		function(full_text, err)
			_predicting = false
			if err then
				Logger.warn(LOG, "Prediction failed: %s", err)
				-- Backspace any partially injected text on error.
				if _auto_inject and #_predicted_text > 0 and sender then
					pcall(function() sender.eraseChars(#_predicted_text) end)
				end
			else
				-- Emit whatever the filter withheld as a possible partial tag, then
				-- strip any thinking block from the complete text before it reaches
				-- the output observer. The streaming filter already protected the
				-- document; this protects every non-streaming consumer.
				local trailing = think_filter:flush()
				if trailing ~= "" then
					_predicted_text = _predicted_text .. trailing
					if _auto_inject and sender then
						pcall(function() sender.send(trailing, { mode = "direct" }) end)
					end
				end
				full_text = Parser.strip_thinking(full_text)

				-- Length only: the completion is about to be typed into the user's
				-- document, so it is user content and does not belong in a log.
				Logger.info(LOG, "Prediction complete: %d chars.", #full_text)
				if _auto_inject and type(full_text) == "string" and full_text ~= "" and _on_output then
					local ok_output, output_err = pcall(_on_output, full_text, output_context)
					if not ok_output then
						Logger.warn(LOG, "Prediction output observer failed: %s", tostring(output_err))
					end
				end
			end
			_predicted_text = ""
		end
	)
end

--- Cancels the current prediction and erases any injected text.
function M.cancel()
	if not _predicting then return end

	local ollama = _get_ollama()
	if ollama then ollama.cancel() end

	local sender = _get_text_sender()
	if _auto_inject and #_predicted_text > 0 and sender then
		pcall(function() sender.eraseChars(#_predicted_text) end)
		Logger.info(LOG, "Prediction cancelled — erased %d chars.", #_predicted_text)
	end

	_predicted_text = ""
	_predicting = false

	-- Reset the engine buffer so the user's next keystroke starts fresh.
	if _engine then _engine:reset() end
end


-- =========================================
-- =========================================
-- ======= 6/ Prompt Building ==============
-- =========================================
-- =========================================

--- Builds the system prompt for the LLM.
--- Delegates to the shared PromptBuilder and ProfileSelector for template resolution.
--- @return string
function _build_system_prompt()
	-- Use the already-loaded shared PromptBuilder and ProfileSelector
	-- (both loaded at module level).
	if PromptBuilder and type(PromptBuilder.build_params) == "function" then
		if ProfileSelector and type(ProfileSelector.get_active_profile) == "function" then
			local profile = ProfileSelector.get_active_profile("basic")
			if profile then
				local resolved = ProfileSelector.resolve_system_prompt(profile, {
					context    = "",
					tail       = "",
					min_words  = 1,
					max_words  = 5,
					n          = 1,
					language   = "fr",
				})
				if resolved and type(resolved.system) == "string" and resolved.system ~= "" then
					return resolved.system
				end
			end
		end
	end

	-- Fallback: basic French completions prompt.
	return [[Tu es un assistant de complétion de texte en français.
        Continue le texte de l'utilisateur de manière naturelle et concise.
        Ne répète pas le texte de l'utilisateur.
        Réponds uniquement avec la suite du texte, sans préambule ni explication.]]
end

--- Builds the user context from the typing buffer.
--- @param context string The full typing buffer (may be long).
--- @return string Truncated context suitable for the LLM.
function _build_user_context(context)
	local limit = max_context_chars()
	if #context <= limit then return context end
	-- Keep the last `limit` characters, which are the ones nearest the caret.
	return context:sub(-limit)
end


-- =========================================
-- =========================================
-- ======= 7/ State Queries ================
-- =========================================
-- =========================================

--- Returns whether the prediction engine is enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Enables the prediction engine (delegates to profiles for persistence).
function M.enable()
	_enabled = true
	local profiles = _get_profiles()
	if profiles and type(profiles.enable) == "function" then
		profiles.enable()
	end
	Logger.info(LOG, "Prediction engine enabled.")
end

--- Disables the prediction engine and cancels any in-flight prediction.
--- Delegates to profiles for persistence.
function M.disable()
	_enabled = false
	M.cancel()
	local profiles = _get_profiles()
	if profiles and type(profiles.disable) == "function" then
		profiles.disable()
	end
	Logger.info(LOG, "Prediction engine disabled.")
end

--- Toggles the prediction engine on/off.
function M.toggle()
	_enabled = not _enabled
	if not _enabled then M.cancel() end
	Logger.info(LOG, "Prediction engine: %s", tostring(_enabled))
end

--- Returns true if a prediction is currently in flight.
--- @return boolean
function M.is_predicting()
	return _predicting
end

--- Returns the list of trigger strings.
--- @return table
function M.get_triggers()
	return _triggers
end

--- Replaces the sequences that start a prediction.
---
--- Refuses an empty list rather than storing it. A prediction engine with no
--- trigger never predicts, and the window offering the field gives no sign that
--- clearing it turns the feature off — the user would read it as broken.
--- @param triggers table Array of strings.
--- @return boolean
function M.set_triggers(triggers)
	if type(triggers) ~= "table" then
		Logger.error(LOG, "set_triggers(): a list is required — triggers unchanged.")
		return false
	end
	local accepted = {}
	for _, trigger in ipairs(triggers) do
		if type(trigger) == "string" and trigger ~= "" then accepted[#accepted + 1] = trigger end
	end
	if #accepted == 0 then
		Logger.error(LOG, "set_triggers(): no usable trigger in the list — triggers unchanged.")
		return false
	end
	_triggers = accepted
	Logger.info(LOG, "Triggers: %d configured.", #_triggers)
	return true
end

--- Delegates to profiles for model management (menu + bridge compatibility).
--- @return table Array of model name strings.
function M.get_models()
	local profiles = _get_profiles()
	if profiles and type(profiles.get_models) == "function" then
		return profiles.get_models()
	end
	return {}
end

--- Delegates to profiles for current model name.
--- @return string|nil
function M.get_current_model()
	local profiles = _get_profiles()
	if profiles and type(profiles.get_current_model) == "function" then
		return profiles.get_current_model()
	end
	return nil
end

--- Delegates to profiles for model selection.
--- @param model_name string
function M.set_model(model_name)
	local profiles = _get_profiles()
	if profiles and type(profiles.set_model) == "function" then
		profiles.set_model(model_name)
	end
end

--- Delegates to profiles for model refresh.
function M.refresh_models()
	local profiles = _get_profiles()
	if profiles and type(profiles.refresh_models) == "function" then
		profiles.refresh_models()
	end
end

--- Returns the configured max tokens (delegates to PromptBuilder or defaults).
--- @return number
function M.get_max_tokens()
	return _max_tokens or PromptBuilder.DEFAULT_MAX_TOKENS
end

--- Sets how many tokens a completion may run to.
---
--- Held in memory rather than persisted, unlike the temperature and the context
--- length: the manifest declares those two as features and says nothing about
--- this one, and storing a value the manifest does not describe would put a key
--- in the user's config that nothing can explain or reset.
--- @param value number
--- @return boolean
function M.set_max_tokens(value)
	local tokens = tonumber(value)
	if not tokens or tokens < 1 then
		Logger.error(LOG, "set_max_tokens(): %s is not a token budget — refused.", tostring(value))
		return false
	end
	_max_tokens = math.floor(tokens)
	Logger.info(LOG, "Max tokens: %d.", _max_tokens)
	return true
end

--- Returns the configured temperature (from the shared bridge).
--- @return number
function M.get_temperature()
	return Settings.get("temperature") or HttpBridge.DEFAULT_TEMPERATURE
end

--- Sets the temperature the next request will use.
---
--- This had no implementation while `ui/token_prompt/bridge.lua` already called
--- it — behind a `type(…) == "function"` guard, so a user saving their settings
--- had the value silently discarded while the context length beside it applied.
--- The guard reads as defensive and makes the branch permanently dead.
--- @param value number
--- @return boolean Whether it was accepted.
function M.set_temperature(value)
	return Settings.set("temperature", tonumber(value))
end

--- Returns the configured max context chars.
--- @return number
function M.get_max_context()
	return max_context_chars()
end

--- Sets the max context chars for the LLM window.
--- @param n number
function M.set_max_context(n)
	if type(n) == "number" and n > 0 then
		_max_context_chars = n
	end
end

--- Returns the configured stop sequences.
--- @return table
function M.get_stop_sequences()
	return {}
end

--- Returns whether auto-inject is enabled.
--- @return boolean
function M.is_auto_inject()
	return _auto_inject
end

return M
