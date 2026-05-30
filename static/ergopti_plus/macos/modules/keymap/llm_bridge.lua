--- modules/keymap/llm_bridge.lua

--- ==============================================================================
--- MODULE: Keymap LLM Bridge
--- DESCRIPTION:
--- Thin orchestrator that connects the keymap core to the LLM prediction engine.
--- Handles the keymap-specific concerns that do not belong in modules/llm/:
--- hotstring detection and preview, keystroke routing for prediction acceptance,
--- and buffer management on navigation or escape events.
---
--- RESPONSIBILITIES:
--- 1. Hotstring preview: each keystroke calls update_preview(), which decides
---    whether to show a hotstring tooltip or arm the inactivity debounce timer.
--- 2. Prediction acceptance: apply_prediction() types the selected completion,
---    updates the in-memory buffer, and delegates chain arming to the engine.
--- 3. Keystroke routing: intercepts arrow keys, Enter, and modifier+digit combos
---    to navigate, accept, or dismiss predictions without disturbing the buffer.
--- 4. Configuration forwarding: all LLM settings flow through here so the
---    menu's public API surface on keymap/init.lua does not need to change.
---
--- NOTE: The actual LLM request, streaming, deduplication, app exclusion, and
--- state management all live in modules/llm/prediction_engine.lua.
--- ==============================================================================

local M = {}

local hs        = hs
local keyStroke = hs.eventtap.keyStroke

local km_utils         = require("modules.keymap.utils")
local text_utils       = require("lib.text_utils")
local core_llm         = require("modules.llm")
local Logger           = require("lib.logger")
local Keycodes         = require("lib.keycodes")
local keylogger        = require("modules.keylogger")
local tooltip          = require("ui.tooltip")
local engine           = require("modules.llm.prediction_engine")
local Registry         = require("modules.keymap.registry")
local hotstrings_config = require("modules.hotstrings_config")

local LOG    = "keymap.llm_bridge"
local _state = nil  -- Shared CoreState, injected via M.init().




-- ===================================
--- ===================================
-- ======= 1/ Module Constants =======
--- ===================================
-- ===================================

-- ── macOS key codes ──────────────────────────────────────────────────────────

-- Digit row 1–0 mapped to prediction slot indices 1–10.
local KEYCODE_DIGITS = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10,
}

local KEYCODE_ESCAPE    = Keycodes.ESCAPE   -- Escape key consumed by the dynamic escape trap
local KEYCODE_RETURN    = Keycodes.RETURN   -- Main Return key (accepts the active prediction)
local KEYCODE_ENTER     = 76   -- Numpad Enter (same behaviour as Return)
local KEYCODE_TAB       = 48   -- Tab: fast-accepts prediction #1 and stops all streaming
local KEYCODE_ARROW_MIN = 123  -- Lowest arrow keycode (left arrow)
local KEYCODE_ARROW_MAX = 126  -- Highest arrow keycode (up arrow); range covers all four

-- ── UI / display parameters ──────────────────────────────────────────────────

-- When a delay is 0 it means "never auto-dismiss the tooltip"; we substitute a
-- concrete 24h timeout so the tooltip module always receives a valid number.
local INFINITE_TOOLTIP_SEC       = 86400  -- 24h stand-in for "never auto-dismiss"
local MIN_TOOLTIP_DURATION_SEC   = 0.05   -- Shortest visible duration for any hotstring tooltip
-- Tiny offset added on top of the tooltip timeout when chaining LLM after a hotstring,
-- so the LLM fires just after the tooltip would normally close.
local HOTSTRING_CHAIN_OFFSET_SEC = 0.05

-- Upper bound on the raw→plain cache populated by provider callbacks. Previews
-- run on every keystroke and each provider returns a raw replacement that
-- needs tokens_from_repl() + plain_text() before it can be compared against
-- the buffer. In practice providers emit a small handful of distinct raw
-- strings, so a cache makes the per-keystroke work a single table lookup.
-- The cap exists purely as a safety net: a pathological provider returning
-- an unbounded set of unique strings would otherwise grow the table
-- forever. When the cap is hit we reset the table — simpler than LRU
-- bookkeeping and fine for a rare overflow.
local PROVIDER_CACHE_MAX = 1024

-- Canonical LLM defaults, owned by modules/llm; used to seed bridge-local flags.
local LLM_DEFAULTS = core_llm.DEFAULT_STATE




