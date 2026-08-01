; tests/meta/test_input_serialization.ahk

; ==============================================================================
; MODULE: Keystroke-Path Critical-Serialization Test
; DESCRIPTION:
; Guards that the keystroke hot path is Critical-serialized so fast typing cannot
; reorder characters, and a hotstring expansion cannot be interleaved with the
; keys typed right after the trigger.
;
; WHY THIS MATTERS (the regression this encodes):
;   Every remapped key re-emits its char via SendEvent (SendMode is "Event"
;   globally, for cascade), and A_MaxThreads is high. Without Critical, two fast
;   keys start overlapping remap threads whose SendEvents interleave in the single
;   OS input queue -> "comme" comes out "cmooe"; and a following key can splice
;   into an in-flight expansion burst -> "trigger"+"bc" -> "outpubct". The fix is
;   to make the per-key remap (_RemapEmit), the watcher fire region (_OnPrefixChar
;   before HSE_FeedChar) and the dispatch's atomic send (HSE_DispatchMatch)
;   uninterruptible via Critical. The Notepad clipboard path now uses one
;   Prefix . "^v" SendInput burst, so it too stays under Critical; only genuine
;   message-pumping waits (such as UIA selection) must release it. If a future edit drops any of those Critical calls, the
;   fast-typing reorder / expansion interleave silently returns: this test makes
;   that loud.
;
; SCOPE: source introspection of modules/keymap/layout.ahk, the prefix watcher and the
;   hotstring engine (timing/concurrency cannot be reproduced in the synchronous
;   headless harness, so the structural guarantee is what we pin). The god-file
;   split (334b5c04a) turned hotstring_prefix_watcher.ahk and
;   hotstring_engine_main.ahk into thin shims that #Include their sub-modules
;   (hotstring_inputhook.ahk and hotstring_dispatch.ahk respectively), so both
;   FileReads below are folded together with infra/hotstrings dir concat.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckInputSerialization() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	; --- Layout remaps must serialize each per-key SendEvent via _RemapEmit ---
	LayoutFile := WindowsDir . "\modules\keymap\layout.ahk"
	Lay := ""
	try Lay := FileRead(LayoutFile)
	Assert(Lay != "", "modules\keymap\layout.ahk must be readable for the input-serialization meta-test")

	EmitPos := InStr(Lay, "_RemapEmit(SendStr")
	Assert(EmitPos > 0, "layout.ahk must define the serialized remap handler _RemapEmit(SendStr, KeyChar, *)")
	; _RemapEmit must enter Critical BEFORE its SendEvent so AHK cannot start the
	; next key's remap thread mid-send (the fast-typing reorder, "comme"->"cmooe").
	RemapKeyPos := InStr(Lay, "RemapKey(ScanCode")
	Assert(RemapKeyPos > EmitPos, "RemapKey(ScanCode ...) must follow the _RemapEmit definition")
	EmitCritPos := InStr(Lay, 'Critical("On")', , EmitPos)
	Assert(EmitCritPos > 0 and EmitCritPos < RemapKeyPos,
		"_RemapEmit must call Critical On before SendEvent so per-key sends serialize")
	; RemapKey must BIND _RemapEmit, not a bare reorder-prone SendEvent lambda.
	Assert(InStr(Lay, "_RemapEmit.Bind("),
		"RemapKey must bind _RemapEmit for its remap hotkeys")
	Assert(!InStr(Lay, '(*) => SendEvent("{Blind}"'),
		"the bare '(*) => SendEvent(...)' per-key remap must be gone -- it reorders under fast typing")

	; --- Watcher: the match -> fire -> buffer region must be Critical ---
	WatcherFile := WindowsDir . "\infra\hotstrings\hotstring_prefix_watcher.ahk"
	WShim := ""
	try WShim := FileRead(WatcherFile)
	Assert(WShim != "", "hotstring_prefix_watcher.ahk must be readable")
	; hotstring_prefix_watcher.ahk is a shim (#Include hotstring_inputhook.ahk +
	; hotstring_registry.ahk) -- _OnPrefixChar / _PrefixRenderFlush live in the
	; included sub-module, so fold in the whole infra/hotstrings dir.
	W := WShim . _DriverDirConcat("infra/hotstrings")

	OnCharPos := InStr(W, "_OnPrefixChar(IH, Char) {")
	Assert(OnCharPos > 0, "watcher must define _OnPrefixChar(IH, Char)")
	FeedPos := InStr(W, "HSEMatch := HSE_FeedChar(Char, true)", , OnCharPos)
	Assert(FeedPos > 0, "_OnPrefixChar must feed the physical Char through HSE_FeedChar with provenance")
	OnCharCritPos := InStr(W, 'Critical("On")', , OnCharPos)
	Assert(OnCharCritPos > 0 and OnCharCritPos < FeedPos,
		"_OnPrefixChar must enter Critical On before HSE_FeedChar so the fire + expansion burst is uninterruptible")

	; The debounced render must skip while a burst is in flight (TooltipShow pumps
	; the message loop and could otherwise straddle an expansion).
	FlushPos := InStr(W, "_PrefixRenderFlush() {")
	Assert(FlushPos > 0, "watcher must define _PrefixRenderFlush()")
	GuardPos := InStr(W, "_PrefixWatcherSuppressed or HSE_Suppressed", , FlushPos)
	LookupPos := InStr(W, "_LookupAndRender()", , FlushPos)
	Assert(GuardPos > 0 and LookupPos > 0 and GuardPos < LookupPos,
		"_PrefixRenderFlush must early-return while suppressed, before _LookupAndRender")

    ; --- Dispatch: every erase/output burst, including Notepad, is Critical ---
	EngineFile := WindowsDir . "\infra\hotstrings\hotstring_engine_main.ahk"
	EShim := ""
	try EShim := FileRead(EngineFile)
	Assert(EShim != "", "hotstring_engine_main.ahk must be readable")
	; hotstring_engine_main.ahk is likewise a shim -- HSE_DispatchMatch lives in
	; the included hotstring_dispatch.ahk sub-module.
	E := EShim . _DriverDirConcat("infra/hotstrings")

	DispPos := InStr(E, "HSE_DispatchMatch(Spec, EndChar) {")
	Assert(DispPos > 0, "engine must define HSE_DispatchMatch(Spec, EndChar)")
	Assert(InStr(E, 'Critical("On")', , DispPos) > 0,
		"HSE_DispatchMatch atomic send must be wrapped in Critical On so non-OnChar callers (e.g. the Space tap-hold) serialize too")
}

