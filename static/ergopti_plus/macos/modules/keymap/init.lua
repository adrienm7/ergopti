--- modules/keymap/init.lua

--- ==============================================================================
--- MODULE: Keymap Core
--- DESCRIPTION:
--- Core engine for Ergopti+. Initializes the central eventtap loop, manages
--- the typing buffer, and routes interactions to the Registry, LLM Bridge, and
--- Expander. This module is the single source of truth for all keymap defaults.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: All keymap-wide defaults live in M.DEFAULT_STATE
---    and M.DELAYS_DEFAULT. Menu modules read from here — never re-declare them.
--- 2. Shared State: Centralizes runtime state via CoreState without globals.
--- 3. Zero-Latency Execution: Uses an ultra-fast event loop directly connected
---    to the OS, with a pcall safety wrapper to prevent keyboard lockups.
--- 4. Modularity: Defers specific responsibilities to specialized submodules.
--- ==============================================================================

local hs         = hs
local eventtap   = hs.eventtap
local text_utils = require("infra.text_utils")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("infra.logger")
local Keycodes   = require("infra.keycodes")
local Manifest   = require("infra.manifest_reader")

local Registry   = require("modules.keymap.registry")
local Expander   = require("modules.keymap.expander")
local LLMBridge  = require("modules.keymap.llm_bridge")
local CoreStateM = require("modules.keymap.state")
local TerminatorReplay = require("modules.keymap.terminator_replay")
local Perf       = require("infra.perf")
local HotPath    = require("infra.hotpath_profiler")

local M   = {}
local LOG = "keymap"





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

-- Per-group expansion delay thresholds (in seconds).
-- A value of 0 means the expansion fires regardless of typing speed.
-- These values are the ULTIMATE fallback. The live values are resolved at
-- startup by `modules.hotstrings_config` from each category TOML's `[_meta]`
-- block and from `~/.config/ergopti_plus/hotstrings_config.toml` user overrides.
M.DELAYS_DEFAULT = {
	STAR_TRIGGER       = 2.0,  -- Manual expansions with ★ (magic key)
	dynamichotstrings  = 2.0,  -- Phone numbers, SSN, dates…
	autocorrection     = 1.0,  -- Spell checking
	rolls              = 0.5,  -- Rolls (e.g. sx → sk)
	sfbsreduction      = 0.5,  -- Comma combos (e.g. ,t → pt)
	distancesreduction = 0.5,  -- Dead keys and suffixes
	llm_prediction     = 20.0, -- AI prediction tooltip timeout
}

-- Maps DELAYS_DEFAULT keys to the category names used by `hotstrings_config`
-- (i.e. the basename of each hotstring TOML file). Keys present here have
-- their delay sourced from the TOML metadata + user overrides; keys absent
-- (`dynamichotstrings`, `llm_prediction`) keep DELAYS_DEFAULT as authoritative.
M.DELAY_KEY_TO_CATEGORY = {
	STAR_TRIGGER       = "magickey",
	autocorrection     = "autocorrection",
	rolls              = "rolls",
	sfbsreduction      = "sfbsreduction",
	distancesreduction = "distancesreduction",
}

--- Canonical defaults exposed to menu modules (single source of truth).
--- Menu modules MUST read from here instead of re-declaring their own values.
--- The hotstring/preview values are sourced from the shared features manifest
--- (`_shared/modules/features/manifest.toml` -> `_generated/features_manifest.lua`) via
--- `lib.manifest_reader`, so they stay in lock-step with the AHK driver (which
--- builds its whole `Features` map from the same manifest). `default_for` fails
--- fast if a path is missing, so a renamed feature never silently becomes nil.
M.DEFAULT_STATE = {
	keymap                      = true,   -- Module on/off toggle (no manifest entry)
	expansion_delay             = Manifest.default_for("hotstrings.expansion_delay"),
	delays                      = {},     -- Per-group overrides; empty = use DELAYS_DEFAULT
	trigger_char                = Manifest.default_for("hotstrings.trigger_char"),
	preview_star_enabled        = Manifest.default_for("hotstrings.preview_star_enabled"),
	preview_autocorrect_enabled = Manifest.default_for("hotstrings.preview_autocorrect_enabled"),
	preview_ai_enabled          = Manifest.default_for("hotstrings.preview_ai_enabled"),
	preview_colored_tooltips    = Manifest.default_for("hotstrings.preview_colored_tooltips"),
}





-- ======================================
-- ======================================
-- ======= 2/ Constants And State =======
-- ======================================
-- ======================================

-- Maximum length of the rolling keystroke buffer, expressed in UTF-8
-- CODEPOINTS (not bytes). Triggers are bounded well under this; the cap
-- only exists to keep memory and per-keystroke work bounded for users
-- who go an extraordinarily long time between resets.
local BUFFER_MAX_CHARS = 500

-- Byte-length gate for the trim path. A UTF-8 codepoint is at most 4 bytes,
-- so when the raw byte length stays under this threshold the codepoint count
-- is guaranteed to be under BUFFER_MAX_CHARS and we can skip the utf8.offset
-- scan entirely. This keeps the fast path to a single integer compare.
local BUFFER_TRIM_BYTE_GATE = BUFFER_MAX_CHARS * 4

-- Complex-keystroke delay multiplier. Shift- or Alt-held keystrokes take
-- longer finger-path time than a bare letter, so we widen the expansion
-- window for them by this factor.
local COMPLEX_DELAY_MULT = 2

-- How long after a complex keystroke the bonus multiplier still applies to
-- the next keystroke — this covers the small lag between releasing Shift
-- and pressing the next letter. Beyond this window the bonus is dropped so
-- it cannot inadvertently stretch an expansion on an unrelated later key.
local COMPLEX_CARRY_SEC = 0.3

-- Central memory struct passed via reference to all sub-modules. The shape,
-- invariants, and default seeding live in modules/keymap/state.lua; keeping
-- them out of init.lua prevents three separate files (Registry, Expander,
-- LLMBridge) from silently assuming divergent field sets.
local CoreState = CoreStateM.new(M.DEFAULT_STATE, M.DELAYS_DEFAULT)

-- Registry exposes the repeat-feature toggle used by the event loop. Binding
-- it after state.new() avoids a circular require (state.lua cannot reference
-- Registry without pulling the full keymap module in).
CoreState.is_repeat_feature_enabled  = Registry.is_repeat_feature_enabled
CoreState.set_repeat_feature_enabled = Registry.set_repeat_feature_enabled

-- Mount dependencies (order matters: Registry before Expander/LLMBridge).
Registry.init(CoreState)
LLMBridge.init(CoreState, M.DEFAULT_STATE)
Expander.init(CoreState, Registry, LLMBridge)

local tap       = nil
local shift_tap = nil
local mouse_tap = nil
local loopback_keyup_tap = nil
local _started = false

local ACTION_EPOCH_LISTENER_ID = "modules.keymap.action_epoch"
local _action_listener_registered = false
local _last_action_epoch = SyntheticInput.current_action_epoch()
local _last_context_epoch = _last_action_epoch
local _action_preview_refresh_pending = false
local _context_reconcile_pending = false
local _context_reconcile_timer = nil


--- Reconciles only the keymap context for one action epoch.
--- This helper deliberately performs no logging, timer, canvas, or LLM work.
--- @param epoch table Opaque token returned by SyntheticInput.
--- @return boolean current True when epoch is still current.
local function observe_context_epoch(epoch)
	if epoch ~= SyntheticInput.current_action_epoch() then return false end
	if epoch ~= _last_context_epoch then
		CoreState.buffer = ""
		CoreState.start_is_word_boundary = false
		_action_preview_refresh_pending = false
		_last_context_epoch = epoch
	end
	return true
end


--- Observes one action epoch using Lua-only, constant-time state mutations.
--- This is the only action-epoch work permitted inside the keyDown eventtap.
--- @param epoch table Opaque token returned by SyntheticInput.
--- @return boolean current True when epoch is still current.
local function observe_action_epoch(epoch)
	if not observe_context_epoch(epoch) then return false end
	LLMBridge.observe_action_epoch(epoch)
	return true
end


--- Async action-listener entry point. It deliberately propagates reset failures
--- so the adapter applies its bounded retry/quarantine policy off the HID path.
--- @param epoch table Opaque action epoch.
local function reconcile_action_epoch_async(epoch)
	if not observe_context_epoch(epoch) then return true end
	if epoch == _last_action_epoch then return true end
	local reconciled = LLMBridge.reset_for_action_epoch(epoch)
	if not reconciled then
		-- A newer token superseded this callback. The adapter notices its own token
		-- changed and schedules the latest epoch; the stale one must not reopen it.
		if epoch ~= SyntheticInput.current_action_epoch() then return true end
		error("LLM action-epoch reset did not reconcile the current token", 0)
	end
	-- Physical typing can overtake the async listener. The HID callback still
	-- updates the authoritative buffer and hotstring preview while the LLM runtime
	-- is quarantined, but it deliberately cannot arm the prediction timer. Re-run
	-- the normal preview path here, off the eventtap, so every character typed in
	-- that window participates in the first post-recovery prediction.
	if _action_preview_refresh_pending then
		LLMBridge.update_preview(CoreState.buffer)
		if epoch ~= SyntheticInput.current_action_epoch() then return true end
		_action_preview_refresh_pending = false
	end
	_last_action_epoch = epoch
	return true
end


