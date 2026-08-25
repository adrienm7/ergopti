; tests/meta/test_expansion_burst_atomic.ahk

; ==============================================================================
; MODULE: Expansion Burst Atomicity Meta Test
; DESCRIPTION:
; Guards the two mechanisms that keep the Windows driver free of the typing
; corruption the macOS driver had to be repaired for in July 2026:
;
;   1. "pex*" producing "pexar exemple" — the erase and the replacement reaching
;      the target as separate, unordered injections, so the backspaces were lost
;      or applied in the wrong place.
;   2. Characters vanishing while typing — a physical key delivered in the gap
;      between two parts of an expansion and spliced into its middle (the
;      historical "outpubct" / "Cha[letter]tGPT" reports).
;
; Windows is immune to both, and the immunity is structural rather than
; incidental:
;
;   * ONE SendInput carries the whole burst — backspaces, replacement and
;     end-char. SendInput is atomic, so a physical keystroke typed during the
;     expansion is buffered by the OS and delivered AFTER it, never spliced into
;     it. The pre-2026 code sent BackSpace, Replacement and EndChar as three
;     separate SendInputs with interleave gaps between them, and those gaps were
;     the corruption source.
;   * Critical wraps the match -> fire -> buffer-sync region, so AHK cannot start
;     the next physical key's remap thread until the burst has drained.
;
; Neither property is expressible as a runtime assertion — nothing observable
; distinguishes "one atomic send" from "three sends that happened not to be
; interrupted this time" — so both are pinned at source level here. A refactor
; that splits the burst, or drops the Critical, fails this test instead of
; silently reintroducing a corruption class that took a full audit to diagnose.
;
; See docs/PROJECT_MEMORY.md, project-typing-order-and-atomicity.
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ The burst is assembled, then sent once ===========
; =============================================================
; =============================================================

_EBA_AssertBurstIsAssembledWhole() {
	; Comment-stripped: the module header above and the dispatch file's own
	; commentary both spell out "SendInput", and a raw scan would count prose.
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the burst-atomicity meta-test")

	; The three parts are concatenated into one payload before any send happens.
	Assert(InStr(Src, "Burst := BackSpaceSeq . ReplacementPart . EndCharPart") > 0,
		"the erase, the replacement and the end-char must be concatenated into ONE payload before "
		. "being sent. Emitting them as separate injections is what let the backspaces go missing "
		. "and let a physical keystroke land in the middle of the replacement")

	; The production path must hand that payload to one kernel SendInput, while
	; the recorder path consumes the same transaction verdict. Keeping both in
	; the dispatch body pins atomicity and the AHK-04 failure boundary together.
	Dispatch := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Dispatch != "", "HSE_DispatchMatch must exist in the driver source")
	SendPos := InStr(Dispatch, "SendInput(Burst)")
	Assert(SendPos > 0 and InStr(Dispatch, "SendInput(Burst)", , SendPos + 1) = 0,
		"the assembled burst must reach exactly one SendInput — splitting the erase, replacement "
		. "and terminator is what lets a physical key splice into an expansion")
	Assert(InStr(Dispatch,
		'Fired := _SendVerdictSucceeded(Hook("SendFinalResult", Burst, false))') > 0,
		"the recorder path must publish the same atomic burst only after its sender reports success")
}
Test("hotstrings: the expansion burst is one atomic SendInput (typing-order-atomicity)", _EBA_AssertBurstIsAssembledWhole)


_EBA_AssertEndCharRidesTheSameBurst() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the burst-atomicity meta-test")

	; The end-char must be resolved into a variable that the burst concatenates,
	; never emitted by a send of its own. A second send for the terminator is
	; exactly the macOS defect: Enter reached the host before the replacement and
	; submitted the pre-expansion line.
	Assert(InStr(Src, "EndCharPart := (EndChar != ") > 0,
		"the end-char must be resolved into EndCharPart for the burst to concatenate")

	Assert(!InStr(Src, "SendInput(EndChar"),
		"the end-char must NEVER be sent on its own. Enter and Tab act on arrival — a separate "
		. "send races the replacement, and the host submits the line as it was before the "
		. "expansion (the macOS terminator-before-expansion defect)")
	Assert(!InStr(Src, "SendEvent(EndChar"),
		"same for SendEvent: one burst, or the terminator overtakes the text it terminates")
}
Test("hotstrings: the end-char is never sent separately from the burst (terminator-before-expansion)", _EBA_AssertEndCharRidesTheSameBurst)