Test("meta input: keystroke path is Critical-serialized (no fast-typing reorder / expansion interleave)",
	_MetaCheckInputSerialization)




; =====================================
; =====================================
; ======= 2/ Layer dispatchers ========
; =====================================
; =====================================

; HIGH-01: LayerDispatch (Shift/CapsLock layer) re-emitted SHIFTED_LETTERS via
; SendNewResult with no Critical, so a second fast key could start its remap
; thread mid-send and reorder the output. The pure-letter emit path must now be
; serialized with Critical("On"). BOTH real layer registrations now pass
; SerializeSymbols=true: the old "SHIFT_SYMBOLS callbacks may Sleep" exemption rested
; on a premise that has since rotted — ActivateHotstrings no longer Sleeps and runs
; under its own Critical. Leaving the Shift layer unserialized let a neighbouring
; remapped-letter emit (itself Critical) preempt between the two halves of an
; NNBSP+symbol pair and transpose them when typing fast (F28). The generic
; unserialized else arm survives as an opt-out default and is still asserted to stay
; out of Critical; the premise-guard below fails if a Sleep is ever reintroduced.
_MIS_CheckLayerDispatchCritical() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\modules\keymap\layout\layout_shift_caps.ahk")
	Assert(Src != "", "layout_shift_caps.ahk must be readable")

	Body := _DriverFuncBody("LayerDispatch")
	Assert(Body != "", "LayerDispatch(SC, SymbolMap, SerializeSymbols, *) must exist in layout_shift_caps.ahk")

	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0, "LayerDispatch must call Critical(On) before the letter emit (HIGH-01)")
	EmitPos := InStr(Body, "SendNewResult(SHIFTED_LETTERS")
	Assert(EmitPos > 0, "LayerDispatch must emit SHIFTED_LETTERS via SendNewResult")
	Assert(CritPos < EmitPos,
		"LayerDispatch must enter Critical(On) BEFORE SendNewResult(SHIFTED_LETTERS) so the letter emit serializes (HIGH-01)")

	; The generic unserialized arm — the "else" of the SerializeSymbols conditional —
	; is the opt-out default (no real layer uses it any more). It must stay OUT of
	; Critical so a future opt-out caller whose callback DOES yield is never forced
	; under a no-yield guarantee.
	ElsePos := InStr(Body, "} else {")
	Assert(ElsePos > 0 and ElsePos < EmitPos,
		"LayerDispatch must have an else branch (SerializeSymbols=false) for the unserialized symbol callback")
	ElseCbPos := InStr(Body, "Cb()", , ElsePos)
	Assert(ElseCbPos > 0 and ElseCbPos < EmitPos,
		"LayerDispatch's else branch must still invoke the symbol callback Cb()")
	ElseBlockEnd := InStr(Body, "}", , ElseCbPos)
	ElseBlock := SubStr(Body, ElsePos, ElseBlockEnd - ElsePos)
	Assert(!InStr(ElseBlock, "Critical("),
		"LayerDispatch's opt-out else branch must NOT wrap Cb() in Critical — it exists for callers whose callback may yield")

	; The serialized (CAPSLOCK_SYMBOLS) branch — SerializeSymbols=true — must wrap
	; its Cb() in Critical, since none of those callbacks ever Sleep
	; (layer-dispatch-capslock-symbols-unserialized).
	IfSerPos := InStr(Body, "if SerializeSymbols")
	Assert(IfSerPos > 0 and IfSerPos < ElsePos,
		"LayerDispatch must gate symbol serialization on a SerializeSymbols flag (layer-dispatch-capslock-symbols-unserialized)")
	IfSerCritPos := InStr(Body, 'Critical("On")', , IfSerPos)
	IfSerCbPos := InStr(Body, "Cb()", , IfSerPos)
	Assert(IfSerCritPos > 0 and IfSerCbPos > 0 and IfSerCritPos < IfSerCbPos and IfSerCbPos < ElsePos,
		"LayerDispatch's SerializeSymbols branch must enter Critical(On) BEFORE Cb() so CAPSLOCK_SYMBOLS "
		. "callbacks serialize against neighbouring remapped-letter emits (layer-dispatch-capslock-symbols-unserialized)")

	; F28: the Shift layer must OPT IN too. Leaving it unserialized let a neighbouring
	; remapped-letter emit (itself Critical) preempt between the NNBSP and the symbol of
	; a French punctuation pair, transposing or splitting them when typing fast.
	Assert(InStr(Src, "LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true)") > 0,
		"RegisterShiftLayer must bind the Shift layer with SerializeSymbols=true so an NNBSP+symbol pair cannot be split by a neighbouring emit (F28)")
	Assert(InStr(Src, "LayerDispatch.Bind(SC, SHIFT_SYMBOLS)") = 0,
		"no Shift-layer binding may omit SerializeSymbols — an unserialized symbol emit re-opens the interleave window (F28)")

	; Premise guard: serializing is only safe while those callbacks never yield. If a
	; Sleep is ever reintroduced into ActivateHotstrings, this fails and forces the
	; serialization decision to be revisited instead of silently breaking no-yield.
	Activate := _DriverFuncBody("ActivateHotstrings")
	Assert(Activate != "", "ActivateHotstrings must exist in infra/hotstrings/hotstring_send.ahk")
	Assert(InStr(Activate, "Sleep(") = 0,
		"ActivateHotstrings must not Sleep: the Shift layer now runs its callbacks under Critical, and a Sleep under Critical breaks the no-yield guarantee (revisit F28 if this changes)")
}