--- Refreshes the preview and remembers when the LLM half was quarantined.
--- The async action listener consumes the marker after reopening the exact epoch.
--- @param buffer string Current authoritative typing buffer.
local function update_preview_with_action_recovery(buffer)
	if not LLMBridge.is_runtime_available() then
		_action_preview_refresh_pending = true
	end
	LLMBridge.update_preview(buffer)
end


--- Cancels a pending catch-up when navigation made the current buffer ineligible.
local function cancel_action_preview_recovery()
	_action_preview_refresh_pending = false
end


--- Discards every belief the driver holds about the text around the cursor.
---
--- Called after a keyDown outage — macOS silently disables an event tap whose
--- callback overruns the system timeout, and the user keeps typing into a driver
--- that no longer sees anything. Reviving the tap without this left the buffer
--- describing a line that no longer exists, so the next expansion sized its
--- backspaces against stale text and erased characters the user had just typed.
--- That is the second half of "my keystrokes get swallowed", and it outlives the
--- outage that caused it.
---
--- Declared HERE, above every caller. A Lua local's scope starts after its
--- declaration, so a copy placed further down would bind the never-assigned
--- GLOBAL in the error handler that needs it most.
local function reconcile_observed_context_async()
	_context_reconcile_timer = nil
	if not _context_reconcile_pending then return end
	_context_reconcile_pending = false
	local ok, err = xpcall(LLMBridge.reconcile_observation_gap, debug.traceback)
	if not ok then
		-- Keep the runtime fail-closed; the watchdog will retry outside CGEventTap.
		_context_reconcile_pending = true
		Logger.error(LOG, "Typing-context reconciliation failed - %s.", tostring(err))
		return
	end
	Logger.warn(LOG, "Typing context invalidated - keystrokes were missed.")
end


--- Closes cursor/prediction state in O(1), then schedules external work after
--- the eventtap returns. The retained pending flag lets the watchdog retry if a
--- timer allocation fails without performing file/canvas work on the HID path.
local function invalidate_observed_context()
	CoreState.buffer = ""
	cancel_action_preview_recovery()
	-- Not a word boundary: the cursor sits in territory we never observed, so
	-- word-anchored triggers must stay silent until a real terminator is seen.
	CoreState.start_is_word_boundary = false
	-- A terminator held across the outage has lost its ordering guarantee, but
	-- dropping it would silently eat the user's Enter — send it rather than lose it.
	TerminatorReplay.flush_now("keyboard tap outage", true)
	LLMBridge.set_runtime_quarantined(true)
	_context_reconcile_pending = true
	if _context_reconcile_timer then return end
	local callback_ran = false
	local ok, timer_or_err = pcall(hs.timer.doAfter, 0, function()
		callback_ran = true
		reconcile_observed_context_async()
	end)
	if ok and timer_or_err ~= nil and not callback_ran then
		_context_reconcile_timer = timer_or_err
	end
end





-- ==========================================
-- ==========================================
-- ======= 3/ Base API And Forwarding =======
-- ==========================================
-- ==========================================

--- Returns the current baseline inter-key delay threshold.
--- @return number The delay in seconds.
function M.get_base_delay()
	return CoreState.BASE_DELAY_SEC
end

--- Sets the baseline inter-key delay threshold used for all unmapped groups.
--- @param secs number The new threshold in seconds (clamped to ≥ 0).
function M.set_base_delay(secs)
	local v = math.max(0, tonumber(secs) or M.DEFAULT_STATE.expansion_delay)
	CoreState.BASE_DELAY_SEC = v
	Logger.debug(LOG, "Base delay: %.3fs.", v)
end

--- Returns the side of the last shift key pressed.
--- @return string|nil "left", "right", or nil if Shift is not held.
function M.get_shift_side()
	return CoreState.shift_side
end

--- Returns the current magic-key character (e.g. "★").
--- @return string
function M.get_trigger_char()
	return CoreState.magic_key or M.DEFAULT_STATE.trigger_char
end

--- Pauses eventtap processing — all keystrokes pass through unmodified.
function M.pause_processing()
	CoreState.processing_paused = true
	cancel_action_preview_recovery()
	Logger.debug(LOG, "Processing paused.")
end

--- Resumes eventtap processing after a pause.
function M.resume_processing()
	CoreState.processing_paused = false
	Logger.debug(LOG, "Processing resumed.")
end

--- Returns true when the eventtap is currently paused.
--- @return boolean
function M.is_processing_paused()
	return CoreState.processing_paused
end

--- Sets the per-group delay threshold for the given key.
--- Only keys present in DELAYS_DEFAULT are accepted; unknown keys are silently ignored.
--- @param key string The group identifier (must be a key of DELAYS_DEFAULT).
--- @param val number The new threshold in seconds.
function M.set_delay(key, val)
	if M.DELAYS_DEFAULT[key] == nil then return end

	CoreState.DELAYS[key] = tonumber(val) or M.DELAYS_DEFAULT[key]
	Logger.debug(LOG, "Delay '%s': %.3fs.", key, CoreState.DELAYS[key])

	-- Recompute WORD_TIMEOUT_SEC whenever any delay changes — factors in the
	-- per-section overrides too (see CoreState.recompute_word_timeout).
	CoreState.recompute_word_timeout()
end

--- Globally reassigns the magic expansion key (the "★" character by default).
--- Registry.update_trigger_char owns the write to CoreState.magic_key because
--- it needs the previous value to rename every affected mapping. Do not
--- pre-assign CoreState.magic_key here — Registry handles it atomically.
--- @param char string The new trigger character (must be a non-empty string).
function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.warn(LOG, "set_trigger_char: received an invalid value ('%s') — ignored.", tostring(char))
		return
	end
	Registry.update_trigger_char(char)
	Logger.debug(LOG, "Trigger char: '%s'.", char)
end

--- Ignores a specific window title from hotstring processing.
--- @param title string The exact window title to ignore.
function M.ignore_window_title(title)
	if type(title) == "string" then
		CoreState.ignored_window_titles[title] = true
	end
end

--- Ignores windows whose title matches a Lua pattern.
--- @param pattern string A Lua pattern matched against window titles.
function M.ignore_window_pattern(pattern)
	if type(pattern) == "string" then
		table.insert(CoreState.ignored_window_patterns, pattern)
	end
end

--- Registers a keystroke interceptor called before the expansion engine.
--- Return "consume" to swallow the event, "suppress" to skip triggers.
--- @param fn function The interceptor callback.
function M.register_interceptor(fn)
	if type(fn) == "function" then
		table.insert(CoreState.interceptors, fn)
	end
end

--- Registers a custom preview provider called by the LLM bridge on each keystroke.
--- Return a non-nil value to display a custom tooltip; return nil to fall through.
--- @param fn function The provider callback.
function M.register_preview_provider(fn)
	if type(fn) == "function" then
		table.insert(CoreState.preview_providers, fn)
	end
end


-- ── Registry proxies ─────────────────────────────────────────────────────────

M.add                   = Registry.add
M.load_file             = Registry.load_file
M.load_toml             = Registry.load_toml
-- Exposed so the hotstring editor can show the personal source default (the
-- single source kept in sync with _shared/modules/hotstrings/priority.json) instead of
-- hardcoding it in the UI.
M.source_priority       = Registry.source_priority
M.is_section_enabled    = Registry.is_section_enabled
M.disable_section       = Registry.disable_section
M.enable_section        = Registry.enable_section
-- Batch form. The menu toggles every section of a group at once, and routing that
-- through the single-section API rebuilt the group once per section.
M.set_sections_enabled  = Registry.set_sections_enabled
M.get_sections          = Registry.get_sections
M.get_meta_description  = Registry.get_meta_description
M.set_group_context     = Registry.set_group_context
M.set_post_load_hook    = Registry.set_post_load_hook
M.disable_group         = Registry.disable_group
M.is_group_enabled      = Registry.is_group_enabled
M.list_groups           = Registry.list_groups
M.register_lua_group    = Registry.register_lua_group
M.enable_group          = Registry.enable_group
M.sort_mappings         = Registry.sort_mappings
M.defer_sort            = Registry.defer_sort
M.flush_sort            = Registry.flush_sort

M.is_repeat_feature_enabled  = Registry.is_repeat_feature_enabled
M.set_repeat_feature_enabled = Registry.set_repeat_feature_enabled

M.set_terminator_enabled   = Registry.set_terminator_enabled
M.is_terminator_enabled    = Registry.is_terminator_enabled
M.get_terminator_defs      = Registry.get_terminator_defs
M.add_custom_terminator    = Registry.add_custom_terminator
M.remove_custom_terminator = Registry.remove_custom_terminator


-- ── LLM bridge proxies ───────────────────────────────────────────────────────

