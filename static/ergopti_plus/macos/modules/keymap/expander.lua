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

local text_utils = require("infra.text_utils")
-- The shared matcher core. Only M.decide is used: the firing DECISION is shared,
-- the buffer traversal is not — macOS slices a byte string, the core an array of
-- codepoints, and neither has to convert for the other.
local HotstringCore = require("infra.hotstring_engine")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("infra.logger")
local Timings    = require("infra.timings")
local CoreStateM = require("modules.keymap.state")
local TextSender = require("adapters.text_sender")
local SyntheticInput = require("adapters.synthetic_input")
local TooltipRenderer  = require("adapters.tooltip_renderer")
local TerminatorReplay = require("modules.keymap.terminator_replay")
local Terminators      = require("modules.keymap.terminators")
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
function M.perform_text_replacement(deletes, emit_action, buffer_action, is_final, is_ignored,
	source_type, source_variant, is_private, terminator_spec, terminal_target_override)
	if not require_state("perform_text_replacement") then return false end
	local discovered_terminal = terminal_target_override
	if discovered_terminal == nil and deletes > 0
		and type(TextSender.terminalInputTarget) == "function" then
		local target_ok, target_or_error = pcall(TextSender.terminalInputTarget)
		if not target_ok then
			pcall(Logger.error, LOG, "Terminal target discovery failed: %s.",
				tostring(target_or_error))
			return false
		end
		discovered_terminal = target_or_error
	end
	if discovered_terminal ~= nil and type(discovered_terminal) ~= "table"
		and type(discovered_terminal) ~= "userdata" then
		pcall(Logger.error, LOG, "Terminal target discovery returned invalid type '%s'.",
			type(discovered_terminal))
		return false
	end
	if discovered_terminal ~= nil
		and type(SyntheticInput.is_collecting_callback) == "function"
		and SyntheticInput.is_collecting_callback() ~= true then
		-- Tooltip acceptance runs from a deferred callback, after its eventtap has
		-- already returned. Give that path the same one-batch terminal transaction
		-- as a raw key callback; otherwise each delete is dispatched separately and
		-- no paced owner can be prepared.
		local entered_ok, entered_or_error = pcall(SyntheticInput.enter_paced_collection)
		if not entered_ok or type(entered_or_error) ~= "table" then
			Logger.error(LOG, "Terminal replacement collector could not be acquired: %s.",
				tostring(entered_or_error))
			return false
		end
		local outcome = table.pack(xpcall(function()
			return M.perform_text_replacement(deletes, emit_action, buffer_action,
				is_final, is_ignored, source_type, source_variant, is_private,
				terminator_spec, discovered_terminal)
		end, debug.traceback))
		if outcome[1] ~= true or outcome[2] ~= true then
			pcall(SyntheticInput.abort_callback)
			if outcome[1] ~= true then
				Logger.error(LOG, "Deferred terminal replacement failed: %s.", tostring(outcome[2]))
				return false
			end
			return table.unpack(outcome, 2, outcome.n)
		end
		local left_ok, left_or_error = pcall(SyntheticInput.leave_paced_collection)
		if not left_ok or left_or_error ~= true then
			-- The paced owner already committed before this memory-only close. Preserve
			-- acceptance so the caller cannot replay its validation key.
			pcall(SyntheticInput.abort_callback)
			Logger.error(LOG, "Deferred terminal collector close failed after commit: %s.",
				tostring(left_or_error))
		end
		return table.unpack(outcome, 2, outcome.n)
	end
	Logger.trace(LOG, "Performing replacement (%d deletion(s))…", deletes)

	-- Every logical producer receives a fresh immutable generation. A previous
	-- terminator cannot remain owned by this replacement, even when two producers
	-- start within the old timing window.
	TerminatorReplay.flush_now("superseded by a new replacement")
	local transaction = SyntheticInput.begin(source_variant or source_type or "replacement", "replacement")
	local terminal_target = discovered_terminal
	local paced_owner = nil
	local paced_settlement_budget = 0
	local replay_owner = nil
	local suppress_deadline = nil
	if not is_ignored then TooltipRenderer.hide({ forced = true }) end

	-- The preview refresh belongs to the same replacement transaction as its
	-- Quartz output. A second raw doAfter timer could be refused independently,
	-- leaving a successful chained expansion with no preview, and its callback
	-- could outlive a stop/re-init. Transaction completion already provides the
	-- required post-eventtap ordering, so make it the sole refresh authority.
	if not is_ignored then
		local preview_state = _state
		local preview_llm = _llm
		local preview_generation = preview_state.lifecycle_generation
		local registered, register_err = pcall(SyntheticInput.on_complete,
			transaction, function(_completed_tx, status)
				if status ~= "complete" or _state ~= preview_state or _llm ~= preview_llm
					or preview_state.lifecycle_generation ~= preview_generation then return end
				local ok, err = pcall(preview_llm.update_preview, preview_state.buffer)
				if not ok then
					Logger.error(LOG, "Replacement preview refresh failed: %s.", tostring(err))
				end
			end)
		if not registered then
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Replacement preview completion could not be registered: %s.",
				tostring(register_err))
			return false, transaction
		end
	end

	local ok, emit_count, emitted_str, logical_text, order_delay = pcall(function()
		return SyntheticInput.with_transaction(transaction, function()
			assert(TextSender.eraseChars(deletes, 0) ~= false,
				"replacement deletion could not be constructed")
			return emit_action()
		end)
	end)
	if not ok then
		-- Nothing in the callback collector has reached Quartz yet. Cancel removes
		-- every already-built prefix, so a producer that emits one token and then
		-- raises cannot leave half a replacement on screen or advance action state.
		pcall(SyntheticInput.cancel, transaction)
		Logger.error(LOG, "emit_action failed: %s.", tostring(emit_count))
		return false, transaction
	end
	if terminal_target then
		local terminal_key_delay_us = Timings.ms(
			"debounce", "terminal_hotstring_key_delay_ms") * 1000
		local paced_ok, paced_or_error = pcall(SyntheticInput.prepare_collected_paced,
			transaction, deletes, terminal_key_delay_us, terminal_target)
		if not paced_ok or paced_or_error == nil then
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Terminal replacement serializer preparation failed: %s.",
				tostring(paced_or_error))
			return false, transaction
		end
		paced_owner = paced_or_error
		local budget_ok, budget_or_error = pcall(
			SyntheticInput.paced_settlement_budget, paced_owner)
		if not budget_ok or type(budget_or_error) ~= "number" then
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Terminal replacement settlement budget failed: %s.",
				tostring(budget_or_error))
			return false, transaction
		end
		paced_settlement_budget = budget_or_error
	end
	emitted_str = emitted_str or ""
	-- Keep extensions that still return the historical two values working. The
	-- built-in clipboard emitter supplies an explicit logical value instead.
	logical_text = logical_text or emitted_str
	if terminator_spec then
		terminator_spec.transaction = transaction
		terminator_spec.min_delay = type(order_delay) == "number" and order_delay > 0
			and order_delay or 0
		terminator_spec.dispatch_budget = paced_settlement_budget
		terminator_spec.target_app = terminal_target
		local replay_ok, replay_or_error = pcall(TerminatorReplay.prepare, terminator_spec)
		if not replay_ok or type(replay_or_error) ~= "table" then
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Terminator replay preparation failed: %s.",
				tostring(replay_or_error))
			return false, transaction
		end
		replay_owner = replay_or_error
	end
	if is_final then
		local clock_ok, deadline_or_error = pcall(
			_state.prepare_suppress_rescan, CoreStateM.FINAL_RESULT_SUPPRESS_SEC)
		if not clock_ok or type(deadline_or_error) ~= "number" then
			if replay_owner then pcall(TerminatorReplay.cancel_prepared, replay_owner) end
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Replacement rescan deadline preparation failed: %s.",
				tostring(deadline_or_error))
			return false, transaction
		end
		suppress_deadline = deadline_or_error
	end

	-- Terminal preparation retained the still-reversible callback batch. Require
	-- an exact seal before publishing the matching engine/telemetry state; a false
	-- native-style result is a refusal, not a successful pcall.
	local seal_call_ok, seal_result = pcall(SyntheticInput.seal, transaction)
	if not seal_call_ok or seal_result ~= true then
		if replay_owner then pcall(TerminatorReplay.cancel_prepared, replay_owner) end
		pcall(SyntheticInput.cancel, transaction)
		Logger.error(LOG, "replacement transaction could not be sealed: %s.",
			tostring(seal_result))
		return false, transaction
	end
	if paced_owner then
		local authorize_ok, authorized_or_error = pcall(
			SyntheticInput.authorize_collected_paced, paced_owner)
		if not authorize_ok or authorized_or_error ~= true then
			if replay_owner then pcall(TerminatorReplay.cancel_prepared, replay_owner) end
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Terminal replacement serializer authorization failed: %s.",
				tostring(authorized_or_error))
			return false, transaction
		end
	end
	if replay_owner then
		local authorize_ok, authorized_or_error = pcall(
			TerminatorReplay.authorize_prepared, replay_owner)
		if not authorize_ok or authorized_or_error ~= true then
			pcall(TerminatorReplay.cancel_prepared, replay_owner)
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "Terminator replay authorization failed: %s.",
				tostring(authorized_or_error))
			return false, transaction
		end
	end

	if type(buffer_action) == "function" then
		local ok_buf, buf_err = pcall(buffer_action)
		if not ok_buf then
			-- Buffer commit and synthetic output are one transaction. Since the batch
			-- is still only being built, roll it back instead of displaying output the
			-- engine cannot describe afterwards.
			if replay_owner then pcall(TerminatorReplay.cancel_prepared, replay_owner) end
			pcall(SyntheticInput.cancel, transaction)
			Logger.error(LOG, "buffer_action failed: %s.", tostring(buf_err))
			return false, transaction
		end
	end

	-- From this point through ownership publication every operation is a bounded
	-- Lua table mutation. Native clocks, timers, target lookup, callback
	-- registration and snapshot validation all completed while rollback was exact.
	if suppress_deadline then _state.commit_suppress_rescan(suppress_deadline) end
	if paced_owner then SyntheticInput.commit_collected_paced(paced_owner) end
	if replay_owner then TerminatorReplay.commit_prepared(replay_owner) end

	-- Guard: skip telemetry when nothing was actually injected. This runs only
	-- after the buffer commit succeeded, so a rolled-back replacement cannot be
	-- persisted as output the application never received.
	if (deletes > 0 or logical_text ~= "") and keylogger and type(keylogger.notify_synthetic) == "function" then
		-- pcall-wrapped like the neighboring buffer_action call above: a truncated
		-- LLM completion cut mid-codepoint (French accents, curly quotes, em-dashes)
		-- can reach notify_synthetic with malformed UTF-8, and its utf8.codes loop
		-- would otherwise raise and abort the expansion mid-flight. is_private is
		-- forwarded so every logical persistence field is redacted; immutable event
		-- tags exclude the later OS echoes independently of payload contents.
		local ok_notify, notify_err = pcall(keylogger.notify_synthetic,
			logical_text, source_type or "hotstring", deletes, source_variant, emitted_str,
			is_private)
		if not ok_notify then
			pcall(Logger.error, LOG, "notify_synthetic failed: %s.", tostring(notify_err))
		end
	end

	if keylogger and type(keylogger.set_buffer) == "function" then
		local ok_set, set_err = pcall(keylogger.set_buffer, _state.buffer)
		if not ok_set then
			pcall(Logger.error, LOG, "keylogger.set_buffer failed: %s.", tostring(set_err))
		end
	end

	-- Named constant rather than a bare 1.0: it is deliberately DOUBLE the module
	-- default, and that relationship is invisible when the literal sits here.
	if not is_ignored then
		local llm_ok, llm_err = pcall(function()
			if (type(_llm.is_runtime_available) ~= "function" or _llm.is_runtime_available())
				and _llm.get_llm_enabled() then _llm.start_timer() end
		end)
		if not llm_ok then
			pcall(Logger.error, LOG, "Post-commit LLM timer update failed: %s.", tostring(llm_err))
		end
	end
	pcall(Logger.done, LOG, "Replacement complete.")
	return true, transaction