; HIGH-01: AltGrShiftDispatch invoked its AltGr emit callback with no Critical,
; so a fast follow-up key could interleave its remap SendEvent. The Cb() emit
; must now be serialized with Critical("On") just before the call.
_MIS_CheckAltGrShiftDispatchCritical() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\modules\keymap\layout\layout_altgr.ahk")
	Assert(Src != "", "layout_altgr.ahk must be readable")

	Body := _DriverFuncBody("AltGrShiftDispatch")
	Assert(Body != "", "AltGrShiftDispatch(SC, Table, *) must exist in layout_altgr.ahk")

	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0, "AltGrShiftDispatch must call Critical(On) before its emit (HIGH-01)")
	CbPos := InStr(Body, "Cb()")
	Assert(CbPos > 0, "AltGrShiftDispatch must invoke the emit callback Cb()")
	Assert(CritPos < CbPos,
		"AltGrShiftDispatch must enter Critical(On) BEFORE Cb() so the AltGr emit serializes (HIGH-01)")
}

Test("meta input: LayerDispatch serializes letter emit with Critical (HIGH-01)",
	_MIS_CheckLayerDispatchCritical)
Test("meta input: AltGrShiftDispatch serializes emit with Critical (HIGH-01)",
	_MIS_CheckAltGrShiftDispatchCritical)

