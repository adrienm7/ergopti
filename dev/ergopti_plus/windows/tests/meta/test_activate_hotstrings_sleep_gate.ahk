; tests/meta/test_activate_hotstrings_sleep_gate.ahk

; ==============================================================================
; MODULE: ActivateHotstrings Sleep-Gate Meta Test
; DESCRIPTION:
; Static source guard for the finding
; activate-hotstrings-sleep-on-keyboard-thread.
;
; ActivateHotstrings() pokes the hotstring engine with a space/backspace dance
; and, in production (no _SendHook), parks the keyboard dispatch thread for
; ACTIVATE_HOTSTRINGS_DELAY_MS (50 ms) so the injected space's char event can
; round-trip through the prefix-watcher InputHook before the backspace lands.
; That blocking Sleep ran on EVERY Shift French-punctuation key (the most
; common French-typography keys: ":", ";", "!", "?", and the NNBSP+symbol pair),
; a hot, default key set — perceptible per-key latency and occasional interleave.
;
; The fix gates the whole dance (and its Sleep) on there actually being a
; pending abbreviation in the engine buffer: when HSE_Buffer is empty there is
; nothing to commit, so ActivateHotstrings() returns early and emits no space,
; no backspace and no Sleep. This test asserts that the empty-buffer guard sits
; BEFORE the space poke so the Sleep can never run on a punctuation key typed at
; a word boundary or after a space (the common case).
;
; Meta-static (scans source text) so it cannot be defeated by a recorder-hook
; install ordering change and never executes the production Sleep path.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_AHSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Gate assertions =======================
; ==================================================
; ==================================================

_AHSG_GateBeforePoke() {
	Src := _AHSG_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Seg := _DriverFuncBody("ActivateHotstrings")
	Assert(Seg != "", "ActivateHotstrings() declaration must exist in hotstring_engine.ahk")

	; The empty-buffer gate must reference HSE_Buffer.
	GateIdx := InStr(Seg, "HSE_Buffer")
	Assert(GateIdx > 0,
		"ActivateHotstrings must gate the poke on HSE_Buffer — the 50 ms Sleep must not run on every Shift punctuation key when no abbreviation is pending")

	; The gate must sit BEFORE the space poke, so an empty buffer returns early
	; and never reaches SendNewResult(" ") nor the Sleep.
	PokeIdx := InStr(Seg, "SendNewResult(" . Chr(0x22) . " " . Chr(0x22) . ")")
	Assert(PokeIdx > 0, "ActivateHotstrings must still emit the space poke when an abbreviation IS pending")
	Assert(GateIdx < PokeIdx,
		"the HSE_Buffer gate must precede the space poke so an empty buffer skips both the poke and the blocking Sleep")
}
Test("hotstring_engine: ActivateHotstrings gates the Sleep poke on a pending HSE_Buffer (activate-hotstrings-sleep-on-keyboard-thread)", _AHSG_GateBeforePoke)

_AHSG_GuardReturnsEarly() {
	Src := _AHSG_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Seg := _DriverFuncBody("ActivateHotstrings")
	; Slice from the function head to the first space poke: the early-return that
	; skips the dance on an empty buffer must live in that prologue.
	PokeIdx := InStr(Seg, "SendNewResult(" . Chr(0x22) . " " . Chr(0x22) . ")")
	Assert(PokeIdx > 0, "space poke must exist in ActivateHotstrings")
	Prologue := SubStr(Seg, 1, PokeIdx - 1)
	Assert(InStr(Prologue, "return") > 0,
		"ActivateHotstrings must early-return before the poke when HSE_Buffer is empty — otherwise the blocking Sleep still runs on the keyboard thread")
	Assert(InStr(Prologue, "==") > 0 and InStr(Prologue, Chr(0x22) . Chr(0x22)) > 0,
		"the gate must test HSE_Buffer for emptiness (== empty string) before returning")
}
Test("hotstring_engine: ActivateHotstrings early-returns on empty HSE_Buffer (activate-hotstrings-sleep-on-keyboard-thread)", _AHSG_GuardReturnsEarly)

_AHSG_PokeIsAtomicWithoutSleep() {
	Seg := _DriverFuncBody("ActivateHotstrings")
	Assert(Seg != "", "ActivateHotstrings() declaration must exist")
	Assert(!RegExMatch(Seg, "\bSleep\s*\("),
		"ActivateHotstrings must not Sleep on the keyboard thread between its synthetic space and backspace")
	OnPos := InStr(Seg, 'Critical("On")')
	SpacePos := InStr(Seg, 'SendNewResult(" ")')
	BackspacePos := InStr(Seg, 'SendNewResult("{BackSpace}", False)')
	RestorePos := InStr(Seg, "Critical(previous_critical)")
	Assert(OnPos > 0 && SpacePos > OnPos && BackspacePos > SpacePos && RestorePos > BackspacePos,
		"ActivateHotstrings must keep the synthetic space/backspace pair inside a Critical transaction and restore the caller state afterwards")
}

Test("hotstring_engine: ActivateHotstrings emits the poke atomically without keyboard-thread Sleep", _AHSG_PokeIsAtomicWithoutSleep)