-- ================================
--- ================================
-- ======= 2/ Mutable State =======
--- ================================
-- ================================

-- The most recently shown hotstring suggestion; kept for dismissal telemetry.
local last_shown_hotstring = nil

-- Persistent Escape trap, created lazily on first tooltip show.
-- Inserting a new eventtap at HEAD ensures it fires before any pre-existing tap (e.g. Raycast).
-- The trap checks tooltip.is_visible() at runtime so it never needs to be disarmed.
local _escape_trap = nil

-- ── Preview visibility toggles ────────────────────────────────────────────────
-- Initial values are set in M.init() from the keymap defaults passed by keymap/init.lua.
-- The menu overrides them at startup via set_preview_*_enabled().

local is_star_preview_enabled        = nil  -- Set in M.init()
local is_autocorrect_preview_enabled = nil  -- Set in M.init()

-- ── Behavioral flags ──────────────────────────────────────────────────────────
-- Sourced from LLM_DEFAULTS so both this module and menu_llm share the same value.

-- Chain LLM immediately after a hotstring tooltip closes.
local fire_llm_after_hotstring   = LLM_DEFAULTS.llm_after_hotstring
-- Clear the buffer when the user presses an arrow key or Escape outside prediction mode.
local reset_buffer_on_navigation = LLM_DEFAULTS.llm_reset_on_nav

-- Memoization of plain-text projections for strings returned by preview
-- providers. Each keystroke used to call tokens_from_repl() + plain_text()
-- on the provider result, both of which scan the whole string; now we pay
-- that cost exactly once per distinct raw value. See PROVIDER_CACHE_MAX
-- for the overflow policy.
local _provider_plain_cache      = {}
local _provider_plain_cache_size = 0

--- Returns the plain-text projection of a raw provider replacement, using a
--- module-local memoization table so the per-keystroke preview path does no
--- tokenization work for previously-seen strings.
--- @param raw string Raw replacement returned by a provider callback.
--- @return string Plain text with tokens resolved.
local function provider_plain(raw)
	-- Defensive: providers are external callbacks, so nothing guarantees they
	-- return a string. A non-string key in the cache would crash downstream
	-- concatenation in plain_text; bail out early and return empty.
	if type(raw) ~= "string" then return "" end
	local cached = _provider_plain_cache[raw]
	if cached ~= nil then return cached end
	if _provider_plain_cache_size >= PROVIDER_CACHE_MAX then
		_provider_plain_cache      = {}
		_provider_plain_cache_size = 0
	end
	local plain = km_utils.plain_text(km_utils.tokens_from_repl(raw))
	_provider_plain_cache[raw] = plain
	_provider_plain_cache_size = _provider_plain_cache_size + 1
	return plain
end


--- Guard: verifies that M.init() was called before any public function that
--- depends on _state. Logs an error and returns false on failure.
--- @param func_name string Name of the calling function.
--- @return boolean
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Returns true when buf ends with the trigger (with optional word-boundary check).
--- Defined at module level so it is not re-allocated as a closure on every keystroke.
--- @param buffer string The current typed buffer.
--- @param trigger string The hotstring trigger to match.
--- @param is_word boolean When true, rejects matches preceded by a letter or "@".
--- @return boolean
local function ends_with_trigger(buffer, trigger, is_word)
	if type(buffer) ~= "string" or type(trigger) ~= "string" or trigger == "" then return false end
	if #buffer < #trigger or buffer:sub(-#trigger) ~= trigger then return false end
	if is_word ~= true then return true end
	local before      = buffer:sub(1, #buffer - #trigger)
	if #before == 0 then return true end
	local prev_offset = utf8.offset(before, -1)
	local prev_char   = prev_offset and before:sub(prev_offset) or ""
	-- Block when the character immediately before the trigger is a letter or "@".
	if prev_char == "@" or text_utils.is_letter_char(prev_char) then return false end
	return true
end

--- Returns true when the buffer ends with a word-boundary character that signals the
--- user has completed a word: punctuation or whitespace (whitespace is already handled
--- separately by the last_word == nil branch, but punctuation reaches this path).
--- @param buf string The current typed buffer.
--- @return boolean
local function is_word_boundary(buf)
	if type(buf) ~= "string" or buf == "" then return false end
	-- Extract the last UTF-8 codepoint rather than the last byte, so that
	-- multi-byte separators like NBSP (U+00A0, "\194\160") and NNBSP
	-- (U+202F, "\226\128\175") — produced by French typography hotstrings —
	-- are recognised as word boundaries instead of looking like stray
	-- continuation bytes that never match any of the ASCII comparisons.
	local ok, poff = pcall(utf8.offset, buf, -1)
	local last = (ok and poff) and buf:sub(poff) or buf:sub(-1)
	return last == " " or last == "," or last == "." or last == "!"
		or last == "?" or last == ";" or last == ":" or last == ")"
		or last == "}" or last == "]" or last == "\n"
		or last == "\194\160" or last == "\226\128\175"
end




-- ==========================================
-- ==========================================
-- ======= 3/ Configuration Setters =========
-- ==========================================
-- ==========================================


--- ================================
-- ===== 3.1) Preview Toggles =====
--- ================================

