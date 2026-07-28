--- modules/keymap/expander.lua

--- ==============================================================================
--- MODULE: Keymap Expander
--- DESCRIPTION:
--- Executes text expansions: auto-expanding hotstrings, terminator-triggered
--- hotstrings, and the magic-key "repeat last character" feature.
---
--- FEATURES & RATIONALE:
--- 1. Fail Fast: A require_state guard prevents silent failures when a function
---    is called before the module is initialized.
--- 2. Intelligent Conflict Resolution: Common prefixes between the trigger and
---    the replacement are kept to minimize the number of backspaces issued.
--- 3. Synchronous Terminator Execution: Expansions run directly inside the HID
---    callback without deferral. CGEventPost() is non-blocking, so keyStroke()
---    calls return immediately — identical to how auto-expand already behaves.
--- ==============================================================================

local M = {}

local hs = hs

local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("lib.logger")
local TextSender = require("adapters.text_sender")
local TooltipRenderer  = require("adapters.tooltip_renderer")
local TerminatorReplay = require("modules.keymap.terminator_replay")
local LOG        = "keymap.expander"

-- Optional modules — loaded with pcall because they are not required for core expansion.
local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local _state    = nil  -- Shared CoreState injected via M.init().
local _registry = nil  -- Registry module injected via M.init().
local _llm      = nil  -- LLMBridge module injected via M.init().


--- Guard: verifies that M.init() was called before any public function that
--- depends on the injected dependencies. Logs an error and returns false on failure.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True when all dependencies are ready.
local function require_state(func_name)
	if not _state or not _registry or not _llm then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end





-- ====================================
-- ====================================
-- ======= 1/ Core Replacements =======
-- ====================================
-- ====================================