M.set_llm_model              = LLMBridge.set_llm_model
M.set_llm_display_model_name = LLMBridge.set_llm_display_model_name
M.set_llm_context_length     = LLMBridge.set_llm_context_length
M.set_llm_reset_on_nav       = LLMBridge.set_llm_reset_on_nav
M.set_llm_temperature        = LLMBridge.set_llm_temperature
M.set_llm_max_words          = LLMBridge.set_llm_max_words
M.set_llm_num_predictions    = LLMBridge.set_llm_num_predictions
M.set_llm_show_info_bar      = LLMBridge.set_llm_show_info_bar
M.set_llm_pred_indent        = LLMBridge.set_llm_pred_indent
M.set_llm_sequential_mode    = LLMBridge.set_llm_sequential_mode
M.set_llm_val_modifiers      = LLMBridge.set_llm_val_modifiers
M.set_llm_nav_modifiers      = LLMBridge.set_llm_nav_modifiers
M.get_llm_enabled            = LLMBridge.get_llm_enabled
M.set_llm_disabled_apps      = LLMBridge.set_llm_disabled_apps
M.set_llm_enabled            = LLMBridge.set_llm_enabled
M.set_llm_after_hotstring    = LLMBridge.set_llm_after_hotstring
M.set_llm_debounce           = LLMBridge.set_llm_debounce
M.set_llm_auto_raise_temp    = LLMBridge.set_llm_auto_raise_temp
M.set_llm_streaming              = LLMBridge.set_llm_streaming
M.set_llm_streaming_multi        = LLMBridge.set_llm_streaming_multi
M.set_llm_url_bar_filter_enabled      = LLMBridge.set_llm_url_bar_filter_enabled
M.set_llm_secure_field_filter_enabled = LLMBridge.set_llm_secure_field_filter_enabled
M.set_llm_instant_on_word_end         = LLMBridge.set_llm_instant_on_word_end

M.set_preview_enabled             = LLMBridge.set_preview_enabled
M.set_preview_star_enabled        = LLMBridge.set_preview_star_enabled
M.set_preview_autocorrect_enabled = LLMBridge.set_preview_autocorrect_enabled
M.set_preview_ai_enabled          = LLMBridge.set_preview_ai_enabled
M.set_preview_colored_tooltips    = LLMBridge.set_preview_colored_tooltips

M.trigger_prediction = LLMBridge._perform_llm_check
M.reset_predictions  = LLMBridge.reset_predictions

M.classify_trigger   = Registry.classify_trigger
M.has_exact_trigger  = Registry.has_exact_trigger
-- The group name personal hotstrings are registered under. infra/personal_hotstrings
-- loads the file with it at boot and ui/hotstring_editor reloads the SAME file with
-- it on save. Exported so the two cannot drift: reloading under a different name
-- left both copies alive, and the sort tie-break handed the win to whichever loaded
-- first — always the boot one — so an edited hotstring kept expanding to its old text.
M.PERSONAL_GROUP_NAME = "personal"

M.has_trigger_prefix = Registry.has_trigger_prefix
M.has_trigger_suffix = Registry.has_trigger_suffix

--- Suppresses rescan for a short window so dynamic-hotstring injectors
--- (personal_info, rules_engine) can issue their synthetic keystrokes without
--- triggering a parallel hotstring expansion on the same buffer content.
--- @param duration number|nil Suppression window in seconds (default 0.5 s).
function M.suppress_rescan(duration)
	CoreState.suppress_rescan(duration)
end

--- Centralized entry point for external modules (rules_engine, personal_info)
--- to emit synthetic keystrokes and accurately sync the core buffer.
---
--- `is_private` is NOT optional decoration: it is the only channel through which
--- a dynamic injector can tell the keylogger that what it just emitted is a
--- secret. perform_text_replacement forwards it to notify_synthetic, which keeps
--- the discard markers intact and redacts only what it persists. Omitting it —
--- which this function structurally forced, by stopping one argument short —
--- means an @-tag expansion of an SSN, IBAN, card or phone number is recorded
--- verbatim in a 14-day log, while the injectors above it carry comments
--- asserting that exact plaintext must never reach the log.
--- @param deletes integer Codepoints to erase before injecting.
--- @param result_text string Logical text the buffer must end up holding.
--- @param emit_action function Emitter returning (count, emitted[, logical]).
--- @param source_variant string|nil Telemetry variant tag.
--- @param is_private boolean|nil True when the payload is PII and must be redacted.
function M.inject_dynamic(deletes, result_text, emit_action, source_variant, is_private)
	return Expander.perform_text_replacement(
		deletes,
		emit_action,
		function()
			local ok, start_pos = pcall(utf8.offset, CoreState.buffer, -deletes)
			if not ok or not start_pos or deletes >= #CoreState.buffer then
				start_pos = 1
			end
			CoreState.buffer = (CoreState.buffer:sub(1, start_pos - 1) or "") .. result_text
		end,
		true, -- is_final (suppress rescan)
		false, -- is_ignored
		"hotstring",
		source_variant,
		is_private
	)
end

--- Starts a provenance-bearing replacement transaction for an external injector.
--- Must be called before the first synthetic event and sealed after the final
--- event has been queued. Every producer gets a fresh generation; elapsed time
--- is never used as transaction identity.
---
--- Arming only: does NOT emit any keystroke. The caller is responsible for
--- also calling suppress_rescan() and keylogger.notify_synthetic() to complete
--- the synthetic-injection contract (see docs/PROJECT_MEMORY.md §synthetic).
---
--- @param deletes number Retained for compatibility with legacy callers.
--- @param text string Retained for compatibility with legacy callers.
--- @param pastes number|nil Retained for compatibility with legacy callers.
--- @return table transaction SyntheticInput transaction handle.
function M.arm_synthetic(deletes, text, pastes)
	TerminatorReplay.flush_now("superseded by a new synthetic transaction")
	local transaction = SyntheticInput.begin("external_replacement", "replacement")
	return transaction
end

--- Runs `fn` inside the explicit external transaction returned by arm_synthetic.
--- @param transaction table SyntheticInput transaction handle.
--- @param fn function Injection callback.
--- @return ... Return values from fn.
function M.with_synthetic_transaction(transaction, fn, ...)
	return SyntheticInput.with_transaction(transaction, fn, ...)
end

--- Seals an external transaction after its final event has been queued.
--- @param transaction table SyntheticInput transaction handle.
function M.finish_synthetic(transaction)
	SyntheticInput.seal(transaction)
end


--- Cancels an external transaction whose producer failed before handoff.
--- Every event already built under the transaction is discarded atomically.
--- @param transaction table SyntheticInput transaction handle.
--- @return boolean changed False when the transaction was already terminal.
function M.cancel_synthetic(transaction)
	return SyntheticInput.cancel(transaction)
end


-- ── Perf telemetry proxies ───────────────────────────────────────────────────
-- Exposed on M so the Hammerspoon console can toggle sampling and read the
-- per-bucket p50/p99/max stats without having to `require("infra.perf")` by
-- hand. Sampling defaults to disabled so production typing pays no cost;
-- `M.perf_enable(true)` arms it, `M.perf_report_all()` emits the summary.

--- Enables or disables latency sampling in the hot path.
--- @param v boolean
function M.perf_enable(v)
	Perf.set_enabled(v == true)
	Logger.info(LOG, "Perf sampling %s.", (v == true) and "enabled" or "disabled")
end

--- Returns true when samples are being recorded.
--- @return boolean
function M.perf_is_enabled()
	return Perf.is_enabled()
end

--- Returns aggregate stats for a single bucket (e.g. "keymap_keydown"),
--- or nil when no samples have been recorded yet.
--- @param name string Bucket identifier.
--- @return table|nil
function M.perf_report(name)
	return Perf.report(name)
end

--- Emits one INFO log line per populated bucket via the keymap logger.
function M.perf_report_all()
	Perf.report_all(function(_, fmt, ...)
		Logger.info(LOG, fmt, ...)
	end)
end

--- Clears the samples for `name`, or every bucket when `name` is nil.
--- @param name string|nil
function M.perf_reset(name)
	Perf.reset(name)
	Logger.debug(LOG, "Perf bucket reset: %s.", tostring(name or "<all>"))
end


-- Per-call state for run_trigger_checks, stored at module level to avoid
-- allocating a closure on every keystroke. Updated by onKeyDownRaw just
-- before calling run_trigger_checks().
local _tc_chars        = ""
local _tc_char_len     = 1
local _tc_dt           = 0
local _tc_complex_mult = 1
local _tc_is_ignored   = false

-- Hot-path sub-segment timings (milliseconds) for the slow-keystroke log line.
-- Populated only when Perf sampling is enabled (DEBUG builds) so steady-state
-- typing pays nothing; nil means "not measured this keystroke". They let a slow
-- keydown be attributed to trigger matching vs. LLM/tooltip preview rebuild.
local _tc_dbg_checks_ms  = nil
local _tc_dbg_preview_ms = nil

--- Per-mapping delay + group-enable gate, module-level to avoid closure allocation.
--- @param m table The mapping entry.
--- @return boolean True when the current timing/group state allows m to fire.
local function mapping_fires(m)
	if m.group and CoreState.groups[m.group] and not CoreState.groups[m.group].enabled then
		return false
	end
	-- Delay precedence (highest first), mirroring the AHK HotstringsResolve chain:
	--   user-overridden group delay > TOML per-section delay > group delay > base.
	-- A group delay that differs from its hardcoded default is treated as a user
	-- override (priority 0) and wins over a per-section TOML value.
	-- Resolved by CoreState so the PREVIEW gets the identical answer: it sizes
	-- the row's lifetime from this, and a second implementation is exactly how
	-- the tooltip came to promise expansions the engine would refuse.
	local specific_delay = CoreState.resolve_mapping_delay(m)
	-- Autocorrections are never stretched for complex keystrokes (they
	-- fire on letter combos, not on modifier+letter sequences)
	local allow_complex_delay = (m.group ~= "autocorrection")
	local allowed_delay       = allow_complex_delay and (specific_delay * _tc_complex_mult) or specific_delay
	return allowed_delay == 0 or _tc_dt <= allowed_delay
end