; =============================================================
; =============================================================
; ======= 2/ No physical key can land inside the burst ========
; =============================================================
; =============================================================

_EBA_AssertDispatchRegionIsCritical() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the burst-atomicity meta-test")

	; Critical is taken around the send itself, and restored in a finally so a
	; throwing send cannot leave the interpreter uninterruptible.
	Assert(InStr(Src, "_AtCrit := Critical(") > 0,
		"the atomic send must run under Critical, so AHK cannot start the next physical key's "
		. "remap thread while the burst is still draining")
	Assert(InStr(Src, "Critical(_AtCrit)") > 0,
		"and the previous Critical state must be restored — a latched Critical starves the "
		. "keyboard hook for the rest of the session")
}
Test("hotstrings: the atomic send runs under a restored Critical (typing-order-atomicity)", _EBA_AssertDispatchRegionIsCritical)


_EBA_AssertProvenanceFilterNotATimeWindow() {
	; The synthetic-input filter must classify by PROVENANCE, not by elapsed time.
	; A time window also discards the user's real keystrokes right after an
	; expansion — the same defect the macOS driver carried until July 2026, where
	; it dropped any key typed within 20 ms of the previous one from the buffer and
	; the next expansion then backspaced over the user's own text.
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the burst-atomicity meta-test")

	Assert(InStr(Src, 'InputHook("V L0 I1")') > 0,
		"the prefix watcher must keep the I1 provenance filter: it drops the driver's own "
		. "SendLevel-0 injections while preserving every physical key. The 60 ms time window it "
		. "replaced also threw away real typing that arrived just after an expansion")
}
Test("hotstrings: synthetic input is filtered by provenance, not by a time window (swallowed-keystrokes)", _EBA_AssertProvenanceFilterNotATimeWindow)




; =============================================================
; =============================================================
; ======= 3/ Terminal TUIs receive paced deletion =============
; =============================================================
; =============================================================

_EBA_AssertTerminalTuiDeletionIsPaced() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the terminal-TUI regression test")

	; React/OpenTUI-style prompt controls can batch a zero-delay Backspace run
	; against one stale render. The replacement then appends to the untouched
	; trigger (for example xgboostXGBoost). Terminal hosts therefore need one
	; protected transaction made of explicitly paced events while ordinary
	; controls retain the zero-latency SendInput path above. SetKeyDelay plus a
	; compact ``{BackSpace N}`` is specifically insufficient: AHK expands those
	; repetitions without an observable delay between them.
	Assert(InStr(Src, "_HSE_IsTerminalInputHost") > 0,
		"the hotstring dispatcher must classify terminal input hosts before choosing its sender")
	Assert(InStr(Src, "_HSE_BeginOwnedTerminalTransaction(") > 0,
		"the terminal branch must defer the behavior-tested edit beyond the visible InputHook callback")
	Assert(InStr(Src, 'Burst .= "{BackSpace}"') > 0,
		"terminal deletion must expand each Backspace token; repeat-count syntax bypasses pacing")
	Assert(InStr(Src, 'SetTimer(Runner, -Max(1, Floor(Owner["DelayMs"])))') > 0,
		"the paced sender must run on a later timer turn so sleeps can yield real render opportunities")
	Assert(InStr(Src, "LLM_NavEventOwner_BeginTerminalCapture") > 0,
		"the terminal owner must acquire the native physical-input capture before scheduling")
	Assert(InStr(Src, "BlockInput(") == 0,
		"terminal pacing must not discard physical input through BlockInput Send mode")
	Assert(InStr(Src, "SendEvent(Burst)") > 0,
		"all explicit deletions and replacement text must remain one protected SendEvent command")
}
Test("hotstrings: terminal TUI deletion uses explicit paced events in one protected transaction (terminal-stale-render)",
	_EBA_AssertTerminalTuiDeletionIsPaced)
