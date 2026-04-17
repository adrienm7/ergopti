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
--- 3. Chain trigger: after a prediction is accepted, arms F20 detection so the
---    next LLM request fires as soon as the HID queue drains.
--- 4. Public API surface: exposed to the keymap bridge and menu modules via
---    typed setters and query helpers; no shared mutable globals.
--- ==============================================================================

local M = {}

local hs = hs

local core_llm  = require("modules.llm")
local Parser    = require("modules.llm.parser")
local Logger    = require("lib.logger")
local tooltip   = require("ui.tooltip")
local keylogger = require("modules.keylogger")
local km_utils  = require("modules.keymap.utils")

local LOG    = "llm.prediction_engine"
local _state = nil  -- Shared keymap core state; injected via M.init()




-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- ── macOS key code ────────────────────────────────────────────────────────────

-- Synthetic "typing complete" signal sent by apply_prediction after all HID events.
-- Exported so the keymap bridge can detect it without duplicating the constant.
local KEYCODE_F20 = 90

-- ── LLM request parameters ────────────────────────────────────────────────────
-- Token budget formula: max_tokens = max(MIN_MAX_TOKENS, effective_max_words * RATIO + OVERHEAD)

local CONTEXT_TAIL_WORDS    = 5    -- Words from buffer tail forwarded as rolling LLM context
local DEFAULT_MAX_TOKENS    = 150  -- Token budget when max_words is uncapped (= 0)
local MIN_MAX_TOKENS        = 15   -- Hard floor on the token budget regardless of word settings
local WORDS_TO_TOKENS_RATIO = 6    -- Conservative words→tokens multiplier for budget estimation
local TOKEN_BUDGET_OVERHEAD = 10   -- Fixed overhead appended to the computed token budget

-- ── Diversity / temperature ───────────────────────────────────────────────────

local TEMP_DIVERSITY_CAP      = 1.0  -- Upper bound when auto_raise_temperature is active
local TEMP_INCREMENT_PER_PRED = 0.1  -- Temperature step per extra prediction requested (+0.1 each)

-- ── UI / display parameters ───────────────────────────────────────────────────

local SPINNER_FPS = 6  -- Frames per second for the streaming progress spinner

-- ── Timing constants ──────────────────────────────────────────────────────────

local STREAM_WATCHDOG_SEC = 12.0  -- Surface partial results after this many seconds of stream stall
local CHAIN_FALLBACK_SEC  = 0.5   -- Fire chain LLM if the F20 signal is somehow missed

-- Reference to the LLM engine defaults, used once at module load to seed Section 2
local LLM_DEFAULTS = core_llm.DEFAULT_STATE




-- ================================
-- ================================
-- ======= 2/ Mutable State =======
-- ================================
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

-- ── Timers ────────────────────────────────────────────────────────────────────

-- Fires perform_check() after inactivity_debounce_sec of silence
local _inactivity_timer = nil

-- Fallback: fires perform_check() if the F20 chain signal is somehow missed
local _chain_trigger_timer = nil

-- Surfaces partial streaming results if the LLM stream stalls
local _stream_watchdog_timer = nil

-- True between an accepted prediction and the F20 chain trigger that follows it
local chain_pending = false

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
local excluded_apps           = {}
local is_ai_preview_enabled   = true
local auto_raise_temperature  = LLM_DEFAULTS.llm_auto_raise_temp
local is_streaming_enabled       = LLM_DEFAULTS.llm_streaming
-- When true, partial prediction batches are shown as each sequential variant completes;
-- when false, the tooltip only appears once the final batch with all predictions is ready
local is_streaming_multi_enabled = LLM_DEFAULTS.llm_streaming_multi




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


-- ===========================
-- ===== 3.2) LLM Config =====
-- ===========================