; F-M02: the two AltGr roll handlers (SC138&SC012, SC138&SC017) are a parallel AltGr
; emit path registered directly via _RegisterRollsAltGrHotkeys (NOT via
; AltGrShiftDispatch), so the HIGH-01 Critical hardening missed them. Their pure
; SendEvent emits must be serialized through _RollEmitCritical; the WrapTextIfSelected
; branch must stay OUT of Critical (it Sleeps).
_MIS_CheckRollHandlersCritical() {
	Helper := _DriverFuncBody("_RollEmitCritical")
	Assert(Helper != "", "_RollEmitCritical(Text, Record) must exist (AltGr roll emit serialization)")
	HCrit := InStr(Helper, 'Critical("On")')
	HEmit := InStr(Helper, "SendNewResult(")
	Assert(HCrit > 0 and HEmit > 0 and HCrit < HEmit,
		"_RollEmitCritical must enter Critical(On) before SendNewResult so roll emits serialize (remap-emit-critical-uneven)")
	Assert(InStr(Helper, "finally") > 0,
		"_RollEmitCritical must restore Critical in a finally so a throw cannot leak Critical")

	; Each roll handler/builder must route its pure emit through _RollEmitCritical and
	; contain NO bare SendNewResult( — a bare emit would be un-serialized (the bug).
	for Fn in ["_RollChevronEqualHandler", "AddRollEqual", "_RollHashtagQuoteHandler", "HashtagOrQuote"] {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist in layout.ahk")
		Assert(!InStr(Body, "SendNewResult("),
			Fn . " must not emit via a bare SendNewResult( — route pure emits through _RollEmitCritical so they serialize (F-M02 remap-emit-critical-uneven)")
	}

	; The Sleep-y WrapTextIfSelected branch must remain a direct call in the two builders.
	Assert(InStr(_DriverFuncBody("AddRollEqual"), "WrapTextIfSelected(") > 0,
		"AddRollEqual must keep its WrapTextIfSelected branch (out of Critical)")
	Assert(InStr(_DriverFuncBody("HashtagOrQuote"), "WrapTextIfSelected(") > 0,
		"HashtagOrQuote must keep its WrapTextIfSelected branch (out of Critical)")
}
Test("meta input: AltGr roll handlers serialize emits via _RollEmitCritical (F-M02 remap-emit-critical-uneven)",
	_MIS_CheckRollHandlersCritical)




; =====================================
; =====================================
; ======= 3/ Dead-key wait release ====
; =====================================
; =====================================

; F6: LayerDispatch's SerializeSymbols path and AltGrShiftDispatch's unconditional
; wrap both invoke dead-key callbacks from inside Critical("On"). ih.Wait() is a
; blocking, message-pumping InputHook wait with up to a 2s timeout ("L1 T2") --
; running it under Critical stalls the ENTIRE AHK message pump (every hotkey and
; timer in the process) for up to 2 seconds on every CapsLock dead-key press.
; DeadKey must release Critical before the wait and restore it only after
; (deadkey-wait-under-critical-stalls-pump).
_MIS_CheckDeadKeyReleasesCriticalBeforeWait() {
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) must exist in layout.ahk")

	WaitPos := InStr(Body, "ih.Wait()")
	Assert(WaitPos > 0, "DeadKey must call ih.Wait()")

	OffPos := InStr(Body, 'Critical("Off")')
	Assert(OffPos > 0 and OffPos < WaitPos,
		'DeadKey must call Critical("Off") before ih.Wait() so the blocking wait does not stall '
		. "the message pump when a caller (LayerDispatch/AltGrShiftDispatch) dispatched it under Critical (F6)")

	RestorePos := InStr(Body, "Critical(_AtCrit)")
	Assert(RestorePos > WaitPos,
		"DeadKey must restore the caller's Critical setting via Critical(_AtCrit) AFTER ih.Wait() completes, "
		. "so the final emit (SendNewResult) below is still serialized as the caller intended (F6)")

	; The release must be scoped to a try/finally around the InputHook creation and
	; Wait() call, so an exception during ih.Start()/Wait() cannot leave the thread
	; stuck with Critical permanently released or never restored.
	FinallyPos := InStr(Body, "finally")
	Assert(FinallyPos > 0 and FinallyPos > OffPos and FinallyPos < RestorePos,
		"DeadKey must restore Critical inside a finally block wrapping ih.Start()/ih.Wait(), "
		. "not an unconditional statement after Wait() (F6)")
}
Test("meta input: DeadKey releases Critical before the blocking ih.Wait() and restores it after (F6 deadkey-wait-under-critical-stalls-pump)",
	_MIS_CheckDeadKeyReleasesCriticalBeforeWait)