--- Runs trigger matching against the current buffer. Module-level function
--- instead of a per-keystroke closure — saves one closure allocation + one
--- inner closure allocation (mapping_fires) on every single keyDown event.
local function run_trigger_checks()
	local chars        = _tc_chars
	local char_len     = _tc_char_len
	local is_ignored   = _tc_is_ignored
	local complex_mult = _tc_complex_mult

	-- Pre-evaluate once: avoids a 20-entry linear scan inside try_terminator_expand
	-- for every non-auto mapping — on a normal letter keystroke that saves ~300 calls
	local chars_is_terminator = Registry.is_terminator(chars)

	-- Auto candidates: triggers whose last codepoint equals the just-typed
	-- char. Bucketed by Registry so we scan a handful of entries instead of
	-- the full ~10-15k global list.
	-- When Karabiner sends a multi-codepoint sequence (e.g. NNBSP + "?"),
	-- only the last codepoint keys the bucket — extract it so we find triggers
	-- whose tail is "?" even when chars = " ?".
	local tail_chars = char_len <= 1 and chars or (function()
		local ok, off = pcall(utf8.offset, chars, -1)
		return (ok and off) and chars:sub(off) or chars
	end)()
	-- Pressing ★ is an explicit validation of whatever the tooltip is displaying,
	-- so a star trigger must never lose to the typing-speed delay: the fallback for
	-- a missed delay is try_repeat_feature below, which doubles the last letter —
	-- the user asked for an expansion and would silently get "aa". The terminator
	-- branch already bypasses the delay for exactly this reason; without the same
	-- bypass here the tooltip (which applies no delay gate when it collects star
	-- matches) and the engine disagree, and the disagreement is what reaches the
	-- screen.
	local star_validated = chars == CoreState.magic_key

	local auto_bucket = Registry.mappings_for_tail(tail_chars)

	--- Runs the end-char path over triggers strictly longer than `min_len`.
	---
	--- Split out because it is invoked TWICE: once before the auto path to let a
	--- longer end-char trigger win, once after in case the auto path declined.
	--- @param min_len number Only mappings with tlen > min_len are considered.
	--- @return boolean True when an expansion fired.
	local function run_end_char_checks(min_len)
		if not chars_is_terminator then return false end
		local buf        = CoreState.buffer
		local chars_b    = #chars
		local before_end = #buf - chars_b
		if before_end <= 0 then return false end
		local prev_sub      = buf:sub(1, before_end)
		local ok_poff, poff = pcall(utf8.offset, prev_sub, -1)
		-- Malformed UTF-8 in the buffer tail is non-fatal: skip terminator expansion
		-- for this keystroke rather than propagating a pcall error up the hot path
		if not (ok_poff and poff) then return false end
		local prev_char   = prev_sub:sub(poff)
		local term_bucket = Registry.mappings_for_tail(prev_char)
		if not term_bucket then return false end
		-- When ★ is pressed, it is an explicit validation of the displayed
		-- tooltip — bypass the typing-speed delay so a slow typist never
		-- gets a repeat-key instead of the intended expansion.
		local skip_delay = star_validated
		for _, m in ipairs(term_bucket) do
			if not m.auto and m.tlen > min_len and (skip_delay or mapping_fires(m))
				and Expander.try_terminator_expand(m, chars, char_len, is_ignored)
			then
				return true
			end
		end
		return false
	end

	-- Longest match wins ACROSS the two paths, which is the rule Windows applies
	-- (_HSE_EndCharBeats: a star match yields only to a STRICTLY longer end-char
	-- trigger, so an equal-length tie still goes to the star). Returning on the
	-- first auto hit made auto win unconditionally here: with a star trigger "b★"
	-- and a non-star "aab", typing "aab★" fired "aab" on Windows and Linux and
	-- "b★" on macOS.
	--
	-- The length of the winning auto candidate is needed BEFORE the end-char loop
	-- runs, and would_fire is the pure predicate that answers it without emitting
	-- anything — it is the same function try_auto_expand consults, so the two
	-- cannot disagree about which mapping wins. The pre-scan is skipped entirely
	-- unless the typed character is a terminator: with no end-char competition
	-- there is nothing to arbitrate, and paying for it on every letter would be
	-- pure hot-path cost.
	local auto_len = 0
	if chars_is_terminator and auto_bucket then
		for _, m in ipairs(auto_bucket) do
			if m.auto and ((star_validated and m.has_magic) or mapping_fires(m))
				and Expander.would_fire(m, CoreState.buffer)
			then
				-- The bucket is sorted longest-first, so the first that would fire is
				-- the longest.
				auto_len = m.tlen
				break
			end
		end
	end

	if run_end_char_checks(auto_len) then return true end

	if auto_bucket then
		for _, m in ipairs(auto_bucket) do
			if m.auto and ((star_validated and m.has_magic) or mapping_fires(m))
				and Expander.try_auto_expand(m, char_len, is_ignored)
			then
				return true
			end
		end
	end

	-- The auto path declined after all (a no-op replacement, say), so the end-char
	-- candidates it out-ranked are back in play.
	if auto_len > 0 and run_end_char_checks(0) then return true end

	local star_allowed = CoreState.DELAYS.STAR_TRIGGER * complex_mult
	if (star_allowed == 0 or _tc_dt <= star_allowed)
		and Expander.try_repeat_feature(chars, is_ignored) then
		return true
	end

	return false
end





-- =========================================
-- =========================================
-- ======= 4/ Keyboard Event Handler =======
-- =========================================
-- =========================================

--- Inner keyboard handler — never called directly; always wrapped in a pcall.
--- @param e table The macOS keystroke event payload.
--- @return boolean True to consume the event, false to pass it through.
-- Keycodes that must exit the callback immediately with no side-effects.
-- Merges synthetic OS-signals (F18/F19/F20) and Karabiner/layer sentinels
-- (F13–F17, LAYER_SYN_1–3) into a single O(1) set tested once at the very
-- top of onKeyDownRaw, eliminating the old 12-branch `or` chain.
local FAST_EXIT_KEYCODES = {
	[80]  = true,  -- F19 volume-scroll modifier
	[90]  = true,  -- F20 Karabiner nav-layer sentinel
	[105] = true,  -- F13 Karabiner Return sentinel
	[107] = true,  -- F14 Karabiner Backspace sentinel
	[113] = true,  -- F15 Karabiner Escape sentinel
	-- F16 (keycode 106) intentionally absent: it is the LLM chain signal injected
	-- by apply_prediction and must reach handle_llm_keys further down in this
	-- handler. Fast-exiting it forced the 500 ms fallback timer path every time.
	[64]  = true,  -- F17 cycle-windows hotkey
	[131] = true,  -- LAYER_SYN_1
	[134] = true,  -- LAYER_SYN_2
	[135] = true,  -- LAYER_SYN_3
}

-- One-shot per interceptor index, so a throwing interceptor is reported once
-- instead of on every keystroke.
--
-- DECLARED HERE, ABOVE onKeyDownRaw, and it must stay above it. In Lua a local's
-- scope begins AFTER its declaration, so a closure written earlier in the file
-- binds the never-assigned GLOBAL of the same name instead. Indexing that nil
-- raises on the very first throwing interceptor -- inside the handler whose
-- whole purpose is to REPORT one -- and the outer pcall then logs a misdirecting
-- "Keyboard interception failure" while every keystroke loses Escape handling,
-- backspace handling, buffer tracking and expansions.
local _interceptor_error_logged = {}

