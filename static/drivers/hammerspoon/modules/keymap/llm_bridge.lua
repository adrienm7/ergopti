--- modules/keymap/llm_bridge.lua

--- ==============================================================================
--- MODULE: Keymap LLM Bridge
--- DESCRIPTION:
--- Thin orchestrator that connects the keymap core to the LLM prediction engine.
--- Handles the keymap-specific concerns that do not belong in modules/llm/:
--- hotstring detection and preview, keystroke routing, and buffer management on
--- navigation or escape events.
---
--- RESPONSIBILITIES:
--- 1. Hotstring preview: each keystroke calls update_preview(), which decides
---    whether to show a hotstring tooltip or arm the inactivity debounce timer.
--- 2. Prediction acceptance: apply_prediction() types the selected completion,
---    updates the in-memory buffer, and delegates chain arming to the engine.
--- 3. Keystroke routing: intercepts arrow keys, Enter, and modifier+digit combos
---    to navigate, accept, or dismiss predictions without disturbing the buffer.
--- 4. Forward all LLM configuration from the menu to the prediction engine.
---
--- The actual LLM request, streaming, deduplication, app exclusion, and state
--- management all live in modules/llm/prediction_engine.lua.
--- ==============================================================================

local M = {}

local hs        = hs
local keyStroke = hs.eventtap.keyStroke

local km_utils   = require("modules.keymap.utils")
local text_utils = require("lib.text_utils")
local core_llm   = require("modules.llm")
local Logger     = require("lib.logger")
local keylogger  = require("modules.keylogger")
local tooltip    = require("ui.tooltip")
local engine     = require("modules.llm.prediction_engine")

local LOG    = "keymap.llm_bridge"
local _state = nil  -- Shared core state, injected at startup via M.init()




-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- ── macOS key codes ──────────────────────────────────────────────────────────
-- Named to avoid magic numbers scattered throughout the keystroke handler.

-- Digit row 1–0 mapped to prediction slot indices 1–10
local KEYCODE_DIGITS = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10,
}

local KEYCODE_RETURN    = 36   -- Main Return key (accepts active prediction)
local KEYCODE_ENTER     = 76   -- Numpad Enter (also accepts active prediction)
local KEYCODE_ARROW_MIN = 123  -- Lowest arrow keycode (left arrow)
local KEYCODE_ARROW_MAX = 126  -- Highest arrow keycode (up arrow); range covers all four directions

-- ── UI / display parameters ──────────────────────────────────────────────────

-- When a hotstring's display delay is 0 it means "never auto-dismiss."
-- We substitute a 24-hour timeout so the tooltip module still has a concrete number.
local INFINITE_TOOLTIP_SEC       = 86400  -- 24h stand-in for "never auto-dismiss"
local MIN_TOOLTIP_DURATION_SEC   = 0.05   -- Minimum visible duration for any hotstring tooltip
-- Small offset added to tooltip_timeout when scheduling the LLM chain after a hotstring
local HOTSTRING_CHAIN_OFFSET_SEC = 0.05

-- Reference to the LLM defaults used to seed bridge-owned behavioral flags
local LLM_DEFAULTS = core_llm.DEFAULT_STATE




-- ================================
-- ================================
-- ======= 2/ Mutable State =======
-- ================================
-- ================================

-- The last hotstring suggestion shown; kept so dismissal can be logged correctly
local last_shown_hotstring = nil

-- ── Preview visibility toggles ────────────────────────────────────────────────
-- Defaults mirror menu_hotstrings.DEFAULT_STATE.preview_*_enabled.
-- The menu overrides all three via set_preview_*_enabled() at startup.

local is_star_preview_enabled        = true
local is_autocorrect_preview_enabled = true

-- ── Behavioral flags ──────────────────────────────────────────────────────────
-- Sourced from LLM_DEFAULTS so both this module and menu_llm share the same factory value.