end





-- ===================================
-- ===================================
-- ======= 2/ Shared Internals =======
-- ===================================
-- ===================================

--- Extracts the one codepoint sitting immediately before a candidate trigger —
--- the only piece of left-hand context the word-boundary rule consults.
---
--- The rule itself is NOT here any more. It moved into the shared matcher core
--- (`HotstringCore.decide`), because macOS, Windows and Linux each carried their
--- own version and no two of them ever agreed at once. What stays here is the
--- part that is genuinely macOS's: pulling that codepoint out of a BYTE-string
--- buffer, which is an O(1) offset rather than the array index the core uses.
---
--- @param buffer string The current rolling buffer.
--- @param trigger_start_byte number 1-based byte index where the trigger starts
---   inside `buffer`. Must be >= 1.
--- @return string|nil The preceding codepoint; nil when the trigger starts the
---   buffer, so the caller falls back to `start_is_word_boundary`; an EMPTY
---   string when a character is there but could not be decoded, which the core
---   treats as "does not open a word" exactly as this function always has.
local function prev_char_before(buffer, trigger_start_byte)
	if trigger_start_byte <= 1 then return nil end
	local before            = buffer:sub(1, trigger_start_byte - 1)
	local ok_utf8, prev_off = pcall(utf8.offset, before, -1)
	-- Treat malformed UTF-8 the same as an absent left-hand char: no block
	if not ok_utf8 then prev_off = nil end
	return prev_off and before:sub(prev_off) or ""
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
--- casing for a "conform" entry, the stored replacement otherwise. nil means
--- the mapping does not fire, for any reason.
---
--- THE DECISION ITSELF IS NO LONGER HERE. It is `HotstringCore.decide`, shared
--- with the Linux engine, and this function is now the macOS half of that split:
--- it does the two slices a BYTE-string buffer makes cheap — the trigger-length
--- tail and the codepoint in front of it — and hands them over. Nothing converts
--- and nothing is duplicated, which is what the adoption was blocked on.
--- @param m table The mapping entry.
--- @param buffer string The buffer to evaluate against, as the engine will see it.
--- @return string|nil eff_plain The plain replacement, or nil when it will not fire.
--- @return string|nil typed The matched trigger text as typed, or nil.
--- @return string|nil eff_repl The raw replacement (may carry {Token} directives).
--- @return boolean is_noop True when it matched but replaces the text with itself.
function M.would_fire(m, buffer)
	if type(buffer) ~= "string" or type(m) ~= "table" then return nil end

	local tb = m.trigger_bytes
	if not tb or #buffer < tb then return nil end
	local typed = buffer:sub(-tb)

	local eff_plain, is_noop = HotstringCore.decide(
		m,
		m.plain_repl,
		typed,
		prev_char_before(buffer, #buffer - tb + 1),
		_state and _state.start_is_word_boundary
	)

	-- Equal visible text is not an identity operation when the raw replacement
	-- also carries key directives: `go -> go{Tab}` must still emit Tab even though
	-- plain_text deliberately strips that action before matching. Unknown
	-- placeholders remain literal, so raw ~= plain identifies a recognised
	-- key/newline directive on this registry path
	if is_noop and m.repl ~= m.plain_repl then
		eff_plain = m.plain_repl
		is_noop = false
	end

	-- A replacement identical to what was typed is a no-op: the engine passes the
	-- keystroke through rather than expanding, so the preview must not offer it.
	-- Reported as a distinct outcome because the engine still has cleanup to do
	-- for it, while the preview treats it exactly like "no match".
	if not eff_plain then
		if is_noop then return nil, typed, nil, true end
		return nil
	end

	-- The raw replacement, which may carry {Token} directives — EXCEPT in conform
	-- mode, where the effective text was re-cased and is plain by construction.
	-- Emitting the stored raw one there would undo the conformance.
	local eff_repl = (m.match_mode == "conform") and eff_plain or m.repl
	return eff_plain, typed, eff_repl, false
end

--- Returns whether a mapping's runtime group currently permits it to fire.
--- The explicit-validation path may bypass typing delay, never feature state.
--- @param mapping table Registry mapping.
--- @return boolean
local function mapping_group_active(mapping)
	if not mapping.group then return true end
	local groups = _state and _state.groups
	local group = groups and groups[mapping.group]
	return not group or not not group.enabled
end

local NNBSP = "\xE2\x80\xAF"  -- U+202F, 3 UTF-8 bytes
local NBSP  = "\xC2\xA0"      -- U+00A0, 2 UTF-8 bytes

--- Resolves the pure matching half of a terminator expansion.
---
--- Both the emitter and the prospective magic-key resolver call this function.
--- It owns terminator enablement, French typography stripping, word/case/no-op
--- matching and consume state, so the tooltip cannot reconstruct a looser
--- answer than the action path.
--- @param mapping table Registry mapping.
--- @param buffer string Buffer including the terminator event.
--- @param chars string Terminator character(s) appended to the buffer.
--- @param explicit_magic boolean|nil True when the configured magic action is
---        being resolved. Bare `:`/`;` are then valid on non-Ergopti layouts.
--- @return table|nil match Matching metadata, including a possible `is_noop`.
local function resolve_terminator_match(mapping, buffer, chars, explicit_magic)
	if type(mapping) ~= "table" or type(buffer) ~= "string" or type(chars) ~= "string" then
		return nil
	end
	if not _registry.is_terminator(chars) then return nil end

	local trigger = mapping.trigger
	local tb = mapping.trigger_bytes
	if type(trigger) ~= "string" or type(tb) ~= "number" then return nil end

	local chars_bytes = #chars
	local extra_bs_bytes = 0
	local is_typo_endchar = (chars == ":" or chars == ";")
	if is_typo_endchar and not explicit_magic then
		local nnbsp_pos = #buffer - chars_bytes - #NNBSP + 1
		local nbsp_pos  = #buffer - chars_bytes - #NBSP + 1
		if nnbsp_pos >= 1 and buffer:sub(nnbsp_pos, nnbsp_pos + #NNBSP - 1) == NNBSP then
			extra_bs_bytes = #NNBSP
		elseif nbsp_pos >= 1 and buffer:sub(nbsp_pos, nbsp_pos + #NBSP - 1) == NBSP then
			extra_bs_bytes = #NBSP
		else
			return nil
		end
	end

	local effective_chars_bytes = chars_bytes + extra_bs_bytes
	if #buffer < tb + effective_chars_bytes then return nil end
	local buf_start = #buffer - effective_chars_bytes - tb + 1
	local body = buffer:sub(1, buf_start + tb - 1)
	local eff_plain, typed_trigger, eff_repl, is_noop = M.would_fire(mapping, body)
	if not eff_plain and not is_noop then return nil end

	return {
		buf_start       = buf_start,
		eff_plain       = eff_plain,
		typed_trigger   = typed_trigger,
		eff_repl        = eff_repl,
		is_noop         = is_noop == true,
		extra_bs_bytes  = extra_bs_bytes,
		consume_term    = _registry.terminator_is_consumed(chars),
	}
end

--- Resolves every static action reachable by pressing the magic key now.
---
--- This is the shared arbitration boundary for the keyboard engine and tooltip.
--- It returns the exact first action the engine will attempt plus the remaining
--- eligible rows. A strictly longer end-character mapping beats an auto mapping;
--- equal length stays with the auto mapping. Group state, terminator state,
--- auto-expand eligibility and case/word matching are all resolved here. The
--- optional predicate is the eventtap's ordinary-auto timing gate; explicit
--- magic mappings bypass it, while literal mappings that merely happen to end
--- with a newly selected magic key retain their historical timing semantics.
---
--- `attempts` preserves the engine's fallback order. `candidates` contains each
--- displayable candidate once, in the UI's end-char then star order.
--- @param buffer string Buffer before the magic key is pressed.
--- @param ordinary_auto_allowed function|nil Runtime eligibility for literal autos.
--- @param event_chars string|nil Real physical payload at commit time. Preview
---        callers omit it and resolve the configured logical action.
--- @return table|nil resolution
function M.resolve_magic_action(buffer, ordinary_auto_allowed, event_chars)
	if not require_state("resolve_magic_action") then return nil end
	if type(buffer) ~= "string" then return nil end
	if ordinary_auto_allowed ~= nil and type(ordinary_auto_allowed) ~= "function" then return nil end

	local magic = _state.magic_key
	if type(magic) ~= "string" or magic == "" then return nil end
	if event_chars ~= nil and not Terminators.matches_magic_event(event_chars, magic) then return nil end
	local physical_magic = event_chars or magic
	local auto_buffer = nil
	local star_attempts = {}
	local literal_attempts = {}
	local end_attempts = {}

	do
		local ok_tail, tail_offset = pcall(utf8.offset, buffer, -1)
		local tail_char = (ok_tail and tail_offset) and buffer:sub(tail_offset) or nil
		local star_bucket = tail_char and _registry.mappings_for_star_tail(tail_char) or nil
		local bare_star_bucket = _registry.mappings_for_star_tail("")
		auto_buffer = (star_bucket or bare_star_bucket) and (buffer .. magic) or nil
		-- A bare magic-key mapping is globally shortest, so scanning it after the
		-- tail-specific bucket preserves the registry's longest-first order without
		-- rebuilding or linearly scanning the full magic-key bucket per preview.
		for bucket_index = 1, 2 do
			local bucket
			if bucket_index == 1 then bucket = star_bucket else bucket = bare_star_bucket end
			if bucket then
				for _, mapping in ipairs(bucket) do
					if mapping.auto and mapping.has_magic and mapping_group_active(mapping) then
						local eff_plain, typed, eff_repl, is_noop = M.would_fire(mapping, auto_buffer)
						if eff_plain or is_noop then
							local action = {
								mapping = mapping,
								kind = "star",
								eff_plain = eff_plain,
								typed = typed,
								eff_repl = eff_repl,
								is_noop = is_noop == true,
							}
							star_attempts[#star_attempts + 1] = action
						end
					end
				end
			end
		end

		-- update_trigger_char deliberately leaves unrelated mappings untouched when
		-- their literal suffix happens to equal the newly selected magic key. They
		-- still fire through the ordinary auto path (including its timing gate), so
		-- both the preview and magic dispatch must retain them in the same ledger.
		local literal_tail_bucket = type(_registry.mappings_for_literal_magic_tail) == "function"
			and tail_char and _registry.mappings_for_literal_magic_tail(tail_char) or nil
		local literal_bare_bucket = type(_registry.mappings_for_literal_magic_tail) == "function"
			and _registry.mappings_for_literal_magic_tail("") or nil
		if literal_tail_bucket or literal_bare_bucket then auto_buffer = auto_buffer or (buffer .. magic) end
		for bucket_index = 1, 2 do
			local literal_bucket = bucket_index == 1 and literal_tail_bucket or literal_bare_bucket
			if literal_bucket then
				for _, mapping in ipairs(literal_bucket) do
					local timing_allowed, remaining_delay = true, nil
					if ordinary_auto_allowed ~= nil then
						timing_allowed, remaining_delay = ordinary_auto_allowed(mapping)
					end
					if mapping.auto and not mapping.has_magic and mapping_group_active(mapping)
						and timing_allowed
					then
						local eff_plain, typed, eff_repl, is_noop = M.would_fire(mapping, auto_buffer)
						if eff_plain or is_noop then
							literal_attempts[#literal_attempts + 1] = {
								mapping = mapping,
								kind = "literal_auto",
								eff_plain = eff_plain,
								typed = typed,
								eff_repl = eff_repl,
								is_noop = is_noop == true,
								remaining_delay = remaining_delay,
							}
						end
					end
				end
			end
		end

		if buffer ~= "" and _registry.is_terminator(magic) then
			local end_bucket = tail_char and _registry.mappings_for_tail(tail_char) or nil
			if end_bucket then
				local end_buffer = buffer .. physical_magic
				for _, mapping in ipairs(end_bucket) do
					if not mapping.auto and mapping_group_active(mapping) then
						local match = resolve_terminator_match(mapping, end_buffer, physical_magic, true)
						if match then
							local action = {
								mapping = mapping,
								kind = "autocorrect",
								eff_plain = match.eff_plain,
								typed = match.typed_trigger,
								eff_repl = match.eff_repl,
								is_noop = match.is_noop,
							}
							end_attempts[#end_attempts + 1] = action
						end
					end
				end
			end
		end
	end

	if #star_attempts == 0 and #literal_attempts == 0 and #end_attempts == 0 then return nil end

	-- True star mappings and literal autos come from two narrow indexes. Merge
	-- only the actions that actually matched, using the rank assigned by the
	-- registry's one canonical comparator; this preserves its length/priority/
	-- group/sequence order without copying that comparator into the expander.
	local auto_attempts = {}
	for _, action in ipairs(star_attempts) do auto_attempts[#auto_attempts + 1] = action end
	for _, action in ipairs(literal_attempts) do auto_attempts[#auto_attempts + 1] = action end
	if #literal_attempts > 0 and #auto_attempts > 1 then
		table.sort(auto_attempts, function(a, b)
			return (a.mapping.registry_rank or math.huge) < (b.mapping.registry_rank or math.huge)
		end)
	end

	local attempts = {}
	local first_auto_len = 0
	for _, action in ipairs(auto_attempts) do
		if action.eff_plain then
			first_auto_len = action.mapping.tlen
			break
		end
	end
	if first_auto_len > 0 then
		for _, candidate in ipairs(end_attempts) do
			if candidate.mapping.tlen > first_auto_len then
				attempts[#attempts + 1] = candidate
			end
		end
		for _, candidate in ipairs(auto_attempts) do
			attempts[#attempts + 1] = candidate
		end
		-- Preserve the historical fallback: if every auto action declines during
		-- commit, the engine gives every end-char candidate one final chance.
		for _, candidate in ipairs(end_attempts) do
			attempts[#attempts + 1] = candidate
		end
	else
		for _, candidate in ipairs(end_attempts) do
			attempts[#attempts + 1] = candidate
		end
		for _, candidate in ipairs(auto_attempts) do
			attempts[#attempts + 1] = candidate
		end
	end

	-- A no-op final action still mutates runtime state: try_*_expand calls
	-- suppress_rescan(), which clears the buffer before returning false. Every
	-- later attempt would therefore re-match against an empty buffer and cannot
	-- fire. Keep the terminal attempt for that cleanup, but do not advertise or
	-- dispatch actions beyond it.
	local attempt_count = #attempts
	local reachable_count = attempt_count
	for index = 1, attempt_count do
		local action = attempts[index]
		action.reachable = true
		if action.is_noop and action.mapping.final_result then
			reachable_count = index
			break
		end
	end
	for index = reachable_count + 1, attempt_count do attempts[index] = nil end

	local end_candidates = {}
	local star_candidates = {}
	local literal_candidates = {}
	local candidates = {}
	for _, action in ipairs(end_attempts) do
		if action.reachable and action.eff_plain then
			end_candidates[#end_candidates + 1] = action
			candidates[#candidates + 1] = action
		end
	end
	for _, action in ipairs(auto_attempts) do
		if action.reachable and action.eff_plain then
			if action.kind == "star" then
				star_candidates[#star_candidates + 1] = action
			else
				literal_candidates[#literal_candidates + 1] = action
			end
			candidates[#candidates + 1] = action
		end
	end

	local winner = nil
	for _, action in ipairs(attempts) do
		if action.eff_plain then winner = action; break end
	end

	return {
		winner = winner,
		attempts = attempts,
		candidates = candidates,
		star_candidates = star_candidates,
		literal_candidates = literal_candidates,
		end_candidates = end_candidates,
	}
end

--- Commits one automatic mapping against either the live buffer or an exact
--- prospective buffer supplied by magic-key arbitration.
--- @param m table Mapping entry.
--- @param char_len number Logical codepoint count of the current trigger event.
--- @param is_ignored boolean Whether the physical event is already on screen.
--- @param match_buffer string|nil Immutable buffer used for matching/splicing.
--- @return boolean True when the expansion committed.
function M.try_auto_expand(m, char_len, is_ignored, match_buffer)
	if not require_state("try_auto_expand") then return false end
	local active_buffer = type(match_buffer) == "string" and match_buffer or _state.buffer

	-- The `*` flag, and the only place it is checked. An entry that does not opt in
	-- waits for a terminator — "ya" must not fire inside "yaourt". Neither
	-- would_fire, this function, nor the tail index filtered on it, so a non-auto
	-- entry expanded the moment its trigger was complete
	-- (test_auto_expand_flag_gate.lua carries the full account).
	if not m.auto then return false end

	local trigger = m.trigger

	-- The whole match decision — length, case resolution, word boundary, no-op —
	-- lives in M.would_fire, which the tooltip preview calls too. Keeping it in one
	-- place is what guarantees the preview cannot promise an expansion this
	-- function then declines to perform.
	local eff_plain, typed, eff_repl, is_noop = M.would_fire(m, active_buffer)

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
	local tstart_byte = #active_buffer - m.trigger_bytes + 1

	-- Compute how many backspaces and what to type, keeping common prefix chars.
	-- In an ignored window (char_len == 0) there is no "last char" to keep, so
	-- we must erase the full trigger length. m.tlen is the precomputed UTF-8
	-- length of the trigger (avoids three utf8_len calls per hot-path hit).
	local trig_len         = m.tlen
	local char_offset      = is_ignored and 0 or char_len
	local screen_len       = trig_len - char_offset
	-- Clamped at zero. A trigger shorter than the typed event's codepoint count
	-- (a multi-codepoint composed character arriving as one event) cannot require
	-- a negative number of on-screen deletions. Keeping the clamp at the operation
	-- boundary also prevents malformed replacement transactions.
	if screen_len < 0 then
		Logger.warn(LOG, "Trigger shorter than the typed event (%d < %d) — clamping deletes to 0.",
			trig_len, char_offset)
		screen_len = 0
	end
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

	local replaced = M.perform_text_replacement(
		deletes,
		function() return emit_dispatch(m, to_type) end,
		function()
			_state.buffer = active_buffer:sub(1, tstart_byte - 1) .. repl_text
		end,
		m.final_result,
		is_ignored,
		"hotstring",
		m.group or nil,
		m.is_private
	)
	if not replaced then return false end

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
--- @param explicit_magic boolean|nil True when the configured magic action owns
---        this event, allowing bare French punctuation on another input source.
--- @return boolean True when the expansion fired.
function M.try_terminator_expand(m, chars, char_len, is_ignored, explicit_magic)
	if not require_state("try_terminator_expand") then return false end
	local match = resolve_terminator_match(m, _state.buffer, chars, explicit_magic)
	if not match then return false end

	local trigger        = m.trigger
	local buf_start      = match.buf_start
	local eff_plain      = match.eff_plain
	local typed_trigger  = match.typed_trigger
	local eff_repl       = match.eff_repl
	local is_noop        = match.is_noop
	local extra_bs_bytes = match.extra_bs_bytes

	-- Precomputed trigger length; avoids a hot-path utf8.len call.
	local trig_len    = m.tlen

	local consume_term = match.consume_term

	if not eff_plain then
		-- No-op guard: when the replacement equals what is on screen, signal
		-- pass-through so the terminating character is NOT consumed. It must stay
		-- on screen — returning true would suppress it with nothing injected (the
		-- dropped-terminator-chars bug).
		if is_noop then
			if m.final_result then _state.suppress_rescan() end
			if not is_ignored then TooltipRenderer.hide({ forced = true }) end
		end
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
		-- The EFFECTIVE replacement, which in conform mode carries the casing the
		-- user typed. tokens_from_repl() is only called below when we actually need
		-- to emit tokens (replacements with {Token} directives).
		local repl_text        = eff_plain
		local deletes, to_type = trig_len, repl_text
		local replay_spec = nil
		if not consume_term then
			if chars == "\r" or chars == "\n" then
				replay_spec = { kind = "key", key = "return", chars = chars }
		elseif chars == "\t" then
				replay_spec = { kind = "key", key = "tab", chars = chars }
		else
				replay_spec = { kind = "text", chars = chars }
			end
		end

		if repl_text == eff_repl then
			-- Simple text: keep common prefix to reduce backspaces. Compared against
			-- the trigger AS TYPED, not the registered canonical, so the characters
			-- left on screen are the ones actually there — they differ for a "fold"
			-- entry, and keeping a "matching" prefix that is cased
			-- differently would leave the user's capital in front of the expansion.
			local common = text_utils.get_common_prefix_utf8(typed_trigger, repl_text)
			deletes = trig_len - common
			to_type = text_utils.utf8_sub(repl_text, common + 1)
		end

		-- In an ignored window there is no "char" kept on screen — erase it too.
		if is_ignored then deletes = deletes + char_len end

		-- When a NNBSP/NBSP was stripped before matching (typographic ``:``/`` ; ``),
		-- add 1 extra backspace to erase the nbsp that sits between trigger and endchar.
		if extra_bs_bytes > 0 then deletes = deletes + 1 end

		local replacement_ok = M.perform_text_replacement(
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
					-- Keep the logical replacement and keylogger record aligned with
					-- the later owned replay.
					s = s .. chars
					logical = logical .. chars
					c = c + text_utils.utf8_len(chars)
				end
				return c, s, logical, order_delay
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
			m.is_private,
			replay_spec
		)
		if not replacement_ok then return false end

		-- Same privacy contract as try_auto_expand: a private mapping's trigger
		-- and replacement are both secrets and must reach neither the keylogger
		-- nor the log.
		if m.is_private then
			Logger.debug(LOG, "Terminator-expand: private mapping fired (content withheld).")
		else
			if keylogger and type(keylogger.log_hotstring) == "function" then
				pcall(keylogger.log_hotstring, trigger, repl_text)
			end
			Logger.debug(LOG, "Terminator-expand: '%s' → '%s'.", typed_trigger, repl_text)
		end
		return true
	end

	-- Build synchronously. Inside the keymap eventtap the adapter returns the
	-- tagged batch to Quartz as the callback's second result; it never posts or
	-- sleeps in this HID callback.
	return do_expansion()
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
	if not Terminators.matches_magic_event(chars, _state.magic_key) then return false end

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

	local next_buffer = _state.buffer:sub(1, magic_offset - 1) .. last_char
	local replaced = M.perform_text_replacement(
		is_ignored and char_len or 0,
		function() return km_utils.emit_text(last_char) end,
		function() _state.buffer = next_buffer end,
		false, is_ignored, "hotstring", "repeat_key", false)
	if replaced ~= true then return false end

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
		local text_u = require("infra.text_utils")
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
--- @return boolean committed True only when every dependency is ready.
function M.init(core_state, registry_mod, llm_mod)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table.")
		return false
	end
	if type(registry_mod) ~= "table" then
		Logger.error(LOG, "M.init(): registry_mod must be a table.")
		return false
	end
	if type(llm_mod) ~= "table" then
		Logger.error(LOG, "M.init(): llm_mod must be a table.")
		return false
	end

	if _state then
		if _state == core_state and _registry == registry_mod and _llm == llm_mod then
			Logger.warn(LOG, "M.init() called more than once with the active dependencies — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): different dependencies are already active — replacement refused.")
		return false
	end

	Logger.start(LOG, "Initializing expander…")
	-- The replay gate reads the same synthetic-echo counters the expander writes,
	-- so it is handed the identical state object before this module publishes any
	-- of its own dependencies.
	if TerminatorReplay.init(core_state) ~= true then
		Logger.error(LOG, "M.init(): terminator replay dependency initialization refused.")
		return false
	end
	_state    = core_state
	_registry = registry_mod
	_llm      = llm_mod
	Logger.success(LOG, "Expander initialized.")
	return true
end

return M
