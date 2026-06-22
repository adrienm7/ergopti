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
;   uninterruptible via Critical, while the two Sleep-ing paths (the UIA wrap and
;   the Notepad clipboard send) stay OUT of Critical (a Sleep would yield and break
;   the guarantee). If a future edit drops any of those Critical calls, the
;   fast-typing reorder / expansion interleave silently returns: this test makes
;   that loud.
;
; SCOPE: source introspection of modules/keymap/layout.ahk, the prefix watcher and the
;   hotstring engine (timing/concurrency cannot be reproduced in the synchronous
;   headless harness, so the structural guarantee is what we pin).
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
	WatcherFile := WindowsDir . "\lib\hotstrings\hotstring_prefix_watcher.ahk"
	W := ""
	try W := FileRead(WatcherFile)
	Assert(W != "", "hotstring_prefix_watcher.ahk must be readable")

	OnCharPos := InStr(W, "_OnPrefixChar(IH, Char) {")
	Assert(OnCharPos > 0, "watcher must define _OnPrefixChar(IH, Char)")
	FeedPos := InStr(W, "HSE_FeedChar(Char)", , OnCharPos)
	Assert(FeedPos > 0, "_OnPrefixChar must call HSE_FeedChar(Char)")
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

	; --- Dispatch: atomic burst Critical; Notepad (Sleeps) releases Critical ---
	EngineFile := WindowsDir . "\lib\hotstrings\hotstring_engine_main.ahk"
	E := ""
	try E := FileRead(EngineFile)
	Assert(E != "", "hotstring_engine_main.ahk must be readable")

	DispPos := InStr(E, "HSE_DispatchMatch(Spec, EndChar) {")
	Assert(DispPos > 0, "engine must define HSE_DispatchMatch(Spec, EndChar)")
	Assert(InStr(E, 'Critical("On")', , DispPos) > 0,
		"HSE_DispatchMatch atomic send must be wrapped in Critical On so non-OnChar callers (e.g. the Space tap-hold) serialize too")
	Assert(InStr(E, 'Critical("Off")', , DispPos) > 0,
		"HSE_DispatchMatch Notepad branch must release Critical Off -- it Sleeps (clipboard), and Critical must not span a Sleep")
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
; serialized with Critical("On"). The symbol-callback branch must stay OUT of
; Critical because those callbacks may Sleep (ActivateHotstrings).
_MIS_CheckLayerDispatchCritical() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\modules\keymap\layout\layout_shift_caps.ahk")
	Assert(Src != "", "layout_shift_caps.ahk must be readable")

	Body := _DriverFuncBody("LayerDispatch")
	Assert(Body != "", "LayerDispatch(SC, SymbolMap, *) must exist in layout_shift_caps.ahk")

	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0, "LayerDispatch must call Critical(On) before the letter emit (HIGH-01)")
	EmitPos := InStr(Body, "SendNewResult(SHIFTED_LETTERS")
	Assert(EmitPos > 0, "LayerDispatch must emit SHIFTED_LETTERS via SendNewResult")
	Assert(CritPos < EmitPos,
		"LayerDispatch must enter Critical(On) BEFORE SendNewResult(SHIFTED_LETTERS) so the letter emit serializes (HIGH-01)")

	; The symbol-callback branch (Cb()) must NOT be preceded by Critical — those
	; callbacks may Sleep (ActivateHotstrings) and a Sleep under Critical breaks
	; the no-yield guarantee. Cb() appears before the letter emit in source order.
	CbPos := InStr(Body, "Cb()")
	Assert(CbPos > 0, "LayerDispatch must still invoke the symbol callback Cb()")
	Assert(CbPos < CritPos,
		"LayerDispatch must NOT enter Critical before the symbol callback Cb() — symbol callbacks may Sleep (HIGH-01)")
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