--- Issues backspaces, fires the emit callback, updates the buffer, and
--- re-arms the LLM timer. This is the single choke-point through which
--- every expansion passes, ensuring consistent logging and side-effects.
---
--- @param deletes number Number of backspaces to issue.
--- @param emit_action function Called to type or paste the replacement text.
---   Must return (emitted_count: number, physical_echo: string,
---   logical_text: string). The logical text includes clipboard-pasted output;
---   physical_echo includes only OS key events that must be discarded.
--- @param buffer_action function Called to sync _state.buffer after emission.
--- @param is_final boolean When true, suppresses re-scanning after completion.
--- @param is_ignored boolean When true, skips tooltip and LLM side-effects.
--- @param source_type string Telemetry label passed to the keylogger.
--- @param source_variant string|nil Optional sub-type for the keylogger.
function M.perform_text_replacement(deletes, emit_action, buffer_action, is_final, is_ignored, source_type, source_variant, is_private)
	Logger.trace(LOG, "Performing replacement (%d deletion(s))…", deletes)

	_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + deletes
	-- Record the arm timestamp so the stuck-counter reset guard in onKeyDownRaw
	-- does not wipe these counters if a runloop lag creates a false 0.5 s gap
	-- between the arm and the first synthetic echo (A6 audit fix).
	if hs and hs.timer then
		_state.last_synthetic_arm_time = hs.timer.secondsSinceEpoch()
	end
	if not is_ignored then TooltipRenderer.hide({ forced = true }) end

	TextSender.eraseChars(deletes, 0)

	local ok, emit_count, emitted_str, logical_text = pcall(emit_action)
	if not ok then
		-- The emit failed — emitted_str contains the error message from pcall.
		Logger.error(LOG, "emit_action failed: %s.", tostring(emit_count))
		emitted_str = ""
		logical_text = ""
	end
	emitted_str = emitted_str or ""
	-- Keep extensions that still return the historical two values working. The
	-- built-in clipboard emitter supplies an explicit logical value instead.
	logical_text = logical_text or emitted_str

	-- Track the emitted characters so the main event loop knows to skip them.
	-- Guard against a nil field: the E2E stub state may not include this slot.
	_state.expected_synthetic_chars = (_state.expected_synthetic_chars or "") .. emitted_str

	-- When the emission used clipboard paste, register the expected Cmd+V echoes
	-- in a dedicated counter instead of expected_synthetic_chars. Paste does not
	-- produce individual character echoes, so expected_synthetic_chars must stay
	-- empty to avoid absorbing real keystrokes typed after the expansion.
	local paste_ops = km_utils.take_paste_ops and km_utils.take_paste_ops() or 0
	if paste_ops > 0 then
		_state.expected_synthetic_pastes = (_state.expected_synthetic_pastes or 0) + paste_ops
	end

	-- Guard: skip notify when nothing was actually injected (deletes=0 and logical_text="")
	-- to avoid a no-op synth_queue entry that would absorb the first real keystroke typed
	-- immediately after a cancelled or empty expansion.
	if (deletes > 0 or logical_text ~= "") and keylogger and type(keylogger.notify_synthetic) == "function" then
		-- pcall-wrapped like the neighboring buffer_action call below: a truncated
		-- LLM completion cut mid-codepoint (French accents, curly quotes, em-dashes)
		-- can reach notify_synthetic with malformed UTF-8, and its utf8.codes loop
		-- would otherwise raise, aborting the expansion mid-flight and leaving the
		-- synthetic-injection trackers desynced (F-HIGH-16 fix).
		-- is_private is forwarded, NOT used to skip the call. Skipping would let
		-- the physical echoes fall through handle_key unclaimed and be logged as
		-- ordinary human keystrokes in buffer_text - the same secret, recorded in
		-- a worse place. The keylogger's private mode keeps the discard markers
		-- intact and redacts only what it persists.
		local ok_notify, notify_err = pcall(keylogger.notify_synthetic,
			logical_text, source_type or "hotstring", deletes, source_variant, emitted_str,
			is_private)
		if not ok_notify then
			Logger.error(LOG, "notify_synthetic failed: %s.", tostring(notify_err))
		end
	end

	if type(buffer_action) == "function" then
		local ok_buf, buf_err = pcall(buffer_action)
		if not ok_buf then
			-- Buffer desync after an expansion leads to phantom chars or missed
			-- triggers downstream; surfacing the failure loudly makes it
			-- traceable instead of masking it as a silent inconsistency.
			Logger.error(LOG, "buffer_action failed: %s.", tostring(buf_err))
		end
	end

	if keylogger and type(keylogger.set_buffer) == "function" then
		keylogger.set_buffer(_state.buffer)
	end

	-- Re-evaluate preview on the updated buffer to support chained autocorrections.
	-- Deferred via doAfter(0) so all synthetic echoes produced by the expansion
	-- (deletes + chars) have already been processed by onKeyDownRaw before the
	-- watcher armed by update_preview sees any keyDown event. Without this
	-- deferral the synthetic chars trigger the preview watcher and call
	-- hide_forced(), destroying the chained preview immediately (E2 audit fix).
	if not is_ignored then
		hs.timer.doAfter(0, function()
			-- Deferring moved this call off the eventtap stack and onto a timer, where a
			-- throw reaches only the HS Console and never the file logger. It is the one
			-- update_preview call site of four still outside a pcall — the same guard the
			-- notify_synthetic and buffer_action calls above already carry.
			local ok, err = pcall(_llm.update_preview, _state.buffer)
			if not ok then
				Logger.error(LOG, "Deferred update_preview failed: %s.", tostring(err))
			end
		end)
	end

	if is_final then _state.suppress_rescan(1.0) end

	if not is_ignored and _llm.get_llm_enabled() then
		_llm.start_timer()
	end

	Logger.done(LOG, "Replacement complete.")
end





-- ===================================
-- ===================================
-- ======= 2/ Shared Internals =======
-- ===================================
-- ===================================

