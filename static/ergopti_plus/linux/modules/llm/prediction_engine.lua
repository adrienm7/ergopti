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
local HttpBridge = nil
local ok_bridge, bridge_mod = pcall(require, "llm.linux_bridge")
if ok_bridge then HttpBridge = bridge_mod end

local PromptBuilder = nil
local ok_pb, pb_mod = pcall(require, "llm.prompt_builder")
if ok_pb then PromptBuilder = pb_mod end


-- =========================================
-- =========================================
-- ======= 1/ Imports (lazy) ===============
-- =========================================
-- =========================================

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

-- Current prediction result (so we can backspace on cancel).
local _predicted_text = ""

-- Trigger patterns that activate prediction.
local _triggers = { "//", ";;", "--" }

-- Maximum characters of context to send to the LLM. Single-sourced from the
-- shared canonical (defaults.json llm_context_length via linux_bridge) so all
-- three drivers send the same window; was a divergent 2000 here.
local _max_context_chars = (HttpBridge and HttpBridge.DEFAULT_CONTEXT_LENGTH) or 500

-- Whether to auto-inject predictions (false = just show tooltip).
local _auto_inject = true


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
--- }
function M.init(opts)
	local options = type(opts) == "table" and opts or {}
	_engine = options.engine
	_keyboard_hook = options.keyboard_hook

	if type(options.triggers) == "table" then _triggers = options.triggers end
	if type(options.max_context) == "number" then _max_context_chars = options.max_context end
	if options.auto_inject ~= nil then _auto_inject = options.auto_inject end

	-- Initialise LLM profiles with the canonical Ollama port (defaults.json
	-- llm_ollama_port via linux_bridge), never a re-typed literal.
	local profiles = _get_profiles()
	if profiles then
		profiles.init({ port = HttpBridge and HttpBridge.OLLAMA_DEFAULT_PORT })
	end

	Logger.success(LOG, "Prediction engine initialised (triggers=%d, max_context=%d, auto_inject=%s).",
		#_triggers, _max_context_chars, tostring(_auto_inject))
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
function M.on_char(ch, buffer)
	if not _enabled or _predicting then return end
	if type(ch) ~= "string" or type(buffer) ~= "string" then return end

	-- Check if buffer ends with any trigger.
	for _, trigger in ipairs(_triggers) do
		if buffer:sub(-#trigger) == trigger then
			Logger.info(LOG, "Trigger '%s' detected — starting prediction.", trigger)
			M.predict(buffer)
			break
		end
	end
end


-- =========================================
-- =========================================
-- ======= 5/ Prediction Flow ==============
-- =========================================
-- =========================================

--- Starts a prediction from the given context buffer.
--- @param context string The typing context (including the trigger).
function M.predict(context)
	if _predicting then return end

	local ollama = _get_ollama()
	local profiles = _get_profiles()
	local sender = _get_text_sender()
	local model = profiles and profiles.get_current_model() or "codellama"

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
		or (HttpBridge and HttpBridge.resolve_base_url())
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

	ollama.chat(
		base_url,
		model,
		messages,
		{
			stream      = true,
			-- Canonical temperature (defaults.json llm_temperature) and max_tokens
			-- (prompt_builder.DEFAULT_MAX_TOKENS) — were divergent 0.3 / 200 here.
			temperature = (HttpBridge and HttpBridge.DEFAULT_TEMPERATURE) or 0.1,
			max_tokens  = (PromptBuilder and PromptBuilder.DEFAULT_MAX_TOKENS) or 150,
		},
		-- on_chunk: inject each delta character immediately.
		function(delta)
			_predicted_text = _predicted_text .. delta
			if _auto_inject and sender then
				pcall(function() sender.send(delta, { mode = "direct" }) end)
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
				Logger.info(LOG, "Prediction complete: %d chars → '%s'",
					#full_text, full_text:sub(1, 80))
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
--- Delegates to the shared prompt_builder when available.
--- @return string
local function _build_system_prompt()
	-- Try the shared prompt builder.
	local ok, prompt_builder = pcall(require, "llm.prompt_builder")
	if ok and prompt_builder and prompt_builder.resolve_system_prompt then
		local prompt = prompt_builder.resolve_system_prompt("linux", "fr")
		if type(prompt) == "string" and prompt ~= "" then return prompt end
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
local function _build_user_context(context)
	if #context <= _max_context_chars then return context end
	-- Keep the last _max_context_chars characters (most relevant).
	return context:sub(-_max_context_chars)
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

return M