function M.set_llm_enabled(enabled)
	is_llm_enabled = (enabled == true)
	Logger.info(LOG, "LLM %s.", is_llm_enabled and "enabled" or "disabled")
	if not is_llm_enabled then M.reset(); return end
	-- Pre-load model weights into GPU when the user enables the LLM; deferred so
	-- the rest of the startup sequence settles before the warmup request fires
	if type(active_model) == "string" and active_model ~= "" then
		hs.timer.doAfter(2, function() pcall(core_llm.warmup_model, active_model) end)
	end
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
		hs.timer.doAfter(2, function() pcall(core_llm.warmup_model, model_name) end)
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

function M.set_llm_disabled_apps(apps)
	excluded_apps = apps
	Logger.debug(LOG, "Excluded apps: %d configured.", type(apps) == "table" and #apps or 0)
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


-- ==================================
-- ===== 3.3) Debounce / Timer =======
-- ==================================

--- Rebuilds the inactivity timer with a new debounce interval.
--- The old timer is stopped before the new one is created to avoid a double-fire race.
function M.set_llm_debounce(seconds)
	inactivity_debounce_sec = seconds
	if _inactivity_timer then _inactivity_timer:stop() end
	_inactivity_timer = hs.timer.delayed.new(inactivity_debounce_sec, M.perform_check)
	Logger.debug(LOG, "Inactivity timer rebuilt: %.3fs.", inactivity_debounce_sec)
end




-- ==================================
-- ==================================
-- ======= 4/ Private Helpers =======
-- ==================================
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

--- Builds a deduplication key from a prediction's visual diff content.
--- Two predictions with identical keys are considered duplicates and merged during streaming.
--- The key is the concatenated diff text, whitespace-collapsed, with leading spaces stripped.
--- @param pred table A prediction object with optional .chunks (diff) and .nw (next words).
--- @return string A trimmed, whitespace-collapsed string key.
local function build_dedup_key(pred)
	local parts      = {}
	local first_done = false
	local last_char  = ""

	local function clean_leading_spaces(s)
		local str = tostring(s or "")
		if not first_done and str ~= "" then
			str = str:gsub("^%s+", "")
			if str ~= "" then first_done = true end
		end
		return str
	end

	if type(pred.chunks) == "table" then
		for _, chunk in ipairs(pred.chunks) do
			local s = clean_leading_spaces(chunk.text)
			if s ~= "" then table.insert(parts, s); last_char = s:sub(-1) end
		end
	end

	local next_words = clean_leading_spaces(pred.nw)
	if next_words ~= "" then
		-- Insert a separator space when diff and next-words regions are adjacent non-space text
		if last_char ~= "" and not last_char:match("%s") and not next_words:match("^%s") then
			next_words = " " .. next_words
		end
		table.insert(parts, next_words)
	end

	return table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Strips the em-dash suffix from a profile label for compact info-bar display.
--- "Mon profil — texte long" → "Mon profil"
--- @param label string|nil The raw profile label.
--- @return string|nil The trimmed label, or nil if it was blank.
local function trim_profile_label(label)
	if not label then return nil end
	local clean = label:match("^%s*(.-)%s*$")
	if clean == "" then return nil end
	local head = clean:match("^(.-)%s*—")
	return (head and head ~= "") and head:gsub("%s+$", "") or clean
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

	local text          = model_name
	local short_profile = trim_profile_label(profile_name)

	if backend and backend ~= "" then text = text .. " — " .. backend end
	if short_profile               then text = text .. " — " .. short_profile end

	if elapsed_ms and elapsed_ms > 0 then
		local s          = elapsed_ms / 1000
		local time_label = s < 10 and string.format("%.1fs", s) or string.format("%ds", math.floor(s + 0.5))
		text = text .. " — ⏱️ " .. time_label
	end

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