--- Returns true when an is_word mapping should be REJECTED because the
--- character immediately before the trigger's start position is a letter
--- (or "@", which marks personal-info triggers). Centralised here so auto
--- and terminator expansion apply the exact same word-boundary policy.
---
--- When the trigger starts at byte index 1 of the buffer, the buffer holds
--- no observable left-hand context. The decision is then delegated to
--- `_state.start_is_word_boundary`: true means the buffer's start is known
--- to abut a word terminator (fresh launch, post-expansion, post-Cmd+A,
--- post-word-timeout) and the match is allowed; false means the cursor
--- moved into territory we never observed (BS past the buffer's start,
--- nav keys, mouse click, Ctrl/Cmd combos other than select-all, paste,
--- undo, etc.) and the match is rejected. This is the Hammerspoon mirror
--- of the AHK HSEv2 word-boundary contract.
---
--- @param buffer string The current rolling buffer.
--- @param trigger string The trigger whose match is being considered.
--- @param trigger_start_byte number 1-based byte index where the trigger
---   starts inside `buffer`. Must be >= 1.
--- @param start_is_word_boundary boolean Whether the buffer's start
---   abuts a known word terminator.
--- @return boolean True when the word boundary blocks the match.
local function word_boundary_blocks(buffer, trigger, trigger_start_byte, start_is_word_boundary)
	-- Triggers that start with a separator carry their own boundary and skip this
	-- check: whitespace, nbsp (U+00A0), nnbsp (U+202F), and the comma-layer ";".
	-- Including ";" guarantees the comma→J expansion (";e" → "Je") fires in every
	-- context, never word-boundary-gated — the mirror of the AHK "*?C" in-word flag.
	if trigger:match("^[ \194\160\226\128\175;]") then return false end
	if trigger_start_byte <= 1 then
		return not start_is_word_boundary
	end
	local before             = buffer:sub(1, trigger_start_byte - 1)
	local ok_utf8, prev_off = pcall(utf8.offset, before, -1)
	-- Treat malformed UTF-8 the same as an absent left-hand char: no block
	if not ok_utf8 then prev_off = nil end
	local prev_char = prev_off and before:sub(prev_off) or ""
	return text_utils.is_letter_char(prev_char) or prev_char == "@"
end

--- Chooses the right emitter for a mapping's replacement: plain_text uses
--- emit_text (fast path, ascii/unicode typing); replacements carrying
--- {Token} directives go through emit_tokens(tokens_from_repl(m.repl)).
--- Extracted so both expansion paths share the exact same dispatch logic.
--- @param m table The mapping entry.
--- @param to_type string The text to emit when the replacement is plain.
--- @return number emit_count The number of codepoints emitted.
--- @return string emitted_str The bytes that will echo as physical key events.
--- @return string logical_text All text inserted, including clipboard output.
local function emit_dispatch(m, to_type)
	if m.plain_repl == m.repl then
		return km_utils.emit_text(to_type)
	end
	-- Lazy: tokens_from_repl() is only called for replacements that contain
	-- {Token} directives — most hotstrings are plain text and never reach this.
	return km_utils.emit_tokens(km_utils.tokens_from_repl(m.repl))
end





-- ======================================
-- ======================================
-- ======= 3/ Expansion Scenarios =======
-- ======================================
-- ======================================

--- Attempts to auto-expand a hotstring when the buffer ends with its trigger.
--- "Auto" hotstrings fire immediately on the last character, without a terminator.
--- @param m table The mapping entry from the registry.
--- @param char_len number UTF-8 length of the latest typed character.
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the expansion fired.
--- Decides whether `m` would expand against `buffer`, WITHOUT emitting anything.
---
--- This is the single source of truth for "will this hotstring fire?". The engine
--- (try_auto_expand, below) and the tooltip preview (llm_bridge.update_preview)
--- both call it, so what the tooltip promises and what the engine produces cannot
--- disagree. They used to be two independent implementations and they diverged in
--- four ways — most visibly at the buffer start, where the preview allowed any
--- match while the engine consulted start_is_word_boundary and refused it.
---
--- Returns the EFFECTIVE plain replacement for this firing: conformed to the typed
--- casing for a case_conform entry, the stored replacement otherwise. nil means
--- the mapping does not fire, for any reason.
--- @param m table The mapping entry.
--- @param buffer string The buffer to evaluate against, as the engine will see it.
--- @return string|nil eff_plain The plain replacement, or nil when it will not fire.
--- @return string|nil typed The matched trigger text as typed, or nil.
--- @return string|nil eff_repl The raw replacement (may carry {Token} directives).
function M.would_fire(m, buffer)
	if type(buffer) ~= "string" or type(m) ~= "table" then return nil end

	local trigger = m.trigger
	local tb      = m.trigger_bytes
	if not tb or #buffer < tb then return nil end
	local typed = buffer:sub(-tb)

	local eff_repl, eff_plain
	if m.case_conform then
		if text_utils.trig_lower(typed) ~= trigger then return nil end
		local conformed = text_utils.conform_replacement(m.plain_repl, typed, trigger)
		-- nil means the typed case was mixed (not a clean lower/Title/UPPER), for
		-- which no variant was ever registered: the hotstring must NOT fire.
		if conformed == nil then return nil end
		eff_repl, eff_plain = conformed, conformed
	else
		if typed ~= trigger then return nil end
		eff_repl, eff_plain = m.repl, m.plain_repl
	end

	local tstart_byte = #buffer - tb + 1
	if m.is_word and word_boundary_blocks(buffer, trigger, tstart_byte, _state and _state.start_is_word_boundary) then
		return nil
	end

	-- A replacement identical to what was typed is a no-op: the engine passes the
	-- keystroke through rather than expanding, so the preview must not offer it.
	-- Reported as a distinct outcome because the engine still has cleanup to do
	-- for it, while the preview treats it exactly like "no match".
	if eff_plain == typed then return nil, typed, nil, true end

	return eff_plain, typed, eff_repl, false