--- Enables or disables the ★ hotstring preview tooltip.
--- @param v boolean
function M.set_preview_star_enabled(v)
	is_star_preview_enabled = (v == true)
	Logger.debug(LOG, "Star preview: %s.", is_star_preview_enabled and "on" or "off")
	if not v then tooltip.hide() end
end

--- Enables or disables the autocorrect hotstring preview tooltip.
--- @param v boolean
function M.set_preview_autocorrect_enabled(v)
	is_autocorrect_preview_enabled = (v == true)
	Logger.debug(LOG, "Autocorrect preview: %s.", is_autocorrect_preview_enabled and "on" or "off")
	if not v then tooltip.hide() end
end

--- Enables or disables the AI prediction tooltip.
--- Delegates to the prediction engine which owns this flag.
--- @param v boolean
function M.set_preview_ai_enabled(v)
	engine.set_preview_ai_enabled(v)
end

--- Enables or disables all non-LLM preview tooltips simultaneously.
--- @param enabled boolean
function M.set_preview_enabled(enabled)
	is_star_preview_enabled        = (enabled == true)
	is_autocorrect_preview_enabled = (enabled == true)
	Logger.debug(LOG, "All hotstring tooltips: %s.", enabled and "on" or "off")
	if not enabled then tooltip.hide() end
end

--- Enables or disables background tinting for all tooltip types.
--- Delegates to the tooltip module, which is the single owner of colorization state.
--- @param v boolean
function M.set_preview_colored_tooltips(v)
	tooltip.set_colorization_enabled(v == true)
	Logger.debug(LOG, "Colored tooltips: %s.", v and "on" or "off")
	tooltip.hide()
end

--- Overrides the accent tint for ★ hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_star_color(color)
	tooltip.set_accent_color("hotstring_star", color)
end

--- Overrides the accent tint for autocorrect hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_autocorrect_color(color)
	tooltip.set_accent_color("hotstring_autocorrect", color)
end

--- Overrides the accent tint for AI prediction tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_ai_color(color)
	engine.set_preview_ai_color(color)
end


-- =============================================
-- ===== 3.2) LLM Settings Forwarding ==========
-- =============================================
-- All LLM configuration is owned by the prediction engine; the bridge
-- forwards these calls so the menu's public API surface does not change.

function M.set_llm_enabled(v)               engine.set_llm_enabled(v)               end
function M.get_llm_enabled()                return engine.get_llm_enabled()          end
function M.set_llm_model(name)              engine.set_llm_model(name)              end
function M.set_llm_display_model_name(name) engine.set_llm_display_model_name(name) end
function M.set_llm_show_model_name(name)    engine.set_llm_show_model_name(name)    end
function M.set_llm_backend_name(label)      engine.set_llm_backend_name(label)      end
function M.set_llm_context_length(l)        engine.set_llm_context_length(l)        end
function M.set_llm_temperature(t)           engine.set_llm_temperature(t)           end
function M.set_llm_num_predictions(n)       engine.set_llm_num_predictions(n)       end
function M.set_llm_pred_indent(v)           engine.set_llm_pred_indent(v)           end
function M.set_llm_show_info_bar(v)         engine.set_llm_show_info_bar(v)         end
function M.set_llm_sequential_mode(v)       engine.set_llm_sequential_mode(v)       end
function M.set_llm_auto_raise_temp(v)       engine.set_llm_auto_raise_temp(v)       end
function M.set_llm_disabled_apps(apps)           engine.set_llm_disabled_apps(apps)           end
function M.set_llm_url_bar_filter_enabled(v)      engine.set_llm_url_bar_filter_enabled(v)      end
function M.set_llm_secure_field_filter_enabled(v) engine.set_llm_secure_field_filter_enabled(v) end
function M.set_llm_instant_on_word_end(v)         engine.set_llm_instant_on_word_end(v)         end
function M.set_llm_val_modifiers(mods)      engine.set_llm_val_modifiers(mods)      end
function M.set_llm_nav_modifiers(mods)      engine.set_llm_nav_modifiers(mods)      end
function M.set_llm_min_words(w)             engine.set_llm_min_words(w)             end
function M.set_llm_max_words(w)             engine.set_llm_max_words(w)             end
function M.set_llm_debounce(seconds)        engine.set_llm_debounce(seconds)        end
function M.set_llm_streaming(v)             engine.set_llm_streaming(v)             end
function M.set_llm_streaming_multi(v)       engine.set_llm_streaming_multi(v)       end