local function onKeyDownRaw(e, provenance, provenance_status)
	-- Tap order is not stable: an action can advance the shared epoch before this
	-- keymap tap sees its tagged echo. The wrapper also claims older deferred
	-- output before entering this function, so re-read the epoch before every
	-- other gate and never route a physical key through stale predictions.
	local action_epoch = SyntheticInput.current_action_epoch()
	if action_epoch ~= _last_context_epoch then
		observe_action_epoch(action_epoch)
	end

	-- A stale internal loopback has lost the live transaction identity required to
	-- re-enter the LLM, but it is still an Ergopti-only control key. Consume it in
	-- every state (including pause) instead of leaking F16 to the frontmost app.
	local internal_loopback = provenance
		and (provenance.loopback == true or provenance.stale_loopback == true)
	if provenance and provenance.stale_loopback then return true end

	-- A failed native user-data read is neither proof of physical input nor proof
	-- of ownership. Pass the event through, but discard every cursor/text belief so
	-- an unreadable synthetic echo cannot be appended as human typing.
	if provenance_status == EventProvenance.STATUS_UNREADABLE then
		invalidate_observed_context()
		return false
	end
	-- Ordinary owned output is already represented logically by its transaction.
	-- Only the explicit live loopback control is allowed to reach key decoding;
	-- every replacement/action echo exits before the native getKeyCode call.
	if provenance and not internal_loopback then return false end

	if CoreState.processing_paused then return internal_loopback == true end

	-- Single getKeyCode() call — reused for every subsequent keyCode check
	local keyCode = e:getKeyCode()

	-- Explicit user-data tags are the only synthetic identity. The wrapper reads
	-- provenance once before its physical-ordering fence and passes the result in,
	-- avoiding a second ObjC property read on the hottest callback in the driver.
	if internal_loopback then
		-- Quartz may duplicate an injected event during tap recovery. A control
		-- signal is edge-triggered, so only its first delivery may reach the LLM.
		if provenance.duplicate then return true end
	end
	-- A loopback tag is an explicit control signal (currently F16 for chained
	-- LLM completion). It is still synthetic for every other consumer, but this
	-- keymap callback must deliberately route it through handle_llm_keys below.

	-- O(1) fast-exit for synthetic signals and Karabiner/layer sentinels.
	-- This replaces both the old SYNTHETIC_SIGNAL_KEYCODES check and the
	-- 9-branch `or` chain further down, saving ~10 comparisons per keystroke.
	if FAST_EXIT_KEYCODES[keyCode] then return false end

	-- Fast-exit when a Hammerspoon webview has focus. The is_ignored_window cache
	-- makes this nearly free on repeated keystrokes; it already treats the HS app
	-- as always-ignored, so we move the check before the expensive LLM/interceptor
	-- path so typing in any HS dialog or webview incurs no processing overhead.
	-- One clock read per keystroke, shared by the ignored-window cache below and
	-- the inter-key delta. Two separate reads bought nothing: they are microseconds
	-- apart, so the second value was identical for every purpose either consumer
	-- has, and this is the hottest path in the driver.
	local now = hs.timer.secondsSinceEpoch()

	if km_utils.is_ignored_window(CoreState.ignored_window_titles, CoreState.ignored_window_patterns, now) then
		return internal_loopback == true
	end

	local dt  = now - CoreState.last_key_time
	CoreState.last_key_time = now

	-- Wipe the buffer after the user pauses long enough that the next keystroke
	-- cannot possibly belong to the same word. The pause itself stands in for
	-- a word terminator, so the post-wipe context starts on a fresh word
	-- boundary and word-boundary-required triggers are allowed to fire.
	if CoreState.WORD_TIMEOUT_SEC > 0 and dt > CoreState.WORD_TIMEOUT_SEC then
		CoreState.buffer = ""
		CoreState.start_is_word_boundary = true
		LLMBridge.reset_predictions()
	end

	local flags = e:getFlags()

	-- Cache hit guaranteed: is_ignored_window was already called above and returned
	-- false (otherwise we would have early-exited). Re-call returns the same cached
	-- value — needed here as `is_ignored` is passed on to LLM and later callers.
	local is_ignored = km_utils.is_ignored_window(CoreState.ignored_window_titles, CoreState.ignored_window_patterns, now)

	-- 2. Route LLM prediction keys (Enter / digits / arrows) before buffer logic.
	-- Tagged synthetic keys already returned above, so every event here is a real
	-- input/control event and must retain the normal LLM semantics.
	if internal_loopback then
		-- F16 is an internal edge, never application input. A declined chain (for
		-- example after a reset) is still consumed; only the first live delivery may
		-- ask the engine to advance.
		LLMBridge.handle_llm_keys(keyCode, flags, is_ignored)
		return true
	end
	-- F16 is an internal control channel only when its exact Quartz tag says so.
	-- A physical/programmable F16 must never satisfy chain_pending ahead of the
	-- delayed loopback that owns that edge.
	if keyCode == Keycodes.F16_LLM_CHAIN_SIGNAL then return false end
	if LLMBridge.handle_llm_keys(keyCode, flags, is_ignored) then return true end

	-- 3. Run custom interceptors registered by external modules.
	-- The character is read HERE rather than at step 8, because the interceptors
	-- below need it too and each was fetching it through its own ObjC accessor.
	-- One read now serves all three consumers; the only keystrokes that pay for
	-- it without using it are those an interceptor suppresses, which are rare
	-- next to the ones that fall through to step 8 and read it anyway.
	local chars = e:getCharacters(false)
	local _interceptor_ctx = { keyCode = keyCode, flags = flags, chars = chars }
	local suppress_triggers = false
	for idx, interceptor in ipairs(CoreState.interceptors) do
		-- The already-fetched event fields are handed over as a third argument.
		-- Every interceptor needs the same flags and characters this callback has
		-- just read, and each was re-fetching them through its own ObjC accessors
		-- — on every keystroke, once per interceptor. Passed additively so an
		-- interceptor that only declares (event, buffer) is unaffected.
		local ok, result = pcall(interceptor, e, CoreState.buffer, _interceptor_ctx)
		if not ok then
			-- The failure branch logged NOTHING, so a throwing interceptor silently
			-- disabled whatever it implements — @-tag and date expansion both run from
			-- here — with no trace anywhere. Reported once per interceptor rather than
			-- per keystroke: this is the hot path and the fault is persistent.
			if not _interceptor_error_logged[idx] then
				_interceptor_error_logged[idx] = true
				Logger.error(LOG, "Interceptor #%d raised — skipping it for this session: %s.",
					idx, tostring(result))
			end
		else
			if result == "consume"   then return true end
			if result == "suppress"  then suppress_triggers = true; break end
		end
	end

	-- 4. Handle Escape — dismiss predictions or optionally clear the buffer.
	-- The cursor stays where it is; the next keystroke starts a fresh run.
	if keyCode == Keycodes.ESCAPE then
		CoreState.start_is_word_boundary = true
		cancel_action_preview_recovery()
		return LLMBridge.check_escape_reset()
	end

	-- 5. Modifier shortcuts (Cmd/Ctrl) break the current word context.
	-- Cmd+A / Ctrl+A is the one exception — select-all replaces the entire
	-- selection with the next typed char, so the new context starts at a
	-- fresh word-start. Every other Cmd/Ctrl combo (cut, paste, undo,
	-- redo, app shortcuts, …) leaves the cursor in unobservable territory.
	if flags.cmd or flags.ctrl then
		CoreState.buffer = ""
		CoreState.start_is_word_boundary = (keyCode == hs.keycodes.map["a"])
		cancel_action_preview_recovery()
		LLMBridge.check_nav_reset()
		return false
	end

	-- 6. Handle Backspace.
	if keyCode == Keycodes.BACKSPACE then
		-- Cmd+Backspace / Alt+Backspace delete whole words — wipe the buffer
		-- and refuse to assume a word boundary on the new cursor's left.
		if flags.cmd or flags.alt then
			CoreState.buffer = ""
			CoreState.start_is_word_boundary = false
			cancel_action_preview_recovery()
			LLMBridge.check_nav_reset()
			return false
		end
		if #CoreState.buffer > 0 then
			-- Remove the last UTF-8 character from the buffer safely.
			local ok, offset = pcall(utf8.offset, CoreState.buffer, -1)
			CoreState.buffer = (ok and offset) and CoreState.buffer:sub(1, offset - 1) or ""
			if not is_ignored then update_preview_with_action_recovery(CoreState.buffer) end
		else
			-- Backspace pressed against an already-empty buffer: the user
			-- has just deleted a character that lived to the LEFT of where
			-- the buffer ever started, into territory we never observed.
			-- Flip the boundary flag so subsequent word-boundary-required
			-- triggers refuse to fire until a real terminator is observed.
			CoreState.start_is_word_boundary = false
			cancel_action_preview_recovery()
		end
		return false
	end

	-- 7. Arrow / navigation keys move the cursor; the next typed run starts
	-- fresh, so treat the new position as a word boundary.
	if keyCode == 117 or keyCode == 115 or keyCode == 116 or keyCode == 119 or keyCode == 121
		or (keyCode >= 123 and keyCode <= 126) then
		CoreState.start_is_word_boundary = true
		cancel_action_preview_recovery()
		LLMBridge.check_nav_reset()
		return false
	end

	-- 8. The character was gathered above, before the interceptors, so it is read
	-- from the event exactly once per keystroke.
	if not chars or chars == "" then return false end

	-- Append to the rolling buffer and cap it at BUFFER_MAX_CHARS CODEPOINTS.
	-- The cap used to be a byte-count cap (500 bytes) but that silently kept
	-- far fewer actual characters when the buffer held multi-byte codepoints
	-- (e.g. accented latin = 2 bytes/char, emoji = 4 bytes/char), and the
	-- utf8.offset call against a count that didn't exist returned nil, leaving
	-- the buffer untrimmed. The fast-path byte gate avoids paying for the
	-- utf8 scan on every keystroke.
	CoreState.buffer = CoreState.buffer .. chars
	if #CoreState.buffer > BUFFER_TRIM_BYTE_GATE then
		local ok, off = pcall(utf8.offset, CoreState.buffer, -BUFFER_MAX_CHARS)
		-- Fall back to empty on a failed offset (malformed UTF-8) rather than
		-- keeping the full overgrown buffer — losing ≤500 chars of history is
		-- acceptable, unbounded growth is not.
		CoreState.buffer = (ok and off) and CoreState.buffer:sub(off) or ""
		-- The trimmed buffer's start no longer corresponds to a known word
		-- boundary on screen — flip the flag so word-boundary-required
		-- triggers do not fire flush against the new (mid-screen) start.
		CoreState.start_is_word_boundary = false
	end

	-- 9. Run expansion trigger checks. The LLM preview used to be refreshed
	-- unconditionally before this block, but when a trigger fires the
	-- expander already re-evaluates the preview on the post-expansion
	-- buffer (via perform_text_replacement), so the pre-expansion preview
	-- was pure waste. We now defer the preview call to the branch below
	-- that actually keeps the buffer unchanged.
	local rescan_suppressed = now < CoreState.no_rescan_until
	if suppress_triggers or rescan_suppressed then
		-- Buffer didn't expand, so refresh the tooltip/predictions once here.
		if not is_ignored then update_preview_with_action_recovery(CoreState.buffer) end
		return false
	end

	-- Complex keystrokes (involving Shift or Alt) allow a wider timing window
	-- to accommodate the extra finger movement required by the modifier. The
	-- bonus also carries over to the NEXT keystroke to cover Shift-release lag
	-- — but only within a short window (COMPLEX_CARRY_SEC). A long pause
	-- between a complex key and the following one means the two are unrelated,
	-- and we must not stretch an expansion delay across that gap.
	local is_complex       = flags.shift or flags.alt
	local carry_from_prev  = CoreState.last_key_was_complex and dt <= COMPLEX_CARRY_SEC
	local complex_mult     = (is_complex or carry_from_prev) and COMPLEX_DELAY_MULT or 1
	CoreState.last_key_was_complex = is_complex

	-- Populate module-level upvalues consumed by run_trigger_checks / mapping_fires.
	-- Single-codepoint fast path: for ASCII and 2-byte latin, byte length IS
	-- char length; the expensive pcall(utf8.len) is only needed for 3-4 byte chars.
	local chars_bytes = #chars
	_tc_chars        = chars
	_tc_char_len     = (chars_bytes <= 2) and 1 or (text_utils.utf8_len(chars))
	_tc_dt           = dt
	_tc_complex_mult = complex_mult
	_tc_is_ignored   = is_ignored

	-- In ignored windows we still want repeatable features to work,
	-- but must run them asynchronously to avoid blocking the event queue.
	-- DEBUG-only sub-segment timing (Perf gate): attribute a slow keystroke to
	-- trigger matching vs. preview rebuild in the HotPath warning line.
	local hot_dbg = Perf.is_enabled()
	if is_ignored then
		-- Capture all five upvalues AND the buffer snapshot into the closure
		-- at scheduling time. A second fast keystroke can overwrite the
		-- upvalues AND grow CoreState.buffer before the deferred call runs,
		-- causing the expansion to splice the wrong buffer state.
		-- The snapshot is temporarily swapped in; if no expansion fires the
		-- live buffer (which may have grown) is restored.
		local buf_snapshot = CoreState.buffer
		hs.timer.doAfter(0, (function(chars, len, dt, mult, ign, buf)
			return function()
				_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored
					= chars, len, dt, mult, ign
				local saved_buf = CoreState.buffer
				CoreState.buffer = buf
			local fired = run_trigger_checks()
			-- When no expansion fired, restore the live buffer so chars
			-- typed after the snapshot are not lost. When an expansion
			-- DID fire, perform_text_replacement's buffer_action already
			-- updated CoreState.buffer — append any chars typed after
			-- the snapshot so they are not lost from the buffer (the
			-- expansion only backspaces over the trigger on screen, so
			-- later keystrokes remain visible and must stay tracked).
			if not fired then
				CoreState.buffer = saved_buf
			else
				local extra = saved_buf:sub(#buf + 1)
				if extra ~= "" then
					CoreState.buffer = CoreState.buffer .. extra
				end
			end
			end
		end)(_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored, buf_snapshot))
	else
		local ck0 = hot_dbg and HotPath.now() or nil
		local fired = run_trigger_checks()
		if ck0 then _tc_dbg_checks_ms = HotPath.elapsed_ms(ck0) end
		if fired then return true end
	end

	-- No trigger fired — the buffer is still the one we appended `chars` to,
	-- so refresh the preview now (expander.update_preview is only reached
	-- when an expansion happens, which we just ruled out).
	if not is_ignored then
		local pv0 = hot_dbg and HotPath.now() or nil
		update_preview_with_action_recovery(CoreState.buffer)
		if pv0 then _tc_dbg_preview_ms = HotPath.elapsed_ms(pv0) end
	end

	-- Enter / Tab with no predictions visible clears prediction state.
	-- When predictions ARE visible, Tab is consumed upstream by handle_llm_keys
	-- (fast-accepts pred #1) and never reaches this point.
	if keyCode == Keycodes.RETURN or keyCode == 48 then
		cancel_action_preview_recovery()
		LLMBridge.check_nav_reset()
	end

	return false
end

--- Concatenates two callback-return event arrays while preserving FIFO order.
--- The common one-sided cases are O(1) and allocate nothing.
--- @param older table|nil Events that must precede newer.
--- @param newer table|nil Later callback output.
--- @return table|nil events
local function merge_returned_events(older, newer)
	if older == nil then return newer end
	if newer == nil then return older end
	local merged = {}
	for _, event in ipairs(older) do merged[#merged + 1] = event end
	for _, event in ipairs(newer) do merged[#merged + 1] = event end
	return merged
end

--- pcall wrapper around onKeyDownRaw to prevent keyboard lockups on uncaught errors.
--- Latency sampling is gated on Perf.is_enabled() so the measurement path adds
--- no steady-state cost in production; when disabled the wrapper is a single
--- `and` short-circuit before the pcall.
--- @param e table Event parameters.
--- @return boolean Pass-through result from the inner handler.
local function onKeyDown(e)
	-- Always-on latency tripwire (ported from the AHK hot-path profiler): two
	-- monotonic clock reads per keystroke, logging a WARNING only when a keystroke
	-- exceeds the slow threshold. Normal typing stays silent; a real hitch surfaces
	-- with the offending char + buffer tail so "typing feels slow" is diagnosable
	-- from the log alone. Opt-in Perf.sample below adds the p50/p99 distribution.
	local t0_hot = HotPath.now()
	local t0 = Perf.is_enabled() and Perf.now() or nil
	-- Clear last keystroke's sub-segment timings so a slow line never reports
	-- stale figures from an earlier keystroke that took a different branch.
	_tc_chars = ""
	_tc_dbg_checks_ms, _tc_dbg_preview_ms = nil, nil

	-- Classify once before any physical-input state mutation. Action-epoch
	-- reconciliation deliberately runs from this immutable provenance result.
	-- The first Ergopti tap reached by a
	-- physical event claims every older deferred action, publishes its epoch and
	-- returns its payload before the original. This makes keymap/keylogger ordering
	-- independent of Quartz tap insertion order.
	local provenance = nil
	local provenance_status = EventProvenance.STATUS_UNREADABLE
	local classify_ok, provenance_or_err, status_or_nil, fence_or_nil = pcall(
		EventProvenance.classify_with_fence, e, "keymap")
	local fence_events = nil
	if classify_ok then
		provenance = provenance_or_err
		provenance_status = status_or_nil or EventProvenance.STATUS_UNREADABLE
		if fence_or_nil then fence_events = fence_or_nil.events end
	else
		pcall(Logger.error, LOG, "Synthetic event provenance classification failed: %s.",
			tostring(provenance_or_err))
		-- Preserve output ordering even if adapter bookkeeping itself failed. The
		-- event remains unreadable and therefore cannot mutate keymap state.
		local fence_ok, fence_or_err = pcall(SyntheticInput.claim_physical_fence)
		if fence_ok and fence_or_err then
			fence_events = fence_or_err.events
		elseif not fence_ok then
			pcall(Logger.error, LOG, "Synthetic physical-input fence failed: %s.",
				tostring(fence_or_err))
		end
	end

	-- Synthetic injectors reached below build tagged Quartz events instead of
	-- posting them recursively from inside this eventtap. The collector hands the
	-- complete ordered batch back as the callback's second result, which keeps the
	-- HID callback non-blocking and gives every echo immutable provenance.
	local entered, enter_err = pcall(SyntheticInput.enter_callback)
	if not entered then
		Logger.error(LOG, "Synthetic callback collector failed to start: %s.", tostring(enter_err))
		HotPath.log_if_slow("keydown", t0_hot, _tc_chars)
		return (provenance and (provenance.loopback or provenance.stale_loopback)) == true,
			fence_events
	end

	local ok, result = pcall(onKeyDownRaw, e, provenance, provenance_status)
	local returned_events = nil
	if ok then
		local left, consume_or_err, events = pcall(SyntheticInput.leave_callback, result)
		if left then
			result = consume_or_err
			returned_events = merge_returned_events(fence_events, events)
		else
			ok = false
			result = consume_or_err
			-- leave_callback is designed to unwind atomically. Keep this backstop
			-- idempotent so a future implementation cannot strand ambient state.
			pcall(SyntheticInput.abort_callback)
		end
	else
		-- Discard every event created before the exception. Returning a partial
		-- replacement would be worse than passing through the user's original key.
		pcall(SyntheticInput.abort_callback)
	end
	if t0 then Perf.sample("keymap_keydown", t0) end
	-- Enrich the slow-keystroke detail with the per-stage breakdown when measured.
	local hot_detail = _tc_chars
	if _tc_dbg_checks_ms or _tc_dbg_preview_ms then
		hot_detail = string.format("%s | match=%.2fms preview=%.2fms",
			tostring(_tc_chars), _tc_dbg_checks_ms or 0, _tc_dbg_preview_ms or 0)
	end
	HotPath.log_if_slow("keydown", t0_hot, hot_detail)
	if not ok then
		Logger.error(LOG, "Keyboard interception failure: %s.", tostring(result))
		-- An uncaught error inside the callback can cause macOS to disable the
		-- tap on the next run-loop cycle; proactively re-arm it here
		if tap and type(tap.isEnabled) == "function" and not tap:isEnabled() then
			Logger.warn(LOG, "Event tap disabled after error — re-enabling.")
			pcall(function() tap:start() end)
			-- Re-arming here means the watchdog never sees the tap down and never
			-- runs its own invalidation, so this path has to do it: keystrokes were
			-- missed between the fault and the restart, and every belief about the
			-- text around the cursor is now a guess.
			invalidate_observed_context()
		end
		return (provenance and (provenance.loopback or provenance.stale_loopback)) == true,
			fence_events
	end
	return result, returned_events
end





-- ===================================
-- ===================================
-- ======= 5/ Module Lifecycle =======
-- ===================================
-- ===================================

tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

-- Loopback controls are emitted as Quartz down/up pairs. The main keymap tap
-- consumes the down phase; this minimal sibling consumes the exact tagged up
-- phase so an application/hotkey cannot observe an orphan F16 release.
loopback_keyup_tap = eventtap.new({ eventtap.event.types.keyUp }, function(e)
	local provenance, _, fence = EventProvenance.classify_with_fence(
		e, "keymap.loopback_keyup")
	local fence_events = fence and fence.events or nil
	if provenance and (provenance.loopback or provenance.stale_loopback) then
		return true, fence_events
	end
	return false, fence_events
end)

-- Per-side shift state. flagsChanged only tells us "shift is down or up" at
-- the aggregate level; with both shifts pressed, the old single-slot tracker
-- was rewritten to whichever side fired the event — including on release,
-- which left shift_side pointing to the wrong side. We now track each shift
-- key independently via its own keycode and derive shift_side from the pair.
local SHIFT_KC_LEFT  = 56
local SHIFT_KC_RIGHT = 60
local _shift_left_down   = false
local _shift_right_down  = false
-- When both shifts are held simultaneously, shift_side reflects the most
-- recently pressed one — that matches the user's "active" intent.
local _shift_last_side   = nil

local function update_shift_side()
	if _shift_left_down and _shift_right_down then
		CoreState.shift_side = _shift_last_side or "left"
	elseif _shift_left_down then
		CoreState.shift_side = "left"
	elseif _shift_right_down then
		CoreState.shift_side = "right"
	else
		CoreState.shift_side = nil
	end
end

shift_tap = eventtap.new(
	{ eventtap.event.types.flagsChanged },
	function(e)
		local provenance, provenance_status, fence = EventProvenance.classify_with_fence(
			e, "keymap.shift")
		local fence_events = fence and fence.events or nil
		if provenance then return false end
		if provenance_status == EventProvenance.STATUS_UNREADABLE then
			_shift_left_down = false
			_shift_right_down = false
			_shift_last_side = nil
			update_shift_side()
			return false, fence_events
		end
		local ok, result = pcall(function()
			local kc = e:getKeyCode()
			local f  = e:getFlags()

			-- The keycode on a flagsChanged event identifies which modifier
			-- just toggled. We flip the matching side's flag, then resync
			-- against the aggregate f.shift at the end as a safety net in
			-- case the watcher missed a release.
			if kc == SHIFT_KC_LEFT then
				_shift_left_down = not _shift_left_down
				if _shift_left_down then _shift_last_side = "left" end
			elseif kc == SHIFT_KC_RIGHT then
				_shift_right_down = not _shift_right_down
				if _shift_right_down then _shift_last_side = "right" end
			end

			-- Hard reconcile: if the OS says shift is not down, neither side
			-- can be down — clears any drift from missed events.
			if not f.shift then
				_shift_left_down  = false
				_shift_right_down = false
				_shift_last_side  = nil
			end

			update_shift_side()
			return false
		end)
		if not ok then
			_shift_left_down = false
			_shift_right_down = false
			_shift_last_side = nil
			update_shift_side()
			SyntheticInput.defer_after_callback("shift-side diagnostic", function()
				Logger.error(LOG, "Shift-side detection failure: %s.", tostring(result))
			end)
			return false, fence_events
		end
		return result, fence_events
	end
)

-- scrollWheel is intentionally excluded: scroll events are high-frequency
-- (60 Hz+) and firing check_nav_reset()/reset_predictions() on every frame
-- causes severe lag when the LLM menu is active (ObjC dispatch per frame).
-- Scroll does not move the text cursor, so no buffer reset is needed here.
mouse_tap = eventtap.new(
	{
		eventtap.event.types.leftMouseDown,
		eventtap.event.types.rightMouseDown,
		eventtap.event.types.middleMouseDown,
	},
	function(e)
		-- A click can move focus to another app before the deferred broker runs.
		-- Claim older output here and return it ahead of the original mouseDown, even
		-- when the optional keylogger tap is disabled. Otherwise an Ergopti shortcut
		-- queued for app A can land in app B after the click changes focus.
		local provenance, provenance_status, fence = EventProvenance.classify_with_fence(
			e, "keymap.mouse")
		local fence_events = fence and fence.events or nil
		if provenance then return false end
		if provenance_status == EventProvenance.STATUS_UNREADABLE then
			invalidate_observed_context()
			return false, fence_events
		end
		-- Close the runtime in O(1) before returning the focus-changing click.
		-- Canvas, AX, task cancellation and logging run only after Quartz receives
		-- the older fence payload and the original mouse event.
		CoreState.start_is_word_boundary = true
		cancel_action_preview_recovery()
		LLMBridge.set_runtime_quarantined(true)
		local scheduled = SyntheticInput.defer_after_callback("keymap mouse reset",
			function()
				local reset_ok, reset_err = xpcall(function()
					LLMBridge.check_nav_reset()
					LLMBridge.reconcile_observation_gap()
				end, debug.traceback)
				if reset_ok then return end
				-- Reuse the retained outage retry if a downstream reset fails. This
				-- stays off CGEventTap and leaves the runtime closed meanwhile.
				invalidate_observed_context()
				error(reset_err, 0)
			end)
		if not scheduled then
			-- A failed timer allocation must not reopen stale prediction state.
			invalidate_observed_context()
		end
		return false, fence_events
	end
)

-- Bundled Hammerspoon normally re-enables a tap in native code when
-- CoreGraphics reports a callback timeout, before returning to Lua. Keep an
-- independent watchdog for any tap that remains disabled after another native
-- or lifecycle failure; otherwise keystrokes pass through without expansions.
--
-- The interval bounds the outage when native recovery does not restore the tap.
-- It was 5 s — several sentences of typing during which no expansion fires and
-- the buffer stops tracking the screen. The check is three CGEventTapIsEnabled
-- reads on a timer, nowhere near the keystroke path, so buying back four
-- seconds of dead typing costs nothing worth measuring.
local TAP_WATCHDOG_SEC = 1
local _watchdog_timer  = nil
-- Post-boot window-filter prewarm timer. Held so M.stop() can cancel it: a reload
-- during the quiet window otherwise left it armed to fire into a torn-down engine.
local _prewarm_timer   = nil

-- Delay before prewarming the ignored-window watchers off the keystroke path.
-- Short enough to almost always beat the user's first keystroke, long enough to
-- clear the heaviest synchronous boot deferrals first (see M.start).
local WINFILTER_PREWARM_SEC = 1.0

local tap_watchdog

local function eventtap_is_enabled(name, event_tap)
	if not event_tap or type(event_tap.isEnabled) ~= "function" then
		Logger.error(LOG, "Keymap %s eventtap has no verifiable native state.", name)
		return false, false
	end
	local ok, enabled = pcall(event_tap.isEnabled, event_tap)
	if not ok then
		Logger.error(LOG, "Keymap %s eventtap state probe failed: %s.", name, tostring(enabled))
		return false, false
	end
	return enabled == true, true
end


local function start_eventtap(name, event_tap)
	if not event_tap or type(event_tap.start) ~= "function" then
		Logger.error(LOG, "Keymap %s eventtap cannot be started.", name)
		return false
	end
	local ok, result = pcall(event_tap.start, event_tap)
	if not ok then
		Logger.error(LOG, "Keymap %s eventtap start failed: %s.", name, tostring(result))
		return false
	end
	local enabled, state_ok = eventtap_is_enabled(name, event_tap)
	if not state_ok or not enabled then
		Logger.error(LOG, "Keymap %s eventtap start did not commit.", name)
		return false
	end
	return true
end


local function stop_eventtap(name, event_tap)
	if not event_tap or type(event_tap.stop) ~= "function" then
		Logger.error(LOG, "Keymap %s eventtap cannot be stopped.", name)
		return false
	end
	local ok, result = pcall(event_tap.stop, event_tap)
	if not ok then
		Logger.error(LOG, "Keymap %s eventtap stop failed: %s.", name, tostring(result))
		return false
	end
	local enabled, state_ok = eventtap_is_enabled(name, event_tap)
	if not state_ok or enabled then
		Logger.error(LOG, "Keymap %s eventtap stop did not commit.", name)
		return false
	end
	return true
end


local function watchdog_is_running(timer)
	if not timer then return false end
	if type(timer.running) == "function" then
		local ok, running = pcall(timer.running, timer)
		return ok and running == true
	end
	return timer.running == true
end


local function stop_watchdog()
	local timer = _watchdog_timer
	if not timer then return true end
	if type(timer.stop) ~= "function" then
		Logger.error(LOG, "Keymap watchdog has no stop capability.")
		return false
	end
	local ok, result = pcall(timer.stop, timer)
	if not ok then
		Logger.error(LOG, "Keymap watchdog stop failed: %s.", tostring(result))
		return false
	end
	if watchdog_is_running(timer) then
		Logger.error(LOG, "Keymap watchdog stop did not commit.")
		return false
	end
	_watchdog_timer = nil
	return true
end


local function start_watchdog()
	if not stop_watchdog() then return false end
	local ok_new, timer = pcall(hs.timer.new, TAP_WATCHDOG_SEC, tap_watchdog)
	if not ok_new or not timer or type(timer.start) ~= "function" then
		Logger.error(LOG, "Keymap watchdog creation failed: %s.", tostring(timer))
		return false
	end
	_watchdog_timer = timer
	local ok_start, result = pcall(timer.start, timer)
	if not ok_start then
		Logger.error(LOG, "Keymap watchdog start failed: %s.", tostring(result))
		stop_watchdog()
		return false
	end
	if not watchdog_is_running(timer) then
		Logger.error(LOG, "Keymap watchdog start did not commit.")
		stop_watchdog()
		return false
	end
	return true
end


local function taps_are_enabled()
	return eventtap_is_enabled("keyDown", tap)
		and eventtap_is_enabled("loopbackKeyUp", loopback_keyup_tap)
		and eventtap_is_enabled("flagsChanged", shift_tap)
		and eventtap_is_enabled("mouse", mouse_tap)
end


tap_watchdog = function()
	-- Timer allocation in the HID callback is best-effort. This periodic path is
	-- the independent retry that guarantees a closed observation-gap latch cannot
	-- strand predictions forever.
	if _context_reconcile_pending and _context_reconcile_timer == nil then
		reconcile_observed_context_async()
	end
	local function revive(name, t)
		if t and not eventtap_is_enabled(name, t) then
			-- The passive mouse tap only resets predictive state and its recovery never
			-- interrupts typing, so reserve WARNING for the typing-critical taps
			local recovery_logger = name == "mouse" and Logger.debug or Logger.warn
			recovery_logger(LOG, "macOS disabled the %s event tap — re-enabling.", name)
			return start_eventtap(name, t)
		end
		return false
	end
	local keydown_revived = revive("keyDown", tap)
	revive("loopbackKeyUp", loopback_keyup_tap)
	revive("flagsChanged", shift_tap)
	revive("mouse", mouse_tap)
	-- Only the keyDown tap feeds the buffer, so only its outage invalidates it.
	if keydown_revived then invalidate_observed_context() end
end

--- Starts the eventtap listeners and attaches them to the OS event queue.
function M.start()
	if _started and taps_are_enabled() and watchdog_is_running(_watchdog_timer) then return true end
	if _started or _action_listener_registered or _watchdog_timer
		or eventtap_is_enabled("keyDown", tap)
		or eventtap_is_enabled("loopbackKeyUp", loopback_keyup_tap)
		or eventtap_is_enabled("flagsChanged", shift_tap)
		or eventtap_is_enabled("mouse", mouse_tap)
	then
		Logger.warn(LOG, "Keymap start found partial native ownership — rolling it back before retry.")
		if M.stop() ~= true then
			Logger.error(LOG, "Keymap start refused: partial ownership could not be rolled back.")
			return false
		end
	end
	if not _action_listener_registered then
		-- Register the last fully safe epoch, not the current one. If an action
		-- occurred while taps were stopped, the adapter immediately schedules the
		-- async reset instead of falsely acknowledging that unreset token.
		local listener_ok, listener_result = pcall(SyntheticInput.register_action_listener,
			ACTION_EPOCH_LISTENER_ID, reconcile_action_epoch_async, _last_action_epoch)
		if not listener_ok or listener_result ~= true then
			Logger.error(LOG, "Keymap action-listener start failed: %s.", tostring(listener_result))
			M.stop()
			return false
		end
		_action_listener_registered = true
		observe_action_epoch(SyntheticInput.current_action_epoch())
	end
	Logger.start(LOG, "Starting keymap engine…")
	-- Auto-arm latency sampling when the log level is already DEBUG so the user
	-- gets measurements without any console intervention. In production (INFO or
	-- WARNING) _enabled stays false and Perf.is_enabled() in onKeyDown short-circuits
	-- in a single table read — zero steady-state cost.
	if Logger.is_enabled(Logger.LEVELS.DEBUG) then
		Perf.set_enabled(true)
		Logger.info(LOG, "Perf sampling auto-enabled (DEBUG log level active).")
	end
	local tap_specs = {
		{ "keyDown", tap },
		{ "loopbackKeyUp", loopback_keyup_tap },
		{ "flagsChanged", shift_tap },
		{ "mouse", mouse_tap },
	}
	for _, spec in ipairs(tap_specs) do
		if not start_eventtap(spec[1], spec[2]) then
			Logger.error(LOG, "Keymap start rolled back after %s eventtap failure.", spec[1])
			M.stop()
			return false
		end
	end

	-- Arm the independent backstop for any tap still observed disabled.
	if not start_watchdog() then
		Logger.error(LOG, "Keymap start rolled back after watchdog failure.")
		M.stop()
		return false
	end

	-- Prewarm the ignored-window watchers off the keystroke path. hs.window.filter
	-- enumerates every open window on first use (~3 s cold); paid lazily inside the
	-- first keyDown it blocks the tap long enough for macOS to disable it. A short
	-- timer pays the cost on the main loop during the quiet post-boot window so the
	-- user's first keystroke is already warm.
	if _prewarm_timer then _prewarm_timer:stop() end
	_prewarm_timer = hs.timer.doAfter(WINFILTER_PREWARM_SEC, function()
		_prewarm_timer = nil
		pcall(km_utils.prewarm_ignored_win_watchers)
	end)

	_started = true
	Logger.success(LOG, "Keymap engine started.")
	return true
end

--- Stops the eventtap listeners and cleans up prediction state.
function M.stop()
	Logger.start(LOG, "Stopping keymap engine…")
	_started = false
	local listener_stopped = true
	if _action_listener_registered then
		local ok, result = pcall(SyntheticInput.unregister_action_listener, ACTION_EPOCH_LISTENER_ID)
		listener_stopped = ok and result ~= false
		if listener_stopped then
			_action_listener_registered = false
		else
			Logger.error(LOG, "Keymap action-listener stop did not commit (result: %s).", tostring(result))
		end
	end
	local watchdog_stopped = stop_watchdog()
	if _context_reconcile_timer then
		pcall(function() _context_reconcile_timer:stop() end)
		_context_reconcile_timer = nil
	end
	_context_reconcile_pending = false
	-- Cancelled here, before km_utils.stop() below, so there is no window in which
	-- the prewarm can fire into an engine that has already been torn down.
	if _prewarm_timer then _prewarm_timer:stop(); _prewarm_timer = nil end
	-- Release a held terminator BEFORE the taps go down. Its release signal is a
	-- synthetic echo arriving through the keyDown tap, so stopping first would
	-- strand it until the watchdog expired — into a torn-down engine, or after a
	-- reload, or never. The user pressed that key; it must not evaporate because
	-- the engine was toggled off a few milliseconds later.
	local replay_ok, replay_result = xpcall(function()
		return TerminatorReplay.flush_now("keymap engine stopping")
	end, debug.traceback)
	local terminator_settled = replay_ok and replay_result ~= false
	if not terminator_settled then
		Logger.error(LOG, "Pending terminator teardown did not commit (result: %s).", tostring(replay_result))
	end
	CoreState.buffer = ""
	CoreState.start_is_word_boundary = false
	cancel_action_preview_recovery()
	local taps_stopped = stop_eventtap("keyDown", tap)
	if not stop_eventtap("loopbackKeyUp", loopback_keyup_tap) then taps_stopped = false end
	if not stop_eventtap("flagsChanged", shift_tap) then taps_stopped = false end
	if not stop_eventtap("mouse", mouse_tap) then taps_stopped = false end
	local reset_ok, reset_result = xpcall(LLMBridge.reset_for_teardown, debug.traceback)
	local predictions_reset = reset_ok and reset_result == true
	if not predictions_reset then
		Logger.error(LOG, "LLM teardown reset did not commit (result: %s).", tostring(reset_result))
	end
	-- Stop the escape trap so it does not intercept Escape after reload
	-- (escape-trap-ghost-tap).
	local trap_ok, trap_result = xpcall(LLMBridge.stop, debug.traceback)
	local escape_trap_stopped = trap_ok and trap_result == true
	if not escape_trap_stopped then
		Logger.error(LOG, "LLM Escape-trap teardown did not commit (result: %s).", tostring(trap_result))
	end
	-- Unsubscribe focus-change watchers so callbacks do not accumulate across
	-- reloads (watcher-leak-on-reload).
	km_utils.stop()

	-- CoreState.interceptors and CoreState.preview_providers are deliberately NOT
	-- cleared here. Their only writers are M.register_interceptor and
	-- M.register_preview_provider, called once at boot by dynamic_hotstrings;
	-- M.start() restarts the taps, watchdog and prewarm but has no way to
	-- re-register them. Wiping them on stop() therefore made a disable/enable
	-- cycle ("Tout désactiver" then "Tout activer") permanently kill @-tag
	-- expansion and the dynamic-hotstring preview until a full reload, while
	-- static TOML hotstrings kept working — so the breakage looked arbitrary.
	-- They are already inert while stopped: both are only consulted from
	-- onKeyDownRaw, which cannot run once the tap is stopped.

	local stopped = listener_stopped and watchdog_stopped and terminator_settled
		and taps_stopped and predictions_reset and escape_trap_stopped
	if stopped then
		Logger.success(LOG, "Keymap engine stopped.")
	else
		Logger.error(LOG, "Keymap engine teardown remains incomplete and retryable.")
	end
	return stopped
end

return M