end

function M.try_auto_expand(m, char_len, is_ignored)
	if not require_state("try_auto_expand") then return false end

	local trigger = m.trigger

	-- The whole match decision — length, case resolution, word boundary, no-op —
	-- lives in M.would_fire, which the tooltip preview calls too. Keeping it in one
	-- place is what guarantees the preview cannot promise an expansion this
	-- function then declines to perform.
	local eff_plain, typed, eff_repl, is_noop = M.would_fire(m, _state.buffer)

	if not eff_plain then
		-- No-op guard: when the plain-text expansion equals what was typed, signal
		-- pass-through so onKeyDownRaw does NOT consume the triggering keystroke.
		-- The character must remain on screen — returning true would suppress it
		-- even though nothing was injected (the dropped-char bug).
		if is_noop then
			if m.final_result then _state.suppress_rescan() end
			if not is_ignored then TooltipRenderer.hide({ forced = true }) end
		end
		return false
	end

	local repl_text = eff_plain
	-- 1-based byte index where the matched trigger starts, used below to splice the
	-- replacement into the buffer. Derived from the same trigger_bytes would_fire
	-- matched on, so the two can never disagree about where the trigger began.
	local tstart_byte = #_state.buffer - m.trigger_bytes + 1

	-- Compute how many backspaces and what to type, keeping common prefix chars.
	-- In an ignored window (char_len == 0) there is no "last char" to keep, so
	-- we must erase the full trigger length. m.tlen is the precomputed UTF-8
	-- length of the trigger (avoids three utf8_len calls per hot-path hit).
	local trig_len         = m.tlen
	local char_offset      = is_ignored and 0 or char_len
	local screen_len       = trig_len - char_offset
	local deletes, to_type = screen_len, repl_text

	if repl_text == eff_repl then
		-- Simple text replacement: find the longest shared prefix to minimise
		-- backspaces. Compare against the TYPED (cased) trigger, not the lowercase
		-- canonical, so the kept on-screen prefix matches what is actually shown.
		local screen = text_utils.utf8_sub(typed, 1, screen_len)
		local common = text_utils.get_common_prefix_utf8(screen, repl_text)
		deletes = screen_len - common
		to_type = text_utils.utf8_sub(repl_text, common + 1)
	end

	M.perform_text_replacement(
		deletes,
		function() return emit_dispatch(m, to_type) end,
		function()
			_state.buffer = _state.buffer:sub(1, tstart_byte - 1) .. repl_text
		end,
		m.final_result,
		is_ignored,
		"hotstring",
		m.group or nil,
		m.is_private
	)

	-- Private mappings carry PII sourced from personal_info.toml (phone, SSN,
	-- IBAN). keylogger.log_hotstring writes trigger + replacement verbatim into
	-- today.log, which ingest copies into events_hotstring and the export then
	-- replicates to every other device; the DEBUG line below reaches the same
	-- 14-day log because DEBUG is the driver's default level. Both sinks are
	-- therefore skipped for private mappings — including the trigger, which is
	-- itself a fragment of the secret. Non-private mappings are unaffected.
	if m.is_private then
		Logger.debug(LOG, "Auto-expand: private mapping fired (content withheld).")
	else
		if keylogger and type(keylogger.log_hotstring) == "function" then
			pcall(keylogger.log_hotstring, trigger, repl_text)
		end
		Logger.debug(LOG, "Auto-expand: '%s' → '%s'.", typed, repl_text)
	end
	return true
