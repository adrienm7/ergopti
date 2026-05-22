--- modules/llm/prediction_engine.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine
--- DESCRIPTION:
--- Owns the full lifecycle of AI-assisted text predictions: request dispatch,
--- streaming ingestion, deduplication, display, and state management. Extracted
--- from modules/keymap/llm_bridge so all LLM-specific logic is consolidated
--- under modules/llm/ and the keymap bridge can focus on hotstring preview and
--- keystroke routing. App exclusion logic is also handled here as a private
--- helper, keeping it alongside the prediction pipeline that consumes it.
---
--- KEY RESPONSIBILITIES:
--- 1. State ownership: pending predictions, visibility flag, request counters,
---    inactivity / chain / watchdog timers, and all LLM configuration.
--- 2. LLM pipeline: sends async requests, streams results progressively,
---    deduplicates candidates, and manages the auto-dismiss countdown.
--- 3. Chain trigger: after a prediction is accepted, arms F16 detection so the
---    next LLM request fires as soon as the HID queue drains.
--- 4. Public API surface: exposed to the keymap bridge and menu modules via
---    typed setters and query helpers; no shared mutable globals.
--- ==============================================================================

local M = {}

local hs = hs

local core_llm         = require("modules.llm")
local Parser           = require("modules.llm.parser")
local WarmupController = require("modules.llm.warmup_controller")
local PromptBuilder    = require("modules.llm.prompt_builder")
local StreamingHandler = require("modules.llm.streaming_handler")
local Logger           = require("lib.logger")
local i18n             = require("lib.i18n")
local Keycodes         = require("lib.keycodes")
local tooltip          = require("ui.tooltip")
local keylogger        = require("modules.keylogger")
local km_utils         = require("modules.keymap.utils")

local LOG    = "llm.prediction_engine"
local _state = nil  -- Shared keymap core state; injected via M.init()





-- ===================================
--- ===================================
--- ======= 1/ Module Constants =======
--- ===================================
-- ===================================

-- ── macOS key code ────────────────────────────────────────────────────────────

-- Synthetic "typing complete" signal sent by apply_prediction after all HID events.
-- Uses F16 — distinct from the F15 script-control kill-switch, so manually pressing
-- F15 cannot accidentally fire an LLM chain. Exported so the keymap bridge can
-- detect it without duplicating the constant.
local KEYCODE_LLM_CHAIN = Keycodes.F16_LLM_CHAIN_SIGNAL

-- ── Diversity / temperature ───────────────────────────────────────────────────

-- ── Context truncation ───────────────────────────────────────────────────────

-- ── UI / display parameters ───────────────────────────────────────────────────

local SPINNER_FPS = 6  -- Frames per second for the streaming progress spinner

-- ── Adaptive debounce ─────────────────────────────────────────────────────────
-- Adjust the inactivity delay based on live WPM so the timer fires sooner
-- when the user is thinking and later when they are actively typing.

local FAST_TYPING_WPM    = 55   -- Above this WPM, extend debounce (user still mid-burst)
local SLOW_TYPING_WPM    = 20   -- Below this WPM, shorten debounce (user paused to think)
local DEBOUNCE_FAST_MULT = 1.5  -- Multiplier applied when WPM is above FAST_TYPING_WPM
local DEBOUNCE_SLOW_MULT = 0.5  -- Multiplier applied when WPM is below SLOW_TYPING_WPM
-- Hard floor / ceiling so extreme WPM values don't produce unusable delays
local DEBOUNCE_MIN_SEC   = 0.05
local DEBOUNCE_MAX_SEC   = 0.6

-- ── N-gram instant prediction ─────────────────────────────────────────────────
-- Show a local word-bigram prediction immediately (< 1 ms) while the LLM warms up.
-- Replaced in-place when the LLM response arrives, so the user always sees something.

local NGRAM_MIN_COUNT = 2  -- Ignore words seen only once (noise / typos)
local NGRAM_MAX_PREDS = 3  -- Maximum instant candidates to show before LLM responds

-- ── Timing constants ──────────────────────────────────────────────────────────

local CHAIN_FALLBACK_SEC  = 0.5   -- Fire chain LLM if the F16 signal is somehow missed

-- ── URL-bar / app exclusion ───────────────────────────────────────────────────

-- AXSubrole assigned by macOS to URL text fields in Safari and other native browser controls.
local AX_URL_SUBROLE = "AXURLField"
-- Lowercase substrings matched against AXIdentifier to detect Chrome/Brave/Opera omniboxes.
-- Edge does not reliably expose an identifier, so a parent-toolbar fallback is used instead.
local URL_BAR_ID_PATTERNS = { "address", "urlfield", "location", "omnibox", "url" }
-- Bundle IDs of browsers for which an AXTextField inside an AXToolbar is always the URL bar.
-- Used as a fallback when AXSubrole and AXIdentifier checks both come up empty.
local BROWSER_BUNDLE_IDS = {
	["com.apple.Safari"]                = true,
	["com.google.Chrome"]               = true,
	["com.google.Chrome.canary"]        = true,
	["com.microsoft.edgemac"]           = true,
	["com.microsoft.edgemac.Dev"]       = true,
	["com.microsoft.edgemac.Canary"]    = true,
	["org.mozilla.firefox"]             = true,
	["com.brave.Browser"]               = true,
	["com.brave.Browser.nightly"]       = true,
	["com.operasoftware.Opera"]         = true,
	["com.vivaldi.Vivaldi"]             = true,
	["company.thebrowser.Browser"]      = true,  -- Arc
}

-- Reference to the LLM engine defaults, used once at module load to seed Section 2
local LLM_DEFAULTS = core_llm.DEFAULT_STATE





-- ================================
--- ================================
--- ======= 2/ Mutable State =======
--- ================================
-- ================================

-- ── Prediction pipeline ───────────────────────────────────────────────────────

-- Predictions currently loaded in the tooltip (empty when nothing is shown)
local pending_predictions = {}

-- True while predictions are on screen and waiting for user interaction
local predictions_visible = false

-- Incremented each time a new LLM request is triggered; stale async callbacks
-- capture this value at request time and discard themselves when it changes
local llm_request_counter = 0

-- Tracks the currently active streaming fetch; finer-grained than llm_request_counter
-- because it resets on every individual fetch call, not only on new user input
local fetch_request_counter = 0