--- Arms the inactivity debounce timer to fire perform_check() after silence.
--- @param delay_override number|nil Override in seconds; uses inactivity_debounce_sec if nil.
local function start_inactivity_timer(delay_override)
	if not is_llm_enabled or inactivity_debounce_sec < 0 or not _inactivity_timer then return end
	if delay_override then
		_inactivity_timer:start(delay_override)
		Logger.trace(LOG, "Inactivity timer started (override: %.3fs).", delay_override)
	else
		_inactivity_timer:start()
		Logger.trace(LOG, "Inactivity timer started (%.3fs).", inactivity_debounce_sec)
	end
end

--- Returns true when LLM predictions should be suppressed for the current frontmost app.
--- Checks both the keymap global window ignore list and the bridge per-app exclusion list.
--- @return boolean True if the active window or app is on an exclusion list.
local function is_blocked_for_current_app()
	if not _state then return false end
	if km_utils.is_ignored_window(_state.ignored_window_titles, _state.ignored_window_patterns) then
		return true
	end
	local front = hs.application.frontmostApplication()
	if not front then return false end
	local bid  = front:bundleID() or ""
	local path = front:path() or ""
	for _, app in ipairs(excluded_apps) do
		if (app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path) then
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

--- Runs the full LLM prediction pipeline against the current buffer state.
---
--- Execution flow:
---   1. Validates preconditions: initialized, LLM enabled, not in an excluded app.
---   2. Syncs the dismiss delay into the tooltip engine BEFORE showing predictions,
---      so the auto-dismiss timer is created with the correct duration immediately.
---      This is the key fix for delay = 0 (infinite) not working previously.
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
	if is_blocked_for_current_app() then
		Logger.debug(LOG, "App excluded — LLM request skipped.")
		return
	end

	-- Sync the dismiss delay NOW, before any show_predictions() call,
	-- so the auto-dismiss timer is created with the correct value from the very first frame.
	-- delay = 0 → tooltip_llm will not start any timer (infinite display).
	local dismiss_delay = (_state.DELAYS and _state.DELAYS.llm_prediction) or 0
	tooltip.set_llm_timeout(dismiss_delay)

	-- Build the tail: last CONTEXT_TAIL_WORDS words, used both for change detection and context
	local buffer = _state.buffer
	local words  = {}
	for w in buffer:gmatch("%S+%s*") do table.insert(words, w) end

	if #words == 0 and not force_trigger then
		Logger.debug(LOG, "Empty buffer — LLM request skipped.")
		return
	end

	local tail = table.concat(words, "", math.max(1, #words - (CONTEXT_TAIL_WORDS - 1)))
	if #tail < 2 and not force_trigger then
		Logger.debug(LOG, "Context too short (%d chars) — request skipped.", #tail)
		return
	end

	-- Freshness guard: skip if the input hasn't changed since the last request
	local signature = buffer .. "\n" .. tail
	if not force_trigger and last_buffer_signature == signature then
		Logger.debug(LOG, "Buffer unchanged — LLM request skipped (freshness).")
		return
	end
	last_buffer_signature = signature

	-- Build request parameters
	local model_to_use    = core_llm.get_current_model()
	local req_temperature = temperature
	local effective_max   = (max_words > 0 and max_words < min_words) and min_words or max_words
	local max_tokens      = effective_max > 0
		and math.max(MIN_MAX_TOKENS, math.floor(effective_max * WORDS_TO_TOKENS_RATIO + TOKEN_BUDGET_OVERHEAD))
		or DEFAULT_MAX_TOKENS
	local num_preds       = num_predictions

	-- Optionally add +TEMP_INCREMENT_PER_PRED per extra prediction to encourage diversity.
	-- Example: 3 predictions → +0.2 ; 5 predictions → +0.4.
	-- Capped at TEMP_DIVERSITY_CAP; no change if temperature is already at or above the cap.
	if auto_raise_temperature and num_preds > 1 then
		local increment = (num_preds - 1) * TEMP_INCREMENT_PER_PRED
		req_temperature = math.min(req_temperature + increment, TEMP_DIVERSITY_CAP)
		Logger.debug(LOG, "Temperature raised to %.2f for %d predictions.", req_temperature, num_preds)
	end

	Logger.start(LOG, "LLM request — model: '%s' | temp: %.2f | %d pred(s) | max tokens: %d.",
		tostring(model_to_use), req_temperature, num_preds, max_tokens)

	-- Show the loading indicator immediately for snappy visual feedback
	tooltip.show("⏳ Génération en cours…", true, is_ai_preview_enabled, tooltip.tint("ai_loading"))

	-- Bump counters to discard any in-flight callbacks that are now stale
	llm_request_counter   = llm_request_counter + 1
	fetch_request_counter = fetch_request_counter + 1
	local my_fetch_id     = fetch_request_counter

	-- Watchdog: surface whatever partial results exist if streaming stalls too long
	if _stream_watchdog_timer then _stream_watchdog_timer:stop() end
	_stream_watchdog_timer = hs.timer.doAfter(STREAM_WATCHDOG_SEC, function()
		if fetch_request_counter ~= my_fetch_id or not predictions_visible then return end
		Logger.warn(LOG, "Watchdog triggered: stream stalled for %gs — surfacing partial results.", STREAM_WATCHDOG_SEC)
		local val_shortcut = format_validation_shortcut(normalize_mods(validation_mods))
		local info = show_info_bar
			and build_info_bar_text(llm_display_name, nil, resolve_backend_label(), "Timeout partiel")
			or nil
		tooltip.show_predictions(pending_predictions, 1, is_ai_preview_enabled, info,
			val_shortcut, prediction_indent, normalize_mods(navigation_mods),
			tooltip.tint("ai_prediction"), nil, #pending_predictions)
	end)

	-- When streaming is enabled, parse each partial accumulation through the full pipeline
	-- (so TAIL_CORRECTED/NEXT_WORDS labels are stripped), then display the result as a
	-- single orange "insert" block — no diff colors, no gray context, no bold corrections.
	-- Diff coloring is applied only once the final result arrives via on_success.
	local on_partial_cb = is_streaming_enabled and function(partial_raw)
		-- Discard if superseded by a newer request
		if fetch_request_counter ~= my_fetch_id then return end
		if type(partial_raw) ~= "string" or partial_raw:gsub("%s", "") == "" then return end
		-- Strip any partial thinking block before attempting to parse
		local stripped = Parser.strip_thinking(partial_raw)
		if not stripped or stripped:gsub("%s", "") == "" then return end
		-- Wait until the parser can produce a valid prediction (early tokens often can't)
		local ok_parse, partial_pred = pcall(Parser.process_prediction, buffer, tail, stripped)
		if not ok_parse or not partial_pred then return end
		-- Build a display-only variant: use the parsed to_type/deletes for accept behaviour,
		-- but replace all diff chunks with a single insert so only orange text is shown
		local display_text = (type(partial_pred.nw) == "string" and partial_pred.nw ~= "" and partial_pred.nw)
			or partial_pred.to_type
		if not display_text or display_text:gsub("%s", "") == "" then return end
		local stream_pred = {
			to_type         = partial_pred.to_type,
			deletes         = partial_pred.deletes,
			chunks          = { { type = "insert", text = display_text } },
			nw              = "",
			has_corrections = false,
			disable_bold    = true,
		}
		pending_predictions = { stream_pred }
		predictions_visible = true
		tooltip.show_predictions(
			{ stream_pred }, 1, is_ai_preview_enabled, nil,
			nil, prediction_indent, normalize_mods(navigation_mods),
			tooltip.tint("ai_prediction"), "⌛ …", 1
		)
	end or nil

	core_llm.fetch_llm_prediction(
		buffer, tail, model_to_use, req_temperature, max_tokens, num_preds,
		function(raw_predictions, elapsed_ms, is_final)
			-- Suppress intermediate batches when streaming_multi is off — only show final
			if not is_final and not is_streaming_multi_enabled then return end

			-- Discard if a newer request superseded this one while we were waiting
			if fetch_request_counter ~= my_fetch_id then
				Logger.debug(LOG, "Stale LLM callback ignored (expected fetch_id=%d, current=%d).",
					my_fetch_id, fetch_request_counter)
				return
			end

			if is_final and _stream_watchdog_timer then
				_stream_watchdog_timer:stop()
				_stream_watchdog_timer = nil
			end

			local front    = hs.application.frontmostApplication()
			local app_name = front and front:title() or nil
			keylogger.log_llm(buffer, raw_predictions, app_name)

			-- ── Filter: remove noise, invalid entries, and exact duplicates ──────
			local valid_preds, seen_keys = {}, {}
			for _, raw_pred in ipairs(raw_predictions) do
				local pred = {}
				for k, v in pairs(raw_pred) do pred[k] = v end

				if pred.to_type then
					local text       = pred.to_type
					local text_lower = text:lower()
					local prev_char  = buffer:match(".*(%S)")
					local first_ch   = text:match("^%s*(.)") or ""
					local ends_sent  = prev_char and prev_char:match("[%.%!%?…:;]") ~= nil

					-- Heuristic noise filter: discard common LLM hallucinations and artifacts
					local is_noise = text_lower:match("^%s*suite%s+finale")
						or text_lower:match("^%s*</")
						or text_lower:match("^%s*vous avez besoin de plus")
						or text_lower:match("^%s*vous etes les plus")
						or (text_lower:match("^%s*vous%s") and not buffer:lower():match("vous"))
						or (first_ch:match("[A-Z]") and not ends_sent)
						or text:find(":", 1, true) ~= nil

					if text:gsub("[%s%.…]", "") ~= ""
						and not is_noise
						and tooltip.make_diff_styled(pred.chunks, pred.nw)
					then
						local key = build_dedup_key(pred)
						if key == "" or not seen_keys[key] then
							if key ~= "" then seen_keys[key] = true end
							table.insert(valid_preds, pred)
						end
					end
				end
			end

			-- ── Streaming merge: blend new batch with what is already on screen ──
			-- Preserves predictions the user can see while progressively enriching the list
			if predictions_visible and #pending_predictions > 0 then
				local merged, merged_keys = {}, {}
				for _, existing in ipairs(pending_predictions) do
					local k = build_dedup_key(existing)
					if k == "" or not merged_keys[k] then
						if k ~= "" then merged_keys[k] = true end
						table.insert(merged, existing)
					end
				end
				for _, new_pred in ipairs(valid_preds) do
					local k = build_dedup_key(new_pred)
					if k == "" or not merged_keys[k] then
						if k ~= "" then merged_keys[k] = true end
						table.insert(merged, new_pred)
					end
				end
				valid_preds = merged
			end

			if #valid_preds == 0 then
				if is_final then
					Logger.warn(LOG, "No valid predictions after filtering (final batch).")
					if not predictions_visible then tooltip.hide() end
				end
				return
			end

			if is_final then
				Logger.success(LOG, "%d prediction(s) received in %dms from '%s'.",
					#valid_preds, elapsed_ms or 0, tostring(model_to_use))
			else
				Logger.debug(LOG, "Streaming — %d prediction(s) received (partial batch).", #valid_preds)
			end

			keylogger.log_llm_suggested(app_name, #valid_preds)

			pending_predictions = valid_preds
			predictions_visible = true

			local active_profile  = core_llm.get_active_profile()
			local display_profile = profile_name or (active_profile and active_profile.label)
			local display_model   = llm_display_name or core_llm.get_current_model()
			local info_bar_text   = show_info_bar
				and build_info_bar_text(display_model, elapsed_ms, resolve_backend_label(), display_profile)
				or nil

			-- During streaming show a spinner in the loading slot to signal work in progress
			local loading_text = nil
			if not is_final and #valid_preds < num_predictions then
				local spinner_frames = { "◐", "◓", "◑", "◒" }
				local frame = spinner_frames[(math.floor(hs.timer.secondsSinceEpoch() * SPINNER_FPS) % #spinner_frames) + 1]
				loading_text = string.format("%s Enrichissement… %d/%d", frame, #valid_preds, num_predictions)
			end

			local val_shortcut  = format_validation_shortcut(normalize_mods(validation_mods))
			local nav_mods_norm = normalize_mods(navigation_mods)
			-- Clamp selected index as the list grows during streaming
			local selected_idx  = math.min(math.max(1, math.floor(tooltip.get_current_index() or 1)), #valid_preds)
			local slot_count    = is_final and #valid_preds or num_predictions

			tooltip.show_predictions(valid_preds, selected_idx, is_ai_preview_enabled, info_bar_text,
				val_shortcut, prediction_indent, nav_mods_norm, tooltip.tint("ai_prediction"),
				loading_text, slot_count)

			-- Start the auto-dismiss countdown only once the full batch has arrived;
			-- reset_llm_dismiss_timer() re-syncs the delay in case it changed mid-session
			if is_final then reset_llm_dismiss_timer() end
		end,
		function()
			-- LLM failure callback: hide the loading indicator only if no predictions are shown yet
			if fetch_request_counter == my_fetch_id and not predictions_visible then
				Logger.error(LOG, "LLM request failed — loading indicator dismissed.")
				tooltip.hide()
			end
		end,
		sequential_mode, force_trigger, function() return fetch_request_counter end,
		on_partial_cb
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

	pending_predictions   = {}
	predictions_visible   = false
	last_buffer_signature = nil
	llm_request_counter   = llm_request_counter + 1
	fetch_request_counter = fetch_request_counter + 1

	tooltip.hide()
	stop_inactivity_timer()
	if _stream_watchdog_timer then _stream_watchdog_timer:stop() end
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
--- Sets chain_pending and starts a fallback timer in case the F20 signal is missed.
--- Must be called BEFORE hs.eventtap.keyStroke({}, "f20", 0) is sent by the bridge.
function M.arm_chain()
	if not require_state("arm_chain") then return end
	if _inactivity_timer    then _inactivity_timer:stop() end
	if _chain_trigger_timer then _chain_trigger_timer:stop() end

	chain_pending = true
	_state.suppress_rescan_keep_buffer(CHAIN_FALLBACK_SEC)

	_chain_trigger_timer = hs.timer.doAfter(CHAIN_FALLBACK_SEC, function()
		if chain_pending then
			chain_pending = false
			Logger.warn(LOG, "Fallback chain triggered — F20 signal was missed.")
			M.perform_check(true)
		end
	end)
end




-- ============================
-- ============================
-- ======= 6/ Public API =======
-- ============================
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

--- Cancels the inactivity timer without firing the LLM check.
function M.stop_timer()
	stop_inactivity_timer()
end

--- Consumes the F20 chain signal if a chain is pending.
--- Called from the keymap bridge's keystroke handler before any other routing.
--- @param keyCode number The macOS key code of the pressed key.
--- @return boolean True if the F20 event was consumed and the chain was triggered.
function M.handle_f20(keyCode)
	if keyCode ~= KEYCODE_F20 or not chain_pending then return false end
	chain_pending = false
	if _chain_trigger_timer then _chain_trigger_timer:stop() end
	Logger.debug(LOG, "F20 received — triggering chained LLM.")
	M.perform_check(true)
	return true
end

--- @return boolean True while predictions are displayed and awaiting user interaction.
function M.is_visible() return predictions_visible end

--- @return boolean True between an accepted prediction and the incoming F20 chain signal.
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
M.KEYCODE_F20        = KEYCODE_F20         -- Bridge uses this to detect the chain signal
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