--- Sets the "chain LLM after hotstring" flag, owned here because
--- update_preview() consumes it directly.
--- @param v boolean
function M.set_llm_after_hotstring(v)
	fire_llm_after_hotstring = (v == true)
	Logger.debug(LOG, "LLM chain after hotstring: %s.", fire_llm_after_hotstring and "on" or "off")
end

--- Sets the "reset buffer on navigation" flag, owned here because
--- check_escape_reset() and check_nav_reset() consume it directly.
--- @param v boolean
function M.set_llm_reset_on_nav(v)
	reset_buffer_on_navigation = (v == true)
	Logger.debug(LOG, "Buffer reset on nav: %s.", reset_buffer_on_navigation and "yes" or "no")
end




-- ====================================
--- ====================================
-- ======= 4/ Hotstring Preview =======
--- ====================================
-- ====================================

--- Refreshes the preview tooltip from the current buffer content.
---
--- Decision tree:
---   1. Custom preview providers take precedence (registered externally).
---   2. Walk the static mappings looking for a trigger or star-trigger match.
---   3. If a match is found → show the hotstring tooltip (and optionally chain LLM).
---   4. Otherwise → reset predictions and arm the inactivity timer.
---
--- @param buf string The current typed buffer.
function M.update_preview(buf)
	if not require_state("update_preview") then return end

	-- Skip timer ops entirely when LLM is off: stop_timer()/start_timer() involve
	-- ObjC dispatch calls that add up on every keystroke even when the engine is idle
	local llm_on = engine.get_llm_enabled()
	if llm_on then engine.stop_timer() end

	if not buf or #buf == 0 then
		Logger.debug(LOG, "Empty buffer — predictions cleared.")
		M.reset_predictions()
		return
	end

	local last_word = buf:match("([^%s]+)$")
	if not last_word then
		M.reset_predictions()
		-- Buffer ends with whitespace: the user just finished a word or sentence.
		-- start_timer_word_end() bypasses the debounce when instant_on_word_end is on.
		if llm_on then engine.start_timer_word_end() end
		return
	end

	-- Collect all matching candidates: provider match first, then star, then
	-- autocorrect. Both star and autocorrect are kept when both match the same
	-- buffer so the stacked tooltip can show all options simultaneously.
	local matches = {}   -- array of { repl, plain_repl, input, type, group }

	-- Custom preview providers take precedence over the static mapping lookup.
	for _, provider in ipairs(_state.preview_providers) do
		local ok, res = pcall(provider, buf)
		if ok and res then
			matches[#matches + 1] = {
				repl       = res,
				plain_repl = provider_plain(res),
				input      = nil,
				type       = "provider",
				group      = nil,
			}
			break
		end
	end

	-- Walk static mappings via the tail-char indexes.
	if #matches == 0 then
		local poff          = utf8.offset(buf, -1)
		local buf_tail_char = poff and buf:sub(poff) or ""

		local function group_active(mapping)
			return not mapping.group
				or not _state.groups[mapping.group]
				or _state.groups[mapping.group].enabled
		end

		local repeat_enabled = _state.is_repeat_feature_enabled()
		local function is_repetition_star(mapping, star_base)
			if not repeat_enabled then return false end
			local offset = utf8.offset(star_base, -1)
			if not offset then return false end
			return mapping.plain_repl == star_base .. star_base:sub(offset)
		end

		-- Star matches (magic-key triggers) — collect EVERY trigger whose star_base
		-- matches the buffer end. The bucket is pre-sorted longest-first by the
		-- registry, so the first collected match is the one the engine will
		-- actually fire; the rest are alternatives shown dimmed + strikethrough.
		local star_bucket = Registry.mappings_for_star_tail(buf_tail_char)
		if star_bucket then
			for _, mapping in ipairs(star_bucket) do
				if group_active(mapping) then
					local star_base = mapping.star_base
					if star_base and star_base ~= ""
						and ends_with_trigger(buf, star_base, mapping.is_word)
						and mapping.plain_repl ~= star_base
						and not is_repetition_star(mapping, star_base)
					then
						matches[#matches + 1] = {
							repl       = mapping.repl,
							plain_repl = mapping.plain_repl,
							input      = star_base,
							type       = "star",
							group      = mapping.group,
						}
					end
				end
			end
		end

		-- Autocorrect matches — same logic: collect every trigger whose body
		-- matches, sorted longest-first by the registry. The first is what
		-- fires; the rest are alternatives.
		local tail_bucket = Registry.mappings_for_tail(buf_tail_char)
		if tail_bucket then
			for _, mapping in ipairs(tail_bucket) do
				local ga = group_active(mapping)
				local c2 = not (mapping.is_word == false and mapping.auto == true)
				local c3 = ends_with_trigger(buf, mapping.trigger, mapping.is_word)
				local c4 = mapping.plain_repl ~= mapping.trigger
				if ga and c2 and c3 and c4 then
					matches[#matches + 1] = {
						repl       = mapping.repl,
						plain_repl = mapping.plain_repl,
						input      = mapping.trigger,
						type       = "autocorrect",
						group      = mapping.group,
					}
				end
			end
		end
	end

	if #matches > 0 then
		M.reset_predictions(true)

		-- Build tooltip rows (one per match). Within each kind (star / autocorrect /
		-- provider) the FIRST surviving row is the one the engine will fire — the
		-- rest are rendered dimmed + strikethrough so the user can see the
		-- alternatives without confusing them with the real outcome.
		local magic_key = "★"
		local rows          = {}
		local any_enabled   = false
		local min_timeout   = nil
		local primary_match = matches[1]

		-- Track whether each kind has already produced its primary row. Subsequent
		-- enabled rows of the same kind are marked dimmed.
		local primary_seen = { star = false, autocorrect = false, provider = false }
		-- Re-order matches so end-char (↵) rows come first, then star (★) rows,
		-- then providers. End-char triggers usually have a shorter delay (the
		-- user types space/tab quickly) so they need maximum visibility on top.
		-- Preserves intra-group order, which is priority order from the registry.
		local ordered = {}
		local function append_kind(kind)
			for _, m in ipairs(matches) do
				if m.type == kind then ordered[#ordered + 1] = m end
			end
		end
		append_kind("autocorrect")
		append_kind("star")
		append_kind("provider")

		for _, m in ipairs(ordered) do
			local is_star = (m.type == "star")

			local tint_key
			if m.group == "personal" or m.group == "custom" or m.type == "provider" then
				tint_key = "hotstring_personal"
			elseif is_star then
				tint_key = "hotstring_star"
			else
				tint_key = "hotstring_autocorrect"
			end

			local enabled = is_star and is_star_preview_enabled
				or (not is_star and is_autocorrect_preview_enabled)
			if enabled and m.group and type(hotstrings_config.resolve) == "function" then
				local ok_cfg, cfg = pcall(function() return hotstrings_config.resolve(m.group, nil) end)
				if ok_cfg and cfg and cfg.show_tooltip == false then enabled = false end
			end

			local delay_key = is_star and "STAR_TRIGGER"
				or (m.type == "autocorrect" and "autocorrection" or "dynamichotstrings")
			local raw_delay = _state.DELAYS[delay_key] or 0
			local row_timeout = raw_delay == 0 and INFINITE_TOOLTIP_SEC
				or math.max(MIN_TOOLTIP_DURATION_SEC, raw_delay)

			if enabled then
				any_enabled = true
				if not min_timeout or row_timeout < min_timeout then
					min_timeout = row_timeout
				end
				local is_primary = not primary_seen[m.type]
				primary_seen[m.type] = true
				rows[#rows + 1] = {
					text          = m.plain_repl,
					tint          = tooltip.tint(tint_key),
					trigger_label = is_star and magic_key or "↵",
					dimmed        = not is_primary,
					duration      = row_timeout,
				}
			end

			Logger.debug(LOG, "Hotstring '%s' → '%s' [%s].",
				tostring(m.input), m.plain_repl, m.type)
		end

		local tooltip_timeout = min_timeout or INFINITE_TOOLTIP_SEC
		tooltip.set_timeout(tooltip_timeout)

		if any_enabled then
			tooltip.show_stacked(rows, true)
		end

		-- Chain: arm the LLM timer so it fires just as the tooltip window closes.
		if fire_llm_after_hotstring and llm_on then
			Logger.debug(LOG, "LLM chain scheduled in %.3gs.", tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
			engine.start_timer(tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
		end

		local trigger_key = primary_match.input or last_word
		local type_str    = primary_match.type == "star" and "star"
			or (primary_match.type == "autocorrect" and "autocorrect" or "personal")
		if not last_shown_hotstring or last_shown_hotstring.trigger ~= trigger_key then
			last_shown_hotstring = { trigger = trigger_key, replacement = primary_match.repl, h_type = type_str }
			keylogger.log_hotstring_suggested(nil, trigger_key, primary_match.repl, type_str)
		end
	else
		-- No hotstring match — let the inactivity timer drive the LLM.
		Logger.debug(LOG, "No hotstring for '%s' — LLM timer armed.", tostring(last_word))
		M.reset_predictions()
		if llm_on then
			if is_word_boundary(buf) then
				engine.start_timer_word_end()
			else
				engine.start_timer()
			end
		end
	end
end




-- ================================================
-- ================================================
-- ======= 5/ Buffer & Keystroke Handlers ==========
-- ================================================
-- ================================================



--- ============================
-- ===== 5.1) Escape Trap =====
--- ============================

--- Arms a single persistent eventtap that intercepts Escape before it reaches the
--- underlying application, but only when a tooltip is actually visible.
--- Creating the tap on first use inserts it at the head of the macOS event tap chain
--- (kCGHeadInsertEventTap), so it fires before any pre-existing tap registered by apps
--- such as Raycast. Once armed, the trap runs permanently — no disarm needed.
--- The runtime check on tooltip.is_visible() handles all state transitions safely
--- without any lifecycle coupling to the tooltip show/hide flow.
---
--- WHY not recreate on every tooltip show: creating an eventtap is synchronous and
--- non-trivial. Doing so on every preview keystroke blows the macOS 50 ms HID-callback
--- budget on the NEXT keystroke, causing the triggering key to leak through to the
--- app (e.g. "hs★" → "hsammerspoon" because ★ reached the screen before our deletes).
local function arm_escape_trap()
	if _escape_trap then return end
	_escape_trap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		if event:getKeyCode() ~= KEYCODE_ESCAPE then return false end
		-- Let Escape through when no tooltip is on screen — Raycast (or the system)
		-- should handle it normally in that case.
		if not tooltip.is_visible() then return false end
		Logger.debug(LOG, "Escape trap — Escape consumed, tooltip dismissed.")
		M.reset_predictions()
		return true
	end)
	_escape_trap:start()
	Logger.debug(LOG, "Escape trap armed (persistent).")
end



--- Clears all active predictions and optionally emits hotstring-dismissed telemetry.
--- @param keep_hotstring_log boolean When true, skips the dismiss telemetry event.
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

--- Applies the selected prediction: issues deletions, types the completion,
--- updates the in-memory buffer, and arms the chained LLM request.
--- @param idx number 1-based index of the prediction to apply.
--- @return boolean True when the prediction was successfully applied.
function M.apply_prediction(idx)
	if not require_state("apply_prediction") then return false end

	local pred, all_preds = engine.consume(idx)
	if not pred then return false end

	local delete_count = pred.deletes or 0
	local text_to_type = pred.to_type or ""

	-- Resolve overlap between the buffer tail and the prediction to prevent ghost-text
	-- duplication when the user is mid-word (e.g. typed "tex", prediction starts with "texte").
	-- Also enforces correct spacing at the join point as a safety net for cases the
	-- parser may not have handled (e.g. raw-mode output with no leading space).
	-- This call was accidentally dropped during the 183effff refactor.
	local ok_overlap, res_deletes, res_text = pcall(
		km_utils.resolve_prediction_overlap, _state.buffer, delete_count, text_to_type)
	if ok_overlap and res_deletes ~= nil and res_text ~= nil then
		delete_count = res_deletes
		text_to_type = res_text
	end

	Logger.start(LOG, "Applying prediction #%d: '%s' (%d deletion(s)).",
		idx, tostring(text_to_type), delete_count)

	-- Capture the text about to be erased for telemetry.
	local deleted_text = ""
	if delete_count > 0 and type(_state.buffer) == "string" and #_state.buffer > 0 then
		local ok, offset = pcall(utf8.offset, _state.buffer, -delete_count)
		if ok and offset then deleted_text = _state.buffer:sub(offset) end
	end

	M.reset_predictions()

	-- Issue deletions then type the completion into the HID event queue.
	_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + delete_count
	for _ = 1, delete_count do keyStroke({}, "delete", 0) end

	local _, emitted_str = km_utils.emit_text(text_to_type)
	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. emitted_str

	if emitted_str ~= "" then keylogger.notify_synthetic(emitted_str, "llm", delete_count) end
	keylogger.log_llm_accepted(text_to_type, nil, all_preds, idx, delete_count, deleted_text)

	-- Update the in-memory buffer to reflect the accepted completion.
	if delete_count == 0 then
		_state.buffer = _state.buffer .. text_to_type
	else
		local ok, start_pos = pcall(utf8.offset, _state.buffer, -delete_count)
		if not ok or not start_pos or delete_count >= #_state.buffer then
			start_pos = 1
		end
		_state.buffer = (_state.buffer:sub(1, start_pos - 1) or "") .. text_to_type
	end
	keylogger.set_buffer(_state.buffer)

	Logger.success(LOG, "Prediction #%d applied — buffer updated.", idx)

	-- Chain trigger: F16 is injected after all deletions and text keystrokes.
	-- The HID event queue is ordered, so by the time handle_llm_keys() sees F16,
	-- all previous keystrokes have been delivered to the target application.
	-- engine.arm_chain() sets a fallback timer in case F16 is somehow missed.
	-- F16 (not F15) so the script-control kill-switch keycode stays exclusive.
	engine.arm_chain()
	Logger.debug(LOG, "F16 signal sent — LLM chain pending.")
	hs.eventtap.keyStroke({}, Keycodes.to_name(Keycodes.F16_LLM_CHAIN_SIGNAL), 0)
	return true
end

--- Routes keystrokes that interact with the prediction pipeline.
--- Called from the main eventtap before any buffer logic runs.
--- Returns true to consume the event and prevent it from reaching the buffer.
--- @param keyCode number The macOS key code of the pressed key.
--- @param flags table The active modifier flags.
--- @param is_ignored boolean True when the current app is on the keymap ignore list.
--- @return boolean True when the event was consumed by the prediction pipeline.
function M.handle_llm_keys(keyCode, flags, is_ignored)
	-- F16: precise "typing complete" signal sent by apply_prediction().
	if engine.handle_chain_signal(keyCode) then return true end

	-- Always handle navigation when predictions are on screen, even in keymap-ignored apps
	-- (e.g. Raycast): the user must be able to navigate/dismiss the tooltip regardless of context.
	-- The is_ignored flag only suppresses hotstring expansion and buffer tracking, not LLM interaction.
	if not engine.is_visible() then return false end

	local preds = engine.get_predictions()

	-- Arrow keys navigate through the prediction list.
	-- We must consume the event so the main eventtap does not call check_nav_reset()
	-- which would clear the buffer and dismiss the tooltip.
	if keyCode >= KEYCODE_ARROW_MIN and keyCode <= KEYCODE_ARROW_MAX and #preds > 1 then
		if core_llm.check_modifiers(flags, engine.get_navigation_mods()) then
			local delta = (keyCode == KEYCODE_ARROW_MIN or keyCode == KEYCODE_ARROW_MAX - 1) and -1 or 1
			Logger.debug(LOG, "Prediction navigation: %+d.", delta)
			engine.navigate(delta)
			return true
		end
	end

	-- Tab immediately accepts prediction #1, cancelling any in-flight streaming for
	-- the other slots. This lets the user grab the first result as soon as it appears
	-- without waiting for all parallel predictions to complete.
	if keyCode == KEYCODE_TAB then
		Logger.debug(LOG, "Tab — fast-accepting prediction #1.")
		if not M.apply_prediction(1) then M.reset_predictions() end
		return true
	end

	-- Return / Enter accepts the currently highlighted prediction.
	if keyCode == KEYCODE_RETURN or keyCode == KEYCODE_ENTER then
		local idx = engine.get_current_index() or 1
		Logger.debug(LOG, "Return — accepting prediction #%d.", idx)
		if not M.apply_prediction(idx) then M.reset_predictions() end
		return true
	end

	-- Modifier+digit selects a prediction by position (e.g., alt+2 → second prediction).
	if #preds > 1 and core_llm.check_modifiers(flags, engine.get_validation_mods()) then
		local n = KEYCODE_DIGITS[keyCode]
		if n and n <= #preds then
			Logger.debug(LOG, "Direct selection — prediction #%d.", n)
			return M.apply_prediction(n)
		end
	end

	return false
end

--- Handles Escape: dismisses any visible tooltip (hotstring, LLM loading indicator, or
--- AI predictions), consuming the event so it never reaches the underlying application.
--- Without this, apps like Raycast receive the Escape and reset their own state.
--- @return boolean True when a tooltip was visible and the event was consumed.
function M.check_escape_reset()
	if not require_state("check_escape_reset") then return false end

	-- Use tooltip.is_visible() rather than engine.is_visible() so we also catch
	-- the LLM loading spinner and hotstring previews, which are shown through the
	-- tooltip module but do not set the prediction-engine "visible" flag.
	if tooltip.is_visible() then
		Logger.debug(LOG, "Escape — tooltip dismissed.")
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

--- Handles navigation keys (arrows, Enter, mouse) outside prediction mode.
--- Optionally clears the buffer depending on the reset_buffer_on_navigation flag.
function M.check_nav_reset()
	if not require_state("check_nav_reset") then return end

	if reset_buffer_on_navigation and _state.buffer ~= "" then
		Logger.debug(LOG, "Buffer cleared on navigation.")
		_state.buffer = ""
	end
	M.reset_predictions()
end




-- =============================
--- =============================
-- ======= 6/ Module API =======
--- =============================
-- =============================

--- Delegates to the prediction engine for callers that reference _perform_llm_check.
--- @param force_trigger boolean When true, bypasses freshness and word-count guards.
--- @param profile_name string|nil Optional profile label shown in the info bar.
function M._perform_llm_check(force_trigger, profile_name)
	engine.perform_check(force_trigger, profile_name)
end

--- Re-arms the LLM inactivity timer.
--- Called by the expander after a text replacement to trigger a fresh prediction.
function M.start_timer()
	engine.start_timer()
end

--- Initializes the bridge with the shared CoreState and keymap defaults.
--- Must be called exactly once before any other public function in this module.
--- @param core_state table The shared state object from keymap/init.lua.
--- @param keymap_defaults table The DEFAULT_STATE table from keymap/init.lua.
function M.init(core_state, keymap_defaults)
	Logger.start(LOG, "Initializing LLM bridge…")

	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s) — bridge non-functional.", type(core_state))
		return
	end
	if type(keymap_defaults) ~= "table" then
		Logger.error(LOG, "M.init(): keymap_defaults must be a table (got %s) — bridge non-functional.", type(keymap_defaults))
		return
	end

	_state = core_state
	engine.init(core_state)

	-- Seed preview toggles from the canonical keymap defaults.
	-- The menu will override these values at startup via set_preview_*_enabled().
	is_star_preview_enabled        = (keymap_defaults.preview_star_enabled        ~= false)
	is_autocorrect_preview_enabled = (keymap_defaults.preview_autocorrect_enabled ~= false)

	Logger.success(LOG, "LLM bridge initialized (buffer: '%s', %d mapping(s)).",
		tostring(_state.buffer or ""), #(_state.mappings or {}))
end

-- Wire tooltip callbacks so the tooltip module can call back into the bridge.
-- Closures ensure the functions are resolved at call time, not at bind time.
tooltip.set_accept_callback(function(idx) M.apply_prediction(idx) end)
tooltip.set_cancel_callback(function() M.reset_predictions() end)
-- Create the persistent Escape trap the first time any tooltip appears.
-- This guarantees the tap is inserted at HEAD after Raycast (or any other app) has
-- already registered its own tap, so our Escape always takes priority while a tooltip
-- is visible. The trap is never destroyed — tooltip.is_visible() drives its behaviour.
tooltip.set_on_show_callback(arm_escape_trap)

return M