end

--- Attempts to expand a hotstring when the buffer ends with the trigger followed
--- by an enabled terminator character (e.g., space, comma, ★).
--- @param m table The mapping entry from the registry.
--- @param chars string The latest typed character(s) (potential terminator).
--- @param char_len number UTF-8 length of `chars`.
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the expansion fired.
function M.try_terminator_expand(m, chars, char_len, is_ignored)
	if not require_state("try_terminator_expand") then return false end

	if not _registry.is_terminator(chars) then return false end

	-- Byte-direct segment match: byte equality implies UTF-8 equality, so we skip
	-- the utf8.offset pair entirely. trigger_bytes is precomputed; #chars is the
	-- byte length of the terminator character(s) that were just typed.
	local trigger     = m.trigger
	local tb          = m.trigger_bytes
	local chars_bytes = #chars
	local buf         = _state.buffer

	-- French-typography rule: ``:`` and ``;`` are emitted by the layout as
	-- NNBSP+``:`` or NNBSP+``;``. The NNBSP (UTF-8: 0xE2 0x80 0xAF, 3 bytes)
	-- or NBSP (UTF-8: 0xC2 0xA0, 2 bytes) lands in the buffer just before the
	-- terminator, so the effective trigger is ``…trigger NNBSP :``.
	-- We strip that nbsp from buf_start so matching finds the bare trigger,
	-- and record extra_bs_bytes so the correct number of characters is deleted.
	local NNBSP = "\xE2\x80\xAF"  -- U+202F, 3 UTF-8 bytes
	local NBSP  = "\xC2\xA0"      -- U+00A0, 2 UTF-8 bytes
	local extra_bs_bytes = 0
	local is_typo_endchar = (chars == ":" or chars == ";")
	if is_typo_endchar then
		-- Check for NNBSP immediately before the terminator in the buffer.
		local nnbsp_pos = #buf - chars_bytes - #NNBSP + 1
		local nbsp_pos  = #buf - chars_bytes - #NBSP  + 1
		if nnbsp_pos >= 1 and buf:sub(nnbsp_pos, nnbsp_pos + #NNBSP - 1) == NNBSP then
			extra_bs_bytes = #NNBSP
		elseif nbsp_pos >= 1 and buf:sub(nbsp_pos, nbsp_pos + #NBSP - 1) == NBSP then
			extra_bs_bytes = #NBSP
		else
			-- Bare ``:`` / ``;`` without preceding nbsp: a mid-sequence char
			-- (e.g. the ``:`` in ``:D``). Must not trigger expansion.
			return false
		end
	end

	local effective_chars_bytes = chars_bytes + extra_bs_bytes
	if #buf < tb + effective_chars_bytes then return false end
	local buf_start   = #buf - effective_chars_bytes - tb + 1
	if buf:sub(buf_start, buf_start + tb - 1) ~= trigger then return false end
	-- Precomputed trigger length; avoids a hot-path utf8.len call.
	local trig_len    = m.tlen

	-- Word-boundary check (shared helper — same policy as try_auto_expand).
	if m.is_word and word_boundary_blocks(buf, trigger, buf_start, _state.start_is_word_boundary) then
		return false
	end

	local consume_term = _registry.terminator_is_consumed(chars)

	-- No-op guard: when the replacement equals the trigger, signal
	-- pass-through so the terminating character is NOT consumed. It must
	-- stay on screen — returning true would suppress it with nothing
	-- injected (the dropped-terminator-chars bug).
	if m.plain_repl == trigger then
		if m.final_result then _state.suppress_rescan() end
		if not is_ignored then TooltipRenderer.hide({ forced = true }) end
		return false
	end

	-- No "suggestion shown" event is recorded here. llm_bridge.update_preview
	-- already calls log_hotstring_suggested(nil, trigger, replacement, type) at
	-- the moment the tooltip is actually rendered, which is the only point where
	-- a suggestion was genuinely shown; the acceptance side is covered by
	-- log_hotstring below. The call that used to sit here passed ZERO arguments
	-- against a four-parameter signature, so it double-counted hs_suggested,
	-- wrote nil-trigger rows into the per-trigger breakdown, and fired even in
	-- ignored windows and with tooltips disabled — recording suggestions that
	-- were never rendered, at the cost of two synchronous write+flush pairs
	-- inside the HID callback.

	local function do_expansion()
		-- Use the precomputed plain_repl; tokens_from_repl() is only called below
		-- when we actually need to emit tokens (replacements with {Token} directives)
		local repl_text        = m.plain_repl
		local deletes, to_type = trig_len, repl_text
		-- Filled in by the emit closure and consumed AFTER perform_text_replacement
		-- has armed the echo bookkeeping the replay gate reads.
		local replay_spec      = nil

		if repl_text == m.repl then
			-- Simple text: keep common prefix to reduce backspaces.
			local common = text_utils.get_common_prefix_utf8(trigger, repl_text)
			deletes = trig_len - common
			to_type = text_utils.utf8_sub(repl_text, common + 1)
		end

		-- In an ignored window there is no "char" kept on screen — erase it too.
		if is_ignored then deletes = deletes + char_len end

		-- When a NNBSP/NBSP was stripped before matching (typographic ``:``/`` ; ``),
		-- add 1 extra backspace to erase the nbsp that sits between trigger and endchar.
		if extra_bs_bytes > 0 then deletes = deletes + 1 end

		M.perform_text_replacement(
			deletes,
			function()
				local c, s, logical, order_delay = emit_dispatch(m, to_type)

				-- The terminator is NOT emitted here. Enter and Tab travel as raw
				-- key events while the replacement travels through the text-input
				-- pipeline (or a clipboard read the target schedules itself), and
				-- posting the two back to back does not order them: the Enter
				-- reached the host first and submitted the pre-expansion content.
				-- It is instead handed to TerminatorReplay below, which releases it
				-- once the replacement has provably landed. order_delay is carried
				-- through as a floor for the paste path, where there is no
				-- per-character echo to wait on.
				if not consume_term then
					if chars == "\r" or chars == "\n" then
						replay_spec = { kind = "key", key = "return", chars = chars }
						-- Track the re-typed terminator so expected_synthetic_chars
						-- and notify_synthetic see it; without this the keylogger
						-- flushes its buffer mid-expansion on the Enter/Tab echo.
						s = s .. chars
						logical = logical .. chars
					elseif chars == "\t" then
						replay_spec = { kind = "key", key = "tab", chars = chars }
						s = s .. chars
						logical = logical .. chars
					else
						replay_spec = { kind = "text", chars = chars }
						s = s .. chars
						logical = logical .. chars
					end
					replay_spec.echo_bytes = #chars
					replay_spec.min_delay  = (type(order_delay) == "number" and order_delay > 0)
						and order_delay or 0
					c = c + text_utils.utf8_len(chars)
				end
				return c, s, logical
			end,
			function()
				-- buf_start is a valid byte index into _state.buffer: the buffer
				-- is only mutated by this very closure, which runs after emit.
				_state.buffer = _state.buffer:sub(1, buf_start - 1)
					.. repl_text
					.. (consume_term and "" or chars)
			end,
			m.final_result,
			is_ignored,
			"hotstring",
			m.group or nil,
			m.is_private
		)

		-- Armed only now: the replay gate reads the synthetic-echo bookkeeping
		-- that perform_text_replacement writes AFTER emit_action returns. Arming
		-- from inside the emit closure would test an expectation that had not
		-- been recorded yet and release the terminator immediately — the very
		-- race this indirection exists to close.
		if replay_spec then
			TerminatorReplay.arm(replay_spec)
			if is_ignored then
				-- The keyboard handler exits before its synthetic-echo drain for
				-- these windows, so no echo can ever be observed here. Waiting for
				-- one would stall every Enter until the watchdog expired.
				TerminatorReplay.flush_now("ignored window — echoes unobservable")
			end
		end

		-- Same privacy contract as try_auto_expand: a private mapping's trigger
		-- and replacement are both secrets and must reach neither the keylogger
		-- nor the log.
		if m.is_private then
			Logger.debug(LOG, "Terminator-expand: private mapping fired (content withheld).")
		else
			if keylogger and type(keylogger.log_hotstring) == "function" then
				pcall(keylogger.log_hotstring, trigger, m.plain_repl)
			end
			Logger.debug(LOG, "Terminator-expand: '%s' → '%s'.", trigger, m.repl)
		end
	end

	-- Run synchronously: CGEventPost() is non-blocking so calling keyStroke()
	-- inside the HID callback is safe. expected_synthetic_chars is already
	-- armed before events fire, preventing re-entrancy into the trigger loop.
	do_expansion()
	return true
end

--- Fires the magic-key "repeat last character" feature when the user types
--- the trigger char twice: the first occurrence of the trigger is replaced by
--- the character that immediately preceded it.
---
--- Example: the user types "a★" → "aa".
---
--- @param chars string The latest typed character(s) (potential magic key).
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the repeat fired.
function M.try_repeat_feature(chars, is_ignored)
	if not require_state("try_repeat_feature") then return false end
	if not _state.is_repeat_feature_enabled() then return false end
	if chars ~= _state.magic_key then return false end

	local char_len = text_utils.utf8_len(chars)
	local buf_len  = text_utils.utf8_len(_state.buffer)
	if buf_len <= char_len then return false end

	-- Find the offset of the magic-key in the buffer and isolate the text before it.
	local ok_magic, magic_offset = pcall(utf8.offset, _state.buffer, -char_len)
	if not ok_magic then magic_offset = nil end
	if not magic_offset then
		Logger.warn(LOG, "try_repeat_feature: utf8.offset returned nil — skipping.")
		return false
	end
	local before = _state.buffer:sub(1, magic_offset - 1)

	-- Read the last character before the magic key.
	local ok_last, last_char_offset = pcall(utf8.offset, before, -1)
	if not ok_last then last_char_offset = nil end
	if not last_char_offset then return false end
	local last_char = before:sub(last_char_offset)

	-- Refuse to repeat whitespace — repeating a space or newline is never useful.
	if last_char == "" or last_char:match("^%s$") then return false end

	-- Refuse to repeat the first letter of a word: the char before last_char
	-- must itself be a non-whitespace letter. Without this guard "c★" would
	-- fire at the start of a word (buffer = "c★"), where the user most likely
	-- intended a text-expansion, not a repeat.
	local before_last = last_char_offset > 1 and before:sub(1, last_char_offset - 1) or ""
	local pred_offset
	if before_last ~= "" then
		local ok_pred, off_pred = pcall(utf8.offset, before_last, -1)
		-- Malformed UTF-8 before the last char: treat predecessor as absent, block repeat
		pred_offset = ok_pred and off_pred or nil
	end
	local pred_char   = pred_offset and before_last:sub(pred_offset) or ""
	if pred_char == "" or pred_char:match("^%s$") or not text_utils.is_letter_char(pred_char) then
		return false
	end

	if not is_ignored then TooltipRenderer.hide({ forced = true }) end

	-- In ignored windows, the magic key is already on screen and must be deleted.
	if is_ignored then
		_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + 1
		TextSender.eraseChars(1, 0)
	end

	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. last_char
	-- Update the arm timestamp so the stuck-counter reset guard does not wipe
	-- expected_synthetic_chars if run-loop lag creates a false gap before the echo.
	if hs and hs.timer then
		_state.last_synthetic_arm_time = hs.timer.secondsSinceEpoch()
	end

	if keylogger and type(keylogger.notify_synthetic) == "function" then
		keylogger.notify_synthetic(last_char, "hotstring", is_ignored and 1 or 0, "repeat_key")
	end
	TextSender.send(last_char, { mode = "direct" })

	-- Update the buffer: strip the magic key and append the repeated character.
	-- magic_offset is already the byte start of the magic key — reuse it.
	_state.buffer = _state.buffer:sub(1, magic_offset - 1) .. last_char

	if not is_ignored and _llm.get_llm_enabled() then
		_llm.start_timer()
	end

	Logger.debug(LOG, "Repeat feature: repeated '%s'.", last_char)
	return true
end





-- =============================
-- =============================
-- ======= 4/ Module API =======
-- =============================
-- =============================

--- Convenience entry point for testing and simple integration: attempts to
--- expand the hotstring at the current buffer tail using `chars` as the last
--- typed character. When `chars` is a registered terminator the terminator
--- expansion path is tried first; if that finds no match the auto-expand path
--- (trigger-only, no terminator) is tried as a fallback.
---
--- This mirrors the logic performed by the live eventtap callback without
--- requiring callers to drive the full keymap init chain. Used by the E2E
--- virtual-keyboard harness (tests/e2e/run_e2e.lua).
---
--- @param chars string The last typed character(s) (potential terminator).
--- @param is_ignored boolean|nil Optional — defaults to false.
--- @return boolean True when any expansion fired.
function M.try_expand(chars, is_ignored)
	if not require_state("try_expand") then return false end
	is_ignored = is_ignored == true

	local char_len = 1  -- ASCII fallback; accurate enough for the E2E corpus
	local ok_len, n = pcall(function()
		local text_u = require("lib.text_utils")
		return text_u.utf8_len(chars)
	end)
	if ok_len and type(n) == "number" and n > 0 then char_len = n end

	-- Helper: iterate the bucket whose tail char matches the given last char.
	-- Falls back to an empty table when the registry has no matching bucket.
	local function bucket_for(tail)
		if type(_registry.mappings_for_tail) == "function" then
			return _registry.mappings_for_tail(tail:lower()) or {}
		end
		return {}
	end

	-- 1. Terminator path — only when chars is a known terminator.
	if type(_registry.is_terminator) == "function" and _registry.is_terminator(chars) then
		local saved_buf = _state.buffer
		-- Append the terminator so try_terminator_expand finds trigger + term suffix.
		_state.buffer = saved_buf .. chars
		-- Look up mappings by the last UTF-8 codepoint of the buffer before the
		-- terminator (i.e., the last codepoint of the trigger itself). Using the
		-- full codepoint is essential for multi-byte triggers (e.g. "cé"): sub(-1)
		-- would return only the trailing continuation byte, missing the bucket.
		local pre_term_tail
		do
			local ok, off = pcall(utf8.offset, saved_buf, -1)
			pre_term_tail = (ok and off) and saved_buf:sub(off) or saved_buf:sub(-1)
		end
		for _, m in ipairs(bucket_for(pre_term_tail)) do
			if M.try_terminator_expand(m, chars, char_len, is_ignored) then
				return true
			end
		end
		-- Restore buffer on no match.
		_state.buffer = saved_buf
	end

	-- 2. Auto-expand path — trigger at the very end, no terminator.
	_state.buffer = _state.buffer .. chars
	-- Use the last full UTF-8 codepoint of the updated buffer; sub(-1) would
	-- return only the trailing continuation byte for multi-byte codepoints.
	local tail
	do
		local ok, off = pcall(utf8.offset, _state.buffer, -1)
		tail = (ok and off) and _state.buffer:sub(off) or _state.buffer:sub(-1)
	end
	for _, m in ipairs(bucket_for(tail)) do
		if M.try_auto_expand(m, char_len, is_ignored) then
			return true
		end
	end

	return false
end


--- Injects the shared dependencies from keymap/init.lua.
--- Must be called exactly once before any expansion function.
--- @param core_state table The shared CoreState object.
--- @param registry_mod table The registry module.
--- @param llm_mod table The LLM bridge module.
function M.init(core_state, registry_mod, llm_mod)
	if type(core_state)  ~= "table" then Logger.error(LOG, "M.init(): core_state must be a table."); return end
	if type(registry_mod) ~= "table" then Logger.error(LOG, "M.init(): registry_mod must be a table."); return end
	if type(llm_mod)     ~= "table" then Logger.error(LOG, "M.init(): llm_mod must be a table."); return end

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	Logger.start(LOG, "Initializing expander…")
	_state    = core_state
	_registry = registry_mod
	_llm      = llm_mod
	-- The replay gate reads the same synthetic-echo counters the expander writes,
	-- so it is handed the identical state object rather than a copy.
	TerminatorReplay.init(core_state)
	Logger.success(LOG, "Expander initialized.")
end

return M
