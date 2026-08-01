; infra/app_state.ahk

; ==============================================================================
; MODULE: Application State
; DESCRIPTION:
; Documents where the driver's mutable cross-module runtime state actually
; lives, so there is exactly one copy of each field and no parallel structure
; that can silently diverge from it.
;
; This module deliberately declares NO state of its own. An earlier design
; introduced an "AppState" Map plus typed accessors here as a consolidation
; target, but the cut-over was never performed: every consumer kept reading and
; writing the plain top-level globals instead. Two parallel copies of the same
; conceptual fields (one in the globals, one in the Map) is a single-source-of-
; truth trap — wiring one caller to the Map while another stays on the global
; yields two diverging counters with no compile error. The Map and its accessors
; were therefore unused dead code, so they are not present.
;
; CANONICAL HOMES OF EACH STATE FIELD (the single source of truth):
; 1. NumberOfRepetitions, ActivitySimulation, OneShotShiftEnabled,
;    RemappedList, LastSentCharacterKeyTime and the pruning thresholds
;    LAST_SENT_KEY_TIME_MAX_AGE_MS / LAST_SENT_KEY_TIME_PRUNE_AT are declared
;    once in ErgoptiPlus.ahk (Variables initialization).
; 2. The repetition counter is mutated only through SetNumberOfRepetitions /
;    ResetNumberOfRepetitions in infra/nav_layer_helpers.ahk.
; 3. last_sent_key_time tracking (write + size-bounded pruning) lives only in
;    UpdateLastSentCharacter / _PruneLastSentKeyTime in modules/keymap/layout.ahk.
;
; RULE: do not reintroduce a parallel state container here. If a future refactor
; genuinely consolidates these globals, move the declarations into a single
; owner and route every site through it — never leave both alive at once.
; ==============================================================================

#Requires AutoHotkey v2.0