-- Chain LLM right after a hotstring tooltip (used in update_preview)
local fire_llm_after_hotstring   = LLM_DEFAULTS.llm_after_hotstring
-- Clear buffer when the user presses an arrow key or Escape outside prediction mode
local reset_buffer_on_navigation = LLM_DEFAULTS.llm_reset_on_nav




-- ==========================================
-- ==========================================
-- ======= 3/ Configuration Setters =========
-- ==========================================
-- ==========================================


-- ================================
-- ===== 3.1) Preview Toggles =====
-- ================================

function M.set_preview_star_enabled(v)
	is_star_preview_enabled = (v == true)
	Logger.debug(LOG, "Star preview: %s.", is_star_preview_enabled and "on" or "off")
	if not v then tooltip.hide() end
end

function M.set_preview_autocorrect_enabled(v)
	is_autocorrect_preview_enabled = (v == true)
	Logger.debug(LOG, "Autocorrect preview: %s.", is_autocorrect_preview_enabled and "on" or "off")
	if not v then tooltip.hide() end
end

--- Delegates to the prediction engine for AI preview visibility.
--- @param v boolean True to show AI prediction tooltips.
function M.set_preview_ai_enabled(v)
	engine.set_preview_ai_enabled(v)
end

--- Enables or disables all non-LLM preview types simultaneously.
--- @param enabled boolean True to show hotstring tooltips, false to suppress them.
function M.set_preview_enabled(enabled)
	is_star_preview_enabled        = (enabled == true)
	is_autocorrect_preview_enabled = (enabled == true)
	Logger.debug(LOG, "Hotstring tooltips: %s.", enabled and "on" or "off")
	if not enabled then tooltip.hide() end
end

--- Enables or disables background tinting across all tooltip types.
--- Delegates to the tooltip module, which is the single owner of colorization state.
--- @param v boolean True to enable tinted backgrounds.
function M.set_preview_colored_tooltips(v)
	tooltip.set_colorization_enabled(v == true)
	Logger.debug(LOG, "Colored tooltips: %s.", v and "on" or "off")
	tooltip.hide()
end

--- Overrides the accent tint for ★ (star / magic-key) hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the module default.
function M.set_preview_star_color(color)
	tooltip.set_accent_color("hotstring_star", color)
end

--- Overrides the accent tint for autocorrect hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the module default.
function M.set_preview_autocorrect_color(color)
	tooltip.set_accent_color("hotstring_autocorrect", color)
end

--- Overrides the accent tint for AI prediction tooltips.
--- @param color table|nil RGBA table, or nil to restore the module default.
function M.set_preview_ai_color(color)
	engine.set_preview_ai_color(color)
end


-- =============================================
-- ===== 3.2) LLM Settings Forwarding ==========
-- =============================================
-- All LLM configuration is owned by the prediction engine; the bridge
-- forwards these calls so the menu's public API surface does not change.

function M.set_llm_enabled(v)           engine.set_llm_enabled(v) end
function M.get_llm_enabled()            return engine.get_llm_enabled() end
function M.set_llm_model(name)          engine.set_llm_model(name) end
function M.set_llm_display_model_name(name) engine.set_llm_display_model_name(name) end
function M.set_llm_show_model_name(name)    engine.set_llm_show_model_name(name) end
function M.set_llm_backend_name(label)  engine.set_llm_backend_name(label) end
function M.set_llm_context_length(l)    engine.set_llm_context_length(l) end
function M.set_llm_temperature(t)       engine.set_llm_temperature(t) end
function M.set_llm_num_predictions(n)   engine.set_llm_num_predictions(n) end
function M.set_llm_pred_indent(v)       engine.set_llm_pred_indent(v) end
function M.set_llm_show_info_bar(v)     engine.set_llm_show_info_bar(v) end
function M.set_llm_sequential_mode(v)   engine.set_llm_sequential_mode(v) end
function M.set_llm_auto_raise_temp(v)   engine.set_llm_auto_raise_temp(v) end
function M.set_llm_disabled_apps(apps)  engine.set_llm_disabled_apps(apps) end
function M.set_llm_val_modifiers(mods)  engine.set_llm_val_modifiers(mods) end
function M.set_llm_nav_modifiers(mods)  engine.set_llm_nav_modifiers(mods) end
function M.set_llm_min_words(w)         engine.set_llm_min_words(w) end
function M.set_llm_max_words(w)         engine.set_llm_max_words(w) end
function M.set_llm_debounce(seconds)    engine.set_llm_debounce(seconds) end

