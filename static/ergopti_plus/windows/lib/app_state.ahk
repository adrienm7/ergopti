; drivers/autohotkey/lib/app_state.ahk

; ==============================================================================
; MODULE: Application State
; DESCRIPTION:
; Single-source-of-truth for all mutable runtime state that is shared across
; modules. Replaces the scattered top-level globals that were previously
; declared in ErgoptiPlus.ahk and read implicitly by every #Include'd module.
;
; FEATURES & RATIONALE:
; 1. Explicit ownership: every piece of cross-module mutable state is declared
;    here with a comment explaining its purpose and invariants. Modules that
;    need to read or write it reference AppState directly, making dependencies
;    visible in code rather than hidden by AHK's implicit global lookup.
; 2. Typed accessors: public setter functions (AppState_SetNumberOfRepetitions,
;    AppState_ResetNumberOfRepetitions, etc.) centralise validation and logging
;    so callers never write raw Map assignments scattered across the codebase.
; 3. Constants co-located: the immutable thresholds that govern AppState fields
;    (LAST_SENT_KEY_TIME_MAX_AGE_MS, LAST_SENT_KEY_TIME_PRUNE_AT) are declared
;    here so they sit next to the data they govern rather than floating at the
;    top of the entry script.
; 4. Test-friendly: the test runner seeds AppState via AppState_Reset() before
;    each test suite, giving it the same starting state as a fresh driver boot
;    without having to re-include ErgoptiPlus.ahk.
;
; NOT included here: CapsWordEnabled and LayerEnabled. Those two globals must
; remain plain AHK globals because they are referenced in #HotIf expressions
; evaluated by the AHK parser before any function can run — the parser does not
; support Map member access in #HotIf conditions.
; ==============================================================================





; ============================================================
; ============================================================
; ======= 1/ State declaration and constant thresholds =======
; ============================================================
; ============================================================

; Any entry older than this many milliseconds is definitionally useless to the
; time-activation check — no hotstring in the codebase uses a window close to
; this. Kept as a constant so pruning is deterministic and easy to tune.
global LAST_SENT_KEY_TIME_MAX_AGE_MS := 60000

; Pruning triggers when the map exceeds this size. ~150 covers ASCII + French
; accents + control-key sentinels ("LAlt", "BackSpace"…) with room to spare.
global LAST_SENT_KEY_TIME_PRUNE_AT := 150

; Single global Map owning all mutable cross-module runtime state.
; Fields must not be added outside this file — open a PR to app_state.ahk
; so the ownership intention stays explicit and auditable.
global AppState := Map(
	; -- Layout / hotstring tracking ------------------------------------------
	; Map<Character, A_TickCount> — timestamp of the last time each character
	; was sent. Used by IsTimeActivationExpired() to gate time-based hotstrings
	; and by the LAlt tap-hold to distinguish tap vs hold.
	"last_sent_key_time", Map(),

	; Map<Character, ScanCode> — populated by RemapKey() for every key that has
	; been remapped to an Ergopti layout position. Read by GetRemapScanCode() to
	; resolve the raw scancode for a character before building a hotkey combo.
	"remapped_list", Map(),

	; -- Navigation layer ------------------------------------------------------
	; Integer — Vim-style repetition counter. ActionLayer() resets to 1 after
	; each action; number keys in the nav layer increment it before the action.
	"number_of_repetitions", 1,

	; -- Feature toggle state (session-only) -----------------------------------
	; Boolean — true while the keep-awake activity simulation is running.
	; Written by StartActivitySimulation / StopActivitySimulation; read by the
	; simulation tick callback and the gesture shortcut.
	"activity_simulation", false,

	; Boolean — true between an OneShotShift keypress and the next character.
	; OneShotShiftFix() clears it when the key is used as a chord modifier.
	"one_shot_shift_enabled", false,

	; -- TOML serialisation lock -----------------------------------------------
	; Boolean — guards against re-entrant calls to TOML_RunStrictCanonicalization
	; while SaveFullConfig is already mid-flight. Never persisted; always false
	; at driver startup.
	"toml_strict_canon_in_progress", false,
)





; ============================================
; ============================================
; ======= 2/ Public accessor functions =======
; ============================================
; ============================================

; Returns the number of repetitions for the next nav-layer action.
AppState_GetNumberOfRepetitions() {
	return AppState["number_of_repetitions"]
}

; Sets the repetition counter. Logs at DEBUG level so keystroke traces are
; available when diagnosing nav-layer behaviour.
AppState_SetNumberOfRepetitions(NewNumber) {
	AppState["number_of_repetitions"] := NewNumber
	try LoggerDebug("AppState", "number_of_repetitions = %s.", NewNumber)
}

; Resets the repetition counter to 1 (the post-action default).
AppState_ResetNumberOfRepetitions() {
	AppState_SetNumberOfRepetitions(1)
}

; Updates the timestamp for a sent character and prunes stale entries.
; This is the sole write path for "last_sent_key_time" — call it from
; UpdateLastSentCharacter() only.
AppState_TouchLastSentKey(Character) {
	AppState["last_sent_key_time"][Character] := A_TickCount
	if AppState["last_sent_key_time"].Count > LAST_SENT_KEY_TIME_PRUNE_AT {
		AppState_PruneLastSentKeyTime()
	}
}

; Removes entries older than LAST_SENT_KEY_TIME_MAX_AGE_MS from the
; last_sent_key_time Map. Called automatically by AppState_TouchLastSentKey
; when the map grows past LAST_SENT_KEY_TIME_PRUNE_AT entries.
AppState_PruneLastSentKeyTime() {
	Cutoff := A_TickCount - LAST_SENT_KEY_TIME_MAX_AGE_MS
	; Two-pass because AHK v2 Map does not support deletion mid-iteration
	ToDelete := []
	for Char, Ts in AppState["last_sent_key_time"] {
		if Ts < Cutoff {
			ToDelete.Push(Char)
		}
	}
	for _, Char in ToDelete {
		AppState["last_sent_key_time"].Delete(Char)
	}
}

; Resets AppState to its boot defaults. Called by the test runner before each
; suite so tests never bleed state into each other.
AppState_Reset() {
	AppState["last_sent_key_time"]          := Map()
	AppState["remapped_list"]               := Map()
	AppState["number_of_repetitions"]       := 1
	AppState["activity_simulation"]         := false
	AppState["one_shot_shift_enabled"]      := false
	AppState["toml_strict_canon_in_progress"] := false
}