-- The last buffer+tail string sent to the LLM; prevents re-sending unchanged input
local last_buffer_signature = nil

-- Length of the buffer at the time of the last LLM request; used by the adaptive
-- debounce to detect ongoing corrections (shrinking buffer = user still deleting)
local _last_request_buffer_len = 0

-- ── Timers ────────────────────────────────────────────────────────────────────

-- Fires perform_check() after inactivity_debounce_sec of silence
local _inactivity_timer = nil

-- Fallback: fires perform_check() if the F16 chain signal is somehow missed
local _chain_trigger_timer = nil

-- True between an accepted prediction and the F16 chain trigger that follows it
local chain_pending = false

-- ── Backend-aware request floor ──
-- The user can debounce as low as they want from the menu, but the engine
-- still enforces this minimum gap between two consecutive backend calls.
-- The cap protects paid API providers from a fast typist's per-keystroke
-- bursts (one debounce = 50 ms x every char = token-burn galore), and
-- doubles as an energy cap on local backends: back-to-back inference keeps
-- the GPU spinning without giving the user a perceptibly snappier UI.
-- The values live in ``_shared/llm/inference.json`` so the AHK twin
-- (modules/llm/api_common.ahk) reads the same floor — a single source
-- of truth across drivers.
local ApiCommon = require("modules.llm.api_common")
local _last_request_at_s = 0

-- ── LLM engine configuration ─────────────────────────────────────────────────
-- Stub values that prevent crashes during the brief startup window before the
-- menu loads and calls the set_* setters. NOT the user-configured values.

local is_llm_enabled          = LLM_DEFAULTS.llm_enabled
local active_model            = core_llm.get_current_model()  -- Backend-aware; overridden by set_llm_model
local llm_display_name        = core_llm.get_current_model()  -- Human-readable label shown in the info bar
local llm_backend_label       = nil                           -- "Ollama 🦙", "MLX 🚀", or a custom label
local temperature             = LLM_DEFAULTS.llm_temperature
local context_window_chars    = LLM_DEFAULTS.llm_context_length
local min_words               = hs.settings.get("llm_min_words") or LLM_DEFAULTS.llm_min_words
local max_words               = hs.settings.get("llm_max_words") or LLM_DEFAULTS.llm_max_words
local num_predictions         = LLM_DEFAULTS.llm_num_predictions
local prediction_indent       = LLM_DEFAULTS.llm_pred_indent
local validation_mods         = LLM_DEFAULTS.llm_val_modifiers
local navigation_mods         = LLM_DEFAULTS.llm_nav_modifiers
local show_info_bar           = LLM_DEFAULTS.llm_show_info_bar
local sequential_mode         = LLM_DEFAULTS.llm_sequential_mode
local inactivity_debounce_sec = LLM_DEFAULTS.llm_debounce
local excluded_apps              = {}
local is_ai_preview_enabled      = true
local url_bar_filter_enabled     = true  -- When false, predictions are allowed inside browser URL bars
local secure_field_filter_enabled = true  -- When false, predictions are allowed inside password/secure fields
local auto_raise_temperature  = LLM_DEFAULTS.llm_auto_raise_temp
local is_streaming_enabled       = LLM_DEFAULTS.llm_streaming
-- When true, partial prediction batches are shown as each sequential variant completes;
-- when false, the tooltip only appears once the final batch with all predictions is ready
local is_streaming_multi_enabled = LLM_DEFAULTS.llm_streaming_multi
-- When true, the debounce is bypassed (delay = 0) when the buffer ends with whitespace,
-- meaning the user just completed a word and a suggestion can fire immediately
local instant_on_word_end        = LLM_DEFAULTS.llm_instant_on_word_end




-- ==========================================
-- ==========================================
-- ======= 3/ Configuration Setters =========
-- ==========================================
-- ==========================================


-- ==============================
-- ===== 3.1) AI Preview ========
-- ==============================

--- @param v boolean
function M.set_preview_ai_enabled(v)
	is_ai_preview_enabled = (v == true)
	Logger.debug(LOG, "AI preview: %s.", is_ai_preview_enabled and "on" or "off")
	if not v then tooltip.hide() end
end

--- @param color table|nil RGBA table, or nil to restore the module default.
function M.set_preview_ai_color(color)
	tooltip.set_accent_color("ai_prediction", color)
end



--- ===========================
--- ===== 3.2) LLM Config =====
--- ===========================

function M.set_llm_enabled(enabled)
	is_llm_enabled = (enabled == true)
	Logger.info(LOG, "LLM %s.", is_llm_enabled and "enabled" or "disabled")
	if not is_llm_enabled then M.reset(); return end
	WarmupController.schedule_warmup_with_retry("set_llm_enabled")
end

--- @return boolean
function M.get_llm_enabled() return is_llm_enabled end

function M.set_llm_model(model_name)
	local backend = core_llm.get_backend()
	if backend == "mlx" then core_llm.set_llm_model_mlx(model_name)
	else core_llm.set_llm_model_ollama(model_name) end
	active_model = model_name
	Logger.info(LOG, "Model set: '%s' (backend: %s).", tostring(model_name), tostring(backend))
	-- Trigger a warmup only when LLM is already enabled (avoids spurious requests
	-- during startup when set_llm_model fires before set_llm_enabled(true))
	if is_llm_enabled then
		WarmupController.schedule_warmup_with_retry("set_llm_model")
	end
end

function M.set_llm_display_model_name(name)
	llm_display_name = name
	Logger.debug(LOG, "Model display name: '%s'.", tostring(name))
end

function M.set_llm_show_model_name(name)
	-- Alias kept for compatibility with older menu versions
	llm_display_name = name
end

function M.set_llm_backend_name(label)
	llm_backend_label = label
	Logger.debug(LOG, "Backend label: '%s'.", tostring(label))
end

function M.set_llm_context_length(l)
	context_window_chars = l
	Logger.debug(LOG, "Context window: %s chars.", tostring(l))
end

function M.set_llm_temperature(t)
	temperature = t
	Logger.debug(LOG, "Temperature: %s.", tostring(t))
end

function M.set_llm_num_predictions(n)
	num_predictions = n
	Logger.debug(LOG, "Prediction count: %s.", tostring(n))
end

function M.set_llm_pred_indent(v)
	prediction_indent = v
	Logger.debug(LOG, "Prediction indent: %s.", tostring(v))