--- Sets the "chain LLM after hotstring" flag, owned by the bridge since
--- update_preview() consumes it directly.
function M.set_llm_after_hotstring(v)
	fire_llm_after_hotstring = (v == true)
	Logger.debug(LOG, "LLM after hotstring: %s.", fire_llm_after_hotstring and "on" or "off")
end

--- Sets the "reset buffer on navigation" flag, owned by the bridge since
--- check_escape_reset() and check_nav_reset() consume it directly.
function M.set_llm_reset_on_nav(v)
	reset_buffer_on_navigation = (v == true)
	Logger.debug(LOG, "Reset buffer on nav: %s.", reset_buffer_on_navigation and "yes" or "no")
end




-- ====================================
-- ====================================
-- ======= 4/ Hotstring Preview =======
-- ====================================
-- ====================================

--- Refreshes the preview tooltip from the current buffer content.
---
--- Decision tree:
---   1. If the buffer ends with a hotstring trigger → show the hotstring tooltip.
---   2. Otherwise → reset any active predictions and arm the inactivity timer.
---
--- The hotstring display timeout comes from the keymap delay table for that mapping type.
--- When fire_llm_after_hotstring is enabled, the inactivity timer is pre-armed to fire
--- immediately after the hotstring window closes instead of waiting for the next keystroke.
---
--- @param buf string The current typed buffer.
function M.update_preview(buf)
	if not _state then
		Logger.error(LOG, "'update_preview' called before M.init() — shared state not initialized.")
		return
	end
	engine.stop_timer()

	-- True when the buffer ends with the given trigger (with optional word-boundary enforcement)
	local function ends_with_trigger(buffer, trigger, is_word)
		if type(buffer) ~= "string" or type(trigger) ~= "string" or trigger == "" then return false end
		if #buffer < #trigger or buffer:sub(-#trigger) ~= trigger then return false end
		if is_word ~= true then return true end
		local before      = buffer:sub(1, #buffer - #trigger)
		if #before == 0 then return true end
		local prev_offset = utf8.offset(before, -1)
		local prev_char   = prev_offset and before:sub(prev_offset) or ""
		-- Block the match when the character immediately before the trigger is a letter or "@"
		if prev_char == "@" or text_utils.is_letter_char(prev_char) then return false end
		return true
	end

	if not buf or #buf == 0 then
		Logger.debug(LOG, "Empty buffer — predictions cleared.")
		M.reset_predictions()
		return
	end

	local last_word = buf:match("([^%s]+)$")
	if not last_word then
		M.reset_predictions()
		engine.start_timer()
		return
	end

	local matched_repl, matched_input, match_type, match_group = nil, nil, nil, nil

	-- Custom preview providers take precedence over the static mapping lookup
	for _, provider in ipairs(_state.preview_providers) do
		local ok, res = pcall(provider, buf)
		if ok and res then matched_repl = res; match_type = "provider"; break end
	end

	-- Walk static mappings to find a hotstring match
	if not matched_repl then
		for _, mapping in ipairs(_state.mappings) do
			local group_active = not mapping.group
				or not _state.groups[mapping.group]
				or _state.groups[mapping.group].enabled
			if not group_active then goto continue end

			local magic_len = #_state.magic_key
			local has_magic = magic_len > 0 and mapping.trigger:sub(-magic_len) == _state.magic_key
			local star_base = has_magic and mapping.trigger:sub(1, #mapping.trigger - magic_len) or nil

			if star_base and star_base ~= "" and ends_with_trigger(buf, star_base, mapping.is_word) then
				local plain = km_utils.plain_text(km_utils.tokens_from_repl(mapping.repl))
				if plain ~= star_base then
					matched_repl  = mapping.repl
					match_type    = "star"
					match_group   = mapping.group
					matched_input = star_base
					break
				end
			elseif ends_with_trigger(buf, mapping.trigger, mapping.is_word)
				and not (mapping.is_word == false and mapping.auto == true)
			then
				local plain = km_utils.plain_text(km_utils.tokens_from_repl(mapping.repl))
				if plain ~= mapping.trigger then
					matched_repl  = mapping.repl
					match_type    = "autocorrect"
					match_group   = mapping.group
					matched_input = mapping.trigger
					break
				end
			end
			::continue::
		end
	end

	-- Anti-loop guard: discard mappings whose expansion is just the trigger + one repeated char
	local is_repetition = false
	if matched_repl and _state.is_repeat_feature_enabled() then
		local plain  = km_utils.plain_text(km_utils.tokens_from_repl(matched_repl))
		local ref    = matched_input or last_word
		local offset = utf8.offset(ref, -1)
		if offset then is_repetition = (plain == ref .. ref:sub(offset)) end
	end

	if matched_repl and not is_repetition then
		-- Hotstring matched — show its tooltip and optionally chain the LLM afterwards
		M.reset_predictions(true)

		local display_text = km_utils.plain_text(km_utils.tokens_from_repl(matched_repl))
		local is_star      = (match_type == "star")

		-- Resolve accent tint: type order is personal/custom/provider → star → autocorrect
		local accent_color
		if match_group == "personal" or match_group == "custom" or match_type == "provider" then
			accent_color = tooltip.tint("hotstring_personal")
		elseif is_star then
			accent_color = tooltip.tint("hotstring_star")
		else
			accent_color = tooltip.tint("hotstring_autocorrect")
		end

		-- Explicit branch: the ternary idiom `A and B or C` fails when B is false,
		-- so we cannot use it here — each flag must be tested against its own is_star condition
		local is_enabled = is_star and is_star_preview_enabled or (not is_star and is_autocorrect_preview_enabled)
		local type_str   = is_star and "star" or (match_type == "autocorrect" and "autocorrect" or "personal")
		local delay_key  = is_star and "STAR_TRIGGER"
			or (match_type == "autocorrect" and "autocorrection" or "dynamichotstrings")
		local raw_delay  = _state.DELAYS[delay_key] or 0

		-- A raw_delay of 0 means "never auto-fire"; substitute a large finite value
		local tooltip_timeout = raw_delay == 0 and INFINITE_TOOLTIP_SEC
			or math.max(MIN_TOOLTIP_DURATION_SEC, raw_delay)

		Logger.debug(LOG, "Hotstring '%s' → '%s' [%s | timeout: %gs].",
			tostring(matched_input), tostring(display_text), type_str, tooltip_timeout)

		tooltip.set_timeout(tooltip_timeout)
		tooltip.show(display_text, false, is_enabled, accent_color)

		-- When chaining is active, arm the LLM timer to fire right as the hotstring window closes
		if fire_llm_after_hotstring then
			Logger.debug(LOG, "LLM chain after hotstring scheduled in %gs.", tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
			engine.start_timer(tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
		end

		local trigger_key = matched_input or last_word
		if not last_shown_hotstring or last_shown_hotstring.trigger ~= trigger_key then
			last_shown_hotstring = { trigger = trigger_key, replacement = matched_repl, h_type = type_str }
			keylogger.log_hotstring_suggested(nil, trigger_key, matched_repl, type_str)
		end
	else
		-- No hotstring match — reset and let the inactivity timer trigger the LLM
		Logger.debug(LOG, "No hotstring for '%s' — LLM timer armed.", tostring(last_word))
		M.reset_predictions()
		engine.start_timer()
	end
end




-- ================================================
-- ================================================
-- ======= 5/ Buffer & Keystroke Handlers ==========
-- ================================================
-- ================================================

--- Clears all active predictions, handles hotstring dismissal telemetry, and delegates
--- the LLM state reset to the prediction engine.
--- @param keep_hotstring_log boolean If true, does not emit a hotstring-dismissed telemetry event.
function M.reset_predictions(keep_hotstring_log)
	if not keep_hotstring_log and last_shown_hotstring then
		keylogger.log_hotstring_dismissed(nil,
			last_shown_hotstring.trigger,
			last_shown_hotstring.replacement,
			last_shown_hotstring.h_type)
		last_shown_hotstring = nil
	end
	engine.reset()
end

--- Applies the selected prediction: types the necessary deletions and completion text,
--- updates the in-memory buffer, and arms the chained LLM request.
--- @param idx number The 1-based index of the prediction to apply.
--- @return boolean True if the prediction was applied, false if the index was invalid.
function M.apply_prediction(idx)
	if not _state then
		Logger.error(LOG, "'apply_prediction' called before M.init() — shared state not initialized.")
		return false
	end

	local pred, all_preds = engine.consume(idx)
	if not pred then return false end

	local delete_count = pred.deletes or 0
	local text_to_type = pred.to_type or ""

	Logger.start(LOG, "Applying prediction #%d: '%s' (%d deletion(s)).",
		idx, tostring(text_to_type), delete_count)

	-- Capture the text about to be erased for telemetry
	local deleted_text = ""
	if delete_count > 0 and _state.buffer and #_state.buffer > 0 then
		local offset = utf8.offset(_state.buffer, -delete_count)
		if offset then deleted_text = _state.buffer:sub(offset) end
	end

	M.reset_predictions()

	-- Inject deletions then the completion text into the HID event queue
	_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + delete_count
	for _ = 1, delete_count do keyStroke({}, "delete", 0) end

	local _, emitted_str = km_utils.emit_text(text_to_type)
	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. emitted_str

	if emitted_str ~= "" then keylogger.notify_synthetic(emitted_str, "llm", delete_count) end
	keylogger.log_llm_accepted(text_to_type, nil, all_preds, idx, delete_count, deleted_text)

	-- Manually update the in-memory buffer to reflect the typed completion
	if delete_count == 0 then
		_state.buffer = _state.buffer .. text_to_type
	else
		local start_pos = utf8.offset(_state.buffer, -delete_count)
		if delete_count >= #_state.buffer then start_pos = 1 end
		_state.buffer = (start_pos and _state.buffer:sub(1, start_pos - 1) or "") .. text_to_type
	end
	keylogger.set_buffer(_state.buffer)

	Logger.success(LOG, "Prediction #%d applied — buffer updated.", idx)

	-- Chain trigger: re-run the LLM so the next prediction is ready immediately.
	--
	-- F20 is injected after all deletion and text keystrokes. The HID event queue is
	-- ordered, so by the time handle_llm_keys() receives F20 all previous keystrokes
	-- have already been delivered to the target application.
	--
	-- engine.CHAIN_FALLBACK_SEC fires only if F20 is somehow missed (e.g., intercepted
	-- by another eventtap before it reaches handle_llm_keys).
	engine.arm_chain()

	Logger.debug(LOG, "F20 signal sent — LLM chain pending.")
	hs.eventtap.keyStroke({}, "f20", 0)
	return true
end

--- Routes keystrokes that interact with the prediction pipeline.
--- Called from the main eventtap before any buffer logic runs.
--- Returns true to consume the event and prevent it from reaching the buffer or expander.
--- @param keyCode number The macOS key code of the pressed key.
--- @param flags table The active modifier flags.
--- @param is_ignored boolean True when the current app is on the keymap ignore list.
--- @return boolean True if the event was consumed by the prediction pipeline.
function M.handle_llm_keys(keyCode, flags, is_ignored)
	-- F20: precise "typing complete" signal sent by apply_prediction().
	-- All synthetic keystrokes are already in the target app by the time this fires.
	if engine.handle_f20(keyCode) then return true end

	if is_ignored or not engine.is_visible() then return false end

	-- Arrow keys navigate through predictions.
	-- We must return true to prevent the main eventtap from calling check_nav_reset(),
	-- which would clear the buffer and dismiss the prediction tooltip.
	local preds = engine.get_predictions()
	if keyCode >= KEYCODE_ARROW_MIN and keyCode <= KEYCODE_ARROW_MAX and #preds > 1 then
		if core_llm.check_modifiers(flags, engine.get_navigation_mods()) then
			local delta = (keyCode == KEYCODE_ARROW_MIN or keyCode == KEYCODE_ARROW_MAX - 1) and -1 or 1
			Logger.debug(LOG, "Prediction navigation: %+d.", delta)
			engine.navigate(delta)
			-- The dismiss timer is reset internally by tooltip.navigate()
			return true
		end
	end

	-- Return / Enter accepts the currently highlighted prediction
	if keyCode == KEYCODE_RETURN or keyCode == KEYCODE_ENTER then
		local idx = engine.get_current_index() or 1
		Logger.debug(LOG, "Return pressed — accepting prediction #%d.", idx)
		if not M.apply_prediction(idx) then M.reset_predictions() end
		return true
	end

	-- Modifier+digit selects a prediction by position (e.g., alt+2 → second prediction)
	if #preds > 1 and core_llm.check_modifiers(flags, engine.get_validation_mods()) then
		local n = KEYCODE_DIGITS[keyCode]
		if n and n <= #preds then
			Logger.debug(LOG, "Direct selection — prediction #%d.", n)
			return M.apply_prediction(n)
		end
	end

	return false
end

--- Handles Escape: dismisses predictions if visible; otherwise optionally clears the buffer.
--- @return boolean True if predictions were active and were dismissed.
function M.check_escape_reset()
	if not _state then
		Logger.error(LOG, "'check_escape_reset' called before M.init() — shared state not initialized.")
		return false
	end
	if engine.is_visible() then
		Logger.debug(LOG, "Escape — visible predictions dismissed.")
		M.reset_predictions()
		return true
	end
	if reset_buffer_on_navigation then
		Logger.debug(LOG, "Escape — buffer cleared.")
		_state.buffer = ""
	end
	M.reset_predictions()
	return false
end

--- Handles navigation keys (arrows, Enter) outside prediction mode.
--- Optionally clears the buffer depending on the reset_buffer_on_navigation setting.
function M.check_nav_reset()
	if not _state then
		Logger.error(LOG, "'check_nav_reset' called before M.init() — shared state not initialized.")
		return
	end
	if reset_buffer_on_navigation then
		if _state.buffer ~= "" then
			Logger.debug(LOG, "Buffer cleared on navigation.")
		end
		_state.buffer = ""
	end
	M.reset_predictions()
end




-- =============================
-- =============================
-- ======= 6/ Module API =======
-- =============================
-- =============================

--- Delegates to the prediction engine for external callers that reference _perform_llm_check.
--- @param force_trigger boolean If true, bypasses the freshness and word-count guards.
--- @param profile_name string|nil Optional profile label override shown in the info bar.
function M._perform_llm_check(force_trigger, profile_name)
	engine.perform_check(force_trigger, profile_name)
end

--- Public alias so the expander can re-arm the LLM timer after a text replacement.
function M.start_timer()
	engine.start_timer()
end

--- Initializes the bridge by injecting the shared keymap core state.
--- Must be called exactly once before any other public function in this module.
--- @param core_state table The shared state object from modules/keymap/init.lua.
function M.init(core_state)
	Logger.start(LOG, "Initializing LLM bridge…")

	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): invalid core_state (expected table, got %s) — bridge non-functional.", type(core_state))
		return
	end

	_state = core_state
	engine.init(core_state)

	Logger.success(LOG, "LLM bridge initialized (buffer: '%s', %d mapping(s)).",
		tostring(_state.buffer or ""), #(_state.mappings or {}))
end

-- Wire tooltip callbacks so the tooltip module can call back into the bridge.
-- Closures ensure the functions are resolved at call time, not at bind time.
tooltip.set_accept_callback(function(idx) M.apply_prediction(idx) end)
tooltip.set_cancel_callback(function() M.reset_predictions() end)

return M