; =====================================
; =====================================
; ======= 4/ Notepad atomic clipboard guard ==
; =====================================
; =====================================

; Guards that the clipboard/SendInstant compatibility branch is still selected only
; for notepad.exe AND has the same atomicity as the regular path. The historical
; branch released Critical, erased with SendEvent, then pasted separately; a
; physical key could land in that gap. This test pins the Prefix . "^v" transaction
; so a future compatibility edit cannot reintroduce the interleave.
_MIS_CheckNotepadClipboardBranchIsAtomic() {
	Body := _DriverFuncBody("HSE_DispatchMatch")
	Assert(Body != "", "HSE_DispatchMatch(Spec, EndChar) must exist")

	; The IsNotepadApp gate must exist.
	IsNotepadPos := InStr(Body, "IsNotepadApp")
	Assert(IsNotepadPos > 0,
        "HSE_DispatchMatch must gate the Notepad clipboard branch on IsNotepadApp")

	; The non-atomic branch must reference notepad.exe.
	NotepadExePos := InStr(Body, "notepad.exe")
	Assert(NotepadExePos > 0,
        "the IsNotepadApp check must be keyed on 'notepad.exe' — no other app must take the compatibility path")

	; The else branch (atomic path) must contain SendInput with Critical On.
	ElsePos := InStr(Body, "} else {", , InStr(Body, "if IsNotepadApp"))
	Assert(ElsePos > 0,
		"HSE_DispatchMatch must have an else branch (atomic path) after the Notepad check")
	ElseBlockStart := ElsePos
	NextSectionEnd := InStr(Body, "HSE_ApplyExpansion", , ElseBlockStart)
	ElseBlock := SubStr(Body, ElseBlockStart, (NextSectionEnd > 0 ? NextSectionEnd : StrLen(Body)) - ElseBlockStart)
	Assert(InStr(ElseBlock, "SendInput") > 0,
		"the atomic else branch must use SendInput (not SendEvent/SendInstant)")
	Assert(InStr(ElseBlock, 'Critical("On")') > 0,
		"the atomic else branch must enter Critical On before the SendInput burst")

    ; The Notepad branch must retain Critical and emit erase+paste through one
    ; SendInstant transaction. No separate SendNewResult erase is permitted.
	IfBlockStart := InStr(Body, "if IsNotepadApp")
	IfBlockEnd := InStr(Body, "} else {", , IfBlockStart)
	IfBlock := SubStr(Body, IfBlockStart, IfBlockEnd - IfBlockStart)
    Assert(InStr(IfBlock, 'Critical("On")') > 0,
        "the Notepad branch must retain Critical through its non-blocking clipboard injection")
    Assert(InStr(IfBlock, "SendInstant(Replacement . EndCharEmitted, BackSpaceSeq)") > 0,
        "the Notepad branch must send erase and clipboard paste as one SendInstant transaction")
    Assert(InStr(IfBlock, "SendNewResult(BackSpaceSeq") = 0,
        "the Notepad branch must not issue a separate SendEvent erase before the paste")
}

Test("meta input: Notepad clipboard branch remains atomic (clipboard/SendInstant gate)",
    _MIS_CheckNotepadClipboardBranchIsAtomic)