end

function M.set_llm_show_info_bar(v)
	show_info_bar = (v == true)
	Logger.debug(LOG, "Info bar: %s.", show_info_bar and "visible" or "hidden")
end

function M.set_llm_sequential_mode(v)
	sequential_mode = (v == true)
	Logger.debug(LOG, "Sequential mode: %s.", sequential_mode and "on" or "off")
end

function M.set_llm_auto_raise_temp(v)
	auto_raise_temperature = (v == true)
	Logger.debug(LOG, "Auto temperature raise: %s.", auto_raise_temperature and "on" or "off")
end

function M.set_llm_streaming(v)
	is_streaming_enabled = (v == true)
	core_llm.set_llm_streaming(v)
	Logger.debug(LOG, "Streaming: %s.", is_streaming_enabled and "on" or "off")
end

function M.set_llm_streaming_multi(v)
	is_streaming_multi_enabled = (v == true)
	Logger.debug(LOG, "Streaming multi: %s.", is_streaming_multi_enabled and "on" or "off")
end

function M.set_llm_instant_on_word_end(v)
	instant_on_word_end = (v == true)
	Logger.debug(LOG, "Instant on word end: %s.", instant_on_word_end and "on" or "off")
end

function M.set_llm_disabled_apps(apps)
	excluded_apps = apps
	Logger.debug(LOG, "Excluded apps: %d configured.", type(apps) == "table" and #apps or 0)
end

function M.set_llm_url_bar_filter_enabled(v)
	url_bar_filter_enabled = (v ~= false)
	Logger.debug(LOG, "URL bar filter: %s.", url_bar_filter_enabled and "on" or "off")
end

function M.set_llm_secure_field_filter_enabled(v)
	secure_field_filter_enabled = (v ~= false)
	Logger.debug(LOG, "Secure field filter: %s.", secure_field_filter_enabled and "on" or "off")
end

--- Accepts either a string ("alt") or a table ({"alt", "cmd"}) for convenience,
--- since the menu may pass either form depending on the number of modifiers configured.
function M.set_llm_val_modifiers(mods)
	validation_mods = type(mods) == "string" and { mods } or mods or {}
	Logger.debug(LOG, "Validation modifiers: [%s].", table.concat(validation_mods, ", "))
end

function M.set_llm_nav_modifiers(mods)
	navigation_mods = type(mods) == "string" and { mods } or mods or {}
	Logger.debug(LOG, "Navigation modifiers: [%s].", table.concat(navigation_mods, ", "))
end

function M.set_llm_min_words(w)
	min_words = w
	hs.settings.set("llm_min_words", w)
	Logger.debug(LOG, "Min words: %s.", tostring(w))
end

function M.set_llm_max_words(w)
	max_words = w
	hs.settings.set("llm_max_words", w)
	Logger.debug(LOG, "Max words: %s (0 = unlimited).", tostring(w))
end


-- =====================================
-- ===== 3.3) Debounce / Timer =========
-- =====================================

--- Rebuilds the inactivity timer with a new debounce interval.
--- The old timer is stopped before the new one is created to avoid a double-fire race.
function M.set_llm_debounce(seconds)
	inactivity_debounce_sec = seconds
	if _inactivity_timer then _inactivity_timer:stop() end
	_inactivity_timer = hs.timer.delayed.new(inactivity_debounce_sec, M.perform_check)
	Logger.debug(LOG, "Inactivity timer rebuilt: %.3fs.", inactivity_debounce_sec)
end





-- ==================================
--- ==================================
--- ======= 4/ Private Helpers =======
--- ==================================
-- ==================================

--- Guards functions that require _state. Logs an error and returns false if it is nil.
--- @param func_name string Name of the calling function (for the error log).
--- @return boolean True if _state is ready, false if it is nil.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Normalizes a modifier input (string or table) to a plain array of strings.
--- @param mod_input string|table The raw modifier value from the configuration.
--- @return table A flat array of modifier name strings.
local function normalize_mods(mod_input)
	if type(mod_input) == "string" then return { mod_input } end
	return mod_input or {}
end

--- Builds the short backend label shown in the info bar.
--- Falls back to a generic emoji name if no custom label is configured.
--- @return string The display label, or an empty string.
local function resolve_backend_label()
	if llm_backend_label and llm_backend_label ~= "" then return llm_backend_label end
	local backend = core_llm.get_backend()
	if backend == "mlx"    then return "MLX 🚀" end
	if backend == "ollama" then return "Ollama 🦙" end
	return ""
end

--- Formats the validation modifier shortcut for tooltip display.
--- Returns "none" to suppress the hint, or a zero-width space to hide it invisibly.
--- @param mods table The normalized validation modifier array.
--- @return string Formatted shortcut string (e.g. "alt", "cmd+shift", or invisible).
local function format_validation_shortcut(mods)
	if #mods == 1 and mods[1] == "none" then return "none" end
	-- Zero-width space: renders as invisible but keeps the slot present in the layout
	if #mods == 0 then return "\226\128\139" end
	return table.concat(mods, "+")
end

--- Strips the em-dash suffix from a profile label for compact info-bar display.
--- "Mon profil — texte long" → "Mon profil"
--- @param label string|nil The raw profile label.
--- @return string|nil The trimmed label, or nil if it was blank.
local function trim_profile_label(label)
	if type(label) ~= "string" then return nil end
	local clean = label:match("^%s*(.-)%s*$")
	if clean == "" then return nil end
	local head = clean:match("^(.-)%s*—")
	-- Pick the head only if it has actual content (head:match("%S")). A bare
	-- em-dash like "— foo" yields head = "" which previously fell through to
	-- `clean` and re-introduced the dash; checking %S guards against that.
	local picked = (head and head:match("%S")) and head or clean
	picked = picked:gsub("^%s+", ""):gsub("%s+$", "")
	-- Also strip a stray trailing em-dash so concatenation downstream never
	-- produces the user-reported "— (vide)" tail.
	picked = picked:gsub("%s*—%s*$", "")
	if picked == "" then return nil end
	return picked
end

--- Assembles the info-bar text displayed beneath the prediction list.
--- Returns nil when model_name is absent, which hides the info bar entirely.
--- @param model_name string Display name of the active model.
--- @param elapsed_ms number|nil Round-trip latency in milliseconds, or nil.
--- @param backend string|nil Short backend label (e.g. "MLX 🚀"), or nil.
--- @param profile_name string|nil Active profile label, or nil.
--- @return string|nil The formatted info string, or nil.
local function build_info_bar_text(model_name, elapsed_ms, backend, profile_name)
	if not model_name or model_name == "" then return nil end

	local pieces = { model_name }
	if type(backend) == "string" and backend ~= "" then pieces[#pieces + 1] = backend end
	local short_profile = trim_profile_label(profile_name)
	if short_profile and short_profile ~= "" then pieces[#pieces + 1] = short_profile end
	-- Concat with em-dash separators in a single pass — guarantees no
	-- trailing or doubled " — " regardless of which fields are present.
	local text = table.concat(pieces, " — ")

	-- Note: elapsed_ms is intentionally NOT rendered here. tooltip_llm owns the
	-- timing zone and composes "Model · Profile — TTFT [— TTLT]" so we
	-- don't duplicate (and contradict) timing across two zones. The
	-- elapsed_ms parameter is retained for backwards compatibility but its
	-- value is discarded on purpose.
	local _ = elapsed_ms

	return text
end

--- Syncs the user-configured dismiss delay into the tooltip engine and resets the countdown.
--- Called after the final prediction batch arrives so the timer starts with the correct duration.
--- A delay of 0 keeps the tooltip on screen indefinitely.
local function reset_llm_dismiss_timer()
	local delay = (_state and _state.DELAYS and _state.DELAYS.llm_prediction) or 0
	tooltip.set_llm_timeout(delay)
	tooltip.reset_llm_timer()
	Logger.debug(LOG, "LLM dismiss timer reset (delay: %gs).", delay)
end

--- Computes an adaptive debounce delay based on the user's current typing speed.
--- Fast typing → extend delay (prediction would be stale before it arrives).
--- Slow/paused → shorten delay (user is thinking, fire sooner).
--- If the buffer shrank since the last request, the user is still correcting —
--- keep the full configured delay to avoid sending a broken intermediate state.
--- @return number The debounce delay in seconds to use for this timer start.
local function compute_adaptive_debounce()
	-- Correction guard: never reduce delay while the user is still deleting
	local cur_len = (_state and type(_state.buffer) == "string") and #_state.buffer or 0
	if cur_len < _last_request_buffer_len then
		return inactivity_debounce_sec
	end

	local ok, stats = pcall(keylogger.get_live_stats)
	local wpm = (ok and type(stats) == "table") and (tonumber(stats.wpm_physical) or 0) or 0

	if wpm > FAST_TYPING_WPM then
		return math.min(inactivity_debounce_sec * DEBOUNCE_FAST_MULT, DEBOUNCE_MAX_SEC)
	elseif wpm > 0 and wpm < SLOW_TYPING_WPM then
		return math.max(inactivity_debounce_sec * DEBOUNCE_SLOW_MULT, DEBOUNCE_MIN_SEC)
	end
	return inactivity_debounce_sec
end

--- Arms the inactivity debounce timer to fire perform_check() after silence.
--- @param delay_override number|nil Override in seconds; uses adaptive debounce if nil.
local function start_inactivity_timer(delay_override)
	if not is_llm_enabled or inactivity_debounce_sec < 0 or not _inactivity_timer then return end
	if delay_override then
		_inactivity_timer:start(delay_override)
		Logger.trace(LOG, "Inactivity timer started (override: %.3fs).", delay_override)
	else
		local delay = compute_adaptive_debounce()
		_inactivity_timer:start(delay)
		Logger.trace(LOG, "Inactivity timer started (adaptive: %.3fs).", delay)
	end
end

--- Returns the currently focused accessibility element, using the Hammerspoon-correct API.
--- hs.axuielement.focusedElement() does not exist — the canonical way is to query
--- AXFocusedUIElement from the application-level accessibility element.
--- @param front userdata The frontmost hs.application.
--- @return userdata|nil The focused AX element, or nil on failure.
local function get_focused_element(front)
	if not front then return nil end
	local ok_ax, ax = pcall(hs.axuielement.applicationElementForPID, front:pid())
	if not ok_ax or not ax then return nil end
	local ok_fe, focused = pcall(function() return ax:attributeValue("AXFocusedUIElement") end)
	return (ok_fe and focused) or nil
end

--- Returns true when the currently focused accessibility element is a secure text field
--- (e.g. a password input). Works across all applications, not just browsers.
--- @param front userdata|nil The frontmost hs.application.
--- @return boolean True if a password/secure field has focus.
local function is_secure_field_focused(front)
	if not front then return false end
	local focused = get_focused_element(front)
	if not focused then return false end
	local ok_role, role    = pcall(function() return focused:attributeValue("AXRole") end)
	local ok_sub,  subrole = pcall(function() return focused:attributeValue("AXSubrole") end)
	return (ok_role and role    == "AXSecureTextField")
	    or (ok_sub  and subrole == "AXSecureTextField")
end

--- Returns true when the currently focused accessibility element is a browser URL bar.
--- Prevents AI predictions from firing while the user is typing a URL or search query.
---
--- Detection strategy (three layers, each more expensive than the last):
---   1. AXSubrole == "AXURLField" — Safari and native WebKit controls; definitive.
---   2. AXIdentifier pattern match — Chrome, Brave, Opera; reliable when id is set.
---   3. Ancestor toolbar check — Edge, Firefox, Arc; no identifier exposed, but a
---      text field directly inside an AXToolbar in a known browser is always the URL bar.
---      Only attempted when the frontmost app is a known browser bundle ID.
---
--- @param front userdata|nil The frontmost hs.application (passed from the caller to
---              avoid a redundant frontmostApplication() call).
--- @return boolean True if a URL-bar-type element has input focus.
local function is_url_bar_focused(front)
	if not front then return false end
	-- Only check known browsers — avoids expensive AX calls for non-browser apps
	local bid = front:bundleID() or ""
	if not BROWSER_BUNDLE_IDS[bid] then return false end

	local focused = get_focused_element(front)
	if not focused then return false end

	-- Only text fields can be URL bars — skip everything else early
	local ok_role, role = pcall(function() return focused:attributeValue("AXRole") end)
	if not ok_role or role ~= "AXTextField" then return false end

	-- Layer 1 — Safari / WebKit: AXSubrole is explicitly "AXURLField"
	local ok_sub, subrole = pcall(function() return focused:attributeValue("AXSubrole") end)
	if ok_sub and subrole == AX_URL_SUBROLE then return true end

	-- Layer 2 — Chrome / Brave / Opera: AXIdentifier contains a recognisable pattern
	local ok_id, identifier = pcall(function() return focused:attributeValue("AXIdentifier") end)
	if ok_id and type(identifier) == "string" and identifier ~= "" then
		local id_lower = identifier:lower()
		for _, pattern in ipairs(URL_BAR_ID_PATTERNS) do
			if id_lower:find(pattern, 1, true) then return true end
		end
	end

	-- Layer 3 — Edge / Firefox / Arc: no usable identifier; check the parent hierarchy.
	-- Walk up two levels: input may be directly in the toolbar (Firefox) or wrapped in
	-- an AXGroup inside the toolbar (Chromium / Edge omnibox structure).
	local ok_p, parent = pcall(function() return focused:attributeValue("AXParent") end)
	if ok_p and parent then
		local ok_pr, parent_role = pcall(function() return parent:attributeValue("AXRole") end)
		if ok_pr and parent_role == "AXToolbar" then return true end
		local ok_gp, grandparent = pcall(function() return parent:attributeValue("AXParent") end)
		if ok_gp and grandparent then
			local ok_gr, gp_role = pcall(function() return grandparent:attributeValue("AXRole") end)
			if ok_gr and gp_role == "AXToolbar" then return true end
		end
	end

	return false
end

--- Returns the application that currently has keyboard focus.
--- Prefers the app owning the focused window because floating-panel launchers
--- (e.g. Raycast) accept keyboard input without becoming the macOS frontmost
--- application — using frontmostApplication() would return the previously
--- active app and incorrectly inherit its exclusion rules.
--- @return userdata|nil hs.application object, or nil on failure.
local function get_focused_app()
	-- focusedWindow() returns the window with keyboard focus regardless of
	-- whether its parent app is the NSWorkspace frontmost application
	local ok_fw, fw = pcall(hs.window.focusedWindow)
	if ok_fw and fw then
		local ok_app, app = pcall(function() return fw:application() end)
		if ok_app and app then return app end
	end
	return hs.application.frontmostApplication()
end

--- Returns true when LLM predictions should be suppressed for the current app.
--- Checks both the keymap global window ignore list and the bridge per-app exclusion list.
--- @return boolean True if the active window or app is on an exclusion list.
local function is_blocked_for_current_app()
	if not _state then return false end
	if km_utils.is_ignored_window(_state.ignored_window_titles, _state.ignored_window_patterns) then
		return true
	end
	-- Use the app that owns the focused window, not the macOS frontmost app
	local front = get_focused_app()
	-- Password/secure fields in any application
	if secure_field_filter_enabled and is_secure_field_focused(front) then
		Logger.debug(LOG, "Secure field focused — LLM request skipped.")
		return true
	end
	-- URL bars (address fields) in browsers: skip when the filter is enabled
	if url_bar_filter_enabled and is_url_bar_focused(front) then
		Logger.debug(LOG, "URL bar focused — LLM request skipped.")
		return true
	end
	if not front then return false end
	local bid  = front:bundleID() or ""
	local path = front:path() or ""
	local name = (front:name() or ""):lower()

	for _, app in ipairs(excluded_apps) do
		local has_path = type(app.appPath) == "string" and app.appPath ~= ""
		local has_bid  = type(app.bundleID) == "string" and app.bundleID ~= ""
		local configured_name = type(app.name) == "string" and app.name:lower() or ""
		local same_name = (not has_path and not has_bid and configured_name ~= ""
			and (configured_name == name
			or name:find(configured_name, 1, true)
			or configured_name:find(name, 1, true)))
		local path_match = has_path and (app.appPath == path)
		local bid_match  = (not has_path and has_bid and app.bundleID == bid)

		if path_match
			or bid_match
			or same_name
		then
			Logger.debug(LOG, "App excluded: '%s' — LLM request skipped.", front:name() or bid)
			return true
		end
	end
	return false
end

--- Cancels the inactivity timer without firing the LLM check.
local function stop_inactivity_timer()
	if _inactivity_timer then
		_inactivity_timer:stop()
		Logger.done(LOG, "Inactivity timer stopped.")
	end
end




-- ============================================
-- ============================================
-- ======= 5/ LLM Prediction Pipeline =========
-- ============================================
-- ============================================


--- Returns instant next-word candidates from the keylogger's in-memory word-bigram
--- index, without any network call. Results are shown immediately while the LLM warms
--- up and replaced in-place when the real response arrives.
---
--- Strategy:
---   1. Extract the last complete word from the buffer (requires buffer to end with a
---      word separator — no prediction at mid-word since the partial word constrains the
---      result space better than bigrams do).
---   2. Scan every app's w_bg (word-bigram) table for entries of the form "lastword X".
---   3. Sort by frequency, deduplicate, cap at NGRAM_MAX_PREDS.
---
--- @param buffer string The current tracked context buffer.
--- @return table Array of placeholder prediction objects (same shape as LLM predictions).
local function ngram_predict(buffer)
	-- Only meaningful at word boundaries — mid-word completion is the LLM's job
	if not buffer:match("%s$") then return {} end

	-- Extract the last completed word (skip trailing whitespace)
	local last_word = buffer:match("(%S+)%s+$")
	if not last_word or last_word == "" then return {} end
	last_word = last_word:lower()

	local ok_idx, today_idx = pcall(keylogger.get_ngram_index)
	if not ok_idx or type(today_idx) ~= "table" then return {} end

	-- Aggregate counts across all apps — more data = better signal, and the
	-- prediction engine already has the per-app LLM exclusion layer above
	local counts = {}
	local prefix = last_word .. " "
	for _, app_idx in pairs(today_idx) do
		local w_bg = type(app_idx) == "table" and app_idx.w_bg
		if type(w_bg) == "table" then
			for key, entry in pairs(w_bg) do
				if key:sub(1, #prefix) == prefix and type(entry) == "table" then
					local next_word = key:sub(#prefix + 1)
					if next_word ~= "" then
						counts[next_word] = (counts[next_word] or 0) + (entry.c or 0)
					end
				end
			end
		end
	end

	-- Collect candidates above the noise floor
	local candidates = {}
	for word, count in pairs(counts) do
		if count >= NGRAM_MIN_COUNT then
			table.insert(candidates, { word = word, count = count })
		end
	end
	if #candidates == 0 then return {} end

	table.sort(candidates, function(a, b) return a.count > b.count end)

	local result = {}
	local seen   = {}
	for _, c in ipairs(candidates) do
		if not seen[c.word] and #result < NGRAM_MAX_PREDS then
			seen[c.word] = true
			-- Prediction appends a space + word after the cursor (no deletions needed)
			table.insert(result, {
				to_type              = " " .. c.word,
				deletes              = 0,
				chunks               = {},
				nw                   = c.word,
				has_corrections      = false,
				disable_bold         = true,
				-- Treated as a stream-placeholder so on_partial_cb and on_success
				-- both evict it cleanly when real LLM tokens arrive
				_is_stream_placeholder = true,
			})
		end
	end

	Logger.debug(LOG, "N-gram instant prediction: %d candidate(s) for '%s'.", #result, last_word)
	return result
end


--- Runs the full LLM prediction pipeline against the current buffer state.
---
--- Execution flow:
---   1. Validates preconditions: initialized, LLM enabled, not in an excluded app.
---   2. Syncs the dismiss delay into the tooltip engine BEFORE showing predictions,
---      so the auto-dismiss timer is created with the correct duration immediately.
---   3. Shows a loading indicator for immediate visual feedback.
---   4. Fires the async LLM request with streaming enabled.
---   5. Progressively renders predictions as they arrive, deduplicating on the fly.
---   6. Starts the auto-dismiss countdown once the final batch is confirmed.
---
--- @param force_trigger boolean If true, bypasses the freshness and word-count guards.
--- @param profile_name string|nil Optional profile label override shown in the info bar.
function M.perform_check(force_trigger, profile_name)
	if not require_state("perform_check") then return end
	force_trigger = force_trigger == true

	if not is_llm_enabled then
		Logger.debug(LOG, "LLM disabled — request skipped.")
		return
	end
	-- Backend readiness gate: until the warmup has confirmed the model is loaded
	-- and serving inference, dispatching a request would show the loading tooltip
	-- against a server that simply cannot answer in time. Skip silently so the
	-- user sees no spinner while the backend warms up.
	if type(core_llm.is_backend_ready) == "function" and not core_llm.is_backend_ready() then
		Logger.debug(LOG, "Backend not ready yet — request skipped (model warming up).")
		return
	end
	if is_blocked_for_current_app() then
		Logger.debug(LOG, "App excluded — LLM request skipped.")
		return
	end

	-- Sync the dismiss delay NOW, before any show_predictions() call,
	-- so the auto-dismiss timer is created with the correct value from the very first frame.
	-- delay = 0 → tooltip_llm will not start any timer (infinite display).
	local dismiss_delay = (_state.DELAYS and _state.DELAYS.llm_prediction) or 0
	tooltip.set_llm_timeout(dismiss_delay)

	local buffer = _state.buffer

	-- Delegate prompt parameter building to PromptBuilder
	local params, skip_reason, signature = PromptBuilder.build(buffer, {
		temperature             = temperature,
		max_words               = max_words,
		min_words               = min_words,
		num_predictions         = num_predictions,
		auto_raise_temperature  = auto_raise_temperature,
	}, last_buffer_signature, force_trigger)

	if not params then
		Logger.debug(LOG, "%s — LLM request skipped.", skip_reason or "unknown reason")
		return
	end

	-- Backend-aware request floor — re-arm the debounce timer for the
	-- remaining gap instead of firing immediately. force_trigger (the
	-- manual hotkey path) bypasses the floor because it is an explicit user
	-- request, not a per-keystroke burst.
	if not force_trigger then
		local now_s        = hs.timer.secondsSinceEpoch()
		local backend_id   = core_llm.get_backend and core_llm.get_backend() or "ollama"
		local min_interval = ApiCommon.get_rate_limit_min_interval_s(backend_id)
		local elapsed      = now_s - _last_request_at_s
		if _last_request_at_s > 0 and elapsed < min_interval then
			local remaining = min_interval - elapsed
			Logger.debug(LOG, "Backend '%s' floor (%dms) — deferring %dms.",
				backend_id, math.floor(min_interval * 1000), math.floor(remaining * 1000))
			if _inactivity_timer then _inactivity_timer:stop() end
			_inactivity_timer = hs.timer.doAfter(remaining, function() M.perform_check(force_trigger, profile_name) end)
			return
		end
	end

	last_buffer_signature    = signature
	_last_request_buffer_len = #buffer
	_last_request_at_s       = hs.timer.secondsSinceEpoch()

	-- Pre-build a model/backend info bar for use during streaming and n-gram display.
	-- elapsed_ms is omitted here (stream not yet complete); on_success will replace this
	-- with the version that includes round-trip latency once the final batch arrives.
	local active_profile_now   = core_llm.get_active_profile()
	local display_profile_now  = profile_name or (active_profile_now and active_profile_now.label)
	local streaming_info_bar   = show_info_bar
		and build_info_bar_text(llm_display_name or core_llm.get_current_model(), nil, resolve_backend_label(), display_profile_now)
		or nil

	-- N-gram instant prediction: show a local word-bigram candidate immediately
	-- (< 1 ms) while the async LLM request is in flight. It is a stream-placeholder so
	-- it gets evicted cleanly when the first streaming token or final on_success arrives.
	local ngram_preds = ngram_predict(buffer)
	if #ngram_preds > 0 then
		pending_predictions = ngram_preds
		predictions_visible = true
		tooltip.show_predictions(
			ngram_preds, 1, is_ai_preview_enabled, streaming_info_bar,
			nil, prediction_indent, normalize_mods(navigation_mods),
			tooltip.tint("ai_prediction"), "…", math.max(#ngram_preds, num_predictions)
		)
	end

	local model_to_use    = core_llm.get_current_model()
	local num_preds       = params.num_preds

	Logger.start(LOG, "LLM request — model: '%s' | temp: %.2f | %d pred(s) | max tokens: %d.",
		tostring(model_to_use), params.req_temperature, num_preds, params.max_tokens)

	-- Arm the backend-agnostic chain timing instrumentation. The tooltip
	-- ignores subsequent calls within the same chain, so this is safe to call
	-- on every perform_check — the first one in a chain wins and TTLT spans
	-- all subsequent links until M.reset() fires mark_chain_complete().
	pcall(tooltip.set_chain_start, hs.timer.secondsSinceEpoch())

	-- Loading indicator: only shown when nothing is already on screen (n-gram placeholder
	-- or previous LLM predictions). Avoids the blank gap that the spinner creates —
	-- existing content stays visible and is replaced in-place when new predictions arrive.
	if not predictions_visible then
		tooltip.show_loading(i18n.get("llm.generating"), is_ai_preview_enabled, tooltip.tint("ai_loading"))
	else
		-- Mark any finalized predictions as placeholders so on_partial_cb evicts them
		-- cleanly when streaming tokens start arriving, without needing to hide the tooltip.
		for _, p in ipairs(pending_predictions) do
			p._is_stream_placeholder = true
		end
	end

	-- Bump counters to discard any in-flight callbacks that are now stale
	llm_request_counter   = llm_request_counter + 1
	fetch_request_counter = fetch_request_counter + 1
	local my_fetch_id     = fetch_request_counter

	-- Shared noise gate used by both the streaming partial path and the final on_success
	-- filter — keeps both in lockstep so no hallucination ever appears during streaming
	-- that the final filter would later remove
	local function is_noise_pred(to_type)
		if not to_type or to_type:gsub("[%s%.…]", "") == "" then return true end
		local text_lower = to_type:lower()
		local prev_char  = buffer:match(".*(%S)")
		local first_ch   = to_type:match("^%s*(.)") or ""
		local ends_sent  = prev_char and prev_char:match("[%.%!%?…:;]") ~= nil
		return (text_lower:match("^%s*suite%s+finale") ~= nil)
			or (text_lower:match("^%s*</") ~= nil)
			or (text_lower:match("^%s*vous avez besoin de plus") ~= nil)
			or (text_lower:match("^%s*vous etes les plus") ~= nil)
			or (text_lower:match("^%s*vous%s") ~= nil and buffer:lower():match("vous") == nil)
			or (first_ch:match("[A-Z]") ~= nil and not ends_sent)
			or (to_type:find(":", 1, true) ~= nil)
	end

	-- Mutable references for shared access between the engine and streaming callbacks
	local pending_ref = { value = pending_predictions }
	local visible_ref = { value = predictions_visible }

	-- Keep local state in sync when the refs are updated by callbacks
	local function sync_refs()
		pending_predictions = pending_ref.value
		predictions_visible = visible_ref.value
	end

	-- Build the streaming callbacks via StreamingHandler
	local on_partial_cb, on_success_cb, on_fail_cb = StreamingHandler.build_callbacks({
		buffer                  = buffer,
		tail                    = params.tail,
		my_fetch_id             = my_fetch_id,
		get_fetch_id            = function() return fetch_request_counter end,
		is_streaming_enabled    = is_streaming_enabled,
		is_streaming_multi_enabled = is_streaming_multi_enabled,
		num_predictions         = num_preds,
		show_info_bar           = show_info_bar,
		streaming_info_bar      = streaming_info_bar,
		prediction_indent       = prediction_indent,
		validation_mods         = normalize_mods(validation_mods),
		navigation_mods         = normalize_mods(navigation_mods),
		model_to_use            = model_to_use,
		llm_display_name        = llm_display_name,
		profile_name            = profile_name,
		build_info_bar_text     = build_info_bar_text,
		resolve_backend_label   = resolve_backend_label,
		is_noise_pred           = is_noise_pred,
		reset_llm_dismiss_timer = reset_llm_dismiss_timer,
		is_ai_preview_enabled   = is_ai_preview_enabled,
		pending_predictions_ref = pending_ref,
		predictions_visible_ref = visible_ref,
	})

	-- Wrap callbacks to keep local state in sync after each call
	local function on_success(raw_predictions, elapsed_ms, is_final, is_batch_progressive)
		on_success_cb(raw_predictions, elapsed_ms, is_final, is_batch_progressive)
		sync_refs()
	end
	local function on_fail()
		on_fail_cb()
		sync_refs()
	end
	local on_partial = on_partial_cb and function(partial_raw)
		on_partial_cb(partial_raw)
		sync_refs()
	end or nil

	-- Arm the watchdog via StreamingHandler
	StreamingHandler.arm_watchdog({
		my_fetch_id             = my_fetch_id,
		get_fetch_id            = function() return fetch_request_counter end,
		pending_predictions_ref = pending_ref,
		predictions_visible_ref = visible_ref,
		validation_mods         = normalize_mods(validation_mods),
		navigation_mods         = normalize_mods(navigation_mods),
		show_info_bar           = show_info_bar,
		llm_display_name        = llm_display_name,
		prediction_indent       = prediction_indent,
		is_ai_preview_enabled   = is_ai_preview_enabled,
		build_info_bar_text     = build_info_bar_text,
		resolve_backend_label   = resolve_backend_label,
	})

	core_llm.fetch_llm_prediction(
		params.context_buffer, params.tail, model_to_use, params.req_temperature,
		params.max_tokens, num_preds,
		on_success,
		on_fail,
		sequential_mode, force_trigger, function() return fetch_request_counter end,
		on_partial
	)
end

--- Clears all active predictions and fully resets the prediction pipeline state.
--- Emits a keylogger dismissal event when predictions were visible before the reset.
--- The keymap bridge wraps this to also handle hotstring dismissal telemetry.
function M.reset()
	local was_visible = predictions_visible and #pending_predictions > 0

	if was_visible then
		keylogger.log_llm_dismissed(nil, pending_predictions)
	end

	-- Finalise chain timing before tearing down state so the tooltip can
	-- compute TTLT against the last update and render the full line one last
	-- time. Safe to call unconditionally — tooltip ignores it if no chain
	-- was armed (e.g. reset fired before any backend dispatch).
	pcall(tooltip.mark_chain_complete)

	pending_predictions        = {}
	predictions_visible        = false
	last_buffer_signature      = nil
	llm_request_counter        = llm_request_counter + 1
	fetch_request_counter      = fetch_request_counter + 1

	StreamingHandler.reset_failure_count()
	tooltip.hide()
	stop_inactivity_timer()
	StreamingHandler.stop_watchdog()
	-- Cancel any in-flight streaming curl task so it doesn't fire stale callbacks
	if is_streaming_enabled then pcall(core_llm.cancel_streaming) end

	if was_visible then
		Logger.debug(LOG, "Predictions cleared (were visible).")
	end
end

--- Captures the prediction at the given index for an apply operation.
--- Sets predictions_visible to false so subsequent reset() does not emit a dismissal event —
--- the bridge will log the acceptance event instead.
--- @param idx number The 1-based prediction index to consume.
--- @return table|nil pred The prediction entry, or nil if the index is invalid.
--- @return table|nil all_preds The full prediction pool at the time of consumption, or nil.
function M.consume(idx)
	local pred = pending_predictions[idx]
	if not pred then
		Logger.warn(LOG, "consume(%d): invalid index (pool of %d prediction(s)).", idx, #pending_predictions)
		return nil, nil
	end
	local all_preds = pending_predictions
	-- Prevent reset() from emitting a dismissal event; the bridge logs acceptance instead
	predictions_visible = false
	return pred, all_preds
end

--- Arms the chain trigger after a prediction is accepted.
--- Sets chain_pending and starts a fallback timer in case the F16 signal is missed.
--- Must be called BEFORE hs.eventtap.keyStroke({}, "f16", 0) is sent by the bridge.
function M.arm_chain()
	if not require_state("arm_chain") then return end
	if _inactivity_timer    then _inactivity_timer:stop() end
	if _chain_trigger_timer then _chain_trigger_timer:stop() end

	chain_pending = true
	_state.suppress_rescan_keep_buffer(CHAIN_FALLBACK_SEC)

	_chain_trigger_timer = hs.timer.doAfter(CHAIN_FALLBACK_SEC, function()
		if chain_pending then
			chain_pending = false
			Logger.warn(LOG, "Fallback chain triggered — F16 signal was missed.")
			M.perform_check(true)
		end
	end)
end





-- ============================
--- =============================
--- ======= 6/ Public API =======
--- =============================
-- ============================

--- Initializes the engine by injecting the shared keymap core state.
--- Must be called exactly once before any other engine function.
--- @param core_state table The shared state object from modules/keymap/init.lua.
function M.init(core_state)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): invalid core_state (expected table, got %s).", type(core_state))
		return
	end
	_state = core_state

	-- Initialize submodules with their required dependencies
	WarmupController.init({
		core_llm        = core_llm,
		get_llm_enabled = function() return is_llm_enabled end,
	})
	StreamingHandler.init({
		core_llm  = core_llm,
		tooltip   = tooltip,
		keylogger = keylogger,
	})

	Logger.debug(LOG, "Prediction engine state injected (%d mapping(s)).", #(core_state.mappings or {}))
end

--- Public alias so the expander can re-arm the LLM timer after a text replacement.
--- Without this, the expander's _llm.start_timer() call would throw a nil-function error,
--- causing onKeyDown to return false instead of true, which lets the trigger character
--- through to the app — resulting in one extra character on screen before the expansion.
--- @param delay_override number|nil Optional timer override in seconds.
function M.start_timer(delay_override)
	start_inactivity_timer(delay_override)
end

--- Arms the inactivity timer after a completed word (buffer ends with whitespace).
--- When instant_on_word_end is enabled, bypasses the debounce entirely (delay = 0)
--- so the prediction fires as soon as the word boundary is detected.
function M.start_timer_word_end()
	if instant_on_word_end then
		start_inactivity_timer(0)
	else
		start_inactivity_timer()
	end
end

--- Cancels the inactivity timer without firing the LLM check.
--- Also terminates any in-flight streaming task: the GPU should not keep generating
--- tokens for a request that is now stale. Without this, a new request queues behind
--- the old curl process and the perceived TTFT is (old generation remaining) + (new TTFT).
function M.stop_timer()
	stop_inactivity_timer()
	core_llm.cancel_streaming()
end

--- Consumes the F16 chain signal if a chain is pending.
--- Called from the keymap bridge's keystroke handler before any other routing.
--- @param keyCode number The macOS key code of the pressed key.
--- @return boolean True if the F16 event was consumed and the chain was triggered.
function M.handle_chain_signal(keyCode)
	if keyCode ~= KEYCODE_LLM_CHAIN or not chain_pending then return false end
	chain_pending = false
	if _chain_trigger_timer then _chain_trigger_timer:stop() end
	Logger.debug(LOG, "F16 received — triggering chained LLM.")
	M.perform_check(true)
	return true
end

--- @return boolean True while predictions are displayed and awaiting user interaction.
function M.is_visible() return predictions_visible end

--- @return boolean True between an accepted prediction and the incoming F16 chain signal.
function M.is_chain_pending() return chain_pending end

--- @return table The current pending predictions array.
function M.get_predictions() return pending_predictions end

--- @return number|nil The currently selected prediction index, or nil.
function M.get_current_index() return tooltip.get_current_index() end

--- Navigates the prediction selection by the given delta.
--- @param delta number Positive moves down the list, negative moves up.
function M.navigate(delta) tooltip.navigate(delta) end

--- Normalizes a modifier input (string or table) to a plain array of strings.
--- Exported so the keymap bridge can use it when routing modifier+key combos.
--- @param mod_input string|table
--- @return table
function M.normalize_mods(mod_input) return normalize_mods(mod_input) end

--- @return table Normalized navigation modifier array.
function M.get_navigation_mods() return normalize_mods(navigation_mods) end

--- @return table Normalized validation modifier array.
function M.get_validation_mods() return normalize_mods(validation_mods) end

-- Export constants needed by external callers
M.KEYCODE_LLM_CHAIN  = KEYCODE_LLM_CHAIN   -- Bridge uses this to detect the chain signal
M.CHAIN_FALLBACK_SEC = CHAIN_FALLBACK_SEC  -- Bridge passes this to suppress_rescan_keep_buffer


-- Create the inactivity debounce timer at module load.
-- If the debounce delay changes later, set_llm_debounce() recreates this timer.
_inactivity_timer = hs.timer.delayed.new(inactivity_debounce_sec, M.perform_check)

-- Enable Enter-to-accept only after the user has explicitly navigated at least once;
-- without this guard, pressing Enter on the very first shown prediction would type a newline.
tooltip.set_navigate_callback(function()
	tooltip.set_enter_validates(true)
end)

return M
